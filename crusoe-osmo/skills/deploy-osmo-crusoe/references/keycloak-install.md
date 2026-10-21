# Phase 10 — Authentication (Keycloak — the default; opt-out only)

Part of the deploy-osmo-crusoe skill. osmo-install.md's Phase 10, in its own reference so the default install never loads it. Gate: Keycloak runs by default  —
the user opted out in provision.md Phase 1h only if they explicitly said so. If they did, skip with "The gateway stays public with no login;
only the Phase 9 firewall rule stands between the internet and admin." Design rationale and every value: [keycloak.md](keycloak.md).
Everything below has been executed and verified end-to-end.


Start with the pin check (see "Inputs and conventions").

**Never print:** the Keycloak admin password, the postgres password, the `osmo-browser-flow` client secret and the oauth2-proxy cookie secret. Each lives only in its Kubernetes Secret — same rule as every other secret in this file.

**a. Keycloak database and secrets.** Create the database on OSMO's own Postgres, then the two Secrets (values only through shell variables):

```bash
# The keycloak namespace must exist before any secret lands in it.
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
# The role password reaches psql via stdin, never argv (the -c form would put the
# cleartext password in kubectl's and psql's process args).
kubectl exec -n osmo deploy/postgres -- psql -U postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='keycloak'" | grep -q 1 || {
  KC_DB_PASS=$(openssl rand -hex 24)
  printf "CREATE ROLE keycloak LOGIN PASSWORD '%s';\n" "$KC_DB_PASS" | \
    kubectl exec -i -n osmo deploy/postgres -- psql -U postgres -v ON_ERROR_STOP=1
  # Secrets reach kubectl via --from-file (a umask-077 temp file), never argv:
  # --from-literal=KEY="$VAL" would put the cleartext value in kubectl's
  # process args (ps/audit), the same exposure class as --env.
  umask 077
  KC_DB_FILE=$(mktemp /tmp/.kc-db.XXXXXX); printf '%s' "$KC_DB_PASS" > "$KC_DB_FILE"
  kubectl create secret generic keycloak-db-secret -n keycloak \
    --from-file=postgres-password="$KC_DB_FILE" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$KC_DB_FILE"; unset KC_DB_PASS
}
kubectl exec -n osmo deploy/postgres -- psql -U postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='keycloak'" | grep -q 1 || \
  kubectl exec -n osmo deploy/postgres -- psql -U postgres -c "CREATE DATABASE keycloak OWNER keycloak;"
kubectl exec -n osmo deploy/postgres -- psql -U postgres -tAc \
  "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='keycloak'" | grep -q keycloak || \
  kubectl exec -n osmo deploy/postgres -- psql -U postgres -c "ALTER DATABASE keycloak OWNER TO keycloak;"
KC_ADMIN_PASS=$(openssl rand -hex 24)
umask 077
KC_ADMIN_FILE=$(mktemp /tmp/.kc-admin.XXXXXX); printf '%s' "$KC_ADMIN_PASS" > "$KC_ADMIN_FILE"
kubectl create secret generic keycloak-admin-password -n keycloak \
  --from-file=password="$KC_ADMIN_FILE" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$KC_ADMIN_FILE"; unset KC_ADMIN_PASS
```

**Keycloak gets its own least-privilege role (`keycloak`), not OSMO's `postgres` superuser** — OSMO's Postgres password is readable from several pods in the cluster (README Limitations), and handing the superuser credential to the internet-exposed identity provider would let any of those principals (or a Keycloak compromise) reach OSMO's own tables. The chart connects as `externalDatabase.user: keycloak` (set in both the bootstrap values below and `keycloak.md` §3c).

**b. Bootstrap install to obtain the Keycloak LB IP** (Phase 4's minimal-install pattern: the final values pin `hostname: <KC_LB_IP>`, which is only knowable once the Service exists):

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"; mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
cat > "$WORKDIR/keycloak-bootstrap-values.yaml" <<'EOF'
global:
  security:
    allowInsecureImages: true
image:
  registry: docker.io
  repository: bitnamilegacy/keycloak
  tag: 26.1.1-debian-12-r0
auth:
  adminUser: admin
  existingSecret: keycloak-admin-password
  passwordSecretKey: password
postgresql:
  enabled: false
externalDatabase:
  host: postgres.osmo.svc.cluster.local
  port: 5432
  user: keycloak
  database: keycloak
  existingSecret: keycloak-db-secret
  existingSecretPasswordKey: postgres-password
nodeSelector:
  osmo-type: control
service:
  type: LoadBalancer
  annotations:
    crusoe.ai/manage-firewall-rule: "true"
EOF
helm upgrade --install keycloak bitnami/keycloak --version 24.4.9 \
  -n keycloak -f "$WORKDIR/keycloak-bootstrap-values.yaml"
KC_IP=""
for i in $(seq 1 120); do
  KC_IP=$(kubectl get svc keycloak -n keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$KC_IP" ] && break
  sleep 5
done
[ -n "$KC_IP" ] && echo "$KC_IP" > "$WORKDIR/kc_ip" \
  || { echo "no Keycloak LB IP after 10 minutes; check the crusoe-lb-controller"; exit 1; }
```

**b2. Firewall the Keycloak LB (hard step).** Keycloak's own LB is
public; it fronts the login and every token refresh, so it gets the same
source restriction as the gateway, using the SAME CIDR list the user gave for
the gateway in Phase 9:

```bash
KC_FW_ID=$(kubectl get svc keycloak -n keycloak -o jsonpath='{.metadata.annotations.crusoe\.ai/firewall-rule-id}')
# Restrict ONLY the sources — keep the rule's nodePort destinations (same
# reason as the Phase 9 gateway step: the controller targets the Service's
# nodePorts; --destination-ports 443 breaks external reachability, observed
# live on crusoe v1.0.9).
crusoe networking vpc-firewall-rules update "$KC_FW_ID" --sources <same cidrs as the gateway> --protocols tcp \
  --destination-ports "$(crusoe networking vpc-firewall-rules get "$KC_FW_ID" --json | jq -r '.destination_ports | join(",")')"
crusoe networking vpc-firewall-rules get "$KC_FW_ID"   # report the sources in effect
```

Same caveat as the gateway: the rule is controller-managed and may be reset by
a later Service change — re-check after every `helm upgrade keycloak`.

**c. Certificate, final values, port patch.** Write `$WORKDIR/keycloak-values.yaml` by hand, substituting `<KC_LB_IP>` with the IP above — the exact file (keycloak.md §3c is the annotated rationale). **Do not derive it from the bootstrap file**: the final values differ from step b's `keycloak-bootstrap-values.yaml` in exactly these ways — `hostname: <KC_LB_IP>` ADDED (absent from the bootstrap file by design; the LB IP did not exist yet), `production: true` and the whole `tls:` block ADDED, `ingress:` block ADDED, `service.http.enabled: false` and `service.ports.https: 8443` CHANGED. A copy-then-append merge of the two files silently drops the hostname line (the single most load-bearing value — every token issuer is keyed to it) and ships Keycloak with a broken issuer; the assert below catches it. The bootstrap file has no line you would carry over unchanged except the image/auth/database blocks:

```yaml
global:
  security:
    allowInsecureImages: true
image:
  registry: docker.io
  repository: bitnamilegacy/keycloak
  tag: 26.1.1-debian-12-r0
auth:
  adminUser: admin
  existingSecret: keycloak-admin-password
  passwordSecretKey: password
tls:
  enabled: true
  usePem: true
  existingSecret: keycloak-tls
hostname: <KC_LB_IP>
production: true
# `proxy` unset and no KC_HTTP_ENABLED=false — the probes target 8080 (§2a Exposure).
autoscaling:
  enabled: false
nodeSelector:
  osmo-type: control
ingress:
  enabled: false
service:
  type: LoadBalancer
  # http off: no cleartext port on the LB (§2a Exposure).
  http:
    enabled: false
  ports:
    https: 8443
  annotations:
    crusoe.ai/manage-firewall-rule: "true"
postgresql:
  enabled: false
externalDatabase:
  host: postgres.osmo.svc.cluster.local
  port: 5432
  user: keycloak
  database: keycloak
  existingSecret: keycloak-db-secret
  existingSecretPasswordKey: postgres-password
resources:
  requests: {cpu: 500m, memory: 512Mi}
  limits: {cpu: "2", memory: 1Gi}
```

Before applying anything, assert the file is the FINAL shape, not a bootstrap copy:

```bash
KC_IP=$(cat "$WORKDIR/kc_ip")
grep -q "^hostname: $KC_IP$" "$WORKDIR/keycloak-values.yaml" \
  || { echo "keycloak-values.yaml has no hostname: $KC_IP line - it is a bootstrap copy or the substitution failed; rewrite step c by hand"; exit 1; }
grep -q '^production: true' "$WORKDIR/keycloak-values.yaml" || { echo "production: true missing"; exit 1; }
grep -q 'existingSecret: keycloak-tls' "$WORKDIR/keycloak-values.yaml" || { echo "tls block missing"; exit 1; }
grep -q 'https: 8443' "$WORKDIR/keycloak-values.yaml" || { echo "service.ports.https: 8443 missing"; exit 1; }
```

Then:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
KC_IP=$(cat "$WORKDIR/kc_ip")
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: keycloak
spec:
  secretName: keycloak-tls
  issuerRef:
    name: osmo-selfsigned
    kind: ClusterIssuer
  commonName: "$KC_IP"
  ipAddresses:
    - "$KC_IP"
  dnsNames:
    - "keycloak"
    - "keycloak.keycloak"
    - "keycloak.keycloak.svc"
    - "keycloak.keycloak.svc.cluster.local"
    - "localhost"
  duration: 8760h
  renewBefore: 720h
EOF
kubectl wait certificate/keycloak-tls -n keycloak --for=condition=Ready --timeout=300s
helm upgrade keycloak bitnami/keycloak -n keycloak --version 24.4.9 \
  -f "$WORKDIR/keycloak-values.yaml"
# Idempotent: `op: add` on /spec/ports/- always appends, so a re-run (this block
# must be re-applied after every `helm upgrade keycloak`) would add a duplicate
# `https-443` port and the API server rejects the Service. Guard on the port's
# presence.
kubectl -n keycloak get svc keycloak -o jsonpath='{.spec.ports[?(@.name=="https-443")].port}' | grep -q 443 || \
  kubectl -n keycloak patch svc keycloak --type=json \
    -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"https-443","port":443,"targetPort":"https"}}]'
kubectl rollout status sts/keycloak -n keycloak --timeout=300s
kubectl wait pod/keycloak-0 -n keycloak --for=condition=Ready --timeout=300s
```

The `https-443: 443 → 8443` port is what makes in-cluster `https://keycloak.keycloak.svc/...` work for Envoy's JWKS fetch (keycloak.md §2a). **Re-apply the patch after every later `helm upgrade keycloak`** — a later upgrade can conflict with the patch and reset the Service.

**`commonName: "$KC_IP"` on the Certificate is required, not cosmetic**: without it cert-manager issues a certificate with an empty subject/issuer DN, and Keycloak 26.1.1 (bitnamilegacy image, Temurin JDK) crash-loops at startup with `VertxException: CertificateParsingException: Empty issuer DN not allowed in X509Certificates` — the pod never becomes Ready. If a Keycloak install crash-loops with that exact error, `kubectl get secret keycloak-tls -n keycloak -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject` showing `subject=` confirms it: add the `commonName`, re-apply the Certificate, and `kubectl rollout restart sts/keycloak -n keycloak`.

**d. Realm import + client edits.** The `osmo-browser-flow` client secret in the sample realm is the literal placeholder `**Verified****Verified****`; the real one is generated in step e. Import the realm and fix both clients against the gateway IP (full-representation fetch-modify-put, so nothing else gets clobbered). **The admin password reaches the pod through stdin, never argv** — on the host (`kubectl exec` has no `--env` flag, verified against kubectl 1.36.3, and an `--env=KC_ADMIN_PASS=…`-style argv would put the cleartext password in `ps`/audit logs) and inside the pod too (the token mint pipes the password as the request body via stdin, so it is in no `curl` argv). In-pod `curl` calls carry the admin bearer token, so they verify against the pod's own certificate (`--cacert /opt/bitnami/keycloak/certs/tls.crt`) instead of `-k` — which is why the Certificate gains a `localhost` SAN (step c).

**The in-pod script needs `jq` — but the `bitnamilegacy/keycloak` image ships none**. Two escape hatches, in order: (1) if the image does have `jq`, run the block below as-is; (2) if it does not, run the same flow from the host against `kubectl -n keycloak port-forward pod/keycloak-0 18443:8443` with a stdlib-python (no `jq`) port of the same five calls, keeping every stdin/password rule (the admin token mint posts the password in the request body; the regenerated client secret is captured into a umask-077 temp file, never printed). Verify with `kubectl exec -n keycloak keycloak-0 -- which jq || echo NOJQ` before choosing. **When porting these blocks, substitute the real shell variables — `$TOKEN`, `$BROWSER`, `$DEVICE`, `$KC_ADMIN_PASS` — never a redacted rendering.** A harness that displays this document with `***` in place of variable values (secret-redacting renderers do this) produces a script that mints no token and 401s every call; observed live: a literal `Bearer ***` header fails the realm import with 401 and the role grant with a JWT-format error. If your view of this file shows `***` where the source shows `$TOKEN`, read the raw file (`git show`, `sed`) instead of the rendered view.

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
KC_IP=$(cat "$WORKDIR/kc_ip")
OSMO_LB_IP=$(cat "$WORKDIR/lb_ip")
curl -fsSL -o "$WORKDIR/sample_osmo_realm.json" \
  https://nvidia.github.io/OSMO/release/6.3/_downloads/3af0bbc2b0a3138cfb6a4258b5f336a5/sample_osmo_realm.json
kubectl cp -n keycloak "$WORKDIR/sample_osmo_realm.json" keycloak-0:/tmp/osmo-realm.json
{
  echo "KC_ADMIN_PASS=$(kubectl get secret keycloak-admin-password -n keycloak -o jsonpath='{.data.password}' | base64 -d)"
  echo "OSMO_LB_IP=$OSMO_LB_IP"
  cat <<'EOF'
set -e
KC_CERT=/opt/bitnami/keycloak/certs/tls.crt
# The password goes into the request body via stdin, not the curl argv. The
# admin password is openssl rand -hex (url-safe), so it needs no url-encoding.
TOKEN=$(printf 'grant_type=password&client_id=admin-cli&username=admin&password=%s' "$KC_ADMIN_PASS" | \
  curl -s --cacert "$KC_CERT" https://localhost:8443/realms/master/protocol/openid-connect/token \
  --data-binary @- | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "Keycloak admin token mint failed" >&2; exit 1; }
CODE=$(curl -s --cacert "$KC_CERT" -o /dev/null -w '%{http_code}' -X POST https://localhost:8443/admin/realms \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @/tmp/osmo-realm.json)
[ "$CODE" = "201" ] || [ "$CODE" = "409" ] || { echo "realm import returned $CODE (201 or 409 expected)" >&2; exit 1; }
BROWSER=$(curl -s --cacert "$KC_CERT" -H "Authorization: Bearer $TOKEN" https://localhost:8443/admin/realms/osmo/clients \
  | jq -r '.[] | select(.clientId=="osmo-browser-flow") | .id')
[ -n "$BROWSER" ] || { echo "osmo-browser-flow not found" >&2; exit 1; }
curl -s --cacert "$KC_CERT" -H "Authorization: Bearer $TOKEN" "https://localhost:8443/admin/realms/osmo/clients/$BROWSER" \
  | jq --arg u "https://$OSMO_LB_IP" '.rootUrl=$u | .baseUrl=$u | .adminUrl=$u
       | .redirectUris=[($u+"/oauth2/callback"),($u+"/api/auth/getAToken")]
       | .webOrigins=[$u]
       | .attributes["oauth2.device.authorization.grant.enabled"]="false"' > /tmp/browser-client.json
curl -s --cacert "$KC_CERT" -o /dev/null -X PUT "https://localhost:8443/admin/realms/osmo/clients/$BROWSER" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary @/tmp/browser-client.json
rm -f /tmp/browser-client.json
DEVICE=$(curl -s --cacert "$KC_CERT" -H "Authorization: Bearer $TOKEN" https://localhost:8443/admin/realms/osmo/clients \
  | jq -r '.[] | select(.clientId=="osmo-device") | .id')
[ -n "$DEVICE" ] || { echo "osmo-device not found" >&2; exit 1; }
curl -s --cacert "$KC_CERT" -H "Authorization: Bearer $TOKEN" "https://localhost:8443/admin/realms/osmo/clients/$DEVICE" \
  | jq --arg u "https://$OSMO_LB_IP" '.redirectUris=[($u+"/*")]
       | .attributes["oauth2.device.authorization.grant.enabled"]="true"' > /tmp/device-client.json
curl -s --cacert "$KC_CERT" -o /dev/null -X PUT "https://localhost:8443/admin/realms/osmo/clients/$DEVICE" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary @/tmp/device-client.json
rm -f /tmp/device-client.json
EOF
} | kubectl exec -i -n keycloak keycloak-0 -- bash -s
```

(The `KC_ADMIN_PASS=`/`OSMO_LB_IP=` lines precede the script on stdin and execute as its first lines, so the in-pod script sees them as environment-free shell variables. The in-pod admin token carries `iss=https://localhost:8443` — fine for the admin API; test tokens minted for the **gateway** must come from the host against the public IP instead, keycloak.md "Failure lessons".)

**e. Client secret + `keycloak-ca` + `oauth2-proxy-secrets`.** Generate the real `osmo-browser-flow` secret through Keycloak's admin API, capture it, and create both `osmo`-namespace Secrets — **one command, never printed** (shell state does not persist, and the value must not appear in any transcript):

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
kubectl get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORKDIR/keycloak-ca.crt"
[ -s "$WORKDIR/keycloak-ca.crt" ] || \
  kubectl get secret keycloak-tls -n keycloak -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORKDIR/keycloak-ca.crt"
kubectl -n osmo create secret generic keycloak-ca --from-file=ca.crt="$WORKDIR/keycloak-ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
KC_SECRET=; KC_ERR=0
# The captured secret must never sit in a world-readable file: a private temp
# file under the operator's umask, removed as soon as it is read.
umask 077
KC_SECRET_FILE=$(mktemp /tmp/.kc-secret.XXXXXX)
{
  echo "KC_ADMIN_PASS=$(kubectl get secret keycloak-admin-password -n keycloak -o jsonpath='{.data.password}' | base64 -d)"
  cat <<'EOF'
set -e
KC_CERT=/opt/bitnami/keycloak/certs/tls.crt
# The password goes into the request body via stdin, not the curl argv. The
# admin password is openssl rand -hex (url-safe), so it needs no url-encoding.
TOKEN=$(printf 'grant_type=password&client_id=admin-cli&username=admin&password=%s' "$KC_ADMIN_PASS" | \
  curl -s --cacert "$KC_CERT" https://localhost:8443/realms/master/protocol/openid-connect/token \
  --data-binary @- | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "Keycloak admin token mint failed" >&2; exit 1; }
BROWSER=$(curl -s --cacert "$KC_CERT" -H "Authorization: Bearer $TOKEN" https://localhost:8443/admin/realms/osmo/clients \
  | jq -r '.[] | select(.clientId=="osmo-browser-flow") | .id')
[ -n "$BROWSER" ] || { echo "osmo-browser-flow not found" >&2; exit 1; }
curl -s --cacert "$KC_CERT" -X POST "https://localhost:8443/admin/realms/osmo/clients/$BROWSER/client-secret" \
  -H "Authorization: Bearer $TOKEN" | jq -r .value
EOF
} | kubectl exec -i -n keycloak keycloak-0 -- bash -s > "$KC_SECRET_FILE" || KC_ERR=$?
[ "$KC_ERR" = 0 ] || { echo "client secret generation failed (kubectl exec exit $KC_ERR)"; rm -f "$KC_SECRET_FILE"; exit 1; }
KC_SECRET=$(cat "$KC_SECRET_FILE"); rm -f "$KC_SECRET_FILE"
# A failed in-pod step now exits non-zero with its diagnostics on stderr; this guard
# additionally rejects anything that is not a plausible single-line secret.
[ -n "$KC_SECRET" ] && [ "$KC_SECRET" != null ] && [ "$(printf '%s' "$KC_SECRET" | grep -c ' ')" = 0 ] \
  || { echo "client secret generation failed (implausible value)"; exit 1; }
# Secrets reach kubectl via --from-file (umask-077 temp files), never argv
# (--from-literal would put the values in kubectl's process args).
umask 077
KC_SECRET_FILE2=$(mktemp /tmp/.kc-cs.XXXXXX); printf '%s' "$KC_SECRET" > "$KC_SECRET_FILE2"
KC_COOKIE_FILE=$(mktemp /tmp/.kc-cookie.XXXXXX); printf '%s' "$(openssl rand -hex 16)" > "$KC_COOKIE_FILE"
# Secret keys are UNDERSCORE (client_secret, cookie_secret), never hyphens: the
# chart's gateway.yaml projects `- key: clientSecretKey | default "client_secret"`
# to the mounted file path client-secret (--client-secret-file=/etc/oauth2-proxy/
# client-secret) — hyphenated keys fail the volume projection and oauth2-proxy
# crash-loops on the missing file. keycloak-ca above must be a SECRET, not a
# ConfigMap: the chart mounts it with `secret: {secretName: keycloak-ca}`.
kubectl -n osmo create secret generic oauth2-proxy-secrets \
  --from-file=client_secret="$KC_SECRET_FILE2" \
  --from-file=cookie_secret="$KC_COOKIE_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$KC_SECRET_FILE2" "$KC_COOKIE_FILE"
unset KC_SECRET KC_ERR
```

(Use the `-hex 16` cookie recipe; the guide's `-base64 32` breaks the mounted cookie-secret file — keycloak.md §2c.)

**f. Gateway values, upgrade, mandatory restarts.** Edit `$WORKDIR/osmo-service-values.yaml` — apply these two blocks (all of it in this one file: Helm replaces list values across `-f` files, Phase 7).

The additions, in `keycloak.md §3a`'s order (gateway/envoy/jwt/oauth2Proxy/authz, then `services.service.auth`, then `ui`):

```yaml
gateway:
  name: crusoe
  envoy:
    # ... ssl / service / scaling / nodeSelector blocks unchanged ...
    idp:
      host: keycloak.keycloak.svc.cluster.local
    jwt:
      user_header: x-osmo-user
      providers:
      - issuer: https://<KC_LB_IP>/realms/osmo
        audience: account
        jwks_uri: https://keycloak.keycloak.svc.cluster.local/realms/osmo/protocol/openid-connect/certs
        user_claim: preferred_username
        cluster: idp
      - issuer: https://<KC_LB_IP>/realms/osmo
        audience: osmo-browser-flow
        jwks_uri: https://keycloak.keycloak.svc.cluster.local/realms/osmo/protocol/openid-connect/certs
        user_claim: preferred_username
        cluster: idp
      - issuer: https://<KC_LB_IP>/realms/osmo
        audience: osmo-device
        jwks_uri: https://keycloak.keycloak.svc.cluster.local/realms/osmo/protocol/openid-connect/certs
        user_claim: preferred_username
        cluster: idp
      - issuer: osmo
        audience: osmo
        jwks_uri: https://osmo-service/api/auth/keys
        user_claim: unique_name
        cluster: osmo-service-jwks
    defaultIdentity:
      user: ""         # MUST be emptied: with authz enabled the authz sidecar
      roles: ""        # sets identity and allowed pools from validated
      allowedPools: "" # JWTs + role policies
  # gateway.oauth2Proxy and gateway.authz are SIBLINGS of gateway.envoy in the
  # chart's values schema (2-space under gateway), NOT children of envoy. Nested
  # inside envoy, Helm silently drops the whole block and oauth2-proxy renders
  # from defaults (no issuer, no client id, no secret mounts) and crash-loops on
  # `open /etc/oauth2-proxy/cookie-secret: no such file or directory` while envoy
  # 403s everything with `ext_authz_error`. idp, jwt and
  # defaultIdentity DO belong inside envoy.
  oauth2Proxy:
    enabled: true
    provider: oidc
    oidcIssuerUrl: https://<KC_LB_IP>/realms/osmo
    clientId: osmo-browser-flow
    cookieDomain: ""
    scope: "openid email profile"
    useKubernetesSecrets: true
    secretName: oauth2-proxy-secrets
    clientSecretKey: client_secret
    cookieSecretKey: cookie_secret
    redis:
      serviceName: redis
      port: 6379
      tlsEnabled: false          # this install runs services.redis with tlsEnabled: false
      dbNumber: 0
    extraArgs:
    - --insecure-oidc-allow-unverified-email=true
    - --whitelist-domain=<KC_LB_IP>                # logout redirect target, chart README
    - --provider-ca-file=/etc/keycloak-ca/ca.crt
    - --oidc-email-claim=preferred_username        # §2b: sessions work without per-user email
    extraVolumes:
    - name: keycloak-ca
      secret: {secretName: keycloak-ca}
    extraVolumeMounts:
    - {name: keycloak-ca, mountPath: /etc/keycloak-ca}   # a DIRECTORY — never a subPath file inside the chart's read-only /etc/oauth2-proxy mount
  authz:
    enabled: true
```

**Indentation cross-check before every `helm upgrade`:** the three sibling blocks of the first yaml — `oauth2Proxy:` and `authz:` at 2 spaces under `gateway:`, while `idp:`, `jwt:` and `defaultIdentity:` sit at 4 spaces inside `envoy:`. YAML that nests oauth2Proxy/authz under envoy passes `helm upgrade` cleanly and produces a crash-looping oauth2-proxy (`open /etc/oauth2-proxy/cookie-secret: no such file or directory`) with envoy 403-ing every request (`ext_authz_error` + `UAEX` in the access log). If `helm get values osmo` shows a `gateway.envoy.oauth2Proxy` key after an upgrade, the block landed in the wrong place; `helm uninstall` of nothing is needed — fix the indentation and re-upgrade.

```yaml
services:
  service:
    auth:
      enabled: true
      device_endpoint: https://<KC_LB_IP>/realms/osmo/protocol/openid-connect/auth/device
      device_client_id: osmo-device
      browser_endpoint: https://<KC_LB_IP>/realms/osmo/protocol/openid-connect/auth
      browser_client_id: osmo-browser-flow
      token_endpoint: https://<KC_LB_IP>/realms/osmo/protocol/openid-connect/token
      logout_endpoint: https://<KC_LB_IP>/realms/osmo/protocol/openid-connect/logout
```

```yaml
ui:
    enabled: true
    apiHostname: crusoe:80        # in-cluster gateway name:80, NOT <LB_IP>:443
    nextjsSslEnabled: false       # matches apiHostname over in-cluster HTTP
```

(The `device_endpoint` path ends `/auth/device` — Keycloak 26 moved it from `/device`; the audience pairing and the rest of §3a's annotated rationale live in keycloak.md.)

The role policies block (keycloak.md §3d is the annotated rationale):

```yaml
services:
  configs:
    roles:
      osmo-user:
        description: "User role — standard workflow and data operations"
        policies:
        - effect: Allow
          actions:            # the chart-default policy, verbatim; do not trim it
          - app:*
          - auth:Token
          - credentials:*
          - dataset:*
          - pool:List
          - profile:Read
          - profile:Update
          - resources:Read
          - user:List
          - workflow:List
          - workflow:Read
          resources:
          - '*'
        - effect: Allow        # the ONLY addition: one workflow grant per GPU pool
          actions:
          - workflow:*
          resources:
          - pool/<pool_name>   # repeat per GPU pool (e.g. pool/h100, pool/default)
        external_roles:
        - osmo-user
      osmo-admin:
        # unchanged — chart default allows *:* on *
```

**CRITICAL CHART QUIRK: the chart renders only a SINGULAR `audience` per provider** — an `audiences:` list is silently ignored, and a provider whose audience never matches 401s every token it should accept. Audiences are token-kind, not client-kind (Keycloak access tokens: `account`; UI id_token: `osmo-browser-flow`; the CLI's device-flow id_token: `osmo-device`) — keycloak.md Failure lessons has the full mechanism.

Then upgrade with the Phase 5 service-install command **with all 7 `--set-string` flags** and restart the gateway components:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
: "${OSMO_ACCESS_KEY_ID:?export OSMO_ACCESS_KEY_ID first}" "${OSMO_ACCESS_KEY:?export OSMO_ACCESS_KEY first}"
PG_PASS=$(kubectl get secret osmo-postgres-password -n osmo -o jsonpath='{.data.password}' | base64 -d)
helm upgrade --install osmo osmo/service -n osmo \
  --version 1.3.1 \
  --set-string services.postgres.password="$PG_PASS" \
  -f "$WORKDIR/osmo-service-values.yaml" \
  --set-string services.configs.workflow.workflow_data.credential.access_key_id="$OSMO_ACCESS_KEY_ID" \
  --set-string services.configs.workflow.workflow_data.credential.access_key="$OSMO_ACCESS_KEY" \
  --set-string services.configs.workflow.workflow_log.credential.access_key_id="$OSMO_ACCESS_KEY_ID" \
  --set-string services.configs.workflow.workflow_log.credential.access_key="$OSMO_ACCESS_KEY" \
  --set-string services.configs.workflow.workflow_app.credential.access_key_id="$OSMO_ACCESS_KEY_ID" \
  --set-string services.configs.workflow.workflow_app.credential.access_key="$OSMO_ACCESS_KEY"
kubectl rollout restart deploy crusoe-envoy -n osmo && \
  kubectl rollout status deploy/crusoe-envoy -n osmo --timeout=300s
kubectl rollout restart deploy crusoe-authz -n osmo && \
  kubectl rollout status deploy/crusoe-authz -n osmo --timeout=300s
```

**The restarts are not optional (phases 6–9 hold the general rule; these two are auth-specific failure lessons):** Envoy's LDS does not hot-reload the mounted `crusoe-envoy-config` ConfigMap on symlink swaps, so the upgrade alone leaves the old JWT/oauth2 config active; the authz sidecar reads its `--roles-file` only at startup, so roles changes need the authz restart. oauth2-proxy restarts as part of the upgrade; restart it explicitly after any later change to its Secrets or issuer.

**g. Backend-operator role.** With authz on, the operator's user needs `osmo-backend` (its opaque token is exchanged at `/api/auth/jwt/access_token` — no token rotation, keycloak.md §3b). The exchange and the role grant run **inside the cluster**: the in-cluster Service name `crusoe` does not resolve on the operator's machine (the same rule Phase 7 and Phase 8 already enforce). The token and Phase 7's combined CA bundle reach the throwaway pod through **stdin as part of the script text** — never argv, never printed — and both `curl` calls verify against that CA bundle instead of `-k` (they carry credentials; `curlimages/curl` has no `jq`, so the token is extracted with `sed`):

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
OPAQUE_TOKEN=$(kubectl -n osmo get secret backend-operator-password -o jsonpath='{.data.password}' | base64 -d)
[ -n "$OPAQUE_TOKEN" ] || { echo "backend-operator-password empty"; exit 1; }
kubectl delete pod svc-role-bootstrap -n osmo --ignore-not-found --wait=true >/dev/null
{
  echo "set -e"
  # Host encodes with openssl (-A, portable incl. macOS); the pod-side decode
  # must be BusyBox `base64 -d` — curlimages/curl (Alpine) ships no openssl CLI.
  echo "echo '$(openssl base64 -A < "$WORKDIR/combined-ca-bundle.crt")' | base64 -d > /tmp/ca.crt"
  echo "printf '{\"token\":\"%s\"}' '$OPAQUE_TOKEN' > /tmp/body.json"
  cat <<'SCRIPT'
SVC_JWT=$(curl -s --cacert /tmp/ca.crt -X POST https://crusoe/api/auth/jwt/access_token \
  -H "Content-Type: application/json" --data-binary @/tmp/body.json \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$SVC_JWT" ] || { echo "service JWT exchange failed" >&2; exit 1; }
curl -s --cacert /tmp/ca.crt -X POST https://crusoe/api/auth/roles/osmo-backend/users \
  -H "Content-Type: application/json" -H "Authorization: Bearer $SVC_JWT" \
  -d '{"user_ids":["backend-operator"]}'
SCRIPT
} | kubectl run svc-role-bootstrap -n osmo --restart=Never -i --rm \
  --image=curlimages/curl:8.10.1 -- sh -s \
  || { kubectl delete pod svc-role-bootstrap -n osmo --ignore-not-found --wait=false; exit 1; }
unset OPAQUE_TOKEN
```

Then check the worker's connection (restart it so it re-exchanges with both roles if the check fails):

```bash
WORKER_POD=$(kubectl get pods -n osmo -o name | grep backend-worker | head -1)
kubectl logs -n osmo "$WORKER_POD" -c backend-worker --tail=50 | grep -q "Successfully connected" \
  || kubectl rollout restart deploy/osmo-backend-operator-osmo-backend-worker -n osmo
```

**h. Users.** Keycloak console at `https://<KC_LB_IP>` (admin credentials in the `keycloak/keycloak-admin-password` Secret — extract with `kubectl get secret ... -o jsonpath='{.data.password}' | base64 -d`, never printed, never echoed). The imported realm already has the `Admin` (roles `osmo-admin`+`osmo-user`), `User` (`osmo-user`) and `Backend Operator` (`osmo-backend`) groups; create one user per group member. Set a real `email` + `emailVerified: true` (recommended) — **not required**: `--oidc-email-claim=preferred_username` makes sessions work without email (keycloak.md §2b Email).

**i. Verify** (each line must hold):

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
# -k is acceptable here only because these are credential-free status probes
# (same convention as Phase 8's in-cluster ping); they send and receive nothing secret.
curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$(cat "$WORKDIR/lb_ip")/"        # 302 → https://<KC_IP>/realms/osmo/protocol/openid-connect/auth?...
curl -sk -o /dev/null -w '%{http_code}\n' "https://$(cat "$WORKDIR/lb_ip")/api/bucket"             # 401
```

- Anonymous `GET /` → **302** to the Keycloak login page at `https://<KC_IP>/realms/osmo/...`.
- Anonymous `GET /api/bucket` → **401**.
- Browser login: user with roles lands on Keycloak and returns; UI pages render; the UI's API calls return **200**.
- A roleless user is denied → **401 or 403, both are passes**: 401 when the JWT fails validation (a wrong audience mapping instead shows `401 Audiences in Jwt are not allowed` — keycloak.md "Failure lessons"; fix the `jwt.providers` audiences, then redo step f's restarts); **403** when the JWT is valid and the authz sidecar denies the action for lack of roles.
- Backend worker log shows `Successfully connected to wss://crusoe/api/agent/worker/backend/default` and submitted jobs complete `SUCCESS`.

Report the Keycloak URL, the two public load balancers (gateway + Keycloak), the KC CA export path, and the user-creation guidance; remind the user that the browser must import the Keycloak CA (same export/import steps as Phase 9) and that `kc_ip` is kept in `$WORKDIR` for teardown.md.

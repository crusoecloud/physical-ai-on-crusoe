# OSMO install — Phases 3–10

Part of the deploy-osmo-crusoe skill. Read [SKILL.md](../SKILL.md) first: its scope, tool-routing and sandbox rules apply here. This file installs OSMO on a cluster that already has its node pools, bucket and Object Storage access key (Phases 0–2).

**Read this whole file before starting.** Phases 6–7 carry hard-won lessons (CA trust, routing, OOM limits) that are not obvious from the Helm charts. Improvising from `helm --set` flags will reproduce bugs already diagnosed.

## Inputs and conventions

Inputs from Phases 1–2: `CLUSTER_NAME`, `LOCATION`, `BUCKET_NAME`, the GPU pool names (every node pool except `osmo-control-pool` and `osmo-backend-pool`), and the Object Storage access key.

- **Cluster context (the pin check).** Phase 2f's `get-credentials` leaves the kubectl current context on the target cluster, but another session or tool can switch it, and a `helm upgrade --install` against the wrong cluster would overwrite another live OSMO. Pool names prove nothing: other clusters in the project reuse `osmo-control-pool` and `h100`. The proof is the API server URL. Phase 3 step 0 records `https://<dns_name>` (from `crusoe kubernetes clusters get "$CLUSTER_NAME" --json`) in `"$WORKDIR/api_url"`, and **the first command of every phase from 3 to 9 repeats this check** and stops on a mismatch:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
[ -s "$WORKDIR/api_url" ] || { echo "no api_url recorded: run Phase 3 step 0 first"; exit 1; }
[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" = "$(cat "$WORKDIR/api_url")" ] \
  || { echo "the current kube context is not $CLUSTER_NAME's"; exit 1; }
```

  If it fails, run `crusoe kubernetes clusters get-credentials "$CLUSTER_NAME" --yes`, repeat the check, and do not continue until it passes.
- **Shell state does not persist between commands.** Re-derive variables in every command that needs them.
- **WORKDIR.** All generated files go in `WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"`, created with `mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"`. It survives between sessions, never holds a secret, and is **kept after the install** so upgrades reuse the values files (teardown deletes it at Level 2; a Level 1 teardown keeps `teardown.env`). Never write these files inside the repo. `kubectl` and `helm` fail TLS verification inside the agent's shell sandbox (as the `crusoe` CLI does), so run every command in this file outside the sandbox.
- **Secrets.** The access key never goes in a file. Use the values Phase 2e captured and `export` them in the same command that uses them, even if the same variables are already set in the environment: a stale value would otherwise override the new one, and OSMO would be installed with the wrong key (test with `[ -n "${OSMO_ACCESS_KEY_ID:-}" ]`; never print them), and ask the user if they are unset. Secrets reach Helm only through `--set-string` (Phase 5). **Never print** the `osmo-service-configs` ConfigMap, `helm get values osmo` or the Helm release Secret: they contain the storage secret key and the PostgreSQL password. If you need a value from them, filter to one named non-secret field with `grep -o`. The repeat-on-every-upgrade rules live at the install commands (Phase 5 and Phase 6c).
- **Long waits.** Several steps wait 5 to 20 minutes (the gateway IP, rollouts). The sandbox/TLS and tool-timeout rules (longest allowed timeout, or background + poll; a timeout is not a failure — check state first) live in [SKILL.md](../SKILL.md)'s Tool routing section.
- **Do not paraphrase the commands below.** Re-run `--help` or `kubectl explain` if a flag looks wrong, and tell the user if reality has drifted.

## Phase 3 — Install cluster prerequisites

**0. Pin the cluster.** Record the API URL that every later pin check compares against, and prove the current context now:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"; mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
DNS=$(crusoe kubernetes clusters get "$CLUSTER_NAME" --json | jq -r .dns_name)
[ -n "$DNS" ] && [ "$DNS" != null ] || { echo "could not read the cluster's dns_name"; exit 1; }
echo "https://$DNS" > "$WORKDIR/api_url"
[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" = "$(cat "$WORKDIR/api_url")" ] \
  || { echo "the current kube context is not $CLUSTER_NAME's: run crusoe kubernetes clusters get-credentials \"$CLUSTER_NAME\" --yes and repeat"; exit 1; }
```

**a. StorageClass.** Fresh clusters with the `crusoe_csi` add-on ship `crusoe-ssd` (provisioner `ssd.csi.crusoe.ai`) and `crusoe-fs` (`fs.csi.crusoe.ai`, the default) — `kubectl get storageclass` first and use `crusoe-ssd` as the SSD class. The historical `crusoe-csi-driver-ssd-sc` StorageClass (provisioner `ssd.csi.crusoe.ai`, from earlier versions of this skill) no longer applies; if it already exists on the target cluster keep it, otherwise do not create it (PVCs sit in `External` / `VolumeBindingMode` wait forever against a provisioner the current add-on no longer registers).

```bash
kubectl get storageclass
# Then use "crusoe-ssd" everywhere this file and the values templates say the SSD class
```

**b. KAI Scheduler**, pinned to the control node:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"; mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
cat > "$WORKDIR/kai-selectors.yaml" <<'EOF'
global:
  nodeSelector:
    osmo-type: "control"
  tolerations: []

scheduler:
  additionalArgs:
  - --default-staleness-grace-period=-1s
  - --update-pod-eviction-condition=true
EOF

helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  -n kai-scheduler --create-namespace \
  --version v0.16.1 \
  --values "$WORKDIR/kai-selectors.yaml"
```

**The first install attempt commonly fails with `no matches for kind "Queue"`.** That is a known CRD-registration race, not a real failure. Run the same command once more; it succeeds on the second attempt. Then:

```bash
kubectl get pods -n kai-scheduler
```

**c. cert-manager**, pinned to the control node:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --set nodeSelector."osmo-type"=control \
  --set cainjector.nodeSelector."osmo-type"=control \
  --set webhook.nodeSelector."osmo-type"=control
kubectl wait deployment cert-manager -n cert-manager --for=condition=Available --timeout=120s
kubectl wait deployment cert-manager-webhook -n cert-manager --for=condition=Available --timeout=120s
```

**d. Crusoe Load Balancer Controller.** Without it the gateway's LoadBalancer Service never gets an IP. First check whether it is already present:

```bash
kubectl get pods -A | grep -i crusoe-lb
```

If a pod shows up, skip the install. If not, the controller needs the `crusoe-secrets` secret in `crusoe-system` (CMK clusters create it). Check it exists with `kubectl get secret crusoe-secrets -n crusoe-system`; if it is missing, stop and tell the user: do not create Crusoe credentials yourself. Then install the chart:

```bash
helm repo add crusoe-lb https://crusoecloud.github.io/crusoe-load-balancer-controller-helm-charts/charts
helm repo update
helm upgrade --install crusoe-lb-controller crusoe-lb/crusoe-lb-controller \
  -n crusoe-system --version 0.0.24
kubectl wait pod -l app=crusoe-lb-controller -n crusoe-system \
  --for=condition=Ready --timeout=180s
kubectl get pods -n crusoe-system -l app=crusoe-lb-controller
```

The controller is a Private Beta product, so tell the user once that this step installed it. If the wait fails, show `kubectl describe` and `kubectl logs` output for the controller pod and stop.

## Phase 4 — Provision external access

Start with the pin check (see "Inputs and conventions").

**a. Deploy OSMO with SSL disabled**, only to provision the gateway LoadBalancer. This first install is minimal; the full values come in Phase 5 once the LB IP is known. **Skip it if the `osmo` release already exists** (a resumed or repeated run): re-running it would reset the release to chart defaults with SSL off and discard the Phase 5 values. The install sets `gateway.name=crusoe` so the gateway Service is called `crusoe` from the start: the chart's default is `osmo-gateway`, and the certificate names, the backend operator's wait and `service_base_url` all assume `crusoe`. Renaming the Service later replaces its load balancer and changes its IP, so this must be set on the first install.

```bash
helm repo add osmo https://helm.ngc.nvidia.com/nvidia/osmo
helm repo update
HS=$(helm status osmo -n osmo 2>&1) || true
case "$HS" in
  *"release: not found"*)
    helm upgrade --install osmo osmo/service -n osmo --create-namespace \
      --version 1.3.1 \
      --set gateway.name=crusoe \
      --set gateway.envoy.ssl.enabled=false \
      --set gateway.envoy.service.type=LoadBalancer
    ;;
  *"STATUS:"*) echo "release osmo already exists; skipping the minimal install" ;;
  *) echo "cannot tell whether release osmo exists: $HS"; exit 1 ;;
esac
```

**b. MEK ConfigMap, backend-operator password and database password.** Generate once and keep stable across re-runs: only create what does not exist yet.

```bash
MEK_STATE=$(kubectl get configmap mek-config -n osmo -o name 2>&1) || true
case "$MEK_STATE" in
  configmap/mek-config) echo "mek-config exists; leaving it as is" ;;
  *NotFound*)
    MEK_KEY=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n')
    MEK_JWK=$(printf '{"k":"%s","kid":"key1","kty":"oct"}' "$MEK_KEY" | base64 | tr -d '\n')
    printf 'currentMek: key1\nmeks:\n  key1: %s\n' "$MEK_JWK" | \
      kubectl create configmap mek-config -n osmo --from-file=mek.yaml=/dev/stdin
    ;;
  *) echo "cannot tell whether mek-config exists: $MEK_STATE"; exit 1 ;;
esac

PW_STATE=$(kubectl get secret backend-operator-password -n osmo -o name 2>&1) || true
case "$PW_STATE" in
  secret/backend-operator-password) echo "backend-operator-password exists; leaving it as is" ;;
  *NotFound*)
    BACKEND_OPERATOR_PASSWORD=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n=' | head -c 43)
    kubectl create secret generic backend-operator-password -n osmo \
      --from-literal=password="$BACKEND_OPERATOR_PASSWORD"
    ;;
  *) echo "cannot tell whether backend-operator-password exists: $PW_STATE"; exit 1 ;;
esac
```

**The database password.** OSMO's bundled PostgreSQL takes its password as a plain value (chart 1.3.1 cannot read it from a Secret), so generate a random one once, keep it in a Secret of ours, and pass it to Helm at install time (Phase 5). If a database from an earlier install still exists (a `postgres-volume` PVC), it was created with the old fixed password `osmo`: keep that password for it instead of generating a new one, or authentication would fail.

```bash
PG_STATE=$(kubectl get secret osmo-postgres-password -n osmo -o name 2>&1) || true
case "$PG_STATE" in
  secret/osmo-postgres-password) echo "osmo-postgres-password exists; leaving it as is" ;;
  *NotFound*)
    PVC_STATE=$(kubectl get pvc postgres-volume -n osmo -o name 2>&1) || true
    case "$PVC_STATE" in
      persistentvolumeclaim/postgres-volume) echo "a database from an earlier install exists: keeping its old password"; PG_PASS=osmo ;;
      *NotFound*) PG_PASS=$(openssl rand -hex 24) && [ -n "$PG_PASS" ] || { echo "openssl rand failed"; exit 1; } ;;
      *) echo "cannot tell whether the postgres-volume PVC exists: $PVC_STATE"; exit 1 ;;
    esac
    kubectl create secret generic osmo-postgres-password -n osmo --from-literal=password="$PG_PASS"
    ;;
  *) echo "cannot tell whether osmo-postgres-password exists: $PG_STATE"; exit 1 ;;
esac
```

Neither the MEK, the backend-operator password nor the PostgreSQL password is written to a file or printed. Only a definite "NotFound" creates them; any other failure stops, so a transient error can never regenerate a key or password.

**c. Wait for the gateway's external IP.** Poll for up to 10 minutes:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"; mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
rm -f "$WORKDIR/lb_ip"
LB_IP=""
for i in $(seq 1 120); do
  LB_IP=$(kubectl get svc crusoe -n osmo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$LB_IP" ] && break
  sleep 5
done
echo "LB IP: ${LB_IP:-none}"
[ -n "$LB_IP" ] && echo "$LB_IP" > "$WORKDIR/lb_ip"
```

If there is no IP after 10 minutes, stop and diagnose. First run `kubectl get svc -n osmo` and check that the gateway Service is named `crusoe` (if it is `osmo-gateway`, the Phase 4a install missed `gateway.name=crusoe`); then `kubectl describe svc crusoe -n osmo` and the Crusoe LB controller's logs (`kubectl logs -n crusoe-system -l app=crusoe-lb-controller --tail=50`). Do not continue without the IP. **`lb_ip` must hold the bare IP and nothing else**: later phases substitute its content directly into the Certificate's `commonName`/`ipAddresses`, and a labeled line (e.g. `LB IP: 1.2.3.4`) makes cert-manager reject the apply with `invalid IP address` (observed). The write above already emits the bare value — never echo labels into this file.

**d. Issue the self-signed certificate.** The `dnsNames` are in-cluster Service names, not the LB IP: see Phase 7 for why.

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
[ -s "$WORKDIR/lb_ip" ] || { echo "no LB IP recorded: run step c first"; exit 1; }
LB_IP=$(cat "$WORKDIR/lb_ip")

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: osmo-selfsigned
spec:
  selfSigned: {}
EOF

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: envoy-ssl-cert
  namespace: osmo
spec:
  secretName: envoy-ssl-cert
  issuerRef:
    name: osmo-selfsigned
    kind: ClusterIssuer
  commonName: "$LB_IP"
  ipAddresses:
    - "$LB_IP"
  dnsNames:
    - "crusoe"
    - "crusoe.osmo"
    - "crusoe.osmo.svc"
    - "crusoe.osmo.svc.cluster.local"
  duration: 8760h
  renewBefore: 720h
EOF
kubectl wait certificate/envoy-ssl-cert -n osmo --for=condition=Ready --timeout=300s
```

## Phase 5 — Write Helm values and install OSMO

Start with the pin check (see "Inputs and conventions").

Now that the LB IP, bucket and location are known, write the two values files into `$WORKDIR` from the templates in [assets/](../assets/): copy each, then substitute every `<…>` by hand (there is no template engine). The files contain no secrets: the access key is added at install time with `--set-string`.

**`$WORKDIR/osmo-service-values.yaml`.** The template is [assets/osmo-service-values.yaml.template](../assets/osmo-service-values.yaml.template): copy it to `$WORKDIR/osmo-service-values.yaml` and repeat the `crusoe_<pool_name>_compute` template and the `<pool_name>` pool block once per GPU pool (`allowedPools` lists every GPU pool name, comma-separated), substituting every `<…>`. No secrets go in the file — the access key is added at install time with `--set-string`.

**`$WORKDIR/osmo-backend-values.yaml`.** The template is [assets/osmo-backend-values.yaml.template](../assets/osmo-backend-values.yaml.template): copy it **verbatim** to `$WORKDIR/osmo-backend-values.yaml` (no placeholders).

**The backend memory limits (`256Mi` / `1Gi`) are already raised from the chart's defaults (`128Mi` / `256Mi`): at the defaults the pods were OOMKilled (exit 137) about every 6 minutes on an 8-node cluster.** Do not lower them. If OOMKilled recurs at `1Gi` on a larger cluster, raise further, after confirming with `kubectl get pod … -o jsonpath='{.status.containerStatuses[?(@.name=="backend-listener")].lastState.terminated}'` showing `"reason":"OOMKilled"`.

**Versions.** Both OSMO charts are pinned to 1.3.1. The images still use the `latest` tag (`osmoImageTag`), so a later run can pull newer images than the chart was tested with:

**Service install command.** Use this block for the first install *and for every later `helm upgrade` of the `osmo` release*: `--set-string` values are not remembered, so omitting them wipes the credentials, and a missing PostgreSQL password locks the service out of its own database.

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
# Export the key in this same command first: the values from Phase 2e, overriding anything already set in the environment.
: "${OSMO_ACCESS_KEY_ID:?export OSMO_ACCESS_KEY_ID first}" "${OSMO_ACCESS_KEY:?export OSMO_ACCESS_KEY first}"
PG_PASS=$(kubectl get secret osmo-postgres-password -n osmo -o jsonpath='{.data.password}' | base64 -d)
: "${PG_PASS:?the osmo-postgres-password Secret is missing: run Phase 4b first}"
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
```

Then the backend operator, which needs the `osmo-test` namespace first:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
kubectl create namespace osmo-test --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install osmo-backend-operator osmo/backend-operator -n osmo \
  --version 1.3.1 \
  -f "$WORKDIR/osmo-backend-values.yaml"
```

The backend operator will NOT trust the self-signed certificate yet. That is expected and fixed in Phase 6.

## Phase 6 — Backend-operator CA trust

Start with the pin check (see "Inputs and conventions").

**The backend operator will NOT trust the self-signed certificate by default (confirmed and reproducible).** It fails two ways: an HTTP `requests` `SSLError` (`CERTIFICATE_VERIFY_FAILED: self-signed certificate`) and a `websockets`/`asyncio.ssl` `SSLCertVerificationError` on the persistent worker connection. The `osmo/backend-operator` chart has no `extraVolumes` to mount a CA, so the fix is an init container that fetches the certificate through the Kubernetes API.

**a. Publish the certificate as a ConfigMap** the operator can read:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
kubectl get secret envoy-ssl-cert -n osmo -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORKDIR/envoy-ca.crt"
kubectl create configmap envoy-ca-cert -n osmo --from-file=ca.crt="$WORKDIR/envoy-ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**b. Grant the operator's service accounts read access to just that ConfigMap.** The real service-account names are release-prefixed. Look them up from the running deployments, never assume the chart's bare `backend-listener` / `backend-worker`. Run the lookup, the guard and the apply below as ONE command: shell variables do not survive between commands, and an empty name would create a binding with a blank subject.

```bash
LISTENER_SA=$(kubectl get deploy -n osmo -o name | grep backend-listener | head -1 | \
  xargs -I{} kubectl get {} -n osmo -o jsonpath='{.spec.template.spec.serviceAccountName}')
WORKER_SA=$(kubectl get deploy -n osmo -o name | grep backend-worker | head -1 | \
  xargs -I{} kubectl get {} -n osmo -o jsonpath='{.spec.template.spec.serviceAccountName}')
echo "listener SA: $LISTENER_SA   worker SA: $WORKER_SA"
[ -n "$LISTENER_SA" ] && [ -n "$WORKER_SA" ] || { echo "service account lookup is empty: the operator deployments are not there yet"; exit 1; }

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-envoy-ca-cert
  namespace: osmo
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["envoy-ca-cert"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-listener-read-envoy-ca-cert
  namespace: osmo
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: read-envoy-ca-cert}
subjects:
- {kind: ServiceAccount, name: $LISTENER_SA, namespace: osmo}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-worker-read-envoy-ca-cert
  namespace: osmo
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: read-envoy-ca-cert}
subjects:
- {kind: ServiceAccount, name: $WORKER_SA, namespace: osmo}
EOF
```

**c. Add the init container and CA environment variables.** The template is [assets/ca-trust-values.yaml.template](../assets/ca-trust-values.yaml.template): copy it **verbatim** to `$WORKDIR/ca-trust-values.yaml` (no placeholders; its header comment carries the initContainers caveat). **Helm replaces list values across `-f` files; it does not merge them** — the template's list contains **both** `wait-for-gateway` and `install-ca-cert`; keep it that way or the gateway-wait silently disappears.

**Both `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE` are required.** `REQUESTS_CA_BUNDLE` alone fixes only the HTTP path; without `SSL_CERT_FILE` the websocket connection keeps crash-looping, because `websockets`/`asyncio.ssl` ignores `REQUESTS_CA_BUNDLE`. Do not work around either failure by switching to a public CA: that brings back the DNS requirement this design avoids.

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
helm upgrade osmo-backend-operator osmo/backend-operator -n osmo \
  --version 1.3.1 \
  -f "$WORKDIR/osmo-backend-values.yaml" -f "$WORKDIR/ca-trust-values.yaml"
```

**The `envoy-ca-cert` ConfigMap does not update itself when the certificate is reissued, and this has caused real repeated failures.** Whenever the certificate changes (new IP, new names, renewal) and is re-applied, every `envoy-ca-cert` copy keeps the old content, and pods that restart afterwards fetch the stale certificate and hit the same `CERTIFICATE_VERIFY_FAILED`. After any reissue, redo Phase 7's bundle refresh and restart the backend operator.

## Phase 7 — Workflow-pod CA trust

Start with the pin check (see "Inputs and conventions").

**`service_base_url` must be the in-cluster gateway address, never the LB IP.** It is already set that way in Phase 5; do not revert it. Every workflow pod runs an `osmo-ctrl` sidecar that phones home to that URL, and workflow pods run inside the cluster and cannot route to an external LB IP. Confirmed failure: workflows run their task but never reach `COMPLETED`, because the sidecar retries forever with no visible error. If workflows hang in running-but-never-completing, check this first: `kubectl get configmap osmo-service-configs -n osmo -o jsonpath='{.data.config\.yaml}' | grep service_base_url` shows the value the sidecars actually read. Always filter: the full ConfigMap contains the storage secret key.

**The `osmo-ctrl` sidecar also needs the CA fix.** The `crusoe_ca_trust` pod template (mounting the CA from a ConfigMap and setting both environment variables) is already in `osmo-service-values.yaml` and referenced by every pool. Confirm with `grep -c crusoe_ca_trust "$WORKDIR/osmo-service-values.yaml"`: it should be 1 (the template definition) plus one per GPU pool.

**`REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` replace the process's whole trust store; they do not extend it.** The ConfigMap must hold the self-signed certificate **plus a full public CA bundle**. With only the self-signed certificate, `osmo-ctrl` trusts the gateway but fails every public endpoint it needs (for example Object Storage uploads) with `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`. Take the public bundle from an in-cluster image, since macOS has no `/etc/ssl/certs/ca-certificates.crt`. The whole sequence — fetch with a ≥100-cert gate, concat, three-namespace fan-out, backend restarts — is one mock-verified command, [scripts/build_ca_bundle.sh](../scripts/build_ca_bundle.sh) (`SKILL_DIR="<path-to>/skills/deploy-osmo-crusoe"`, same convention as provision.md):

```bash
"$SKILL_DIR/scripts/build_ca_bundle.sh"
```

**Workflow pods do NOT run in the `osmo` namespace (confirmed by a real `Unschedulable` failure).** They run in `global.backendNamespace` (`default`) or `global.backendTestNamespace` (`osmo-test`). A `configMap` volume only resolves in the pod's own namespace, so a ConfigMap created only in `osmo` is invisible to them. That shows up as `Missing required configmaps: [envoy-ca-cert]`, `Unschedulable`, which is easy to mistake for a scheduler or resource problem. Keep three copies in sync:

(the fan-out + backend restart is the script's steps 3–4 — same invocation, same command)

ConfigMap volumes reach running pods within about a minute without a restart, but the backend operator fetches its CA once at startup, so it needs the restart above. Rebuild and refresh all three copies on every certificate reissue.

**Known app-config gotchas.** Apply only if hit, by editing `$WORKDIR/osmo-service-values.yaml` and re-running the Phase 5 service install command (with its `--set-string` flags):
- **Private Docker registry submissions return 500 before scheduling.** OSMO's server-side registry-credential validation rejects the credential before any pod exists. This is an app-level field, confirmed from the OpenAPI schema (`/api/openapi.json`, `components.schemas.CredentialConfig`), not a chart value. Fix: `services.configs.workflow.credential_config.disable_registry_validation: ["<registry-hostname>"]`, with the hostname exactly as used when the registry credential was registered (no scheme, no trailing slash, no port mismatch).
- **Uploads hang forever retrying** (`Could not connect to the endpoint URL: "https://<bucket>.object.<region>.crusoecloudcompute.com/..."`). Crusoe Object Storage needs path-style addressing. Phase 5's values already set `addressing_style: path` on all three credential blocks; if you ever see this signature, confirm all three still carry it.
- **General lesson:** when the chart's `values.yaml` is silent on something OSMO clearly supports, check the OpenAPI schema before assuming the field does not exist.

## Phase 8 — Verify

Start with the pin check (see "Inputs and conventions").

Check pod status, certificate status and, critically, the backend worker's log content, not just `READY`: a pod can read `1/1 Running` during the brief up-window of a crash loop right after a rollout.

```bash
kubectl get pods -n osmo
kubectl get certificate -n osmo
WORKER_POD=$(kubectl get pods -n osmo -o name | grep backend-worker | head -1)
kubectl logs -n osmo "$WORKER_POD" -c backend-worker --tail=100
```

Expect `Successfully connected to wss://crusoe/api/agent/worker/backend/default` (the in-cluster Service name, **not** the LB IP) and jobs completing with `status SUCCESS`. Give new pods a few minutes after the Phase 7 restart before judging; if they still crash-loop, read the log for `CERTIFICATE_VERIFY_FAILED` (Phases 6–7) or `OOMKilled` (Phase 5).

Check the API from inside the cluster, where routing is certain:

```bash
kubectl run -n osmo curl-test --rm -i --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -k -s https://crusoe/api/version
```

and, if this machine can reach the LB, from outside, verifying against the gateway's own certificate:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
kubectl get secret envoy-ssl-cert -n osmo -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORKDIR/gateway.crt"
curl -s --cacert "$WORKDIR/gateway.crt" "https://$(cat "$WORKDIR/lb_ip")/api/version"
```

(The in-cluster ping above uses `-k` only because the throwaway pod has no copy of the CA; it carries no credentials and only proves reachability.)

In `mcp+cli` mode also call `cluster_health_check(cluster_name)` and report anything unhealthy.

This skill does not submit workflows; the concrete regression test for the routing and CA fixes is a submitted workflow reaching `COMPLETED` — tell the user that.

## Phase 9 — Report

Start with the pin check (see "Inputs and conventions").

Export the certificate so the user can trust it, and record what was installed. The files in `$WORKDIR` are kept on purpose (they hold no secrets, and later upgrades reuse them); teardown.md removes them.

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
LB_IP=$(cat "$WORKDIR/lb_ip" 2>/dev/null)
[ -n "$LB_IP" ] || { echo "no LB IP recorded in $WORKDIR/lb_ip; get it with: kubectl get svc crusoe -n osmo"; exit 1; }
kubectl get secret envoy-ssl-cert -n osmo -o jsonpath='{.data.ca\.crt}' | base64 -d > "$HOME/osmo-ca-$CLUSTER_NAME.crt"
[ -s "$HOME/osmo-ca-$CLUSTER_NAME.crt" ] || \
  kubectl get secret envoy-ssl-cert -n osmo -o jsonpath='{.data.tls\.crt}' | base64 -d > "$HOME/osmo-ca-$CLUSTER_NAME.crt"
[ -s "$HOME/osmo-ca-$CLUSTER_NAME.crt" ] || { echo "certificate export is empty"; exit 1; }
echo "URL: https://$LB_IP"
helm list -n osmo
helm list -n cert-manager
kubectl get deploy -n osmo -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
kubectl get certificate envoy-ssl-cert -n osmo -o jsonpath='valid until {.status.notAfter}, renews about {.status.renewalTime}{"\n"}'
```

**Firewall the gateway (hard step).** The gateway LB is publicly
routable; whether or not Keycloak runs, anyone who can reach it is inside the
admin surface. Restrict the LB's managed firewall rule to the operator's
source addresses BEFORE handing over the URL:

```bash
FW_ID=$(kubectl get svc crusoe -n osmo -o jsonpath='{.metadata.annotations.crusoe\.ai/firewall-rule-id}')
# Ask the user for the CIDRs that need the gateway (their office/VPN egress
# IPs, e.g. 203.0.113.0/24); NEVER proceed with 0.0.0.0/0.
#
# KEEP the rule's existing destination-ports: the controller-managed rule
# targets the Service's NODEPORTS (e.g. 32246,31487), not 443 — the LB
# forwards 443 to them. Overwriting with --destination-ports 443 breaks
# external reachability entirely (observed live on crusoe v1.0.9: the rule
# matched nothing and the gateway timed out until the nodePort destinations
# were restored). Restrict ONLY the sources:
crusoe networking vpc-firewall-rules update "$FW_ID" --sources <cidr1, cidr2...> --protocols tcp \
  --destination-ports "$(crusoe networking vpc-firewall-rules get "$FW_ID" --json | jq -r '.destination_ports | join(",")')"
```

Then re-read the rule and report the sources actually in effect
(`crusoe networking vpc-firewall-rules get "$FW_ID"`). The rule is managed by
the load balancer controller and may be reset when the Service changes —
re-run this check after any later `helm upgrade`/Service edit, and re-verify
the rule at every Phase 9 report. If the user declines to give CIDRs, stop and
report: an unrestricted gateway plus no login means anyone who finds the IP
holds admin.

(`tls.crt` is the fallback when `ca.crt` is empty: the self-signed leaf certificate is its own CA.) If the sandbox refuses to write under `$HOME`, print the `kubectl` command for the user to run instead.

Report to the user:
- The URL: `https://<LB IP>`.
- A one-time browser trust warning is expected (self-signed, no domain), not a bug. The exported certificate (`~/osmo-ca-<cluster>.crt`) can be imported to avoid it. On macOS: Keychain Access → System → drag the file in → set to Always Trust.
- What now exists: the cluster, its pools with node counts, the bucket (give its name and say whether object lock is enabled), the IB partition used or created, the Object Storage key's alias, access key ID and **expiry** (`crusoe storage tokens list --json` if `KEY_EXPIRY` needs confirming; never the secret) — state plainly that the key is org-scoped (all buckets, all projects) and dies at the stated time, the Crusoe LB controller if this run installed it, and the OSMO releases `osmo` and `osmo-backend-operator`.
- **CLI access — offer the `osmo` CLI install (opt-in).** Ask at the report; if they say yes, download the install script to a
  file pinned to a tag or commit (never the mutable `refs/heads/main`, and never piped
  straight into bash — it is unreviewed third-party code running with the user's
  privileges on the machine that holds their Crusoe credentials; CWE-494):
  `curl -fsSL -o /tmp/osmo-install.sh https://raw.githubusercontent.com/NVIDIA/OSMO/<pinned-tag-or-sha>/install.sh`,
  let the user review it (`less /tmp/osmo-install.sh`), then `bash /tmp/osmo-install.sh`
  and `osmo --version`; if they decline, print the steps so they (or the workload
  skill) can run them later. Do **not** log the CLI in here — tokens issued now can be
  stale by the time a workload runs, and the login flow (device flow + the
  self-signed-gateway CA handling, and the Keycloak variant when Phase 10 ran) belongs
  to the session that will submit. Print the login handoff instead:
  - Login-free gateway: `SSL_CERT_FILE=~/osmo-ca-<cluster>.crt REQUESTS_CA_BUNDLE=~/osmo-ca-<cluster>.crt osmo login "https://<LB IP>/" --method code`
  - Keycloak deployment (Phase 10): the same command, device flow against the `osmo-device` client — run it when the user is ready to submit (the run-osmo-workload skill's Phase 1b).
- **Security: the gateway is public; the firewall step above is the control.** Without Keycloak (Phase 10 skipped) the gateway has **no login**: anyone the firewall admits who finds `https://<LB IP>` is treated as `osmo-admin` and can submit GPU workflows on the user's account. State which sources the firewall rule admits (from the `get` output above), that the rule is managed by the load balancer controller and must be re-checked after any Service change, and that the deployment should still be removed when not in use.
- Versions: the OSMO charts are pinned to 1.3.1; the images use the `latest` tag, so report the resolved images and cert-manager's version from the output above.
- Certificate: say the `valid until` and `renews about` dates from the output above. When cert-manager renews it, the `envoy-ca-cert` copies go stale: redo Phase 7's bundle rebuild and the backend-operator restart.
- Cost and removal: the cluster, its GPU nodes and the load balancer bill until the deployment is removed; point the user to [teardown.md](teardown.md).
- Anything not created or read in this session (the IB partition, the key alias, the bucket's object-lock state) is unknown: read it (`crusoe storage buckets get`, `crusoe networking transport-partitions list`) or say so.
- The database password: random for a new database. If OSMO was reinstalled over a database created by an earlier version of this skill, it is still the old fixed value `osmo` (a Level 1 teardown followed by a fresh install gives a random one).
- Anything skipped or unverified (quota not pre-checked, key file not verified, MCP checks not run).

## Phase 10 — Authentication (Keycloak — the default; opt-out only)

**Keycloak runs by default .** The Phase 1h summary offers it as the
default-yes ("Keycloak login is included — opt out only if this cluster must
stay login-free"); run this phase as part of the same approved run unless the
user explicitly opted out. If they did opt out, skip with one sentence stating
the residual risk plainly: "The gateway stays public with no login; only the
Phase 9 firewall rule stands between the internet and admin."

The phase lives in its own reference, loaded only when you reach it: [keycloak-install.md](keycloak-install.md). It runs after the Phase 9 report (it flips the login-free gateway from Phase 9 to Keycloak-enforced and adds a second public load balancer). The design rationale and every value are explained in [keycloak.md](keycloak.md).

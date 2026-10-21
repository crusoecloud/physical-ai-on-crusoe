# Keycloak as IdP for the Crusoe OSMO deployment — executed and verified

Part of the deploy-osmo-crusoe skill. This is the verified Keycloak/IdP path: Keycloak installed and enforcing, wired in as Phase 10 — the exact commands are [keycloak-install.md](keycloak-install.md), this file is the design rationale. Every substantive claim cites its source or is marked **[INFERENCE]**; the Failure lessons and §6 below record what testing proved and what remains untested. It fits the deployment this skill builds: OSMO `service` 1.3.1 + `backend-operator` 1.3.1 (`oci://helm.ngc.nvidia.com/nvidia/osmo`, appVersion 6.3.1), gateway Service `crusoe` (Envoy) on a public Crusoe LoadBalancer IP, self-signed cert for the bare IP, `gateway.oauth2Proxy.enabled: false` + `gateway.authz.enabled: false` + `gateway.defaultIdentity {user: testuser, roles: osmo-admin, allowedPools: <pools>}`, in-cluster Service DNS for all internal traffic (`https://crusoe.osmo.svc.cluster.local`, backend operator on `wss://crusoe/api/agent/worker/…`), and workflow sidecars trusting the `envoy-ca-cert` ConfigMap.

## Sources

- **Docs** — NVIDIA OSMO deployment guide, release/6.3 (the release matching chart 1.3.1's appVersion 6.3.1; both were verified against the NGC helm index and the chart's `Chart.yaml`, see below). Docs root: https://nvidia.github.io/OSMO/release/6.3/index.html. Auth pages:
  - Authentication and Authorization overview: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/index.html
  - Authentication Flow: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/authentication_flow.html
  - Roles and Policies: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/roles_policies.html
  - IdP Role Mapping and Sync Modes: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/idp_role_mapping.html
  - Service Accounts: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/service_accounts.html
  - Identity Provider (IdP) Setup: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/identity_provider_setup.html
  - Keycloak as a sample IdP: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/keycloak_setup.html
  - Deploy Service: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/getting_started/deploy_service.html
  - Minimal Deployment: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/deploy_minimal.html
  - Deploy Backend Operator: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/install_backend/deploy_backend.html
  - Config references: https://nvidia.github.io/OSMO/release/6.3/deployment_guide/references/configs_definitions/service.html and .../backend.html
- **Charts** — read from the official NGC helm repo itself: `https://helm.ngc.nvidia.com/nvidia/osmo/index.yaml` lists `service` 1.3.1 (appVersion `6.3.1`) and `backend-operator` 1.3.1 (appVersion `6.3.1`) as the newest releases; the tarballs `https://helm.ngc.nvidia.com/nvidia/osmo/charts/service-1.3.1.tgz` and `.../backend-operator-1.3.1.tgz` were downloaded anonymously with curl (the NGC chart index redirects to a signed object store, no NGC API key needed for these URLs) and their `values.yaml`, `README.md`, `Chart.yaml` and templates read directly. Chart citations below say "chart" and name the file plus the claim; the tarball URL is the provenance.
- **GitHub** — NVIDIA/OSMO repo (source of the docs): https://github.com/NVIDIA/OSMO. The authz sidecar's header/role logic was read from https://github.com/NVIDIA/OSMO/blob/main/src/service/authz_sidecar/server/authz_server.go (quoted where load-bearing). oauth2-proxy flag behavior is cited from the oauth2-proxy docs pinned at the chart's image tag (https://github.com/oauth2-proxy/oauth2-proxy/tree/v7.14.2 docs).
- **NGC catalog** — the OSMO collection page (https://catalog.ngc.nvidia.com/orgs/nvidia/osmo/collections/osmo) describes the platform but carries no SSO/Keycloak guidance of its own. No other NGC page was found describing Keycloak for OSMO; the docs pages above are the official material.

Below, claims without a citation URL are marked **[INFERENCE]**. Where docs are silent or contradictory, that is stated plainly.

## 1. What OSMO officially supports, claim by claim

| Claim | Status | Evidence |
|---|---|---|
| OSMO operates without an IdP: a `defaultAdmin` user is created at startup with the `osmo-admin` role and an access token whose secret is the configured password; access is token-based | Documented | https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/index.html ("Default admin (no IdP)"), https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/authentication_flow.html |
| With an IdP, Envoy runs an OAuth2/OIDC flow: unauthenticated browser users are redirected to the IdP, Envoy validates the returned JWT and sets `x-osmo-user` / `x-osmo-roles` for the backend | Documented | Authentication Flow (Architecture components, Browser login) |
| The OSMO service does **not** validate JWTs; it trusts the `x-osmo-user`/`x-osmo-roles` headers set by Envoy, so the gateway must strip client-supplied identity headers | Documented | Authentication Flow (Token validation and headers) |
| The chart strips client-supplied `x-osmo-{user,roles,token-name,workflow-id,allowed-pools}` at the gateway whenever any auth source (oauth2Proxy, authz, jwt.providers) is enabled; only when **all three** are off does the gateway trust client headers — the current deployment's mode | Documented (chart) | chart `service/README.md` "Identity header trust by mode" table; chart `service/templates/_gateway-envoy-config.tpl` (`internal_only_headers`); https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/deploy_minimal.html warning ("any caller with network access can claim any user, role, or pool") |
| The official Keycloak guide deploys Keycloak itself (Bitnami chart `24.4.9`, image `bitnamilegacy/keycloak:26.1.1-debian-12-r0`), imports a sample `osmo` realm with two clients — `osmo-browser-flow` (confidential, client secret) for the UI and `osmo-device` (public, device flow) for the CLI — and then wires OSMO via `services.service.auth`, `gateway.oauth2Proxy`, and `gateway.envoy.jwt.providers` | Documented | https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/keycloak_setup.html |
| With Keycloak, three Envoy JWT providers are configured: Keycloak access tokens (audience `account`), the UI's ID token (audience `osmo-browser-flow`), OSMO-issued JWTs (issuer `osmo`, `jwks_uri` `https://osmo-service/…` — `https`, because gateway→upstream TLS stays on; the docs' value is `http`). **Verified**; the full semantics and the singular-`audience` chart quirk are in the Failure lessons and §3a below | Documented + verified | keycloak_setup.html, "Gateway Envoy JWT providers"; gateway-jwt-providers appendix |
| Roles and policies: preconfigured roles `osmo-admin` (immutable), `osmo-user`, `osmo-backend`, `osmo-ctrl`, `osmo-default`; policies are `effect`/`actions`/`resources` (`workflow:Create` scoped to `pool/<name>`, `Deny` wins); pool access is determined by policies, with a naming convention `osmo-<pool-group>` | Documented | https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/roles_policies.html |
| IdP group/role claims map to OSMO roles via each role's `external_roles` field (default 1:1 by name) with sync modes `import` (default) / `force` / `ignore`; configured under `services.configs.roles` in Helm values | Documented | idp_role_mapping.html; roles_policies.html ("Creating Custom Roles") |
| Keycloak-side model: roles named `osmo-<pool-group-name>` created in **both** clients, assigned to groups (`OSMO <Team>`), users join groups; `Admin`/`User` groups are the sample convention | Documented | keycloak_setup.html, Part 3 |
| Just-in-time provisioning: users are created in OSMO automatically on first IdP login; roles merge from DB and IdP claims per sync mode | Documented | authentication/index.html; idp_role_mapping.html |
| Access tokens still work with an IdP: the CLI/API can exchange an access token for a service-issued JWT at `POST /api/auth/jwt/access_token`; that path is in the gateway's `skipAuthPaths` | Documented | Authentication Flow (Token-based login (service-issued JWT)); chart `service/values.yaml` `gateway.envoy.skipAuthPaths` |
| The service mints JWTs for workflow pods: `service_auth.keys` auto-generated RSA pair, `issuer: osmo`, `audience: osmo`, `user_roles: [osmo-user]`, `ctrl_roles: [osmo-user, osmo-ctrl]`, `max_token_duration: 365d`; `login_info` (device/browser/token/logout endpoints) is the service-side copy of the auth block | Documented | https://nvidia.github.io/OSMO/release/6.3/deployment_guide/references/configs_definitions/service.html (Service Authentication) |
| Service accounts (backend operator): `osmo user create <id> --roles osmo-backend` + `osmo token set <name> --user <id> --roles osmo-backend`; token expires, no refresh | Documented | service_accounts.html; deploy_backend.html |
| The backend operator connects with `loginMethod: token` (`--token_file`) or `password`; its `router_address` config field is the WebSocket address for backend communication | Documented (chart + docs) | chart `backend-operator/values.yaml` (`loginMethod`, `accountTokenSecret`) and `backend-operator/templates/backend-worker.yaml` (`--login_method`, `--token_file`); https://nvidia.github.io/OSMO/release/6.3/deployment_guide/references/configs_definitions/backend.html (`router_address`); https://nvidia.github.io/OSMO/release/6.3/deployment_guide/install_backend/deploy_backend.html |
| The newer **unified `osmo` chart** (main docs, appVersion 6.4+) configures Keycloak under `authentication.externalOidc` with `embeddedDependencies.dex.enabled: false` | Documented, **not applicable to 1.3.1** | https://nvidia.github.io/OSMO/main/deployment_guide/appendix/keycloak_setup.html. Chart 1.3.1 contains no `dex` or `authentication.externalOidc` values at all (verified in the tarball); do not follow the `main` docs for this cluster. |

Not found in official material (checked): any doc for `gateway.defaultIdentity.allowedPools` beyond its one-line README entry; any documented interplay between oauth2-proxy and workflow-pod S3 traffic; any official statement about `OSMO_LOGIN_DEV`. See §6.

### The 1.3.1 values schema

Read it from the chart itself: `helm show values osmo/service --version 1.3.1` (`gateway.oauth2Proxy.*` defaults to `enabled: true`, so the skill's install turns it off explicitly). The stale-path gotcha from this schema: the values comment quotes `device_endpoint .../protocol/openid-connect/device`, which Keycloak 26 moved to `.../openid-connect/auth/device` — the correct value is used in §3a and in the workload skill's troubleshooting table.


The auth-relevant values (`gateway.authz.*`, `gateway.envoy.idp/internalJwks/jwt/defaultIdentity`, `services.service.auth.*`, the oauth2-proxy container args) are all in `helm show values` output and in §3a/§3c's exact blocks; the fields this skill sets are called out there. Two schema facts that matter beyond the blocks: `authz` and `oauth2Proxy` both default to `enabled: true` (the no-login install turns both off explicitly), and the gateway's `skipAuthPaths` already includes `/api/auth/*` and `/api/version` (so the auth flows and the in-cluster ping survive oauth2 enforcement; do not add `/api/agent/` — §4).

## 2. Keycloak on this cluster — what shipped

Official material assumes a DNS name (`auth-<your-domain>`, `osmo.example.com`) and an ingress controller. This cluster has neither: one public LB IP for the gateway, self-signed certs, no ingress controller. What ships keeps the official chart/version and every official value that survives the constraints, and changes only what the IP/no-ingress reality forces; every deviation below was exercised and verified.

### 2a. Keycloak install

The resulting values file is §3c.

- **Chart and version**: `bitnami/keycloak` **24.4.9** with image `bitnamilegacy/keycloak:26.1.1-debian-12-r0` and `global.security.allowInsecureImages: true` — exactly what the official guide pins (https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/keycloak_setup.html). Do not upgrade unprompted: the guide is version-pinned and newer Bitnami charts change image naming again. `allowInsecureImages: true` is required (the pull is from `docker.io`).
- **Namespace**: `keycloak` (official guide).
- **Scheduling**: `nodeSelector: osmo-type: control`, `autoscaling.enabled: false`, single StatefulSet replica (`keycloak-0`) — verified running `1/1 Ready`. The `osmo-control-pool` c1a.8x node already carries postgres, redis and all control-plane services; Keycloak joins it.
- **Resources**: official guide's `requests {cpu: 500m, memory: 512Mi}`, `limits {cpu: 2, memory: 1Gi}` (same URL).
- **Production posture**: `production: true`, **`hostname` pinned to the public LB IP** (`hostname: <KC_LB_IP>`), **`proxy` unset** (chart default — none). The issuer is therefore `https://<KC_LB_IP>/realms/osmo`, and Keycloak only answers for that host. Do not use `proxy: edge`: with no reverse proxy in front of Keycloak, `edge` makes it trust client-supplied `X-Forwarded-*` headers — a client could assert `X-Forwarded-Proto: https` over plaintext. Keycloak terminates its own TLS here, so there is no proxy for it to trust.
- **Database**: a `keycloak` database on OSMO's own in-chart Postgres, owned by a dedicated least-privilege role `keycloak` (`CREATE ROLE keycloak LOGIN …` + `CREATE DATABASE keycloak OWNER keycloak` via `psql` inside the postgres pod), `postgresql.enabled: false` + `externalDatabase` pointing at `postgres.osmo.svc.cluster.local` with `user: keycloak` (full block in §3c). The chart-bundled database (the guide's "for testing" path) is avoided so there is no second database workload. `keycloak-db-secret` in the `keycloak` namespace holds key `postgres-password` — the dedicated keycloak role's own random password (the chart's secret-key name is fixed), created with a shell variable so the value never prints. Keycloak deliberately does NOT use OSMO's `postgres` superuser credential: that password is readable from several pods, and the internet-exposed IdP must not share the database's most privileged credential.
- **TLS**: Keycloak terminates its own TLS: `tls.enabled: true`, `tls.usePem: true` (cert-manager's Secret holds `tls.crt`/`tls.key` PEM; without `usePem: true` the Bitnami chart expects JKS keystores and Keycloak fails to start), `tls.existingSecret: keycloak-tls` — no `autoGenerated` (autoGenerated mints a cert nobody holds the CA for, which breaks oauth2-proxy's provider CA pinning). The Secret is a cert-manager `Certificate` from the existing `osmo-selfsigned` ClusterIssuer (Phase 4d of [osmo-install.md](osmo-install.md)) with `dnsNames` for the in-cluster Service names (`keycloak`, `keycloak.keycloak`, `keycloak.keycloak.svc`, `keycloak.keycloak.svc.cluster.local`) **plus `localhost`** (in-pod admin calls verify against this certificate via `https://localhost:8443`), **`ipAddresses: [<KC_LB_IP>]`** so the cert matches the IP, `duration: 8760h`, `renewBefore: 720h` (all ). Consequence stated plainly: browsers hitting `https://<KC_LB_IP>` get an untrusted-certificate warning unless the user imports that CA (`keycloak-tls`'s `ca.crt`, exported the way Phase 9 exports the gateway CA) into their trust store. A public CA will not issue for a bare IP, same rule as the gateway cert.
- **Exposure**: Service `type: LoadBalancer` in the `keycloak` namespace with the `crusoe.ai/manage-firewall-rule: "true"` annotation (the Service will show a managed firewall-rule-id). The guide's Ingress is not used (no ingress controller). **No cleartext port is published on the LB**: `service.http.enabled: false` omits the http Service port (helm-template-verified on chart 24.4.9) — the default install publishes 8080 and it must be closed afterwards. Do **not** also set `KC_HTTP_ENABLED=false`: the chart's liveness/readiness probes target the `http` (8080) port, so a dead 8080 means the pod never goes Ready; the container's in-cluster 8080 listener stays but nothing exposes it. **The `https-443: 443 → 8443` Service port is added via `kubectl patch`** — that is what makes in-cluster `https://keycloak.keycloak.svc/...` (no port) work for Envoy's JWKS fetch (§2d). The extra port cannot live in the chart values, and **any later `helm upgrade` of the keycloak release resets the Service — re-apply the patch afterwards** (a live `helm upgrade` conflicted with the patch: "Apply failed with 1 conflict: … .spec.type").
- **Firewall**: the Keycloak LB gets its own firewall rule like the gateway's; restrict it to user networks per the skill's existing warning pattern. **[INFERENCE]** — same controller-managed rule behavior observed for the gateway Service (recorded in [osmo-install.md](osmo-install.md) Phase 9).

### 2b. Realm and clients

Follow the official guide Part 1 Step 3 exactly (https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/keycloak_setup.html):

1. Import the sample realm `sample_osmo_realm.json` (guide's download; a copy lives at https://nvidia.github.io/OSMO/release/6.3/_downloads/3af0bbc2b0a3138cfb6a4258b5f336a5/sample_osmo_realm.json). It defines realm `osmo`, clients `osmo-browser-flow` (confidential, has `secret`, roles-claim protocol mapper, `oauth2.device.authorization.grant.enabled: false`) and `osmo-device` (public, device grant enabled), and groups `Admin` (roles `osmo-admin`, `osmo-user` in both clients), `Backend Operator` (role `osmo-backend` on `osmo-device`), `User` (role `osmo-user` in both clients). The mappers build a `roles` claim from client roles — that is the claim the Envoy lua filter turns into `x-osmo-roles` (chart `service/templates/_gateway-envoy-config.tpl`, `envoy.filters.http.lua.roles` reads `verified_jwt.roles`).
2. Update both clients' URLs to **this** deployment (guide says replace `osmo.example.com` with the real host; here that is an IP):
   - `osmo-browser-flow`: Root/Home/Admin URL `https://<OSMO_LB_IP>`, **Valid Redirect URIs** `https://<OSMO_LB_IP>/oauth2/callback` and `https://<OSMO_LB_IP>/api/auth/getAToken`, Web Origins `https://<OSMO_LB_IP>`.
   - `osmo-device`: Valid Redirect URIs `https://<OSMO_LB_IP>/*`.
   - `/oauth2/callback` is the redirect the chart hard-bakes into oauth2-proxy (`--redirect-url=https://$envoyHostname/oauth2/callback`, chart `service/templates/gateway.yaml`); `/api/auth/getAToken` is the redirect the docs register for IdP apps (https://nvidia.github.io/OSMO/release/6.3/deployment_guide/appendix/authentication/identity_provider_setup.html).
3. On `osmo-browser-flow` → Credentials, create and save the client secret (guide). Mechanics: the secret is generated (`secrets.token_urlsafe(32)`), **never printed**, and stored straight into the Kubernetes secret from §2c. The device-grant attributes matter: `osmo-browser-flow` has `oauth2.device.authorization.grant.enabled: "false"`, `osmo-device` has it `"true"` — getting either backwards breaks the CLI's device flow or lets the browser client mint device tokens.
4. Keycloak does not set `email_verified: true` by default; the guide requires `--insecure-oidc-allow-unverified-email=true` in oauth2-proxy's `extraArgs`, or logins get rejected. Keep it (guide, "Note").

**Import and client edits.** The realm was imported with a single `POST /admin/realms` carrying `sample_osmo_realm.json` (HTTP 201), and the client edits above were made with the Keycloak admin API (`PUT /admin/realms/osmo/clients/<id>`, including `rootUrl`/`baseUrl`/`adminUrl`), from a token minted **inside the `keycloak-0` pod against `https://localhost:8443`** (see "Failure lessons" for the issuer caveat). The same steps work in the admin console at `https://<KC_LB_IP>` (admin credentials live in the `keycloak/keycloak-admin-password` Secret, never in a file or the chat).

**Email.** The guide's oauth2-proxy rejects logins whose email is unverified, so Keycloak users must have `email` + `emailVerified: true` there. The skill instead sets `--oidc-email-claim=preferred_username` in oauth2-proxy's `extraArgs` (§3a), which makes sessions work even when a user has no email at all — no per-user manual email step. The doc records both requirements and **prefers the flag**: when creating users, set a real `email` + `emailVerified: true` (recommended), but the flag is the mechanism that makes email non-blocking.

### 2c. OAuth2 proxy secret

Per the guide ("Create secrets"), in the `osmo` namespace — the chart's own secret is also named `oauth2-proxy-secrets`, so this replaces nothing:

```bash
kubectl --namespace osmo create secret generic oauth2-proxy-secrets \
  --from-literal=client_secret=<client secret from 2b step 3> \
  --from-literal=cookie_secret="$(openssl rand -hex 16)"
```

The mounted keys must be exactly `client_secret` and `cookie_secret` (chart `secretName`/`clientSecretKey`/`cookieSecretKey` defaults). **Verified recipe:** `openssl rand -hex 16`. The guide's `openssl rand -base64 32` produces standard base64 whose `+/` characters and trailing newline the mounted `--cookie-secret-file` path does not tolerate; 32 hex chars decode to the same 16 raw bytes oauth2-proxy requires, and hex carries none of those problems. Do not swap back to base64. Generate the client secret (§2b step 3) and create this Secret **in the same command** — shell state does not persist between commands.

`useKubernetesSecrets: true` makes the chart mount both keys as files (`--client-secret-file/--cookie-secret-file`, chart `service/templates/gateway.yaml`); `secretName`/`clientSecretKey`/`cookieSecretKey` keep their defaults. Never print the client secret (same rule as the Object Storage key in [osmo-install.md](osmo-install.md) Phase 2e).

### 2d. Envoy → Keycloak JWKS

`gateway.envoy.idp.host` renders an Envoy `idp` cluster: STRICT_DNS, **port 443, TLS, no cert validation** (chart `service/templates/_gateway-envoy-config.tpl` — the cluster has `UpstreamTlsContext` + SNI but no `validation_context`, so the self-signed Keycloak cert works). Point it in-cluster at `keycloak.keycloak.svc.cluster.local` — the Service name `keycloak` in namespace `keycloak` (verified with `kubectl get svc -n keycloak`). The 443→8443 Service port from §2a is what makes this FQDN reachable on 443 with no port in the URL; without the patch the JWKS fetch hits a closed port. Note the asymmetry, verified: in-cluster pods **can** reach the Keycloak LB IP (a curl to `https://<KC_LB_IP>/realms/osmo` returned 200 from in-cluster), unlike the gateway's own LB IP (osmo-install.md Phase 7); the JWKS still goes in-cluster so it never depends on the LB.

Envoy validates Keycloak JWTs against `jwks_uri` via the `idp` cluster; the issuer string in the provider must equal Keycloak's pinned issuer (`https://<KC_LB_IP>/realms/osmo`). The `jwks_uri`'s authority is only used to select the cluster, so the value is `jwks_uri: https://keycloak.keycloak.svc.cluster.local/realms/osmo/protocol/openid-connect/certs` with `cluster: idp` — the JWKS fetch stays inside the cluster. Chart mechanics: `remote_jwks.http_uri` + `cluster: {{ $provider.cluster }}` (`_gateway-envoy-config.tpl`).

oauth2-proxy itself talks to Keycloak (discovery, token exchange, userinfo) over **HTTPS against the public LB IP** (`oidcIssuerUrl: https://<KC_LB_IP>/realms/osmo`) and **validates certificates by default**; the chart has no CA-file value, so pin the Keycloak CA through the existing escape hatches (all in §3a):

- Secret `keycloak-ca` in the `osmo` namespace, `--from-file=ca.crt=<the Keycloak CA from §2a>` (the same CA the browser imports).
- `gateway.oauth2Proxy.extraArgs: ["--provider-ca-file=/etc/keycloak-ca/ca.crt", …]` plus `extraVolumes`/`extraVolumeMounts` mounting that Secret.
- **The mountPath is a directory (`/etc/keycloak-ca`); never a subPath file inside the chart's read-only `/etc/oauth2-proxy` secret mount** — a subPath file there fails at container create.

The skill's hard rule stands: **never** use `--ssl-insecure-skip-verify` (the same flag family as "never disable certificate verification" in [SKILL.md](../SKILL.md)).

## 3. Exactly which existing values blocks change

### 3a. `$WORKDIR/osmo-service-values.yaml` — gateway auth additions

The exact yaml (gateway/envoy `idp`+`jwt` providers, `oauth2Proxy`, `authz.enabled: true`, `services.service.auth`, `ui.apiHostname: crusoe:80`) is inline at keycloak-install.md step f, in the order it is applied. The rationale this section carries:

**CRITICAL CHART QUIRK: this chart renders only a SINGULAR `audience` per provider.** `service/templates/_gateway-envoy-config.tpl` reads `$provider.audience`; an `audiences:` list is silently ignored, and a provider whose audience never matches 401s every token it should accept. The audience values are not the client IDs, and that is the subtle part: Keycloak **access** tokens (password grant, device grant, and the code flow's `access_token`) carry `aud=account` (with `azp=<client-id>`), while the UI forwards its **id_token**, whose `aud=osmo-browser-flow`. **The CLI's device flow sends its `id_token` as the Bearer token, and that id_token carries `aud=osmo-device`**. The `services.service.auth` endpoints follow the official Keycloak endpoint table, with the device endpoint at `.../openid-connect/auth/device` (Keycloak 26's path — the values-comment's `.../device` is stale).

### 3b. `$WORKDIR/osmo-backend-values.yaml`

**No values change.** `serviceUrl: https://crusoe.osmo.svc.cluster.local` and `loginMethod: token` are both documented for IdP-enabled deployments (deploy_backend.html), and `accountTokenSecret: backend-operator-password` / `accountTokenSecretKey: password` stay as they are. **The backend operator authenticates with OSMO's own opaque token, NOT a Keycloak token** — it exchanges the `accountTokenSecret` value at `POST /api/auth/jwt/access_token` (a `skipAuthPath`) for a service-issued JWT carrying the user's roles. What changes with `authz.enabled` is therefore not the token but the **user's roles**: `/api/agent/worker/…` traffic must carry the `osmo-backend` role — `osmo-admin` alone is excluded from the backend websocket APIs (roles_policies.…)

(Request shapes per the OSMO source `src/service/core/auth/auth_service.py` and the "Authentication Flow" doc: exchange body `{"token": …}` → `{token}`; role assignment is `BulkAssignRequest {user_ids: […]}` at `POST /api/auth/roles/{role_name}/users`.) The token value never prints: it exists only inside the command substitution. **Order:** run this after the `helm upgrade` in §5 step 5 — the exchange endpoint stays an auth-skipped path, so the bootstrap admin can still mint the JWT — then restart the backend worker so it re-exchanges with both roles; skip the restart only if the worker log still shows `Successfully connected` afterwards.

**How to run the exchange and grant: inside the cluster, with TLS verified.** The in-cluster Service name `crusoe` does not resolve on the operator's machine, and the calls carry credentials, so neither a host-side `curl` nor `-k` is acceptable. The token and Phase 7's combined CA bundle reach the throwaway pod through stdin as script text — never argv, never printed (the exact mechanics: keycloak-install.md step g).

The exact commands are [keycloak-install.md](keycloak-install.md) step g (token from the Secret, in-cluster exchange and grant, stdin-only secrets, BusyBox-decode CA).

### 3c. New Keycloak values file

The exact `$WORKDIR/keycloak-values.yaml` is inline at keycloak-install.md step c. The rationale this section carries: it pins `hostname: <KC_LB_IP>` (Keycloak uses the request `Host` as the token issuer, so the issuer must be the public IP), `tls.usePem: true` with the cert-manager Secret, `production: true`, `proxy` deliberately unset (§2a Exposure), `autoscaling.enabled: false` (single replica — §6), the `osmo-type: control` nodeSelector, `service.http.enabled: false` (no cleartext port on the LB), and the external database with the dedicated least-privilege `keycloak` role (step a).

### 3d. Role policy wiring for allowedPools

With `defaultIdentity` emptied, pool visibility and workflow access come from authz role policies (the sidecar's `computeAllowedPools` derives `x-osmo-allowed-pools` from them, authz_server.go — no static header anywhere). **What shipped: `services.configs.roles` keeps the chart defaults EXACTLY — `osmo-admin` (`*:*`), `osmo-backend` (`*:*`), `osmo-ctrl` (`internal:*`), `osmo-default`, and the rich `osmo-user` policy — and `osmo-user` gains exactly ONE extra policy granting `workflow:*` on each GPU pool resource:**

(The exact policies yaml is inline at keycloak-install.md step f.)

**Do not invent a stripped-down `osmo-user` policy: a stripped one denies `/api/bucket` with 401.** The rich chart-default actions (`app:*`, `credentials:*`, `dataset:*`, …) are exactly what the UI's authenticated API calls exercise; with them intact and the per-pool workflow grant added, users with `osmo-user` get 200s on the UI's API calls and roleless users get 401 (both verified). No `osmo-<pool_name>` roles are needed and none were created — the per-pool workflow grant on `osmo-user` covers the pool. Nothing is mirrored in Keycloak either: Keycloak only carries the `osmo-*` client roles onto the `roles` claim; the policies live solely in this Helm block.

## 4. Service-to-service traffic that must keep working

| Path | Today | Under oauth2Proxy+authz | Basis |
|---|---|---|---|
| Backend operator websocket `wss://crusoe/api/agent/worker/…` (in-cluster Service DNS) | Plain Bearer token against unauthenticated gateway | Bearer requests skip oauth2-proxy (Envoy matcher on `authorization: Bearer`), must satisfy a JWT provider, then pass authz with the `osmo-backend` role | **Verified**: the operator exchanges its opaque token for a service JWT at `/api/auth/jwt/access_token` (a `skipAuthPath`), the `issuer: osmo` provider validates that JWT (§3a), and its user carries `osmo-backend` via the users API (§3b). **Do not add `/api/agent/` to `gateway.envoy.extraSkipAuthPaths`** — even as a troubleshooting escape hatch. That path is served on the **public** load balancer, so skipping auth there lets anyone on the internet register as a backend worker and receive or forge GPU-workflow results on the user's account (the live run shows the token-exchange path works and the hatch is not needed). Only the user, seeing the exact value, can decide to expose an unauthenticated public route; never as an agent-initiated "fix" |
| Workflow `osmo-ctrl` sidecars → gateway (`service_base_url https://crusoe.osmo.svc.cluster.local`) | Trusted via self-signed CA ConfigMap + `OSMO_LOGIN_DEV: true` | Service mints JWTs for workflows with `ctrl_roles: [osmo-user, osmo-ctrl]`, issuer `osmo`, audience `osmo`; provider_2 validates them; `osmo-ctrl` role policies allow `internal:Logger`/`internal:Router` | configs_definitions/service.html (Service Authentication); roles_policies.html (osmo-ctrl). **Verified**: the compute templates keep `OSMO_LOGIN_DEV: true` and workflows run to `SUCCESS` with auth on — no removal needed |
| S3 (workflow data/logs/apps → Crusoe Object Storage) | Direct `AWS_ENDPOINT_URL_S3` / bucket-credential traffic from service/worker pods and workflow pods | Unchanged: S3 traffic does not traverse the Envoy gateway at all — the docs treat storage as a plain credential concern (Deploy Service, "Workflow storage credentials"; user data via per-workflow credentials) and never route it through the gateway | deploy_service.html storage sections; the auth docs never mention S3 |
| Operator `wait-for-gateway` init containers (`nc -z crusoe 443`) | TCP-only reachability check | Unaffected (no HTTP involved) | [osmo-install.md](osmo-install.md) Phase 5 |
| Backend-operator → Postgres/Redis, workflow → K8s API | In-cluster, outside the gateway | Unaffected — the auth chain lives entirely in the Envoy gateway and its two sidecars | chart `service/templates/gateway.yaml` (auth components are gateway-scoped) |
| Envoy → upstream services (osmo-service, router, agent, logger) | TLS, encryption-only (no CA validation) | Unchanged: `gateway.tls.enabled: true` with `caSecret: ""` stays; docs confirm Envoy connects without validating | chart `service/values.yaml` `gateway.tls`; chart README "Gateway → Upstream TLS" |

## 5. Execution order (all steps verified)

The exact ordered commands are [keycloak-install.md](keycloak-install.md) — its steps a–i carry everything this run executed, in order. What §5 adds here is only the order rationale the commands do not spell out:

1. Keycloak namespace + database + Secrets + Certificate first (the namespace must exist before any secret lands in it); a bootstrap install obtains `KC_LB_IP`, then the final `helm upgrade` applies `hostname: <KC_LB_IP>` (the issuer pins to the request host — see §3c).
2. Realm import and client edits before any OSMO values change (the client secret generated here feeds §2c's `oauth2-proxy-secrets`).
3. OSMO values edits + `helm upgrade` (all 7 `--set-string` flags) after the secrets exist — then the two mandatory rollout restarts (Failure lessons below).
4. The backend-operator role grant after authz is on (its opaque-token exchange needs the gateway; §3b).

### Failure lessons

The lessons whose full mechanism lives elsewhere: the singular-`audience` chart quirk and the provider pairing (§3a), the mandatory envoy/authz rollout restarts (keycloak-install.md step f), the stripped-`osmo-user` 401 (§3d). What is unique to this run:

- **In-cluster pods CAN reach the Keycloak LB IP (tested: curl → 200) — but they cannot reach the GATEWAY's own LB IP** (osmo-install.md Phase 7). That asymmetry is why oauth2-proxy can use `oidcIssuerUrl: https://<KC_LB_IP>/realms/osmo` from inside the cluster while the UI must use `apiHostname: crusoe:80`.
- **Token mints inside the pod carry `iss=https://localhost:8443`** (Keycloak uses the request `Host` for the token issuer). For test tokens whose issuer must match the pinned `https://<KC_LB_IP>/realms/osmo`, mint from the host against the public IP instead of in-pod.

## 6. Residual unknowns

What remains genuinely unverified, in order of likelihood to bite:

1. **Multi-node Keycloak HA.** This setup runs a single replica (`autoscaling.enabled: false`); the official guide's two-replica autoscaling was never exercised. On a multi-node cluster, verify pod anti-affinity and that the authz/oauth2 flows are unaffected by a Keycloak pod move.
2. **Realm-wide email strictness.** The `--oidc-email-claim=preferred_username` flag sidesteps email entirely; Keycloak configured to *require* verified emails (realm-level `emailVerified` enforcement + no fallback claim) was never tested. Prefer the flag (§2b).
3. **Certificate renewal rotation.** `keycloak-tls` renews after 8760h (renewal ~720h before); that event is over a year out and untested. There is no `envoy-ca-cert`-style refresh loop for the Keycloak CA: on rotation, re-export the CA, update the `keycloak-ca` Secret and the browser-imported CA, and restart `crusoe-oauth2-proxy`. Also confirm cert-manager rotates the IP SAN correctly (it did on issuance).
4. **Long-lived token refresh beyond the 168h cookie.** oauth2-proxy's session cookie expires at `cookie-expire: 168h` with `cookie-refresh: 1h`; the refresh path through Keycloak was exercised for short sessions only. A session idle for more than 168h (or a refresh failure after a Keycloak restart) is untested — expect a re-login.

[keycloak-install.md](keycloak-install.md) (osmo-install.md's Phase 10) carries the exact commands; [teardown.md](teardown.md) covers the Keycloak resources (namespace, load balancer, certificate, secrets).

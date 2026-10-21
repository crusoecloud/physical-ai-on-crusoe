# Teardown

Part of the deploy-osmo-crusoe skill. Read [SKILL.md](../SKILL.md) first: its scope, tool-routing and sandbox rules apply. Use this when the user asks to tear down, delete or uninstall an OSMO deployment that this skill created. It deletes billable and partly irreversible things, so it is built around one rule: **nothing is deleted until the user has confirmed the exact inventory.**

Run Phase 0 of SKILL.md first (tools, mode announcement, identity, project), then this file. As in [osmo-install.md](osmo-install.md), run every `kubectl`, `helm` and `crusoe` command outside the sandbox, always in the same mode.

## Safety rules

- Delete only what appears in the inventory the user confirmed. Never run a broad delete (`kubectl delete --all`, `--all-namespaces`, or deleting by a name pattern).
- Delete Crusoe resources by **ID** taken from this cluster's own data, never by bare name or alias: other clusters in the same project can have pools, keys and partitions with the same names (for example `osmo-control-pool`, `h100`, `osmo-workflow-data`).
- **Pin the cluster.** Every `kubectl` command uses `--context "$KCTX"` and every `helm` command uses `--kube-context "$KCTX"`, where `KCTX` was proven in T1 to be this cluster. Never rely on the current context.
- Never touch another cluster's pools, load balancers, disks, partitions, buckets or keys. If this cluster holds something this skill did not create (an unknown pool, extra namespaces, other LoadBalancer Services), say so and ask.
- Run each destructive command on its own, report its result, and only then run the next.
- Never delete a storage key, a bucket or an IB partition on your own: see Phases T3 and T4.
- If a command fails, stop and report. Do not retry with different flags or force options. Never strip finalizers.

## Variables

Shell state does not persist between commands, and the Crusoe IDs below are needed after the cluster is gone. T1 therefore writes them (no secrets, only names and IDs) to `"$WORKDIR/teardown.env"`, and **every later command block starts with**:

```bash
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"
set -a; . "$WORKDIR/teardown.env"; set +a
```

and then guards each variable it uses, for example `: "${LB_ID:?}"`, so an empty value stops the command instead of becoming `delete ""` or `grep -c ""`.

## Phase T1 — Inventory (read-only)

1. **Cluster and project.** Ask for the cluster name (or take it from `kubectl config current-context` if it is clearly the one) and set `CLUSTER_NAME`. Then:

```bash
case "$CLUSTER_NAME" in ""|*[!A-Za-z0-9_-]*) echo "invalid cluster name (letters, digits, - and _ only)"; exit 1 ;; esac
WORKDIR="$HOME/.osmo-install/${CLUSTER_NAME:?set CLUSTER_NAME}"; mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
CJ=$(crusoe kubernetes clusters get "$CLUSTER_NAME" --json)
CLUSTER_ID=$(printf '%s' "$CJ" | jq -r .id)
[ -n "$CLUSTER_ID" ] && [ "$CLUSTER_ID" != null ] || { echo "could not read the cluster ID (is jq installed, or does the cluster no longer exist? then go to T4)"; exit 1; }
API_URL="https://$(printf '%s' "$CJ" | jq -r .dns_name)"
[ "$API_URL" != "https://null" ] && [ "$API_URL" != "https://" ] || { echo "could not read the cluster's dns_name"; exit 1; }
echo "cluster $CLUSTER_ID  api $API_URL  project ${CRUSOE_DEFAULT_PROJECT:-$(crusoe config get default_project)}"
```

   If `clusters get` fails because the cluster no longer exists, skip to T4 and say so. T4 can then only use an existing `teardown.env` from an earlier run. If there is none, the IDs are unknown: offer nothing in T4 (keep every bucket, key and partition), say why, and never fall back to matching by name or alias.
2. **Prove which kubectl context is this cluster.** A context's name does not have to match the cluster's name; compare API server URLs instead:

```bash
for c in $(kubectl config get-contexts -o name); do
  s=$(kubectl config view --minify --context "$c" -o jsonpath='{.clusters[0].cluster.server}')
  [ "$s" = "$API_URL" ] && echo "match: $c"
done
```

   Exactly one match: that is `KCTX`. None: run `crusoe kubernetes clusters get-credentials "$CLUSTER_NAME" --yes` and repeat. Several: ask the user which. Then check `kubectl --context "$KCTX" get nodes` shows this cluster's pool names.
3. **Node pools**, with IDs: `crusoe kubernetes nodepools list --cluster-id "$CLUSTER_ID" --json` (name, `id`, type, state). Flag any pool that is not `osmo-control-pool`, `osmo-backend-pool` or a GPU pool the user recognises.
4. **OSMO in the cluster**: `helm --kube-context "$KCTX" list -A` (expect `osmo` and `osmo-backend-operator` in `osmo`, plus cert-manager, kai-scheduler, crusoe-lb-controller) and `kubectl --context "$KCTX" get ns`. Also list workflow pods that may still run in `default` and `osmo-test` (`get pods -n default`, `-n osmo-test`): report them, never delete them in bulk.
5. **What the OSMO gateway owns on the Crusoe side.** Read it from the running Service before anything is uninstalled:

```bash
LB_ID=$(kubectl --context "$KCTX" get svc crusoe -n osmo -o jsonpath='{.metadata.annotations.crusoe\.ai/load-balancer-id}')
FW_ID=$(kubectl --context "$KCTX" get svc crusoe -n osmo -o jsonpath='{.metadata.annotations.crusoe\.ai/firewall-rule-id}')
echo "load balancer: ${LB_ID:-none}   firewall rule: ${FW_ID:-none}"
```

   If the Service is named `osmo-gateway` (a deployment made with the chart's old default), use that name. If the Service is missing or an annotation is empty, the load balancer cannot be identified: list the load balancers named `osmo-crusoe-*` (or `osmo-osmo-gateway-*` for the old Service name) in this cluster's location with `crusoe networking load-balancers list --json` (ID, name, VIP), mark them "unidentified, will not be touched", and let the user say which ID, if any, belongs to this cluster.
6. **Keycloak (only when installed).** Detect it before inventorying anything Keycloak-related: `kubectl --context "$KCTX" get ns keycloak` exists or `helm --kube-context "$KCTX" list -n keycloak` shows the release `keycloak` (chart `bitnami/keycloak`). If neither does, Keycloak is absent: skip the rest of this step, everything Keycloak-related in T2, and write no `KC_*` variable to `teardown.env`. If it is present, warn the user now: the `keycloak-admin-password` Secret in the `keycloak` namespace holds the **only copy of the Keycloak admin password**, and the T2 deletion of that namespace loses console access permanently. Record the release name and chart, then read what Keycloak's load balancer owns on the Crusoe side, exactly as step 5 does for the gateway:

```bash
KC_LB_ID=$(kubectl --context "$KCTX" get svc keycloak -n keycloak -o jsonpath='{.metadata.annotations.crusoe\.ai/load-balancer-id}')
KC_FW_ID=$(kubectl --context "$KCTX" get svc keycloak -n keycloak -o jsonpath='{.metadata.annotations.crusoe\.ai/firewall-rule-id}')
echo "keycloak load balancer: ${KC_LB_ID:-none}   firewall rule: ${KC_FW_ID:-none}"
```

   If the Service is missing or an annotation is empty: handle it exactly like step 5's gateway case.
```bash
for pv in $(kubectl --context "$KCTX" get pvc -n keycloak -o jsonpath='{.items[*].spec.volumeName}'); do
  echo "$pv disk=$(kubectl --context "$KCTX" get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}') reclaim=$(kubectl --context "$KCTX" get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
done
```

   Record the IDs as `KC_DISK_IDS` (space-separated, same `%q` quoting as `DISK_IDS`). Keycloak's database is the `keycloak` database inside OSMO's own Postgres (the chart's `externalDatabase.host` is `postgres.osmo.svc.cluster.local`), so it dies with the `osmo` namespace deletion in T2 — no separate database cleanup. The `oauth2-proxy-secrets` and `keycloak-ca` Secrets in the `osmo` namespace are **not** part of the `osmo` release: Phase 10e creates them with `kubectl apply`, so `helm uninstall osmo` leaves them behind and the `osmo` namespace deletion in T2 is what removes them; the `keycloak-db-secret`, `keycloak-tls`, ConfigMaps and Service in `keycloak` die with the namespace deletion. A reclaim policy other than `Delete` on any Keycloak PV means the namespace deletion will NOT remove that disk: note it for T3, same as the OSMO disks. **For Level 2**, the `kubectl --context "$KCTX" get svc -A --field-selector spec.type=LoadBalancer` and `get pv` listing in step 7 already covers the `keycloak` namespace; show it to the user with the rest.
7. **What the OSMO volumes own.** The disks behind the PVCs in `osmo`:

```bash
for pv in $(kubectl --context "$KCTX" get pvc -n osmo -o jsonpath='{.items[*].spec.volumeName}'); do
  echo "$pv disk=$(kubectl --context "$KCTX" get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}') reclaim=$(kubectl --context "$KCTX" get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
done
```

   Record the disk IDs as `DISK_IDS` (space-separated). A reclaim policy other than `Delete` means the namespace deletion will NOT remove that disk: note it for T3. **For Level 2, also list everything else in the cluster that owns billable Crusoe resources:** `kubectl --context "$KCTX" get svc -A --field-selector spec.type=LoadBalancer` and `kubectl --context "$KCTX" get pv`. Show every item that is not part of OSMO. They will be orphaned when the cluster is deleted; the skill does not delete them, so the user decides.
8. **IB partitions this cluster's pools actually use.** Each GPU node's VM names its partition. VMs belong to a pool through `instance_group_id` (equal to the pool ID):

```bash
POOLS_JSON=$(crusoe kubernetes nodepools list --cluster-id "$CLUSTER_ID" --json)
crusoe compute vms list --json | jq -r --argjson ids "$(printf '%s' "$POOLS_JSON" | jq '[.[].id]')" \
  '[.[] | select(.instance_group_id as $g | $ids | index($g)) | .host_channel_adapters[]?.transport_partition_id] | unique | .[]'
```

   Record them as `PARTITION_IDS`. Show each with its name from `crusoe networking transport-partitions list --json`.
9. **The bucket and the storage key, without printing credentials.**
   - Bucket: `kubectl --context "$KCTX" get configmap osmo-service-configs -n osmo -o jsonpath='{.data.config\.yaml}' | grep -o 's3://[a-z0-9-]*' | head -1 | sed 's#s3://##'` (or ask the user), then `crusoe storage buckets get "$BUCKET_NAME"` for its versioning, object lock and retention state, and record its `location` as `LOCATION` (the T3 purge needs it: object access is location-scoped).
   - Key: read the access key **ID** (an identifier, not the secret) that this cluster's OSMO uses: `kubectl --context "$KCTX" get configmap osmo-service-configs -n osmo -o jsonpath='{.data.config\.yaml}' | grep -o 'access_key_id: *[A-Z0-9]*' | head -1 | sed 's/.*: *//'` as `KEY_ACCESS_ID`. Match it against `crusoe storage tokens list --json` on the `access_key_id` field to get this cluster's `KEY_UUID` and alias. The T4 delete identifies the key by this **access key ID** (the by-access-key-ID rule lives in [tool-routing.md](tool-routing.md)). Keys with the same alias that do not match belong to other clusters and are never offered. If nothing matches, keep every key and say so. If OSMO was never installed (a failed Phase 2), there is no `osmo-service-configs` ConfigMap to read: use the bucket name and the key's `key_uuid` and access key ID that Phase 2 reported to the user, confirm them with the user, and still match the key against `tokens list` on `access_key_id` before offering anything.
10. **Write the env file** `"$WORKDIR/teardown.env"`, one line per variable, written with `printf '%s=%q\n' NAME "$value"`. The variables are `CLUSTER_NAME`, `CLUSTER_ID`, `API_URL`, `KCTX`, `LB_ID`, `FW_ID`, `DISK_IDS`, `PARTITION_IDS`, `BUCKET_NAME`, `KEY_ACCESS_ID`, `KEY_UUID`, `POOLS` (`name:id name:id ...`), `LOCATION`, and, when Keycloak exists (step 6), `KC_LB_ID`, `KC_FW_ID`, `KC_DISK_IDS` (empty means that resource was absent; none of them is written at all when Keycloak is absent). `%q` quotes each value so the space-separated lists (`DISK_IDS`, `KC_DISK_IDS`, `PARTITION_IDS`, `POOLS`) survive being sourced; a bare `DISK_IDS=a b` line would run `b` as a command and leave the variable unset. The file holds names and IDs only, never secrets; then `chmod 600`. **If `teardown.env` already exists** (a re-run after a partial teardown), first compare its recorded `CLUSTER_ID` with the live one from step 1: if they differ, it belongs to an earlier cluster that had the same name, so stop and ask the user whether to discard it. Otherwise show its contents and merge it with what you just read: for each variable use the value read live in steps 1-9 when it is non-empty (a fresh reinstall after a Level 1 teardown creates a new load balancer, firewall rule and disks, so the recorded IDs can be stale), and keep the recorded value only where the live read came back empty because its source is already gone. Never overwrite a recorded `LB_ID`, `FW_ID`, `DISK_IDS`, `KC_LB_ID`, `KC_FW_ID`, `KC_DISK_IDS`, `BUCKET_NAME`, `KEY_ACCESS_ID` or `KEY_UUID` with an empty value, because the Service, PVCs and ConfigMap they were read from may already be gone.
11. **Show the inventory** as a table, with the project name and ID and the context `KCTX`, and ask for the level:
    - **Level 1, uninstall OSMO only.** Removes the OSMO releases and namespaces and the gateway load balancer, and, when Keycloak is installed (step 6), the Keycloak release, namespace, load balancer and disks — that namespace also holds the only copy of the Keycloak admin password — and **permanently deletes OSMO's Postgres and Redis volumes: workflow history, users and configuration are lost.** The cluster and node pools stay; reinstalling OSMO means a fresh end-to-end run of the deploy skill.
    - **Level 2, full teardown.** Level 1, then the bucket and key (with separate questions, while the cluster still exists), then the node pools, the cluster, and the IB partition.
12. **Confirm.** Print exactly what will be deleted at the chosen level (IDs and `KCTX` included) and ask the user to type the cluster name to confirm. Do not continue on anything else.

## Phase T2 — Level 1: uninstall OSMO

Start every command block with the Variables lines above. **Before the first delete, re-prove the pin** and stop if it fails:

```bash
: "${KCTX:?}" "${API_URL:?}"
[ "$(kubectl config view --minify --context "$KCTX" -o jsonpath='{.clusters[0].cluster.server}')" = "$API_URL" ] \
  || { echo "context $KCTX no longer points at $API_URL"; exit 1; }
```

Uninstall the releases first (only those that are still installed, so a re-run works), so that the gateway Service goes away and the Crusoe LB controller deletes its load balancer and firewall rule:

```bash
helm --kube-context "$KCTX" list -n osmo -q
helm --kube-context "$KCTX" uninstall osmo-backend-operator -n osmo
helm --kube-context "$KCTX" uninstall osmo -n osmo
```

(run an uninstall only if its release appears in the list). **If Keycloak was inventoried in T1 step 6**, uninstall it too — again only if `helm --kube-context "$KCTX" list -n keycloak -q` still shows the release — report its result, then delete its namespace:

```bash
helm --kube-context "$KCTX" uninstall keycloak -n keycloak
kubectl --context "$KCTX" delete namespace keycloak --ignore-not-found --timeout=10m
```

Deleting the namespace removes the `keycloak-data-*` PVCs and (with reclaim `Delete`) their disks — exactly like the `osmo` namespace below; Keycloak's database was OSMO's own Postgres and dies with it. The admin-password and TLS Secrets die with the namespace (T1 step 6 warned: no other copy). If a Keycloak PV had a reclaim policy other than `Delete` (noted in T1), its disk is verified below and deleted by name only on the user's say-so.

```bash
kubectl --context "$KCTX" delete namespace osmo --ignore-not-found --timeout=10m
kubectl --context "$KCTX" delete namespace osmo-test --ignore-not-found --timeout=5m
kubectl --context "$KCTX" delete clusterissuer osmo-selfsigned --ignore-not-found
kubectl --context "$KCTX" delete configmap envoy-ca-cert -n default --ignore-not-found
```

If a namespace deletion times out it is stuck in `Terminating`: report what is blocking it (`kubectl --context "$KCTX" get ns <name> -o yaml`) and stop. Never remove finalizers. Leave KAI Scheduler, cert-manager, the Crusoe LB controller and the StorageClass in place: they are shared cluster components. Mention them to the user.

**Verify the Crusoe-side resources are gone.** The controllers delete them asynchronously: poll every 30 seconds for up to 10 minutes until all five checks print `0` (an ID that was not recorded prints `none recorded` instead of passing silently):

```bash
[ -n "${LB_ID:-}" ] && echo "lb listed: $(crusoe networking load-balancers list --json | jq --arg id "$LB_ID" '[.[] | select(.id==$id)] | length')" || echo "lb: none recorded"
[ -n "${FW_ID:-}" ] && echo "firewall rule listed: $(crusoe networking vpc-firewall-rules list --json | jq --arg id "$FW_ID" '[.[] | select(.id==$id)] | length')" || echo "firewall rule: none recorded"
[ -n "${KC_LB_ID:-}" ] && echo "keycloak lb listed: $(crusoe networking load-balancers list --json | jq --arg id "$KC_LB_ID" '[.[] | select(.id==$id)] | length')" || echo "keycloak lb: none recorded"
[ -n "${KC_FW_ID:-}" ] && echo "keycloak firewall rule listed: $(crusoe networking vpc-firewall-rules list --json | jq --arg id "$KC_FW_ID" '[.[] | select(.id==$id)] | length')" || echo "keycloak firewall rule: none recorded"
# One snapshot per poll iteration: the listing is hoisted out of the disk loop
# (a per-disk list call inside the loop re-enumerates the whole project once
# per disk; with 3+ disks × 20 polls that is ~60-100 identical listings).
DISK_LISTING=$(crusoe storage disks list --json)
printf '%s\n' "${DISK_IDS:-} ${KC_DISK_IDS:-}" | tr ' ' '\n' | while read -r d; do
  [ -n "$d" ] && echo "disk $d listed: $(printf '%s' "$DISK_LISTING" | jq --arg id "$d" '[.[] | select(.name==$id or .id==$id)] | length')"
done
[ -n "${DISK_IDS:-}${KC_DISK_IDS:-}" ] || echo "disks: none recorded"
```

A resource still listed after 10 minutes is an orphan: report its ID and tell the user it keeps billing. Do not delete it unless the user says to, and then only that one ID: `crusoe networking load-balancers delete "$LB_ID"`, `crusoe networking vpc-firewall-rules delete "$FW_ID"` or `crusoe storage disks delete "<disk name>"` (the `name` of the entry in `crusoe storage disks list --json` whose `id` or `name` equals the recorded disk ID); for the Keycloak ones the same rule applies with `"$KC_LB_ID"`, `"$KC_FW_ID"` and the recorded `KC_DISK_IDS` disk names. **If the user chose Level 2, do not start T3 while any orphan from this step is unresolved, unless the user acknowledges it by ID**: after the cluster is deleted nothing is left to clean it up.

If the user chose Level 1, go to Phase T3 (bucket and key — the cluster still exists, which the in-cluster bucket-empty path needs), then Phase T5. Only a Level 2 continues to Phase T4.

## Phase T3 — Bucket and storage key (while the cluster still exists)

The default for every item below is **keep**. Ask separately, show the evidence, and delete only on an explicit yes. Start every block with the Variables lines.

**This phase runs BEFORE the pools and cluster are deleted, at BOTH levels.** Crusoe Object Storage is reachable only from VMs in the bucket's own location (the docs state "All S3 operations are performed directly from your Crusoe Cloud VMs"; cross-location S3 access is not served — the endpoint of another location does not resolve this bucket's region). While this cluster exists, its own nodes are that in-location compute. There is no fallback: object deletion ALWAYS runs on the existing node-pool VMs (a pod on the backend node), which is why this phase precedes every pool deletion — once the pools are gone, this skill has no in-location compute and must not attempt the purge. At Level 1 nothing else is being deleted, so a kept bucket can also be emptied at any later time from the same nodes; only a Level 2 run makes it now-or-never.

- **Bucket.** Show its name and its versioning, object lock and retention state (`crusoe storage buckets get "$BUCKET_NAME"`; it does not report object counts; the skill cannot see noncurrent object versions). If object lock is enabled with a retention period, say that objects cannot be deleted until the retention expires, so the bucket cannot be removed until then, and offer to leave it. Otherwise, on an explicit yes:
  1. Try `crusoe storage buckets delete "${BUCKET_NAME:?}"` first — an empty bucket deletes immediately. "Not empty" is the normal case: OSMO's install writes bootstrap objects even when no workload ran, and bucket versioning (always on) keeps every version of them.
  2. If the delete fails with `Bucket ... is not empty`, empty it from inside this cluster with [scripts/empty_bucket.py](../scripts/empty_bucket.py) — a version-aware purge (it deletes every object VERSION and every delete MARKER; plain object deletes leave noncurrent versions and create markers, both of which keep the bucket delete failing). **Two acts, in order — never one**: the purge (S3 object operations, from a pod on the backend node — the node-pool VMs are the in-location compute; no new VM is created) and then, only after the script confirms 0 versions and 0 markers, the agent re-runs `crusoe storage buckets delete` (the CLI/control plane — S3 credentials manage objects, only the CLI/API manages the bucket itself; an S3-level `delete_bucket` gets `Access Denied`, ). The credentials are the storage key's two values: if the user still holds the secret (it is shown only once at creation), they export `CRUSOE_ACCESS_KEY_ID`/`CRUSOE_SECRET_KEY` in their shell first — the block below turns them into a one-off k8s Secret mounted at the `/root/.s3keys` shape the script reads (the secret never appears in a pod spec or a file in the cluster) — and are deleted with the pod and Secret afterwards. The script stops after the purge is verified and never deletes the bucket itself — the agent completes it with the CLI.

  The robust invocation (use this one): copy the script in, then run it — the pod stays alive just long enough, and the exit code tells the story:

```bash
set -a; . "$WORKDIR/teardown.env"; set +a
: "${CRUSOE_ACCESS_KEY_ID:?export the storage key values first}" "${CRUSOE_SECRET_KEY:?}"
# The secret enters the cluster ONLY as a Secret object (mounted at the /root/.s3keys shape the
# script reads) - never as a pod-spec env value, which any cluster reader can list.
kubectl --context "$KCTX" -n default create secret generic empty-bucket-creds \
  --from-literal=access_key_id="$CRUSOE_ACCESS_KEY_ID" \
  --from-literal=access_key="$CRUSOE_SECRET_KEY"
kubectl --context "$KCTX" -n default run empty-bucket --restart=Never --image=python:3.12-slim \
  --overrides='{"spec":{"nodeSelector":{"osmo-type":"backend"},"containers":[{"name":"empty-bucket","image":"python:3.12-slim","command":["sleep","300"],"volumeMounts":[{"name":"creds","readOnly":true,"mountPath":"/root/.s3keys"}]}],"volumes":[{"name":"creds","secret":{"secretName":"empty-bucket-creds"}}],"restartPolicy":"Never"}}'
kubectl --context "$KCTX" -n default wait pod/empty-bucket --for=condition=Ready --timeout=120s
kubectl --context "$KCTX" -n default cp "$SKILL_DIR/scripts/empty_bucket.py" default/empty-bucket:/tmp/empty_bucket.py
# BUCKET_NAME and LOCATION are passed as ARGV expanded agent-side (double quotes in the exec string):
kubectl --context "$KCTX" -n default exec empty-bucket -- bash -c "pip install --quiet boto3 && python3 /tmp/empty_bucket.py '$BUCKET_NAME' '$LOCATION'"
kubectl --context "$KCTX" -n default delete pod empty-bucket --wait=false
kubectl --context "$KCTX" -n default delete secret empty-bucket-creds
# crusoe v1.0.9: with CRUSOE_ACCESS_KEY_ID or CRUSOE_SECRET_KEY in the environment
# (even with dummy values — presence-based), the CLI parses
# them as its auth credentials and hides the object-storage subcommand tree, so the
# delete below would fail with: invalid argument "buckets" for crusoe storage.
# Drop both before any `crusoe storage buckets ...` call; the CLI falls back to its
# config-file login (~/.crusoe/config), which is what manages buckets anyway.
unset CRUSOE_ACCESS_KEY_ID CRUSOE_SECRET_KEY
crusoe storage buckets delete "${BUCKET_NAME:?}"   # now succeeds on the empty bucket
```

  If the user does not still hold the key's secret, the bucket cannot be emptied now: keep it (a later teardown can clean it — the next deploy's cluster nodes are in the same location, and its own run will hold a fresh key).

- **Storage key.** Only the key matched to this cluster in T1 (by `KEY_ACCESS_ID`, with `KEY_UUID` as its cross-check) is ever offered. It is organization-scoped, so other clusters may use it: say so, show its alias, `KEY_UUID`, access key ID and creation date, and on an explicit yes run `crusoe storage tokens delete "${KEY_ACCESS_ID:?}"` (by access key ID — see [tool-routing.md](tool-routing.md)). Never delete any other key. The key is asked **after** the bucket: emptying the bucket needs the key, so both the user's export and this delete only happen once the bucket question is resolved.

## Phase T4 — Level 2: node pools, cluster, and IB partition

Start every block with the Variables lines and repeat the pin check from T2 (it applies until the cluster is gone). Level 2 assumes T2 ran with the Keycloak additions, so the Keycloak load balancer, firewall rule and disks need no new deletions here; if the cluster is already gone instead and those T2 checks never ran, the Keycloak LB, firewall rule and disks fall to the same T4-with-`teardown.env` pattern as the gateway's orphans (`KC_LB_ID`, `KC_FW_ID` and `KC_DISK_IDS` are still in the env file). The bucket and key were resolved in T3, before anything here is deleted — that ordering is what keeps the in-cluster empty path available.

1. Delete each node pool **by ID** from `POOLS`, one at a time, GPU pools first:

```bash
crusoe kubernetes nodepools delete "${POOL_ID:?set POOL_ID from POOLS}" --yes
```

   (set `POOL_ID` to that pool's ID from `POOLS` in the same command; `POOLS` holds `name:id` pairs, so for the entry `h100:<id>` use `POOL_ID=${entry#*:}`). The command blocks until the pool is gone, which can exceed a shell timeout (a GPU pool delete can take over two minutes): run it in the background or let it run, and confirm with the list; never re-run the delete (if it printed an error instead of timing out, list first, then decide). After each, wait for it to leave `crusoe kubernetes nodepools list --cluster-id "$CLUSTER_ID" --json` (poll every 30 seconds, up to 20 minutes).

2. Delete the cluster by ID and wait until it no longer appears in `crusoe kubernetes clusters list --json` (up to 20 minutes). This command has no `--yes` flag and does not prompt. Like the pool deletes it blocks until the cluster is gone (several minutes): run it in the background or let it run, confirm with `clusters list`, and never re-run it (if it printed an error, run `clusters list` first, then decide):

```bash
crusoe kubernetes clusters delete "${CLUSTER_ID:?}"
```

3. If a disk from T1 had a reclaim policy other than `Delete`, it still exists: list it (`crusoe storage disks list`) and ask the user.

4. Local cleanup:

```bash
kubectl config delete-context "${KCTX:?}"
rm -f "$HOME/osmo-ca-${CLUSTER_NAME:?}.crt"
```

   Also remove the matching cluster and user entries from the kubeconfig if they exist only for this cluster (`kubectl config get-clusters`, `get-users`). Delete `"$WORKDIR"` only at the very end of T5, because T4 still needs `teardown.env`.

5. **IB partition.** Offer a partition only if all three hold: its ID is in `PARTITION_IDS` (this cluster's GPU nodes used it), its name is exactly `osmo-<pool>` (what this skill creates; any other name was reused or belongs to someone else and is never deleted), and no VM in the project still references it: `crusoe compute vms list --json | jq --arg id "<partition id>" '[.[] | select(any(.host_channel_adapters[]?; .transport_partition_id==$id))] | length'` must print `0`. Show that count to the user. The check sees only running VMs, not a node pool of another cluster that currently has zero nodes: if the project has other clusters, say so and ask the user to confirm that none of them uses this partition before deleting. A partition built by this skill for another cluster that reused it will show a non-zero count: keep it. To delete: `crusoe networking transport-partitions delete "<partition id>"`; if the API refuses, report that and leave it.

## Phase T5 — Verify and report

Re-list what should be gone and report anything left. For clusters, pools, load balancers and disks, use the MCP reads in `mcp+cli` mode (`list_kubernetes_clusters`, `list_kubernetes_node_pools` with the cluster ID recorded in `teardown.env`, `list_load_balancers`, `list_disks`) and the CLI lists otherwise (`crusoe kubernetes clusters list`, `crusoe kubernetes nodepools list --cluster-id`, `crusoe networking load-balancers list`, `crusoe storage disks list`). Partitions, buckets and keys are always checked with the CLI, because the MCP has no tools for them (`crusoe networking transport-partitions list`, `crusoe storage buckets list`, `crusoe storage tokens list`). State the project name and ID. Then clean up the work directory (it holds the Helm values, `lb_ip`, `api_url` and `teardown.env`, none of them secret). **At Level 1** the cluster stays, so delete nothing: keep `teardown.env`, because it records the bucket and key that a later Level 2 teardown needs, and tell the user where it is (`~/.osmo-install/<cluster>/`) and which bucket and key it names. **At Level 2** run `case "$CLUSTER_NAME" in ""|*[!A-Za-z0-9_-]*) echo "invalid cluster name"; exit 1;; esac; rm -rf "${HOME:?}/.osmo-install/${CLUSTER_NAME:?}"` (the name check is repeated because this runs in a fresh shell). `teardown.env` goes away with it, so if the user kept the bucket, the key or any partition in T4, write their names and IDs into the report below. Report:
- what was deleted, with IDs;
- what was kept on purpose (the cluster and pools at Level 1; any bucket, key or partition the user chose to keep);
- anything that could not be deleted and still bills (for example a locked bucket, with its retention end date, or an unresolved orphan);
- any orphaned Keycloak load balancer, firewall rule or disk still listed, by the ID recorded in `KC_LB_ID`, `KC_FW_ID` or `KC_DISK_IDS`;
- local leftovers the skill does not remove: Helm repos it added (`helm repo list`), any OSMO certificate the user imported into their OS trust store (macOS Keychain), and, after a Level 1 teardown, the exported `~/osmo-ca-<cluster>.crt`;
- anything unexpected.

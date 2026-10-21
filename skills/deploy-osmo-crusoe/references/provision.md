# Phases 1–2 — Resolve inputs, then provision

Part of the deploy-osmo-crusoe skill. Read [SKILL.md](../SKILL.md) first: its Phase 0
hard gates, Tool routing rules and secret rules apply before anything here runs. This
reference is loaded on a fresh deploy; a teardown (teardown.md) never runs Phases 1–2.

## Phase 1 — Resolve inputs from the user's sentence

Parse the request sentence, resolve everything else yourself, and ask only for what is missing. Everything in this phase is read-only, except a key deletion that the user explicitly names in step f2.

**a. Parse.** Extract the location and, for each GPU type, a count. **A count means nodes, not GPUs**: "1x H100" is 1 node, which is 8 GPUs. Crusoe GPU nodes are single-tenant full hosts: 8 GPUs for H100/H200/B200/B300/A100, 4 for GB200/GB300; L40s is the exception (1, 2, 4, 8 or 10 GPUs per node) and defaults to `l40s-48gb.10x` unless the user says otherwise. If a count could plausibly be a GPU count (for example "16x H100"), or the GPU type or L40s size is unclear, ask: "Do you mean N nodes (N × <num_gpu> GPUs per node = <N × num_gpu> GPUs) or N GPUs?" Take <num_gpu> for the named GPU from `crusoe compute vms types --json` (8 for H100, 4 for GB200/GB300); never assume 8. Do not guess in unclear cases. If the user says GPUs, convert: nodes = GPUs ÷ the GPUs per node (`num_gpu`); if that is not a whole number, ask.

**b. Required from the user, no default: SSH public key path.** Ask if they did not give it. Check the path ends in `.pub`. If you can read the file, check it exists. If your sandbox cannot read `~/.ssh`, do not ask to bypass the sandbox for this: accept the path, say in the summary that the key file was not verified, and let `nodepools create` fail clearly if it is wrong.

**c. Defaults the user may override.**

- `CLUSTER_NAME`: `osmo`.
- `BUCKET_NAME`: `osmo-` plus 6 random lowercase hex characters (`osmo-$(openssl rand -hex 3)`). Bucket names are globally unique; creation in Phase 2 is the real uniqueness check.
- Pool names: derived from the instance type (see d).
- Per-job resource defaults for every pool: `USER_CPU=8`, `USER_GPU=1`, `USER_MEMORY=32Gi`, `USER_STORAGE=100Gi`. Never ask; list them in the summary.
- Object lock: off. Enable it only if the user's request asks for it, and then ask for the retention period (no default); see Phase 2d.

**d. Resolve each GPU pool.**

1. `LOCATION`: must appear in `list_locations` (or `crusoe locations list`). If not, show the valid ones and ask.

2. Instance type: run `crusoe compute vms types --json` and select entries whose `gpu_type` contains the requested GPU family (case-insensitive; for example `H100` matches `H100-SXM-80GB`). The type string is `product_name`; GPUs per node is `num_gpu`. For L40s choose `l40s-48gb.10x` unless told otherwise. If more than one entry still matches a non-L40s GPU, ask. If none matches, stop and say the GPU type is not offered.

3. **Offered and in stock here? — two disjoint checks, one per class.**
   - **InfiniBand-connected types (`-ib.` in the type string, e.g. H100/H200/A100): check the IB networks only (step e). Never gate on `/capacities` for them** — its `quantity` is a presence flag that has misread actual IB availability (it read `1` for a type whose whole 16-GPU IB reservation was already consumed; the measurement lives in [references/api-capacities.md](api-capacities.md)). The IB check is the one that stops the run. Record the `/capacities` number in the summary as informational only.
   - **Non-IB types (L40s, every other type without `-ib.`): check `GET /v1/capacities`** (`https://api.cloud.crusoe.ai`), response `items[]` of `{type, quota_type, num_slices, location, quantity}` (entries repeat: dedupe). There is no IB network to ask and no CLI command: `crusoe compute vms types` is a global catalog with no per-location availability; the MCP's `list_capacities` is this same endpoint. The CLI has no capacities command.
     - In `mcp+cli` mode call `list_capacities(location=[LOCATION], product_name=[instance type])`.
     - In `cli-only` mode call the API directly with the user's API credentials from `~/.crusoe/config` (or `CRUSOE_ACCESS_KEY_ID`/`CRUSOE_SECRET_KEY`): signing and a ready-to-run script are in [references/api-capacities.md](api-capacities.md). Never print the secret key; never send credentials anywhere but the Crusoe API.
     - `quantity` is a **capacity-presence flag, not a unit count**: `0` = none, `1` = some capacity exists — the full story is in [references/api-capacities.md](api-capacities.md). **`num_slices` is real and matters for the quota check below** (how many quota slices one node consumes — `l40s-48gb.10x`: 10), but it is not a unit of stock. Require `quantity >= 1` for the whole order; otherwise **out of stock: stop and tell the user** (they can pick another location or type). For multi-node orders this API cannot prove depth of stock — the create is the real test: if `nodepools create` fails for capacity after a `quantity >= 1` read, report it as a stock race, not a skill bug. Absence of the type in the response is weak evidence it is not offered there — treat as not offered and say which way the check landed. This is not a reservation: stock can change between check and create.

4. Pool name: the type string up to its first `-` (`h100-80gb-sxm-ib.8x` → `h100`, `l40s-48gb.10x` → `l40s`). Node pool names must be unique in the cluster: if the user asks for the same GPU type twice, or two types give the same prefix, make the names unique (`h100`, `h100-2`) and show them in the summary.

5. `ephemeral`: `false` for L40s, `true` for every other type.

6. IB-connected types are those whose type string contains `-ib.`. L40s is not IB-connected: it gets no IB network and no partition, ever.

**e. Select the IB network for each IB-connected pool.** Reserved GPU capacity is held per InfiniBand physical network, and only the CLI exposes it. Partitions are not needed to read it.

1. `crusoe networking transport-networks list --json`; keep networks whose `location` is `LOCATION` and whose `name` contains the GPU family (for example `H100-80GB SXM IB Network`). **Collect every candidate in one pass, never a truncated view**: a location commonly has SEVERAL networks of the same GPU family (us-southcentral1-a has three H100 networks, numbered 0–2), and reading only the first match is how a deploy picked the one empty network while the org's reservation sat on another. Filter in the JSON (`jq`/python over the full array), not with a line-limit on the printed table.
2. For EACH candidate, `crusoe networking transport-networks get <id> --json`. Find the `capacities` entry whose `slice_type` equals the instance type. No entry, or `capacities: []`, means no capacity. Show the candidate table in the plan (network name, quantity) — every candidate, not just the chosen one.
3. `quantity` is the total **GPU** count reserved in that network (2 reserved H100 nodes read 16). Required = `nodes × num_gpu`.
4. A network matches when `quantity >= required`. If several match, choose the one with the smallest sufficient `quantity`. Set the pool's `ib_network_id` to it. If the project has earlier OSMO deployments in the same location, cross-check the network against their recorded handoff (`~/.osmo-install/<cluster>/` or the deploy report) — a working deployment proves which network actually carries the reservation.
5. If several pools use the same GPU type, check them cumulatively: reduce a network's remaining quantity by what earlier pools claimed.
6. If no network matches, **stop the skill now, before creating anything** — no partition create, no pool create, no plan with the zero-capacity network "as a footnote". A `quantity < required` network is not a risk to note and proceed past; it is a wrong answer. Tell the user: no InfiniBand network in `LOCATION` has `required` reserved GPUs of `<type>` (list each network and its quantity), and they should check with Crusoe that their reservations are in place.

**f. Quota.** Call `list_project_quotas(project_id)` in `mcp+cli` mode, or `GET /v1/projects/{project_id}/quotas` in `cli-only` mode (script in [references/api-capacities.md](api-capacities.md); note the response's items carry `max`, `used` and `available` as strings — convert to int before comparing). The `quota_type` from the `list_capacities` entry names the quota this instance type consumes and `num_slices` is the number of slices per node. For an IB-connected type, those two values come from the same informational `/v1/capacities` call of step 3 (run it in `cli-only` mode too, for this purpose alone — **ignore the script's `OUT-OF-STOCK` exit and output entirely for `-ib.` types: it must not gate them**; read only `quota_type`/`num_slices` from the printed entry — the gate for IB types stays the IB-networks check of step e). If the quota output has an entry for that `quota_type`, require `int(available) >= nodes × num_slices` (equivalently `max - used`); if it is short, stop and report the numbers. If the output has no matching entry, say "could not verify quota" in the summary and continue.

**f2. Storage access keys (all modes).** Phase 2 creates one organization-scoped Object Storage access key, and the organization caps how many keys can be active (observed: 2).

Check now, before anything is created: `crusoe storage tokens list --json` (fields `key_uuid`, `alias`, `access_key_id`, `status`, `created_at`; active keys have `status` `KEY_STATE_ACTIVE`). If two or more keys are active, do not start provisioning.

Show the user each active key (`alias`, `key_uuid`, `created_at`) and ask how to proceed: (1) they name a key to delete, and you run `crusoe storage tokens delete <access_key_id>` (by access key ID, not `key_uuid` — see the Delete storage token row in [references/tool-routing.md](tool-routing.md)) only on that explicit say-so; (2) they already have the access key ID and secret of a key to reuse, in which case Phase 2e is skipped and they give you those two values; or (3) they stop. Never delete a key on your own and never choose one for them: existing keys may be live credentials for other clusters. If fewer than two keys are active, note in the summary that a key slot is available. The real limit is whatever the API enforces, so the same stop-and-ask applies if Phase 2e still fails with "maximum number of S3 keys".

**g. Cluster version and subnet.**

- `CLUSTER_VERSION`: from `list_kubernetes_versions` (or `crusoe kubernetes versions list`). The output has two sections, **Cluster Versions** and **Node Pool Versions**; use only the Cluster Versions section (the MCP returns two JSON blocks, cluster versions first). In it every minor release (1.30, 1.31, ...) has its own `stable` row. Pick the `stable` row of the **highest minor release** (for example `1.35.5-cmk.24`), not the first `stable` row in the list, which belongs to the oldest minor. Ignore rows labelled `deprecated` or `unreleased`. **A `stable` row can carry a second, per-SKU variant label (e.g. `1.35.5-cmk.33-amdmi35x`) alongside the plain version; the create rejects that version ("invalid kubernetes cluster version") when its plain form is listed `unreleased` — observed when the plain `1.35.5-cmk.33` row also appeared as `unreleased`. If the highest stable row carries a variant tag, fall back to the newest `stable` row WITHOUT one (the run recorded here used `1.35.5-cmk.30`).**
- `SUBNET_ID`: the entry named `default-subnet-<LOCATION>` from `list_vpc_subnets(project_id)` (or `crusoe networking vpc-subnets list --json`). If missing, ask the user for a subnet ID.
- `CLUSTER_NAME` must be free: run `crusoe kubernetes clusters list --json`. If a cluster with that name already exists in the project, do not reuse it: ask for another name and show the chosen name in the summary.

**h. Summary and confirmation.** This phase ends with one summary, and nothing is created until the user approves it:

- Project (`PROJECT_NAME`), location, cluster name, Kubernetes version, subnet, SSH key path, bucket name — and one property of the bucket, stated plainly: it is reachable only from VMs in its own location (cross-location S3 access is not served), which is why teardown empties it before the pools/cluster are deleted.

- Mode (`mcp+cli` / `cli-only`) and what was or was not checked (offered-in-location and stock came from the capacities API in both modes; quota came from the quotas API in `mcp+cli` mode and from `GET /v1/projects/{id}/quotas` in `cli-only` mode).

- A table of pools. Fixed CPU pools: `osmo-control-pool` (`c1a.8x` ×1, label `osmo-type=control`) and `osmo-backend-pool` (`c1a.4x` ×1, label `osmo-type=backend`). Then one row per GPU pool: pool name, instance type, nodes, GPUs (state the arithmetic, e.g. "1 node × 8 = 8 GPUs"), IB network name and its reserved quantity (or "none — not IB-connected"), and for IB pools whether the IB partition will be reused or created: run `crusoe networking transport-partitions list --json` and, if one of the user's partitions has `ib_network_id` equal to the pool's network, name it as reused; otherwise say a new partition `osmo-<pool name>` will be created.

- The per-job defaults, and the note that they are fixed unless the user asks otherwise.

- What else this run does that the user should expect: it creates an **organization-scoped Object Storage key** (alias `osmo-workflow-data`; skipped if the user supplies an existing key; **every key this run creates carries a bounded lifetime — `KEY_EXPIRY`, default 30 days out, stated here and in the Phase 9 report** — because Crusoe keys reach every bucket in the org and bucket-scoped keys do not exist; if the user supplies their own existing key, tell them its expiry from `tokens list`, or that it never expires; if `tokens list` in step f2 showed the organization at its key cap — observed cap: 2 active — say so HERE, in the summary, and fold the f2 stop-and-ask question into the approval: which key to delete, or which existing key to reuse, BEFORE anything is created — hitting the cap at Phase 2e, mid-provision, wastes a built cluster of waiting time), turns on bucket versioning (object lock stays off unless the user asked for it; if they did, state the retention period they gave and that it is irreversible), and installs the **Crusoe Load Balancer Controller** (a Private Beta product) if the cluster does not have it.

- **A warning, stated plainly:** the OSMO gateway is a public LoadBalancer IP. The install's Phase 9 restricts its firewall rule to the user's own source addresses (a hard step, not advice), and Phase 10 (Keycloak) is the default — without both, anyone who finds the IP is treated as an admin (`osmo-admin`) and can submit GPU workflows on the user's account.

- **Authentication is the default .** The summary asks "Keycloak login (Phase 10) is included — keep it?" — default: **yes**; the gateway without it is a public, login-free admin surface, and Phase 10 is the only thing standing between a URL guess and full GPU-workflow control. If the user explicitly opts out, say the residual risk plainly (only the Phase 9 firewall rule protects the gateway) and that Phase 10 then does not run. If they keep it, Phase 10 runs as part of this same approved run (billable: a second public load balancer plus Keycloak's namespace, disk-backed database, certificate and secrets).

- "This will create billable infrastructure and then install OSMO on it (Phases 3–9, plus Phase 10 Keycloak unless you opt out). Proceed?"

## Phase 2 — Provision infrastructure

Set once per shell: `SKILL_DIR="<path-to>/skills/deploy-osmo-crusoe"`. Only after the user approved the Phase 1 summary. All Crusoe creates run through [scripts/provision_crusoe.sh](../scripts/provision_crusoe.sh) (one home for the five create commands — mock-verified against flag drift; `SKILL_DIR` is this skill's directory). Re-running `create` on something that exists errors rather than succeeding; if a previous attempt may have partly worked, check with `get`/`list` first. If a step fails after something was created, stop, list what now exists (cluster, pools, IB partition, the bucket name, and the storage key's `key_uuid` and access key ID if it was created) and tell the user, because references/teardown.md cannot read the bucket and key from an OSMO config that was never installed: they can fix the cause and continue, or remove it with [references/teardown.md](teardown.md). A half-built deployment keeps billing.

**a. Kubernetes cluster.**

```bash
"$SKILL_DIR/scripts/provision_crusoe.sh" cluster
```

This command blocks until the cluster is built (about 8 minutes), which can exceed a shell timeout: run it in the background, or expect a long wait. If its output is lost or it is interrupted, do not re-run `create`: check `crusoe kubernetes clusters get "$CLUSTER_NAME" --json` first, because the cluster is usually already being provisioned. If it reports that the cluster does not exist, the create never started: run it again. Treat a cluster of that name as yours only if this run started the create (Phase 1 already checked that the name was free). Then wait for `STATE_RUNNING` (see Readiness polling in [references/tool-routing.md](tool-routing.md#readiness-polling)): poll every 30 seconds, give up after 30 minutes and report the last state. Do not create node pools before it is running.

**b. Control and backend pools** (CPU-only):

```bash
# NOTE: the pools phase ALSO loops over any exported POOLS variable — do NOT
# export POOLS for the control/backend invocation (the loop would re-create
# those pools with the GPU specs' ephemeral flags and c1a rejects
# --ephemeral-storage-for-containerd, killing the run under set -e).
"$SKILL_DIR/scripts/provision_crusoe.sh" pools
```

**c. One GPU pool per pool from Phase 1.**

For an IB-connected pool, first get a partition on the network chosen in Phase 1 step e. Run `crusoe networking transport-partitions list --json`; if one of the user's partitions already has `ib_network_id` equal to the pool's `ib_network_id`, reuse its `id`. Otherwise create one:

```bash
crusoe networking transport-partitions create --name osmo-<pool name> \
  --transport-network-id <the chosen network's id>
```

(The create takes `--transport-network-id`, not `--ib-network-id`. The partition name is rejected with `invalid IB partition name` if it contains dots — name it `osmo-<pool name>` where `<pool name>` is the pool name from step d.4, e.g. `osmo-h100`, never the raw instance type. The delete prompt is interactive; `nodepools delete` wants the pool **ID** when several clusters have pools of the same name, and takes `y` on stdin.)

and take `.id` from the output (the CLI prints a "successfully created" line before the JSON; parse from the first `{`). Then create the pool:

```bash
POOLS="<name>:<type>:<nodes>:<ephemeral>:<partition-id>" "$SKILL_DIR/scripts/provision_crusoe.sh" pools
```

For L40s omit `--transport-partition-id` entirely and pass `--ephemeral-storage-for-containerd=false`.

If any pool creation fails, stop and report. **The pools phase is not re-runnable after a partial failure** (its own header comment says so): a re-run errors "already exists" on the first hardcoded create before the GPU pools are reached. On a partial failure, list what exists (`nodepools list --cluster-id`), then create ONLY the missing pools directly with the same CLI surface the script wraps (`crusoe kubernetes nodepools create --name <name> --cluster-name "$CLUSTER_NAME" --type <type> --count <n> --keyfile "$SSH_PUBLIC_KEY_PATH" [--transport-partition-id <id>] [--ephemeral-storage-for-containerd=<bool>] --node-labels osmo-type=<label>`). If this run created a partition that no pool ended up using, offer to delete it (`crusoe networking transport-partitions delete <id>`); never delete a partition this run did not create.

Wait for every node pool to reach `STATE_RUNNING` (same polling rule). Read the state with `crusoe kubernetes nodepools list --cluster-name "$CLUSTER_NAME" --json`, not `nodepools get <name>` (other clusters in the project reuse pool names). In `mcp+cli` mode `list_kubernetes_node_pools(cluster_id)` works too. A pool's `STATE_RUNNING` only means the pool object is healthy; it does not mean its nodes are booted and `Ready`. Step f (`kubectl get nodes`) is the real pass/fail for the nodes.

**d. Object Storage bucket.**

```bash
"$SKILL_DIR/scripts/provision_crusoe.sh" bucket
```

If creation fails because the name is taken, generate a new suffix, tell the user the new name, and retry. Object lock is off by default: OSMO does not need it, and enabling it is irreversible (the CLI asks for confirmation) and makes objects undeletable until the retention period passes, which makes cleaning up a test bucket painful. Enable it only if the user's request asked for it. In that case a retention period is required (the create fails with `bad request: Incorrect request body` without `--retention` and succeeds with `--retention 7d`): the user must give you the period (no default; for example `7d` or `3y`), you confirm once more that it is irreversible, and then you run `crusoe storage buckets enable-locking "$BUCKET_NAME" --retention <period> --yes`. If the user did not ask for lock, skip it and say in the final report that object lock is not enabled.

**e. Storage access keys.** The Phase 1 summary already told the user that this key is organization-scoped (valid across all buckets and all projects in the org — Crusoe offers no bucket-scoped key; the docs state "You can use object storage API keys in all buckets in all projects within your organization", and keys are user-scoped for management: only the creating user can view or delete them, so rotation and teardown of this key must run as the deploying user) and they approved the run, so do not ask again. Keys also carry a **mandatory expiry** (the compensating control for the missing bucket scope): export `KEY_EXPIRY` as an RFC 3339 timestamp a bounded interval (default 30 days) after the deploy date, and state the expiry in the Phase 1 summary and the Phase 9 report. Then:

```bash
KEY_EXPIRY="$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"   # macOS: date -u -v+30d '+%Y-%m-%dT%H:%M:%SZ'
"$SKILL_DIR/scripts/provision_crusoe.sh" key
```

The script refuses to run without `KEY_EXPIRY` (a key with no expiry outlives the cluster it was made for). The secret is shown once. Capture `ACCESS_KEY_ID` and `ACCESS_KEY` immediately and keep them only in memory for the OSMO install, where they become the environment variables `OSMO_ACCESS_KEY_ID` and `OSMO_ACCESS_KEY` (see references/osmo-install.md, Phase 5). They always override any value of those variables that is already set in the environment. Never write them to any file or to skill output. If `crusoe storage tokens` is unavailable, tell the user to create an Object Storage key in the console (Settings → API Keys) with an expiry and give you the values. If creation fails because the organization's S3 key limit is reached, stop and ask the user how to proceed as in Phase 1 step f2; never delete a key on your own.

**f. Credentials and access check.**

```bash
"$SKILL_DIR/scripts/provision_crusoe.sh" creds
```

Confirm every expected pool has the expected number of `Ready` nodes (control 1, backend 1, and each GPU pool's node count) before moving on; if nodes are not yet `Ready`, re-run `kubectl get nodes` every 30 seconds for up to 30 minutes and report what is missing. In `mcp+cli` mode also call `cluster_health_check(cluster_name)` and `list_kubernetes_node_pool_instances(node_pool_id)` per pool, and report anything unhealthy.


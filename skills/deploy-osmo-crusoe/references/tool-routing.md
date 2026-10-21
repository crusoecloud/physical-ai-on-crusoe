# Tool routing — MCP vs CLI

Per operation (SKILL.md Tool routing owns the general rules):

1. **Read:** use the `crusoe-cloud` MCP tool if it is loaded; otherwise the CLI command in the same row.
2. **No MCP tool in the row:** use the CLI.
3. **Create or change a Crusoe resource:** always the CLI. The MCP is read-only.
4. **Cluster-side work:** `kubectl` / `helm` directly.

MCP tool names and parameters below were read from `@crusoeai/cloud-mcp` v0.1.6. On first use of any tool, check the output looks like what the row says; if it errors or looks different, retry once, then use the CLI for that operation and tell the user. Do not loop.

MCP array parameters must be arrays: `list_capacities` takes `location: ["us-east1-a"]`, not a string.

CLI notes: `crusoe` v1.0.9 (Phase 0a stops if the installed CLI is older). Add `--json` for machine-readable output. The sandbox/TLS and tool-timeout rules live in [SKILL.md](../SKILL.md) (Tool routing section).

Never use `crusoe reservations list`.

## Identity and project

| Operation | MCP | CLI |
|---|---|---|
| Who am I | `get_user_identity()` | `crusoe whoami` |
| Current project | `get_current_project()` → `{id, name, organization_id, is_default, is_explicitly_set}` | `crusoe config get default_project` (name only) |
| Switch MCP project | `use_project(project_name)` | n/a (set `CRUSOE_DEFAULT_PROJECT` or `crusoe config set default_project <name>`) |
| List projects | `list_available_projects()` | `crusoe projects list` |

The MCP and CLI each keep their own current project. Before any create, confirm both name the same project; if not, tell the user and stop.

## Locations and instance types

| Operation | MCP | CLI |
|---|---|---|
| Valid locations | `list_locations()` | `crusoe locations list` |
| Instance types (type string, GPU family, GPUs per node) | none | `crusoe compute vms types --json` → fields `product_name` (type string), `gpu_type`, `num_gpu` |
| Is the type offered and in stock in the location | IB-connected types: never gate on this — the MCP/`/capacities` quantity is informational only (see provision.md Phase 1 step d.3). Non-IB types (L40s…): `list_capacities(location=[loc], product_name=[type])`, require `quantity >= 1` (a presence flag, not a unit count; multi-node depth is unprovable from this API) | IB-connected types: IB networks only (rows above). Non-IB types: signed `GET /v1/capacities?location=<loc>&product_name=<type>` per [api-capacities.md](api-capacities.md) |

## Quota

| Operation | MCP | CLI |
|---|---|---|
| Project quotas (max and current usage) | `list_project_quotas(project_id)` | signed `GET /v1/projects/<project-uuid>/quotas` per [api-capacities.md](api-capacities.md) (UUID required; a name returns 400) |

The `quota_type` string on a `list_capacities` entry names the quota that instance type consumes; `num_slices` is how many quota slices one node uses.

## Kubernetes versions and subnets

| Operation | MCP | CLI |
|---|---|---|
| Versions | `list_kubernetes_versions()` | `crusoe kubernetes versions list` (rows carry labels: `stable`, `deprecated`, `unreleased`). The output has two sections, Cluster Versions and Node Pool Versions: use only Cluster Versions, and take the `stable` row of the highest minor release (each minor has its own `stable` row). |
| Subnets | `list_vpc_subnets(project_id)` | `crusoe networking vpc-subnets list --json` |

Subnet for a location is the one named `default-subnet-<location>`.

## IB networks and partitions

CLI only. The MCP has no transport-network tools.

| Operation | CLI |
|---|---|
| List IB networks | `crusoe networking transport-networks list --json` |
| Reserved capacity of one network | `crusoe networking transport-networks get <network-id> --json` → `capacities[]` of `{quantity, slice_type}`; `quantity` is total GPUs |
| List partitions | `crusoe networking transport-partitions list --json` (field `ib_network_id`) |
| Create partition | `crusoe networking transport-partitions create --name <name> --transport-network-id <network-id> --json` → `{id, ib_network_id, name}` |
| Delete partition | `crusoe networking transport-partitions delete <id>` (no `--yes` flag) |

## Provisioning (CLI only)

| Operation | CLI |
|---|---|
| Create cluster | `crusoe kubernetes clusters create --name N --location L --cluster-version V [--subnet-id S] --add-ons nvidia_gpu_operator,nvidia_network_operator,crusoe_csi` |
| Create node pool | `crusoe kubernetes nodepools create --name N --cluster-name C --type T --count K [--keyfile PUB] [--node-labels k=v] [--ephemeral-storage-for-containerd=true\|false] [--transport-partition-id P]` |
| Create bucket | `crusoe storage buckets create --name N --location L` |
| Bucket versioning / locking | `crusoe storage buckets enable-versioning N --yes`, `crusoe storage buckets enable-locking N --retention <period> --yes` (opt-in only and irreversible; the API requires `--retention` even though the CLI help marks it optional; see provision.md Phase 2 step d) |
| Storage token (org-scoped) | `crusoe storage tokens create --alias A` |
| List storage tokens | `crusoe storage tokens list --json` → `key_uuid`, `alias`, `access_key_id`, `status` (`KEY_STATE_ACTIVE`), `created_at` |
| Delete storage token | `crusoe storage tokens delete <access_key_id>` — the CLI help's `<key-id>` means the access key ID, not the `key_uuid` (only on the user's explicit say-so) |
| Kubeconfig | `crusoe kubernetes clusters get-credentials <cluster-name> --yes` |

## Readiness polling

| Operation | MCP | CLI |
|---|---|---|
| Cluster state | `list_kubernetes_clusters()` to find the id, then `get_kubernetes_cluster(cluster_id)` | `crusoe kubernetes clusters get <name> --json` → `.state` |
| Node pool state | `list_kubernetes_node_pools(cluster_id)` to find the id, then `get_kubernetes_node_pool(node_pool_id)` | `crusoe kubernetes nodepools list --cluster-name C --json` → `.state` of the pool with that name in this cluster (not `nodepools get <name>`: other clusters in the project reuse pool names) |
| Node pool instances | `list_kubernetes_node_pool_instances(node_pool_id)` | `kubectl get nodes` after kubeconfig |

Ready means `.state` is `STATE_RUNNING`. For a cluster that is the real signal; for a node pool it only means the pool object is healthy, and node readiness is confirmed with `kubectl get nodes` (or `list_kubernetes_node_pool_instances`). Poll every 30 seconds, give up after 30 minutes and report the last state. `clusters create` itself blocks for several minutes (about 8); if it is interrupted, check `clusters get` before re-running it.

## Post-deploy health

| Operation | MCP | CLI |
|---|---|---|
| Cluster health | `cluster_health_check(cluster_name)` | `kubectl get nodes` plus pod checks |

Phases 3–9 (osmo-install.md) use `kubectl` and `helm`, plus `crusoe kubernetes clusters get` (the API URL for the pin check) and `get-credentials`. The one MCP read there is `cluster_health_check` in Phase 8.

## Teardown (teardown.md)

Deletes are CLI only. Delete Crusoe resources by ID from a list filtered to the cluster, never by bare name (other clusters can have pools with the same names). Check each delete command with `--help` before using it.

| Operation | MCP (reads) | CLI |
|---|---|---|
| Node pools of the cluster | `list_kubernetes_node_pools(cluster_id)` | `crusoe kubernetes nodepools list --cluster-name C --json` (field `id`) |
| Delete node pool | none | `crusoe kubernetes nodepools delete <id> --yes` |
| Delete cluster | none | `crusoe kubernetes clusters delete <id>` |
| Load balancers | `list_load_balancers()` | `crusoe networking load-balancers list --json`; the gateway's ID is the Service annotation `crusoe.ai/load-balancer-id` |
| Firewall rules | `list_firewall_rules()` | `crusoe networking vpc-firewall-rules list --json`; the gateway's ID is the Service annotation `crusoe.ai/firewall-rule-id` |
| Disks | `list_disks()` | `crusoe storage disks list --json`; a PVC's disk ID is its PV's `spec.csi.volumeHandle` |
| Delete a leftover LB, firewall rule or disk | none | `crusoe networking load-balancers delete <id>`, `crusoe networking vpc-firewall-rules delete <id>`, `crusoe storage disks delete <name>` (the `name` of the disk whose ID equals the `volumeHandle` recorded from this cluster's PV), only on the user's say-so |
| Delete IB partition | none | `crusoe networking transport-partitions delete <id>` (only `osmo-<pool>` partitions, only on the user's say-so) |
| Delete bucket | none | `crusoe storage buckets delete <name>` (only on the user's say-so; object lock may block it) |
| Delete storage key | none | `crusoe storage tokens delete <access_key_id>` (only on the user's say-so; the key is organization-scoped; the by-access-key-ID rule is the Delete storage token row in the Provisioning table above) |

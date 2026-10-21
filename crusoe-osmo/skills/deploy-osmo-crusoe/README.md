# deploy-osmo-crusoe — stand up and tear down a single-cluster NVIDIA OSMO platform on Crusoe Cloud

An agent-agnostic skill (SKILL.md format): from one sentence, it provisions a Crusoe Managed Kubernetes cluster, node pools, an Object Storage bucket and an access key, then installs NVIDIA OSMO on it — and tears it down upon request.

> **The gateway this skill creates is a public LoadBalancer IP.** The full security
> model (confirmation gates, credential scoping, network exposure, residual risks)
> is the repo's [SECURITY.md](../../SECURITY.md). The install restricts its firewall rule to your source addresses (hard Phase 9 step) and turns on the Keycloak login by default (Phase 10; opt out only if you accept a login-free gateway). Anyone the firewall admits who finds the IP is otherwise an administrator. Also know before you deploy: OSMO's PostgreSQL and Redis run as single replicas with **no backup** — a Level 1 teardown (uninstall OSMO, keep the cluster) permanently deletes their volumes (workflow history, users, configuration); the bucket, storage key and IB partition are kept unless you say yes to each. The OSMO **charts are pinned to 1.3.1 but the images use the `latest` tag**, so a later run can pull newer images than the charts were tested with (the final report lists what was resolved). Cluster and node-pool creates take minutes; agent tool timeouts are not failures — the skill checks state and polls. The `crusoe` CLI changes between versions; the skill's commands were checked against v1.0.9 and it confirms flags with `--help`.

## Architecture

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Crusoe Managed Kubernetes (CMK) Cluster                   │
│                                                                                │
│  ┌──────────────────────────────┐  ┌──────────────────────────────────────┐  │
│  │   NodePool: osmo-control-pool │  │   NodePool: osmo-backend-pool        │  │
│  │   (c1a.8x, osmo-type=control) │  │   (c1a.4x, osmo-type=backend)        │  │
│  │                              │  │                                      │  │
│  │  ┌────────────────────────┐  │  │  ┌──────────────────────────────┐    │  │
│  │  │   OSMO service          │  │  │  │   OSMO Backend Operator      │    │  │
│  │  │  ┌──────────────────┐  │  │  │  │  ┌────────────────────────┐  │    │  │
│  │  │  │  osmo-service    │  │  │  │  │  │  backend-listener      │  │    │  │
│  │  │  │  osmo-router     │  │  │  │  │  │  backend-worker        │  │    │  │
│  │  │  │  osmo-agent      │  │  │  │  │  └────────────────────────┘  │    │  │
│  │  │  │  osmo-logger     │  │  │  │  └──────────────────────────────┘    │  │
│  │  │  │  osmo-ui         │  │  │  │                                      │  │
│  │  │  │  postgres        │  │  │  │   GPU NodePools (one per GPU type)   │  │
│  │  │  │  redis           │  │  │  │  ┌─────────────┐ ┌─────────────┐     │  │
│  │  │  └──────────────────┘  │  │  │  │  NodePool   │ │  NodePool   │     │  │
│  │  │                        │  │  │  │  h100 (8/G) │ │  l40s (10)  │     │  │
│  │  │  ┌──────────────────┐  │  │  │  └─────────────┘ └─────────────┘     │  │
│  │  │  │  Envoy Gateway   │  │  │  │   Workflow pods scheduled here by      │  │
│  │  │  │  (LoadBalancer)  │◄─┼──┼──┼─►│   KAI Scheduler via PodGroup         │  │
│  │  │  │  TLS :443       │  │  │  │                                       │  │
│  │  │  └──────────────────┘  │  │  │   [+ keycloak (default-on, own LB)]       │  │
│  │  └────────────────────────┘  │  └──────────────────────────────────────┘  │
│  └──────────────────────────────┘                                              │
└──────────────────────────────────────────────────────────────────────────────┘
          │                                           │
          ▼                                           ▼
  ┌───────────────┐                        ┌──────────────────────────────┐
  │  Web Browser  │                        │   Crusoe Object Storage      │
  │  (port 443)   │                        │  (workflow data, logs, apps) │
  └───────────────┘                        └──────────────────────────────┘
```

What this builds: a CMK cluster with a control node (the OSMO service and its PostgreSQL/Redis, behind the Envoy Gateway on a public load balancer with a self-signed IP certificate), a backend node (the OSMO backend operator), and one GPU node pool per GPU type — KAI Scheduler lands workflow pods there. Outside the cluster: an Object Storage bucket and an org-scoped access key, plus an IB partition for IB-connected pools. In-cluster extras: KAI Scheduler, cert-manager and the Crusoe LB Controller. The Keycloak login (Phase 10, on by default) adds a second load balancer with OIDC enforcement at the gateway; both LB firewall rules are restricted to the operator's source addresses during the install.

## What the skill does

### Cluster creation

You describe the cluster you want:

```
I want to create an OSMO cluster on Crusoe Cloud, using 1x H100 and 1x L40s in us-east1-a.
My SSH key is ~/.ssh/id_ed25519.pub.
```

How the skill reads it: **counts are nodes, not GPUs** (`1x H100` is 8 GPUs; `1x L40s` is the 10-GPU node — the plan shows the arithmetic before you approve). Optional in the same sentence: a cluster name (default `osmo`), a bucket name (default `osmo-<random>`), and object lock with a retention period (off by default). Add `Show me the plan and wait.` to stop at the plan.

The skill then:

1. **Reads and checks** (nothing is created yet): your Crusoe project and local tools, whether the cluster name is free, the GPU instance types, how many GPUs you have **reserved** on each InfiniBand network (IB types), live stock for non-IB types (L40s, via the capacities API), your organization's storage-key limit, live quota, and the newest stable Kubernetes version. The same checks run with or without the optional MCP server.
2. **Shows you one plan** (cluster, node pools, networks, bucket, what else it will create, whether to enable **Keycloak login (Phase 10)**, and a security warning) and asks `Proceed?`. Nothing is created until you say yes.
3. **Provisions** a Crusoe Managed Kubernetes (CMK) cluster, node pools, an Object Storage bucket and an access key.
4. **Installs OSMO** on it: KAI Scheduler, cert-manager, the Crusoe Load Balancer Controller (if the cluster does not already have it), the OSMO service and the OSMO backend operator — then, if you opted in, **enables Keycloak login (Phase 10)**.
5. **Verifies** the install and reports the URL, the exported certificate and what now exists — and **offers to install the `osmo` CLI** for command-line submissions (the login itself happens later, in the workload skill, right before it submits).

### Cluster teardown

Ask the skill to tear down a deployment it created — it lists everything it found with IDs and deletes nothing until you type the cluster name:

```
Read and follow skills/deploy-osmo-crusoe/references/teardown.md.
Tear down the OSMO deployment on my cluster osmo (us-southcentral1-a).
Show me the inventory and wait for my choice of level.
```

**Level 1** uninstalls OSMO only (keep the cluster; OSMO's database is deleted — no backup); **Level 2** also deletes the node pools and the cluster. The bucket, the storage key and any InfiniBand partition are each kept unless you say yes separately. Object access is location-scoped: a bucket is only reachable from VMs in its own location, so a bucket you choose to delete is emptied **before** the pools/cluster go — from the cluster's own nodes.

## After the deploy

Once the cluster is up you can use it for any OSMO workflow you submit through the UI or CLI — to the GPU pools you asked for (`h100`, `l40s`, ...), with data and checkpoints on the cluster's Object Storage bucket. The bundled Physical-AI pipeline (LeRobot → Cosmos → GR00T) is the [run-osmo-workload](../run-osmo-workload/README.md) skill.

To confirm the deployment yourself:

- Open the URL from the report, `https://<load balancer IP>`. Your browser shows a one-time warning because the certificate is self-signed; the skill exports it to `~/osmo-ca-<cluster>.crt` (import to trust it — macOS: Keychain Access, System, Always Trust). With Keycloak there is a second certificate and a second warning.
- When you submit a workflow in the OSMO UI, choose the pool named after your GPU type (`h100`, `l40s`, ...).
- The skill offers to install the `osmo` CLI at the end of its report; login is left to the session that submits a workflow (see the run-osmo-workload skill).
- The observable contract for a passing deploy (and the Keycloak and teardown scenarios) is in [the evals](evals/README.md).

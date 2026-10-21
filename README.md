# OSMO on Crusoe Cloud

> **Risks — read before running these skills.** The full security model —
> confirmation gates, credential scoping, network exposure and known residual
> risks — is [SECURITY.md](SECURITY.md). These skills create, change and delete **real cloud infrastructure and GPU resources** on your Crusoe account: clusters, GPU node pools, load balancers, storage keys and a bucket. Teardown deletes cluster data (workflow history, users, databases) and, at Level 2, the cluster itself. The gateway the deploy skill creates is a **public LoadBalancer IP**; the install restricts its firewall rule to your source addresses and enables the Keycloak login by default (opt-out only) — anyone the firewall admits who finds the IP is otherwise an administrator (and the workload skill runs third-party code and mounts an org-scoped storage key into its task pods). Buckets are reachable only from VMs in their own location, so the teardown empties any bucket you choose to delete from the cluster's own nodes — before the pools/cluster are removed. The skills ask before anything destructive, but you — not the agent — are responsible for what they run against.

> **License and disclaimer.** This project is licensed under the MIT License (see [LICENSE](LICENSE)) and is provided "as is", without warranty of any kind. It is sample code and is not covered by Crusoe support or service-level commitments. NVIDIA OSMO, Cosmos, Isaac GR00T, LeRobot, Keycloak and other third-party software, models and datasets used by these skills are subject to their own license terms, which you are responsible for reviewing and complying with — the components these skills install or execute, with their licenses and acceptance gates, are inventoried in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). You are responsible for all resources created and all charges incurred on your Crusoe account. NVIDIA, OSMO, Cosmos and Isaac GR00T are trademarks of NVIDIA Corporation; this project is not affiliated with or endorsed by NVIDIA.

Two agent skills (SKILL.md format) that any agent harness can run:

- **[deploy-osmo-crusoe](skills/deploy-osmo-crusoe/README.md)** stands up [NVIDIA OSMO](https://www.nvidia.com/en-us/solutions/osmo/) on [Crusoe Cloud](https://crusoe.ai) from a single sentence — cluster, node pools, bucket, the OSMO install, a default-on Keycloak login (opt-out only) — and tears it down upon request.
- **[run-osmo-workload](skills/run-osmo-workload/README.md)** drives a chained Physical-AI workload through the deployed cluster: LeRobot data preparation → Cosmos visual augmentation → Isaac GR00T fine-tuning.

NVIDIA OSMO is a cloud-native platform for orchestrating large-scale robotics and simulation workloads: one API and UI for submitting, scheduling and monitoring GPU workflows across compute pools.

## Prerequisites

- A Crusoe account and project with **reserved GPU nodes** (InfiniBand-connected GPU types need reserved IB capacity in the location; the deploy skill checks and stops if there is none).
- On your machine: the [Crusoe CLI](https://docs.crusoecloud.com/installing-the-cli) (**v1.0.9+**, already logged in), `helm`, `kubectl`, `jq`, `openssl`, and an SSH **public** key file.

## MCP or CLI usage

Both skills work with or without the optional [Crusoe MCP server](https://docs.crusoecloud.com/reference/mcp-server/) (`@crusoeai/cloud-mcp`):

- **With the MCP** (read-only): reads go through convenience wrappers (`list_capacities`, `list_project_quotas`, `cluster_health_check`, ...), and quota is pre-checked at planning time. Register it per your agent's MCP configuration and start a new session — with Claude Code, for example: `claude mcp add --scope user crusoe-cloud -- npx -y @crusoeai/cloud-mcp`.
- **Without the MCP**: every read uses the [Crusoe CLI](https://docs.crusoecloud.com/installing-the-cli) and the signed Crusoe API ([api-capacities.md](skills/deploy-osmo-crusoe/references/api-capacities.md), [check_capacities.py](skills/deploy-osmo-crusoe/scripts/check_capacities.py)); a quota or stock shortfall can surface at pool-create time instead of planning time.

Creates and changes always go through the Crusoe CLI; the MCP is read-only.

## Repository layout

```
skills/deploy-osmo-crusoe/
├── SKILL.md                      # entry point: Phase 0 gates, scope, tool routing, pointers
├── README.md                     # human docs: architecture diagram, prompts, timing, security
├── references/
│   ├── provision.md              # Phases 1-2: input resolution, quotas/stock, approval plan, provisioning
│   ├── osmo-install.md           # Phases 3-10: prerequisites, Helm, CA trust, verify, report
│   ├── keycloak.md               # Keycloak/IdP design + rationale (Phase 10)
│   ├── keycloak-install.md       # Phase 10's exact commands (loaded only when opted in)
│   ├── api-capacities.md         # signed capacities/quotas API checks (non-IB GPU types)
│   ├── teardown.md               # two-level teardown
│   └── tool-routing.md           # which operations use the MCP, the API, and which the CLI
├── scripts/
│   ├── check_capacities.py       # signed /v1/capacities call (env credentials or ~/.crusoe/config)
│   ├── provision_crusoe.sh       # Phase 2's five create commands (mock-verified)
│   ├── build_ca_bundle.sh        # Phase 7's CA build + 3-namespace fan-out + backend restarts
│   └── empty_bucket.py          # version-aware bucket purge (empty a bucket from in-location compute)
├── assets/
│   ├── osmo-service-values.yaml.template    # Helm values templates (substitute <…> by hand)
│   ├── osmo-backend-values.yaml.template
│   └── ca-trust-values.yaml.template
└── evals/                                 # deploy scenarios (cluster + script-harness)

.claude/skills/ + .hermes/skills/    # committed pointer stubs → skills/<name>/SKILL.md

skills/run-osmo-workload/
├── SKILL.md                      # entry point: phases 0-6, verify gates, credential flows
├── README.md                     # human docs: the pipeline, requirements, verification status
├── scripts/
│   └── submit_stage.sh            # submit + ID-parse + rendered-spec verification (all stages)
├── references/
│   ├── troubleshooting.md        # full decision table (submit-time, runtime, install-side)
│   ├── tested-status.md          # the tested-status lessons, verbatim
│   ├── design-notes.md          # variant choice, topology, the pin contract, timestamp math
│   ├── sources.md               # primary-source citations + decision log
│   └── merge-augmented.md       # merge semantics, v2.1 layout, failure modes
├── assets/
│   └── status-subagent.md        # the polling subagent's spawn template
├── workflows/                    # submit-ready OSMO workflow YAMLs (stage 1, 2a, 2b, 3)
└── evals/                         # workload scenarios (cluster + script-harness)
```

Skill-discovery directories are committed for Claude Code (`.claude/skills/`) and Hermes (`.hermes/skills/`): each contains pointer stubs that redirect to the real skills under `skills/`. For other harnesses, point a session at a skill's `SKILL.md`. Prompt examples are in each skill's README (linked above).

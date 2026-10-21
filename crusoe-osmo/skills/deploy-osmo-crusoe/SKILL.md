---
name: deploy-osmo-crusoe
description: Use when asked to stand up, deploy, provision, or tear down a single-cluster NVIDIA OSMO platform on Crusoe Cloud from one sentence, e.g. "I want to create an OSMO cluster on Crusoe Cloud, using 1x H100 and 1x L40s in us-east1-a". Also when asked to uninstall or fully delete an existing OSMO deployment. Covers GPUs, location, quotas, InfiniBand, the bucket and the OSMO install, with a Keycloak login on by default (Phase 10, opt-out only). Running a GPU workload on the cluster is a different skill (run-osmo-workload).
compatibility: Requires the crusoe CLI (v1.0.9 or higher), helm, kubectl, jq (or jaq) and openssl; network access to api.cloud.crusoe.ai, the Crusoe Object Storage endpoint and the cluster gateway; the read-only crusoe-cloud MCP server is optional. Runs cluster-side commands outside the agent shell sandbox — sandboxed TLS fails, see Tool routing.
metadata:
  author: yjeong1
  version: "1.1"
---

# Deploy OSMO Single-Cluster on Crusoe — MCP + CLI

Stands up a single-cluster OSMO platform on Crusoe Managed Kubernetes from a one-sentence request. The user names the GPUs and the location; this skill works out everything else.

**Read this whole skill before starting.** Later phases carry operational lessons (CA trust, routing, OOM limits) that are not obvious from the Helm charts.

## Scope

UI-only for the cluster itself; the `osmo` CLI is **offered at the report** (install here,
login later — the run-osmo-workload skill logs in when it is about to submit). TLS is
always a self-signed certificate for the gateway's public LoadBalancer IP: no domain, no
DNS provider, no Tailscale. Do not suggest Let's Encrypt/ACME: a public CA will not issue
a certificate for a bare IP.

## Tool routing

Per operation: read with the `crusoe-cloud` MCP if it is loaded, otherwise with the CLI; create or change any Crusoe resource with the CLI (the MCP is read-only); do cluster-side work with `kubectl`/`helm`. Exact tools, parameters and commands are in [references/tool-routing.md](references/tool-routing.md) — consult it before every Crusoe call. Never use `crusoe reservations list`.

If an MCP call errors or returns something unexpected, retry once, then use the CLI for that operation and tell the user. Do not loop, and do not silently switch.

Verify CLI flags with `--help` before relying on them: the `crusoe` CLI changes between versions (this skill requires v1.0.9 or higher — Phase 0a stops on an older one — and was validated against v1.0.9). If `--help` disagrees with this skill, trust `--help`, adapt, and tell the user.

The `crusoe` CLI, `kubectl` and `helm` fail TLS verification inside the agent's shell sandbox (in Claude Code's Bash sandbox: `x509: OSStatus -26276`). If you see that, run them outside the sandbox. Several steps wait 5 to 20 minutes and your agent's tool timeout is often shorter (Claude Code's Bash tool: 2 minutes by default): set the longest tool timeout your agent allows (Claude Code's Bash tool allows up to 600000 ms) or run the command in the background and poll. A tool timeout is not a failure of the operation, so check its state before retrying. Never disable certificate verification and never work around an auth or TLS error any other way: stop and tell the user.

## Phase 0 — Preconditions

**a. Local tools — hard gate.** Check all three critical tools first, then the two helpers:

```bash
crusoe --version
helm version
kubectl version --client
jq --version
openssl version
```

**Stop immediately if `crusoe`, `helm` or `kubectl` is missing — before any other Phase 0 step, before `crusoe whoami`, before anything else.** Do not run any other command of this skill. Tell the user exactly which of the three is missing and the install path (helm: `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`; the Crusoe CLI and kubectl per the user's usual install method). Do not install them yourself.

**Strict version floor: `crusoe` must report `v1.0.9` or higher** (parse `crusoe --version`; accept `v1.0.9` and any higher semver). If it is older, stop with the upgrade instruction — older releases have different flags (a v1.0.3 run failed even to parse `--version`). `jq` may be satisfied by a compatible drop-in (`jaq`); `openssl` just needs to be present. If a helper (`jq`/`jaq`, `openssl`) is missing, stop as well, with the same rules.

**b. Detect the MCP and announce the mode.** Check whether `crusoe-cloud` MCP tools are available (their names start with `mcp__crusoe-cloud__`; if the tools are deferred, search for "crusoe-cloud"). Call `get_user_identity`.

- Works: `MODE=mcp+cli`. Say: "Using the crusoe-cloud MCP for reads and the crusoe CLI for creating resources."
- Missing or erroring: `MODE=cli-only`. Say this as one message; the setup hint is part of it, do not drop it: "The crusoe-cloud MCP is not available, so I'm using the crusoe CLI for everything and quota will not be pre-checked. To enable the MCP for next time, register it per your agent's MCP configuration (Claude Code example: `claude mcp add --scope user crusoe-cloud -- npx -y @crusoeai/cloud-mcp`) and start a new session." Say it once, then keep going. Only if the user says the MCP is registered but still does not load, add: local scope only covers the exact project path, and a root-owned `~/.npm` cache makes `npx` fail with EPERM (fix: `sudo chown -R "$(id -u):$(id -g)" ~/.npm`).

**c. Identity.** `crusoe whoami` (and `get_user_identity` in `mcp+cli` mode). If this fails, stop: it is an auth or environment problem outside this skill.

**d. Project.** Get the CLI's project with `crusoe config get default_project` → `PROJECT_NAME`. If that is empty (the project may come from the `CRUSOE_DEFAULT_PROJECT` environment variable), use the variable, or run `crusoe projects list` and ask the user which project to use. In `mcp+cli` mode also call `get_current_project`; if it differs from `PROJECT_NAME`, stop until both agree (offer `use_project(PROJECT_NAME)`). Set `PROJECT_ID` from `get_current_project`, or from `crusoe projects list --json` matching `PROJECT_NAME`. State the project name in your first message to the user: everything below creates billable resources in it.

## Phases 1–2 — Resolve inputs, then provision

Loaded on a fresh deploy: the full resolution-and-provisioning procedure lives in
[references/provision.md](references/provision.md) — Phase 1 (inputs, quotas, stock,
key slots, the plan you present for approval) and Phase 2 (cluster, pools, IB partition,
bucket, storage key, the `get-credentials` check). Nothing in Phases 1–2 runs on a
teardown (references/teardown.md); the skill is end-to-end — a cluster with no OSMO installed is not a state it supports re-entering.

## Phases 3–10 — OSMO install

Continue straight on to [references/osmo-install.md](references/osmo-install.md) and follow it from Phase 3, in order, without stopping to ask: the user already approved the whole run in Phase 1. It needs the Phase 2 outputs (the access key becomes `OSMO_ACCESS_KEY_ID`/`OSMO_ACCESS_KEY`). Continue through Phase 10 (Keycloak — the default; run it unless the user opted out in the Phase 1 summary) after the Phase 9 report — it lives in its own reference, [references/keycloak-install.md](references/keycloak-install.md), loaded only then. If the user opted out, skip it with the one-sentence residual-risk statement Phase 10 specifies.

## Teardown

To delete or uninstall a deployment this skill created, follow [references/teardown.md](references/teardown.md). It offers two levels (uninstall OSMO only, or a full teardown), deletes only what the user confirmed by typing the cluster name, and never deletes a bucket, a storage key or an IB partition without a separate explicit yes.

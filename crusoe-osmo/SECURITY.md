# Security model — the OSMO-on-Crusoe agent skills

This document states, in one place, what these skills do to billable GPU infrastructure and org-scoped storage, which guardrails exist, which are behavioral (LLM-enforced) rather than structural, and what remains unverified.

Scope: `skills/deploy-osmo-crusoe` and `skills/run-osmo-workload` as driven by an agent harness (Claude Code, or Hermes through the `.hermes/` stubs).

This file accompanies the security-hardening changes in the same change set
(template-value allowlists, hash-verified installs, key TTL enforcement,
integrity manifest + CI, firewall-on-install, Keycloak-by-default).

## What the skills can do (the blast radius)

- **deploy-osmo-crusoe**: creates and deletes a CMK cluster, node pools (GPU
  billable), load balancers, disks, an IB partition, an Object Storage bucket,
  and an org-scoped storage key (see "Credentials" below). Destructive
  operations are confirmation-gated (below), but the capability is real: an
  agent following these skills holds cloud-creation and cloud-deletion power
  on the configured Crusoe account.
- **run-osmo-workload**: submits GPU workflows that execute third-party code
  (PyPI packages, pinned GitHub checkouts, HuggingFace models, NGC containers)
  as root in pods with an org-scoped storage key mounted at `/root/.s3keys/`
  and an HF token. The workflows' entry scripts are content-pinned and
  hash-verified where feasible (uv binary, git checkouts, exact pip pins);
  their transitive dependencies are not hash-pinned (see Residual risks).

## Confirmation gates (HITL)

Behavioral gates, enforced by instructions in the skill text — they are NOT
enforced by any harness capability restriction:

1. **Deploy plan approval** — nothing is created until the user approves the
   Phase 1 summary (explicit "Proceed?").
2. **Teardown confirmation** — the user must type the cluster name to confirm
   any teardown; buckets, storage keys and IB partitions each require a
   separate explicit yes (`teardown.md` step 12).
3. **Key deletion** — only a key matched to the cluster, on an explicit yes.
4. **Workload license gate** — the NVIDIA license acceptance is a hard stop.

A harness that fails to honor instructions (prompt injection, a harness with
weaker instruction-following) can bypass these gates. The CI integrity gate
(below) is the structural control on the instruction files themselves.

## Framework security models

### Claude Code
Documented upstream: Bash-tool sandboxing (network/TLS denials), tool
permission prompts, and per-tool timeouts. The deploy skill explicitly runs
cluster-side `kubectl`/`helm`/`crusoe` commands **outside** the sandbox
(sandboxed TLS fails against the self-signed gateway cert — `SKILL.md`
"Tool routing"); this sandbox-escape is deliberate, disclosed, and limited to those commands. MCP `crusoe-cloud` (read-only) is preferred for reads; the CLI carries writes. The MCP/CLI split is routing advice, not a capability boundary — a CLI write is always reachable in-session.

### Hermes
Registered for these skills via `.hermes/skills/` stubs (same stub→canonical
redirect as Claude Code; now hash-verified). Locally observed
(v0.20.0): a `terminal` tool with a `singularity` sandbox backend, a
container-scoped code-execution tool, and an approvals subsystem
**Live exercise (v0.20.0, full deploy from these skills, observed)**: Hermes
**honors the confirmation gates** — it presented the Phase 1 plan summary and waited for approval, stopped at every step needing user input (firewall CIDRs, per-item confirmations), and was blocked by its own harness approval gate on signed API calls, `helm repo add`, the Phase 4a install, Phase 10 step e and a sed — re-issuing each only after the user's live approval. It did not work around a single gate, reported every conflict instead of improvising, followed the skill's documented partial-failure recovery exactly (pools "already
exists" case), refused to fabricate a blocked validation result, and left
deletion-class actions (orphaned firewall rules) untouched pending user
say-so. Sandbox-escape scoping: no blanket sandbox disabling was observed —
cluster-side commands ran and TLS-failing calls were handled per the skill's
instruction. **Gate coverage in that exercise, stated plainly**: gates 1 (plan
approval) and 4 (license) fired and held directly; gates 2 (teardown typing)
and 3 (key deletion) had no trigger event in the cooperative run — their
behavioral evidence is negative-only: deletion-class items surfaced by the
run (orphaned `0.0.0.0/0` firewall rules) were reported and left untouched
pending explicit user say-so, and the pre-approved key deletion had no
target (no `osmo-workflow-data` key existed; nothing was chosen for the
user). Both were subsequently exercised at that cluster's teardown (same
day): the typed cluster-name confirmation held (Level 2, deletion started
only after the name), and the bucket, storage key and IB partition were each
deleted on a separate explicit yes, by ID. All four gates have now fired
and held under Hermes.

**Still unverified for Hermes**:

1. The four gates under an *adversarial* prompt (the live exercise was a
   cooperative run; the gates held, but prompt-injection resistance was not
   probed).
2. Whether the deployment running Hermes enforces access control and audit
   logging on its sessions (orchestration-level, outside this repo).

**Two Hermes-run findings fixed in the skills** (see the same commits): the
run skill's Phase 1b CA bundle must include Keycloak's CA on a Phase-10
deployment, and the deploy skill's step-d/e scripts printed a redacted Bearer
that broke literal porting — both documented and patched.

This repo's part is done: the stubs carry the same description and the
hash-verification step, and the CI stub-drift job keeps them synchronized.

## Credentials

- **Object Storage key** — org-scoped by the platform (docs: usable "in all
  buckets in all projects within your organization"); bucket-scoped keys do
  not exist . Compensating controls: keys created by these skills
  carry a mandatory `KEY_EXPIRY` (default 30 days; the create refuses without
  it), a dedicated expiry-bearing `osmo-workload-run` key is the REQUIRED
  default for the workload chain (deploy-key reuse only on the user's
  explicit choice with a verified expiry; no-expiry keys are refused), and
  teardown lists/deletes the cluster's key by access-key ID.
  Management is user-scoped: only the creating user can list or delete a key — rotation and teardown must run as the deploying user.
- **Key secret handling** — the secret prints once at creation, is captured in
  memory only, and is never written to skill output or files.
- **HF/NGC tokens** — provided by the user as env vars; registered via
  `--payload-file`, never argv; never printed.

## Instruction-file integrity

- `.skill-hashes` pins the SHA256 of every SKILL.md, reference and script
  under `skills/`, plus the `.claude/` and `.hermes/` stubs.
- CI (`skill-integrity` job) rejects any change to a pinned file without a
  matching manifest update in the same commit.
- Stub bodies instruct the agent to verify the target hash before following
  the redirect. **Caveat:** that instruction is itself behavioral; the CI gate and CODEOWNERS review are the structural controls.
- CODEOWNERS assigns review ownership of all skill instruction surfaces.

## Network exposure

- The OSMO gateway is a public LoadBalancer IP. The install **restricts its firewall rule to operator-supplied CIDRs as a hard Phase 9 step** (rule re-read and reported; re-verified after any Service change; refusing to supply CIDRs stops the report).
- Keycloak authentication is the default (Phase 10; explicit opt-out required to run a login-free gateway, with the residual risk stated). Keycloak's own LB gets the same source restriction.
- Residual: whether the LB controller reverts a hand-edited firewall rule is platform-unverified; the skill compensates by re-checking after every Service change and at every report.

## Residual risks (known, accepted or gated)

- **runAsNonRoot on workflow pods is not implemented — schema gate ANSWERED (rejected)**: verified live against OSMO (charts 1.3.1 / server 6.3.1): `osmo workflow validate` on a task-level `securityContext: {runAsNonRoot: true, runAsUser: 1000}` returns HTTP 400 — `VersionedWorkflowSpec: workflow.groups.0.tasks.0.securityContext: Extra inputs are not permitted [extra_forbidden]`. Caveat recorded with it:
  `osmo workflow submit --dry-run` renders the same block through UNVALIDATED
  (the render is not schema acceptance; do not read a clean dry-run as
  support). All four entry scripts therefore keep assuming root (apt, system
  pip, `/root/.s3keys` mount paths); the non-root rework (non-root UID +
  local venvs + non-root credential mount path) stays gated off until an
  OSMO version whose schema accepts pod securityContext. Until then the
  entry scripts are the least-privileged we can make them: exact pins,
  hash-verified uv, allowlisted template values.
- **Transitive pip dependencies are not hash-pinned** (`--require-hashes` over
  the torch-class trees is disproportionate to the pins already in place);
  exact pins on every direct install; the review's Medium-tier ask stands.
- **The status subagent reads workflow logs that untrusted code writes**;
  its constraints are behavioral . The subagent template carries a
  trust-boundary instruction; treating log content as adversarial input is
  enforced only by instructions.
- **Container images are pinned by tag, not digest** : the four workflow images plus the OSMO chart images (`latest` tag) can be re-pushed under the same tag. Digest-pinning the workflow images is a mechanical follow-up; the OSMO chart's image tags are upstream's choice (recorded in the Phase 9 report: report the resolved images).
- **Framework-specific instruction audit** : the SKILL.md files mix harness-agnostic rules with Claude-Code-specific ones (sandbox escape MCP tool naming, `mcp__` prefixes). Untested on Hermes; the production-Hermes checklist above gates first use.
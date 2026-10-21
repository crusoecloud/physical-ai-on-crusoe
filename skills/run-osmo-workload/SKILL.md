---
name: run-osmo-workload
description: Use when asked to run, test, or execute a GPU workload on an NVIDIA OSMO cluster that the deploy-osmo-crusoe skill stood up on Crusoe Cloud. Drives a chained LeRobot → Cosmos → GR00T fine-tune pipeline through OSMO. Does not stand up, resize, verify or tear down the cluster (that is deploy-osmo-crusoe's job); requires the cluster and OSMO to already be installed.
compatibility: Requires the deploy skill's artifacts ($HOME/.osmo-install/<cluster> workdir with lb_ip and combined-ca-bundle.crt, an Object Storage bucket), the osmo CLI (offered by the deploy skill; install on request), kubectl, and network access to the cluster's gateway and Crusoe Object Storage.
metadata:
  author: yjeong1
  version: "1.3"
---

# Run a Physical-AI workload on an OSMO cluster — LeRobot → Cosmos → GR00T

Part of this repository. You must already have a single-cluster OSMO platform on Crusoe
Cloud from [deploy-osmo-crusoe](../deploy-osmo-crusoe/SKILL.md): cluster up, OSMO
installed, gateway reachable at `https://<LB_IP>`, Object Storage bucket created, and two
GPU pools: `h100` (N nodes × 8 H100, InfiniBand — the fine-tune discovers the node count
live and scales torchrun) and `l40s` (enough 48 GB L40Ss for the augmentation's strided
tasks; the node's local disk bounds how many tasks gang-schedule together).
**This skill never creates, checks out or deletes Crusoe resources.** If any input is
missing, stop and send the user back to the deploy skill.

**Read this whole file before starting.** The workflow YAMLs in [workflows/](workflows/)
are complete and submit-ready; each stage's own reference is linked at its gate (the
merge's is [references/merge-augmented.md](references/merge-augmented.md)) — read them
when you reach the stage, not up front.

## What this runs

One chained Physical-AI workload, in four separately submitted OSMO workflows:

| Stage | Workflow file | Pool | What it does |
|---|---|---|---|
| 1 | [workflows/01_prepare_dataset.yaml](workflows/01_prepare_dataset.yaml) | `l40s` | Download the public LeRobot **v3** dataset `izuluaga/finish_sandwich` (SO-101 arm, 80 episodes, 2 cameras, 1.2 GB), convert v3 → v2.1 with NVIDIA's official converter, attach the GR00T SO-100 `modality.json`, transcode AV1 → h264, upload | ~5–10 min |
| 2a | [workflows/02_cosmos_augment.yaml](workflows/02_cosmos_augment.yaml) | `l40s` | Cosmos-**Predict2-2B-Video2World** visual augmentation: strided parallel tasks (default 2 × gpu:1, `n_tasks` scales — gang-scheduled, so n_tasks × storage must fit the node's local disk), default first 5 episodes × 2 variants, front camera; resamples 30→10 fps, chunk-walks the episode (61-frame chunks), trims to the exact frame count | ~1.5 h (10 clips on 2 tasks) |
| 2b | [workflows/04_merge_augmented.yaml](workflows/04_merge_augmented.yaml) | `l40s` | Merge the augmented clips into the converted dataset as new episodes (visual only: parquet rows copied, timestamps rewritten to 10 fps, wrist camera resampled) | ~5–10 min |
| 3 | [workflows/03_groot_finetune.yaml](workflows/03_groot_finetune.yaml) | `h100` | Fine-tune **Isaac GR00T N1.5-3B** on the merged dataset, one task per H100 node (8 GPUs each), torchrun across the pool (`n_nodes` discovered at runtime), OSMO checkpointing every 30 min from the lead | ~2 h smoke (2000 steps) |

**Success bar: all stage workflows reach `COMPLETED` in OSMO**, with the converted
dataset, the augmented clips, the merged training dataset and the final checkpoint in the
OSMO bucket under `s3://<bucket>/oso-data/`.

Dataset, VRAM-fit, checkpoint-variant and pin citations live with their primary
sources in [references/sources.md](references/sources.md); the pin inventory and
per-stage design rationale are in [references/design-notes.md](references/design-notes.md).
The chain itself (LeRobot data → Cosmos augmentation → GR00T VLA) is NVIDIA's documented
SO-101 sim-to-real strategy 3 and its OSMO cookbook `nut_pouring` pipeline, adapted to
Crusoe's two GPU types.

## Scope

Running a workload only. No cluster provisioning, no OSMO install, no teardown. The osmo
CLI is usually installed by the **deploy** skill's report (it offers the install); if it
is missing, this skill installs it on request. Login happens here, right before
submitting; everything else comes from the deploy skill's run.

**Tested end-to-end** — see "Testing notes" at the bottom for what that means
before relying on any stage.

## Phase 0 — Preconditions

**a. Cluster inputs.** Read the deploy skill's work directory:

```bash
CLUSTER="${CLUSTER:-${CLUSTER_NAME:-osmo}}"   # CLUSTER_NAME is the deploy skill's variable name
WORKDIR="$HOME/.osmo-install/$CLUSTER"
[ -s "$WORKDIR/lb_ip" ] || { echo "no $WORKDIR/lb_ip — run deploy-osmo-crusoe first (or set CLUSTER to a cluster whose WORKDIR exists)"; exit 1; }
LB_IP=$(cat "$WORKDIR/lb_ip")
echo "gateway: https://$LB_IP"
# Set once per shell: SKILL_DIR is this skill's directory (its scripts and workflows are
# addressed as "$SKILL_DIR/scripts/..." and "$SKILL_DIR/workflows/..." everywhere below).
SKILL_DIR="<path-to>/skills/run-osmo-workload"
```

The deploy skill's final report named the bucket. If the user does not know it,
`crusoe storage buckets list` shows the `osmo-*` bucket in the cluster's location. Set:

```bash
BUCKET="<bucket-name>"
STORAGE_URL="s3://$BUCKET/oso-data"
```

Shell state does not persist between commands: re-derive `CLUSTER`, `WORKDIR`, `LB_IP`,
`BUCKET` and `STORAGE_URL` in every command that needs them (or write them to
`$WORKDIR/run.env` — no secrets — and source it). The submit helper
([scripts/submit_stage.sh](scripts/submit_stage.sh)) re-derives `WORKDIR` itself the same
way, but the idfile path you pass it must be correct on entry.

**b. Pools exist — hard gate.** Verify both pools against the running cluster before any
submission:

```bash
kubectl get nodes -l crusoe.ai/nodepool.name=l40s -o name
kubectl get nodes -l crusoe.ai/nodepool.name=h100 -o name
```

Each must print at least one node. If `l40s` is absent — L40s stock is thin and varies
by location and week (check the deploy skill's capacities API before assuming) — **stop**
and tell the user stages 1–2 cannot run on this cluster. Only if the user explicitly accepts a slower path: stages
1–2 can run on `h100` (pass `h100` as the `<pool>` argument to each submit instead of `l40s`),
where the augment tasks
serialize on the 8-GPU node — state the slowdown plainly, never hide it.

**c. Warning, stated plainly.** The workflows below bill GPU time against the user's
Crusoe account (roughly 4–8 GPU-hours of L40S and 16–32 GPU-hours of H100 for the smoke
defaults), and the gateway is the deploy skill's login-free public IP unless the user
opted into Phase 10 authentication. Do not share the URL.

**d. Decision points** (ask, with defaults): dataset (default `izuluaga/finish_sandwich`),
augmentation scope (default: episodes 0–4, 2 variants each, front camera only), training
length (default: smoke 2000 steps, checkpoint every 500). GR00T N1.5 is pinned by this
design; GR00T N1.7 is out of scope (its LeRobot integration dropped the N1.5 flows this
chain is built on).

## Phase 1 — osmo CLI, login and HF token

**a. Check for the CLI; install only if the user asks.** The deploy skill **offers to
install the CLI at the end of its report** (skills/deploy-osmo-crusoe/references/osmo-install.md Phase 9), so it may already
be here: `command -v osmo || true`. If present, skip to step c. If absent, ask: the
install is a machine-level change the deploy skill only makes on request, and so does
this one. The install script is unreviewed third-party code that runs with the user's
privileges (their Crusoe and kubeconfig credentials live on this machine): download it
to a file, let the user review it, then run it — never pipe it straight into bash, and
never from a mutable ref like `refs/heads/main` (the content can change under you;
CWE-494). Pin the tag or commit the run used:

```bash
curl -fsSL -o /tmp/osmo-install.sh https://raw.githubusercontent.com/NVIDIA/OSMO/<pinned-tag-or-sha>/install.sh
# the user reviews it first: less /tmp/osmo-install.sh
bash /tmp/osmo-install.sh && osmo --version
```

If the user declines → **UI-paste mode**: every submission step below becomes "open
`"$SKILL_DIR"/workflows/<file>`, paste into the OSMO UI's Submit Workflow,
set the pool on the submit screen, and fill the `default-values` overrides in the
parameters panel"; monitoring steps become the UI click-path (workflow detail page →
status and task logs). Everything else — bucket URLs, stage IDs carried between stages,
verify gates — is identical. Record IDs from the UI's workflow detail URL.

**b. Login (device flow; the user completes it in their browser).**

```bash
osmo login "https://$LB_IP/" --method code
```

**TLS against the self-signed gateway:** the gateway's certificate is self-signed (no domain, no CA), so the first `osmo login` may fail TLS verification. If it does, point the CLI at the deploy install's CA bundle and retry — never disable verification and never use an insecure flag:

```bash
SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo login "https://$LB_IP/" --method code
```

(every later `osmo` command talks to the same gateway — re-derive both in each command, per the shell-state rule at the top of Phase 0). If the CLI still refuses, read its `--help` for the CA flag it actually wants and use that; stop and report if none exists.

**Keycloak-enabled deployments (deploy Phase 10 ran): the login's TLS path
also involves Keycloak's CA.** The device flow and every ~300 s token refresh
reach the Keycloak LB, whose certificate the deploy skill issues separately —
the gateway-only `combined-ca-bundle.crt` does NOT verify it (observed live:
`osmo login --method code` fails with a TLS error against the Keycloak device
endpoint after the gateway connection succeeds). Extend the bundle before
logging in — append `$WORKDIR/keycloak-ca.crt` (the deploy skill's Phase 10e
writes it into the workdir) and point both env vars at the extended file:

```bash
cat "$WORKDIR/combined-ca-bundle.crt" "$WORKDIR/keycloak-ca.crt" > "$WORKDIR/cli-ca-bundle.crt"
SSL_CERT_FILE="$WORKDIR/cli-ca-bundle.crt" REQUESTS_CA_BUNDLE="$WORKDIR/cli-ca-bundle.crt" \
  osmo login "https://$LB_IP/" --method code
```

(If `keycloak-ca.crt` is absent from the workdir, the deploy skill's Phase 10
did not complete its step e — re-run it rather than skipping the Keycloak CA.)

On a Keycloak-enabled deployment (deploy Phase 10) the same flow works against the
`osmo-device` client. If `--method code` fails against the login-free gateway, fall back
to the install's default identity:

```bash
osmo login "https://$LB_IP/" --method dev --username testuser
```

and say plainly that this is the deploy skill's no-auth default (anyone with the URL is
admin) — prefer `--method code` whenever real auth exists.

**c. Profile.** `osmo profile set pool h100` (a default; each workflow targets its pool
explicitly anyway). State it.

**d. HF token, license gate, and the two data credentials (1f/f2) — required before any
submit, and mostly the user's own hands.** Follow
[references/credentials.md](references/credentials.md) exactly: the user provides the HF
token as the `HF_TOKEN` environment variable (the skill validates presence and shape —
never printing it — and hard-stops if it is unset), then registers it via
`--payload-file` (never argv, never chat), the NVIDIA license acceptance is a **hard
stop** until accepted, and BOTH `osmo credential set` registrations (the user-level
`crusoe-s3` DATA credential and the task-mounted `s3-keys` GENERIC credential) must
exist or submission fails with `NoCredentialsError`. Its safety note (organization-scoped
key; a dedicated, expiry-bearing `osmo-workload-run` key is the REQUIRED default —
reusing the deploy key needs the user's explicit choice and a verified expiry, and a
no-expiry key is refused) is part of the step.

## Phase 2 — Stage 1: prepare the dataset

**Gate: workflow `COMPLETED` + the dataset on the bucket.**

1. Submit (CLI) — via the skill's submit helper, [scripts/submit_stage.sh](scripts/submit_stage.sh) (one home for the ID-parse pipeline and the two `--set` parser footguns: it always uses `--set-string` for URL-shaped values and refuses a second `--set`):

```bash
"$SKILL_DIR"/scripts/submit_stage.sh "$SKILL_DIR"/workflows/01_prepare_dataset.yaml \
  l40s "$WORKDIR/stage1_id" --set-string "storage_url=$STORAGE_URL"
```

2. The helper verified the overrides (the rendered spec shows the real bucket, no
   placeholder); re-check by hand only when debugging a submit failure.
   Then monitor (poll at the cadence table's interval — 2 min for stage 1): `osmo workflow query "$(cat "$WORKDIR/stage1_id")"`.

**What COMPLETED looks like:** workflow and group `prepare` COMPLETED (the task is named
`run` — group and task names must differ, see the decision table); `osmo workflow logs <id> -t run`
with the sanity gate's `v2.1 dataset OK: <N> episodes, <C> cameras` and
`stage-1 artifact done` lines (counts follow the chosen scope — the defaults print
80 episodes, 2 cameras), and
`osmo data list "$STORAGE_URL/dataset/$(cat "$WORKDIR/stage1_id")/"`).

## Phase 3 — Stage 2a: Cosmos augmentation

**Gate: workflow `COMPLETED` + the clips on the bucket.**

1. Submit:

```bash
"$SKILL_DIR"/scripts/submit_stage.sh "$SKILL_DIR"/workflows/02_cosmos_augment.yaml \
  l40s "$WORKDIR/stage2a_id" --set-string "storage_url=$STORAGE_URL" \
  --set "stage1_id=$(cat "$WORKDIR/stage1_id")"
```

2. Monitor: `osmo workflow query "$(cat "$WORKDIR/stage2a_id")"`. The `aug-*` tasks (default `n_tasks: 2`)
should be RUNNING concurrently, each handling a strided subset of episodes; with the
default `max_episode: 5`, tasks past the augmented subset complete in seconds
(each writes a `.skipped` sentinel — empty uploads are not allowed).

**What COMPLETED looks like:** all `aug-*` tasks COMPLETED;
`s3://$BUCKET/oso-data/augmented/<stage2a_id>/` contains `ep_0_aug_0.mp4` … `ep_4_aug_1.mp4`,
an `ep_<E>_frames.txt` per augmented episode and the `.skipped` sentinels.

3. **Frame-count spot check — do not skip it.** In `aug-0`'s log
   (`osmo workflow logs "$(cat "$WORKDIR/stage2a_id")" -t aug-0`), the `generated … aligned to <N> frames` line
   must show the same `N` as `episode 0: N frames at 10fps`. A mismatch means the trim
   pass failed: **do not proceed to the merge** — a misaligned clip would silently
   corrupt the merged dataset.

4. Duration: see the cadence table (~1.5 h cold at the defaults; the checkpoint
   download dominates — details in design-notes).

## Phase 4 — Stage 2b: merge the augmented episodes

**Gate: workflow `COMPLETED` + the merged dataset on the bucket.** Semantics and failure
modes: [references/merge-augmented.md](references/merge-augmented.md) — read it before this stage.

1. Submit:

```bash
"$SKILL_DIR"/scripts/submit_stage.sh "$SKILL_DIR"/workflows/04_merge_augmented.yaml \
  l40s "$WORKDIR/stage2b_id" --set-string "storage_url=$STORAGE_URL" \
  --set "stage1_id=$(cat "$WORKDIR/stage1_id") stage2a_id=$(cat "$WORKDIR/stage2a_id")"
```

(`stage1_id`/`stage2a_id` have no defaults on purpose: OSMO fails the submission on an
unset variable, so a missing `--set` fails loudly instead of reading an empty prefix.)

2. **What COMPLETED looks like:** group `merge` COMPLETED (task `run`; `osmo workflow logs <id> -t run`);
   its log ends `merged dataset OK: <N> episodes (<K> augmented; augmented rows == lengths == video frames)`
   — the row count AND the ffprobe frame-count assertion both passed (the counts follow
   the chosen scope — the defaults print 90 episodes (10 augmented)) and
   `s3://$BUCKET/oso-data/training-data/<stage2b_id>/dataset/` is non-empty (the `-data` suffix keeps the self-uploaded tree outside the outputs URL — OSMO's output-sidecar mirror-sync deletes keys under that URL and once truncated a self-upload from 246 objects to 88).

## Phase 5 — Stage 3: GR00T fine-tune

**Gate: workflow `COMPLETED` + the checkpoint on the bucket.**

0. **Discover the pool's node count and submit in the SAME command block** (shell state
does not persist between tool invocations — a separate block would submit with an empty
`n_nodes`):

```bash
NODES=$(kubectl get nodes -l crusoe.ai/nodepool.name=h100 --no-headers | wc -l)
"$SKILL_DIR"/scripts/submit_stage.sh "$SKILL_DIR"/workflows/03_groot_finetune.yaml \
  h100 "$WORKDIR/stage3_id" --set-string "storage_url=$STORAGE_URL" \
  --set "stage2b_id=$(cat "$WORKDIR/stage2b_id") n_nodes=$NODES"
```

(`n_nodes` = the count; the template spawns one task per node and torchruns
across them — `--nnodes=$NODES`, 8 GPUs per node, rendezvous on the lead task)

   Global batch = `batch_size × 8 × n_nodes` (defaults: 4 × 8 × 1 = 32). Only the
   `master` task writes outputs and checkpoints; workers run the same entry script
   and join torchrun's rendezvous (`{{host:master}}`).

1. Monitor: `osmo workflow query "$(cat "$WORKDIR/stage3_id")"`; watch the logs for, in order:
   - first minutes: image pull + the entry script's apt/pip install (long, and normal)
   - torchrun startup on every task (`--nnodes=$NODES`), then loss lines every 10 steps
   - every 30 min: `Checkpointing data from … to s3://…/checkpoints/<stage3_id>/` (OSMO's
     checkpointing signature; the master only)

**What COMPLETED looks like:** every task COMPLETED (the group ends when `master`
exits; workers exit with it);
`s3://$BUCKET/oso-data/groot-finetune/<stage3_id>/` holds the last checkpoint
(`checkpoint-2000/` with the smoke defaults) and `s3://$BUCKET/oso-data/checkpoints/<stage3_id>/`
holds the periodic uploads. VRAM is ~25 GB/GPU with this recipe (projector + diffusion
head tuned, LLM backbone frozen); if a task ever OOMs, see the decision table.

3. **Done = all stage workflows COMPLETED + artifacts present.** Report to the user:
   the four workflow IDs (from `$WORKDIR/stage1_id`, `stage2a_id`, `stage2b_id`,
   `stage3_id`), the bucket prefixes they wrote, the checkpoint path
   (`s3://$BUCKET/oso-data/groot-finetune/<stage3_id>/checkpoint-<last>/`), and the bucket
   cost note below.

## Phase 6 — Monitor, fail-safes, cleanup

**Polling cadence per stage** (stage durations in the table above; poll
just often enough to catch a failure within a reasonable window — OSMO tasks do not
degrade silently, and the counted-transfer asserts fail loud and fast):

| Stage | Expected duration | Poll interval | First check |
|---|---|---|---|
| 1 — prepare | ~5–10 min | 2 min | at +2 min (uv/torch install lines) |
| 2a — augment | ~1.5 h | 15 min | at +5 min (all tasks RUNNING) |
| 2b — merge | ~5 min | 2 min | at +2 min |
| 3 — finetune | ~2 h | 15 min | at +10 min (config banner) |

**Status subagent (cheap, smol).** Long stages (2a, 3) should be watched by a *read-only
status subagent*, not by the main agent blocking in a sleep loop. Spawn one per
long-running workflow, at the cadence above, using the verbatim template in
[assets/status-subagent.md](assets/status-subagent.md) (verified shape; fill its `<ID>`/`<N>` slots and paste, do not paraphrase —
its text carries the rules: read-only, sleep-in-subagent, env prefix, one report
then exit).
While a stage is young (its first 1–2 cycles) the main agent checks once inline to catch
instant failures (undefined-variable 400s, missing-credential submits) before handing to
the subagent.

Monitor loop (CLI):

```bash
WORKFLOW_ID="<from submit_stage.sh output>"
osmo workflow query "$WORKFLOW_ID"             # workflow + task statuses
osmo workflow logs "$WORKFLOW_ID"              # lead-task log tail
osmo workflow logs "$WORKFLOW_ID" -t aug-0     # per-task logs (aug-i)
osmo workflow logs "$WORKFLOW_ID" --error      # error log of a FAILED task
osmo workflow list --status FAILED             # find failed runs
```

Runtime failures — the full symptom→cause→action decision table (registry-auth
rejection at submit, install-side rows owned by the deploy skill, per-stage OOM and
gate failures) lives in [references/troubleshooting.md](references/troubleshooting.md);
read it at the first failure, do not guess. Two rows matter mid-loop:

- `submit_stage.sh` exits 1 — one of its four failure modes (its message says which):
  modes 1–2 → nothing submitted (report, fix, retry once); modes 3–4 → the workflow IS
  state (check `osmo workflow list`, do NOT resubmit — mode 4 already canceled it and
  removed the idfile).
- Stage 3 stuck PENDING — `h100` pool busy: `osmo workflow list --status RUNNING`;
  queue_timeout 4h then reschedules; or ask the user whether to wait.

Restart a transiently failed workflow with `osmo workflow restart <id>` — pinned images
and uv caches make a re-run cheaper than the first. Two restarts failing is a report, not
a third restart.


**Cleanup / teardown.** Everything this skill writes lives under
`s3://$BUCKET/oso-data/` (`dataset/`, `augmented/`, `training/`, `checkpoints/`,
`groot-finetune/`) — roughly 6–10 GB for the smoke run. It stays after the run: the
deploy skill's teardown never deletes bucket objects without a separate explicit yes.
For the prefixes the user wants gone: the Crusoe console, or
`osmo data delete s3://$BUCKET/oso-data/<prefix>/` (ask first — it is a delete). The
cluster keeps every workflow record; the UI's workflow list stays as history unless the
user cancels/deletes entries themselves. Also offer to **revoke the workload storage
key** (`crusoe storage tokens delete <access_key_id>` — by its access key ID, not the
key_uuid) if a dedicated one was created for this run: the credentials registered in
OSMO and the key mounted into task containers outlive the run (see 1f2's safety note).

## Design notes (why it looks like this)

Variant choice, task topology, platform lines, the full pin inventory and the
timestamp math live in [references/design-notes.md](references/design-notes.md) —
read it before changing any workflow YAML. One rule worth stating here: **the pins
are the contract** (Isaac-GR00T `796ca8d8`, cosmos-predict2 `661da47`, lerobot
converter `c75455a6`, stage-1 checkout `d2b7e75b`); do not float them.

## Testing notes

**Tested end-to-end** — all four stage workflows reached `COMPLETED` on a real
cluster and the final checkpoint landed in the bucket. The first iterations of each
stage failed; every failure was fixed in the YAMLs this skill now ships. The nine
failure lessons are recorded in full in
[references/tested-status.md](references/tested-status.md) — **read it before editing
any workflow YAML or debugging a gate/assert failure.** The two rules that matter most
on every run:

1. **Never trust the upload/download sidecar** — it silently truncates large trees;
   every stage self-manages its S3 transfer with boto3 and asserts a counted minimum.
2. **A COMPLETED run is not proof of correct data** — assert the contract (row counts
   == video frames; the merge's decimation exists because a 3×-slowed track once
   trained to completion anyway).
 On a new run: record what happened in that reference, and fix the YAMLs
rather than improvising flags mid-run.

**Guard scripts** — run all three after ANY workflow-YAML edit, before a run:
`python3 "$SKILL_DIR"/scripts/check_workflow_python.py` (AST smoke over the
python heredocs), `python3 "$SKILL_DIR"/scripts/check_workflow_sh_quoting.py`
(fails on any `{{ var }}` in bash outside double quotes — the renderer
substitutes verbatim, so an unquoted site is command injection), and
`bash -n` on [scripts/submit_stage.sh](scripts/submit_stage.sh).

# Testing notes — failure lessons

Part of the run-osmo-workload skill. Read SKILL.md first. This file is the
full record behind the digest in SKILL.md — read it before editing any
workflow YAML or debugging a gate/assert failure, not on a clean run.

**Tested end-to-end** — all four stage workflows reached `COMPLETED` on a real
cluster (stage 1's 246 objects confirmed via
`list_object_versions`) and the final checkpoint
(`s3://<bucket>/<prefix>/checkpoints/<workflow_id>/output/…model*.safetensors`) landed.

**Counting caveat:** on freshly written versioned prefixes, bare
`list_objects_v2` can undercount badly — a stage-1 gate read 88 of 246 present objects;
`list_object_versions` listed all 246 (one version each, zero delete markers) and spot
`head_object` confirmed the "missing" files. A bare-v2 undercount on a just-written
prefix is NOT evidence of truncation: verify with `list_object_versions` or `head_object`
spot-checks before declaring a gate failed. The self-uploaded trees live under the
`-data` sibling prefixes (outside the outputs URL) as a clobber guard against the
output sidecar's sync.

The first iterations of each stage failed; every failure below was fixed in the YAMLs
that this skill now ships, so the shipped versions carry all of these:

1. **OSMO's upload/download sidecar silently truncates large trees, both directions**
   (stage 1's 286-object upload → 87 objects landed; stage 2b's upload and stage 3's
   input download the same). The sidecar's completion line ("Data has been uploaded")
   says nothing about completeness. Every stage therefore self-manages its S3 transfer
   with boto3 (the `s3-keys` storage credential mounted via the task's `credentials`
   field) and **asserts a counted minimum** before declaring success:
   stage 1 counts ≥ 240 upload objects, stage 2b ≥ 270, stage 3 ≥ 270 downloads.
   Never trust the sidecar for anything with more than a handful of files.
2. **S3 listing cache on the object store goes stale per leaf prefix** (a `PUT` to
   prefix X refreshes only X's listing; sibling leaves stay stale for minutes). Any
   multi-prefix tree walk needs a leaf-wise heal: list each leaf, if short of its
   expected count PUT a `.refresh-*` marker INTO that leaf and re-list (up to 4×).
   Stage 2b's merge downloader and stage 3's self-download both do this.
3. **Object-store objects are versioned and heal markers can clobber data keys** — one
   observed incident: a probe PUT wrote 5 bytes over a real episode video (recovered from
   the object's version). Rule: never `PUT` to a data key, only to throwaway
   `.refresh-*`/probe keys inside the same leaf prefix; and verify sizes of
   downloaded videos if anything other than boto3 ever wrote to the prefix.
4. **`{{input:N}}` only renders when the task still HAS an `inputs:` block** — after
   switching a task to self-download, any remaining `{{input:0}}` in the entry script
   is passed through **literally** (the failure signature is `FileNotFoundError:
   Dataset path {{input:0}}/dataset/...`). Stage 3's `--dataset-path` now points at the
   self-downloaded tree.
5. **GR00T N1.5's `_get_metadata` indexes EVERY stats.json entry of the state/action
   keys with the modality's index range** (`stat[arange(start,end)]`), so any stat
   shorter than the feature length — notably LeRobot's `count` (a `[1]` list or
   scalar) — crashes with `IndexError`. Stage 2b rewrites `meta/stats.json`
   post-merge to keep only stats whose list length matches the feature shape
   (which **empties the image modalities' stats** — their stats are `[channels]`-long,
   not `[pixels]`-long; the loader then falls back to recomputing statistics from the
   parquet itself — seconds of work per rank, no failure).
6. **The `so100_dualcam` data config asserts the DECODED video resolution == 640×480**
   (the recordings were 768×432). Stage 2b transcodes every original video to 640×480
   and resamples the augmented clips (front AND wrist) through the same 640×480/10fps
   pass; a verbatim copy of a 768×432 Cosmos clip fails.
7. **The N1.5 finetune script hard-codes `ddp_find_unused_parameters=False`** — with
   `--tune-visual` under multi-GPU DDP the frozen-path params trigger
   `DDP: wasn't able to locate the output tensors` at step 1. Stage 3 pins
   `--no-tune-visual` (projector + diffusion tuned; the VLM tower frozen — NVIDIA's
   standard finetune recipe) which trains cleanly.
8. **The upload worker cannot read mode-600 root-owned files** (`[Errno 13]`
   Permission denied on HF-written safetensors) and OSMO's checkpoint
   `regex` must be widened to `.*\.(pt|ckpt|safetensors|json)$` — the default
   `pt|ckpt` matched only optimizer/scheduler states, silently uploading ~34 GB of
   Adam states with NO model weights. Stage 3 runs `chmod -R a+rX $OUTPUT_DIR`
   **after** torchrun exits. Mechanism: OSMO's **periodic**
   30-minute checkpoint uploads ignore unreadable files silently (no error, but the
   excluded safetensors never reach the bucket), while the **final** upload (post-train,
   the full output tree) hard-fails with `[Errno 13]` on the mode-600 safetensors
   HF just wrote. The post-train chmod makes the final full-tree upload succeed and the
   widened regex lets the periodic uploader carry safetensors from then on.

9. **Parquet rows must be decimated to the video's frame count**: the first merge shipped ALL 30 fps rows (892) against a 297-frame video —
   a 3×-slowed state/action track that outlasted the video — and the smoke training
   still COMPLETED (the video backend clamps out-of-range reads), so nothing failed
   loudly. The merge now decimates (row `j` = source frame `3j`, real time `j/10 s`),
   renumbers `frame_index`, and asserts rows == `episodes.jsonl` length per augmented
   episode. **A COMPLETED run is not proof of correct data — assert the contract.**

Measured on a 2× H100 run (global batch 4×8×2=64, 2000 steps): ~1h50m training
(train_loss 0.058 → final loss 0.020), ~2h05m wall including image pull + model download;
`train_steps_per_second` 0.33. Scale expectations linearly with node count.

On a new run: append what actually happened here, and fix the YAMLs rather than
improvising flags mid-run.

## Security-hardening verification state

The hardening fixes carried by these workflows (template-value allowlists,
hash-verified uv install, key TTL enforcement, integrity manifest/CI) carry
this evidence:

The hardening fixes carried by these workflows carry this evidence:

- **Template-value injection** — mock-OSMO matrix, all green: 14/14 submit-side
  cases (`;`, `|`, `$(...)`, backticks, spaces, parens, braces, `&&`, redirects,
  newlines refused; benign `s3://` URLs, repo ids, numeric sets pass) and 44/44
  rendered-gate cases (4 workflows × 11 values, executed through bash after
  real-style rendering). A first gate iteration DID pass `x$(curl evil)` (the
  submit-side class allowed parens) — caught by this matrix, fixed to the strict
  per-variable class. Lesson: the matrix is the regression test; run it after
  ANY change to a gate's character class.
- **uv binary pinning** — tarball digest byte-verified against the fetched
  asset at pin time (`e14d48c1…d9f`, uv 0.13.2 x86_64-linux-gnu).
- **Key TTL / pip pins** — `KEY_EXPIRY` refusal logic and `--expires-at` help
  verified; pins resolved from the versions current at pin time.
  **The accelerate==1.15.0 pin is inferred, not observed** — it was the latest
  release at pin time. The first stage-3 run after pinning must confirm it
  trains.
- **Integrity manifest / CI** — tamper test RED (one appended line →
  HASH-MISMATCH, exit 1) / GREEN; CI jobs live-green on GitLab, including after
  the missing-git fix (stub-drift trace shows `bash git` install then a clean
  run — the pre-fix job passed with `git: command not found` in the trace,
  a silent no-op cd; the script now fails loudly instead).
- **Hermes** — claims grounded in probed local config; the confirmation-gate
  exercise results live in SECURITY.md.

**What a fresh deploy must prove (re-verify after any change to these gates):**
1. hostile `dataset_repo` via the OSMO UI (bypasses the submit helper) → task
   fails FAST with `dataset_repo failed allowlist: refused`; plus one via
   `submit_stage.sh` → refused before any OSMO call.
2. stages 1/2a: `sha256sum -c` passes in-pod before first uv use.
3. `tokens create --expires-at` accepted; `tokens list` shows the expiry;
   stage 3 completes on the accelerate pin.
4. Phase 9/b2 firewall updates land on real managed rules; own IP reaches
   both LBs; foreign source refused; rule state re-checked after the first
   `helm upgrade` (the controller may revert rules on Service changes).

## Live-verified gate behavior (recorded from a full deploy-and-run campaign)

Recorded on a fresh single-L40s/single-H100 deployment; the observations
generalize:

- **Template-injection gate (hostile values)**: OSMO's real renderer substituted
  a hostile `dataset_repo` (`evil;rm -rf /`) verbatim into the rendered bash
  (dry-run via POST /api/pool/<pool>/workflow?dry_run=True) — the injection
  surface is real. Executing the rendered entry script: `dataset_repo failed
  allowlist: refused`, exit 1, before any use of the value. Benign
  `izuluaga/finish_sandwich` passes the same rendered gate (exit 0).
- **uv binary pinning**: live pod log shows
  `curl -fsSL -o /tmp/uv.tgz ...0.13.2/...` → `sha256sum -c` → `/tmp/uv.tgz: OK`
  → extraction; no installer script executed.
- **Key TTL**: `tokens create --alias osmo-workflow-data --expires-at` accepted
  by the API; `tokens list` shows `expire_at` 30 days out. (First create
  attempt printed a spurious-looking key-cap error while ALSO creating the
  key — re-check `tokens list` before assuming a create failed; the orphaned
  key's secret is unrecoverable, delete and recreate.)
- **Firewall + Keycloak default**: anonymous `GET /` → 302 to
  `https://<KC_IP>/realms/osmo/...`; anonymous API → 401. Gateway rule
  (sources=<operator IP>/32) held across two `helm upgrade`s. **The Keycloak
  LB's rule REVERTED to 0.0.0.0/0 after the Service was re-created by the
  final-values upgrade — the controller-revert behavior is now CONFIRMED,
  not [INFERENCE]: re-check the rule after every keycloak Service change.**
- **Stage 1 (benign) end-to-end**: a full stage-1 workflow COMPLETED on the
  l40s pool; `self-upload: 246 objects` gate passed; the ~8-min
  post-artifact finalization tail observed again (status stays RUNNING with
  the entry script already done — "finalizing", not a hang).
- **Deploy-skill lessons from this run**: (1) the `versions list` "stable"
  row can carry a per-SKU variant tag (1.35.5-cmk.33-amdmi35x) whose plain
  form is unreleased — the create rejected it; fall back to the newest
  stable row WITHOUT a variant tag. (2) `provision_crusoe.sh pools` is not
  re-runnable after a partial failure (its own comment says so) — the
  hardcoded control/backend creates error "already exists" before the GPU
  pools; on partial failure create the missing pools directly with the same
  CLI surface. (3) `pools: <name>:...` passed to the pools phase ALSO feeds
  the GPU loop — the control/backend pools were re-created with the loop's
  ephemeral flag and errored; do not export POOLS for the control/backend
  invocation. (4) The `lb_ip` file must hold the bare IP (a labeled line
  breaks the Certificate apply with "invalid IP address").

## Live-verified workload behavior (full chain under Hermes supervision)

Full deploy + workload chain run under Hermes, Keycloak on. Deploy-side
findings are in SECURITY.md. Results:

- **securityContext schema probe (the gated item, ANSWERED)**: task-level
  `securityContext: {runAsNonRoot: true, runAsUser: 1000}` → `osmo workflow
  validate` rejects with HTTP 400 `extra_forbidden`. **`osmo workflow submit
  --dry-run` renders the same block UNVALIDATED** — a clean dry-run render is
  NOT schema acceptance; probe with `validate`. Non-root entry-script rework
  stays gated off. SECURITY.md residual register updated.
- **Stage 1** stage 1 COMPLETED (80 episodes, 2 cameras;
  self-upload 246 objects, gate passed). **Platform listing anomaly
  (observed, >1h, stable)**: `list_objects_v2` returns 87/246 for the
  dataset-data prefix (1 of 80 parquets visible) while
  `list_object_versions` shows all 246 current with zero delete markers and
  HEAD/GET succeed on "missing" keys — data intact, listing surface stale.
  Worth a platform report. The task-side (in-pod) reads that matter for
  stages 1–2a were unaffected.
- **Stage 2a** stage 2a COMPLETED (91 min, 2 aug tasks).
  Frame-count spot check PASS (ep0 330/330, ep2 308/308, ep4 297). 10 mp4 +
  5 frames.txt + 1 .skipped on `augmented/<id>/`; that prefix lists correctly.
- **NGC registry gate (live confirmation of the troubleshooting row)**:
  `cosmos-predict2-container:1.2` is auth-gated (401 anonymous); an NGC key
  via a REGISTRY credential fixes both the submit-side validation and the
  runtime pull. nvcr.io uses a bearer-token realm (`/proxy_auth`) — testing
  with basic auth directly 401s even with a valid key; broker a token or let
  containerd do it.
- **Keycloak CLI login under Hermes**: the browser device flow cannot
  complete from an operator box whose browser egress ≠ the firewall CIDR
  (device codes expired unused; Keycloak log shows zero page requests).
  Working machine path: create a realm user (Phase 10h recipe, Admin group),
  `osmo login --method password --username <user> --password-file <umask-077
  file>`. The CLI session can later fail refresh (`invalid_client`, 401) —
  re-login per poll cycle in monitor loops.
- **Stage 2b held**: the merge downloads the parquet tree via
  `list_objects_v2`, which the listing anomaly shows 87/246 — the shipped
  YAML would fail its counted assert (loudly, after 2a's hours). Options:
  submit as shipped (cheap loud failure), a versioned-listing variant
  (deviation, needs explicit user authorization), or a platform ticket.
- **STILL unobserved**: `accelerate==1.15.0` (stage 3 not run this time —
  the pin remains inferred). The four confirmation gates under Hermes: all
  four now fired and held — gates 2/3 at the subsequent agent-run teardown
  of this cluster (typed cluster name; separate yes for bucket, storage key
  and partition; deletes by ID).

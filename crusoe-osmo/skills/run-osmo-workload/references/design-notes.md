# Design notes — why the chain looks like this

Part of the run-osmo-workload skill. Read SKILL.md first. Rationale for YAML
edits and future variants — not needed on a clean run.

- **Cosmos variant.** Visual augmentation needs no depth/segmentation controls, so the
  chain uses **Cosmos-Predict2-2B-Video2World** (32.54 GB VRAM; ~127 s per 480p/10fps
  clip on an L40S). Cosmos-**Transfer2.5 needs 65.4 GB per GPU and does not fit the L40S
  48 GB**; its robot-augmentation workflow (edge/seg ControlNet-style) is the heavier
  alternative for a future H100-only variant of this skill.
- **Strided parallel tasks, not one big GPU task.** Independent tasks (no `inputs: [task:]`)
  run concurrently, and `n_tasks` × gpu:1 gang-schedule on the pool (default
  `n_tasks: 2` — 2 × 128 Gi task storage must fit the node's local disk; the pre-fix
  10-task default overflowed it). One `gpu: <whole-node>` task
  would pin the whole node for one episode at a time. Tasks beyond the augmented subset
  write a `.skipped` sentinel and exit 0, so the same YAML scales to all 80 episodes
  (`--set max_episode=80`) without edits.
- **No `platform:` lines, no `topology:` fields.** Every pool was installed with
  `default_platform: default` (skills/deploy-osmo-crusoe/references/osmo-install.md Phase 5), so the pool default applies when
  `platform` is omitted; Crusoe installs configure no topology keys. If a future install
  drops `default_platform`, submission fails with a platform error — add one
  `platform: default` line per resource spec then, and only then.
- **Pins are the contract.** `Isaac-GR00T @ 796ca8d8` (N1.5 era; torch 2.5.1,
  flash-attn 2.7.1.post4, opencv 4.8.0.74 — the OSMO cookbook's verified set),
  `cosmos-predict2 @ 661da47` (the 480p/10fps pipeline config), lerobot converter
  subproject pin `c75455a6`, and the stage-1 modality/converter checkout pin
  `d2b7e75b` (see `workflows/01_prepare_dataset.yaml`). Do not float them.
- **Timestamps carry the fps.** The merge decimates the augmented episodes' parquet rows
  to the 10 fps frame count (every 3rd source row, one row per video frame), renumbers
  `frame_index`, and writes `timestamp = frame_index / 10`; the wrist camera is resampled
  to 10 fps, so every frame index, timestamp and video frame of a new episode agrees 1:1
  (a final gate asserts rows == length). Kept state/action values are the source's own —
  real-time against the resampled video. Details and the two documented approximations:
  [merge-augmented.md](merge-augmented.md).

## Provenance

The pin inventory and per-stage rationale above are . Primary-source
citations for the dataset, VRAM fits, checkpoint variants and pins live in
[sources.md](sources.md). The original design plan (superseded
by the skill) remains recoverable with
`git log --diff-filter=D --summary -- .planning/workload-skill-plan.md`.

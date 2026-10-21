# Sources and decision log

Part of the run-osmo-workload skill. Read SKILL.md first. This file preserves the
durable citations and design decisions behind the skill; the superseded planning
documents (research-brief.md, workload-skill-plan.md — 709 of the plan's 1,303 lines
embedded pre-test copies of the shipped YAMLs) were removed from the repo and remain
recoverable with:
`git log --diff-filter=D --summary -- .planning/`

## Primary sources (all verified official docs)

- **The chain itself** — NVIDIA's documented SO-101 sim-to-real strategy 3:
  https://docs.nvidia.com/learning/physical-ai/sim-to-real-so-101/latest/14-strategy3-cosmos.html
  and the OSMO cookbook's closest pipeline (nut_pouring: MimicGen → Cosmos Transfer →
  LeRobot conversion → GR00T N1.5 finetune):
  https://github.com/NVIDIA/OSMO/tree/main/cookbook/nut_pouring
- **LeRobot v3.0** — file-based shards, meta/episodes/ parquet (v2.1 used per-episode
  files + episodes.jsonl): https://huggingface.co/docs/lerobot/lerobot-dataset-v3
- **GR00T trains on LeRobot v2 + modality.json**; official v3→v2 converter at
  scripts/lerobot_conversion/convert_v3_to_v2.py and SO-100 modality.json:
  https://github.com/NVIDIA/Isaac-GR00T ("Why LeRobot v2?" note; N1.7-era lerobot
  dropped the N1.5 flows — pin lerobot==0.5.1 for N1.5):
  https://huggingface.co/docs/lerobot/groot
- **GR00T N1.5 finetune** — HF tutorial:
  https://huggingface.co/blog/nvidia/gr00t-n1-5-so101-tuning; finetune script
  defaults batch_size 32/GPU, max_steps 10000, save_steps 1000, ~25 GB VRAM;
  --no-tune_diffusion_model reduces VRAM further.
- **Cosmos-Predict2-2B-Video2World** — 32.54 GB VRAM, ~127 s per 480p clip on L40S
  (performance table):
  https://github.com/nvidia-cosmos/cosmos-predict2/blob/main/documentations/performance.md;
  checkpoints gated 'auto' on HF (NVIDIA Open Model License; HF_TOKEN required).
  Cosmos-**Transfer2.5** robot augmentation:
  https://github.com/nvidia-cosmos/cosmos-transfer1/tree/main/cosmos_transfer1/auxiliary/robot_augmentation
  — 65.4 GB/GPU, does NOT fit L40S 48 GB.
- **OSMO workflow specification** (release/6.3): serial data flow via
  `inputs: [task: X]` → `{{input:0}}`; outputs `- url: s3://…{{output}}`; `files:`
  inline contents OK via UI (localpath needs CLI); resources cpu/gpu/memory/storage in
  `Gi`/`Mi` only; tasks and groups mutually exclusive; groups need exactly one
  `lead: true`; `checkpoint: {path,url,frequency,regex}`; single-unit `timeout:`;
  exitActions COMPLETE/RESCHEDULE/RESTART; data creds auto-apply at submit; independent
  tasks run concurrently:
  https://nvidia.github.io/OSMO/release/6.3/user_guide/workflows/specification/index.html

## Decision log (why this exact chain)

| Decision | Value | Rationale |
|---|---|---|
| Base VLA model | GR00T N1.5-3B (not N1.7) | N1.7 dropped N1.5-era flows; N1.5 is the cookbook-verified path |
| Dataset | `izuluaga/finish_sandwich` | GR00T's own SO-100 example dataset: v3, 80 eps, 2 cams, h264, 1.2 GB, apache-2.0. Alternates: `lerobot/libero` (AV1, no N1.5-era modality preset), `youliangtan/so101-table-cleanup` (v2.1, conversion-optional fallback) |
| Success bar | all stage workflows reach `COMPLETED`, artifacts in the OSMO bucket | per-stage verify gates in SKILL.md |
| Cosmos variant | Predict2-2B-Video2World on L40S (not Transfer2.5) | Transfer2.5 needs 65.4 GB/GPU > L40S 48 GB; visual-only augmentation needs no depth/seg controls |
| Augmentation scope | first 5 episodes × 2 variants, front camera (defaults) | ~21 min GPU time proves the chain; cheap to extend via `--set max_episode` |
| Stage-1 placement | l40s pool, `gpu: 1` | CPU-mostly work; `gpu: 0` not relied on (OSMO resource plumbing assumes a GPU on GPU pools) |
| Submission path | CLI-first, UI fallback | three chained submissions + monitoring; UI supports inline `files` so the same YAMLs work |
| `{{input:0}}` vs dataset dirs | each stage re-derives paths at runtime | scripts `find` their files instead of assuming one layout |

# run-osmo-workload — a chained Physical-AI workload on the OSMO cluster

An agent-agnostic skill (SKILL.md format): it drives one end-to-end GPU workload through a cluster the [deploy-osmo-crusoe](../deploy-osmo-crusoe/README.md) skill built — prepare a public LeRobot robotics dataset, visually augment it with NVIDIA Cosmos, merge the augmented episodes back in, then fine-tune Isaac GR00T — as OSMO workflows with per-stage verify gates and checkpoints on the bucket.

> **Know before you run.** The full security model (confirmation gates,
> credential scoping, residual risks) is the repo's [SECURITY.md](../../SECURITY.md). The stages run **unpinned third-party code** (PyPI, GitHub, HuggingFace) as root in their pods, and the storage key mounted into them is **organization-scoped** (it reaches every bucket in your org). Your HuggingFace token is required and is handled with a payload-file flow that keeps it out of chat and argv — but you are choosing to run these images.

## Architecture

```text
                    Object Storage bucket (s3://<bucket>/oso-data/)
       ┌──────────────┬──────────────┬──────────────┬──────────────┐
       │  dataset/    │ augmented/   │  training/   │ checkpoints/ │
       └──────┬───────┴──────┬───────┴──────┬───────┴──────┬───────┘
              ▲ stage 1      ▲ stage 2a     ▲ stage 2b    ▲ stage 3
              │ upload       │ upload       │ upload      │ upload
       ┌──────┴──────┐ ┌─────┴───────┐ ┌────┴────────┐ ┌──┴──────────┐
       │ prepare     │ │ augment ×N  │ │ merge      │ │ fine-tune  │
       │ (l40s pool) │ │ (l40s pool) │ │ (l40s pool)│ │ (GPU pool) │
       └─────────────┘ └─────────────┘ └────────────┘ └────────────┘
        LeRobot v3→v2.1  Cosmos-Predict2   rows/videos   GR00T N1.5
        + modality +      video2world      merged into   multi-node
        h264 transcode    variants         one dataset   torchrun
```

Stages share data only through the bucket prefixes — never task-to-task — and each stage's YAML carries hard gates (counted-transfer asserts, parquet-rows == video-frames, ffprobe frame counts) so a `COMPLETED` badge alone is never accepted as proof of correct data. A `COMPLETED` run that passes the gates produces a finetuned checkpoint on the bucket.

## What the skill does

| Stage | Workflow | Pool | What happens | Wall clock |
|---|---|---|---|---|
| 1 — prepare | [01_prepare_dataset.yaml](workflows/01_prepare_dataset.yaml) | data-prep pool | Download the public LeRobot **v3** dataset `izuluaga/finish_sandwich` (SO-101 arm, 80 episodes, 2 cameras), convert v3 → v2.1 with NVIDIA's official converter, attach the GR00T SO-100 modality, transcode AV1 → h264, upload | ~5–10 min |
| 2a — augment | [02_cosmos_augment.yaml](workflows/02_cosmos_augment.yaml) | data-prep pool | **Cosmos-Predict2-2B-Video2World** generates video variants of a subset of episodes (default first 5 episodes × 2 variants; `n_tasks` parallel tasks, default 2) | ~1.5 h |
| 2b — merge | [04_merge_augmented.yaml](workflows/04_merge_augmented.yaml) | data-prep pool | Merge the augmented clips into the converted dataset as new episodes (rows decimated to the 10 fps video frames, both cameras resampled to 640×480) | ~5 min |
| 3 — fine-tune | [03_groot_finetune.yaml](workflows/03_groot_finetune.yaml) | training pool | Fine-tune **Isaac GR00T N1.5-3B** on the merged dataset, one task per training node, torchrun across the pool, OSMO checkpointing | ~2 h (2,000-step smoke) |

The default pools (`l40s` for data prep — the Cosmos 2B model fits its 48 GB; `h100` for the fine-tune) are what the shipped YAMLs target; any pool with equivalent memory works, and stages 1–2 can fall back to the training pool (serialized) if the data-prep pool is absent.

**Success bar:** all four workflows reach `COMPLETED` with the merged dataset and the final checkpoint on the bucket, and every stage gate passed.

## What you need

- A cluster the deploy skill built (its work directory `$HOME/.osmo-install/<cluster>/` with the load balancer IP and the combined CA bundle), and the `osmo` CLI (the deploy skill offers to install it; this skill logs in right before it submits — device flow).
- A **HuggingFace token** with the NVIDIA Open Model License accepted on `nvidia/Cosmos-Predict2-2B-Video2World`, `nvidia/GR00T-N1.5-3B` and `meta-llama/Llama-Guard-3-8B` (you accept the licenses in the browser; the token never enters the chat).
- The OSMO credentials this skill registers from your storage key (submit validation and the task-side S3 mounts).

## After the workload

To confirm the run yourself: `osmo workflow list` shows the four workflows `COMPLETED`; `osmo data list` shows objects under `oso-data/training/<merge-id>/dataset/` and `oso-data/checkpoints/<finetune-id>/output/`; the fine-tune task log ends with the final loss line and "Data has been uploaded". The model checkpoint (`model*.safetensors` + optimizer/scheduler states) is on the bucket — see [the evals](evals/README.md) for the full observable contract.

The full decision table (submit-time, runtime and install-side failures) is [references/troubleshooting.md](references/troubleshooting.md); the design rationale (variant choice, task topology, the pin contract, timestamp math) is [references/design-notes.md](references/design-notes.md); the failure modes are [references/tested-status.md](references/tested-status.md).

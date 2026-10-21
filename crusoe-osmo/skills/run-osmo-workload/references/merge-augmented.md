# Stage 2b — merging Cosmos-augmented episodes into the training dataset

Companion to `workflows/04_merge_augmented.yaml` (the submit-ready YAML ships as that
file; this document explains what the merge does and why). Read [SKILL.md](../SKILL.md) first.

## What the merge does

For every augmented clip `ep_<E>_aug_<K>.mp4` that stage 2a produced (episode `E`,
variant `K`), the merge appends **one new episode** to the converted (v2.1) dataset:

- **Front camera** = the generated Cosmos clip, resampled with the same ffmpeg pass
  the original videos get (`scale=640:480,fps=10`, h264 yuv420p — 640x480 is the
  resolution the N1.5 `so100_dualcam` config asserts; the raw recordings are 768x432,
  and a verbatim 768x432 copy of a clip fails for exactly this reason).
- **Wrist camera** = the source episode's wrist clip through the same
  `scale=640:480,fps=10` resample — the merge does this itself, so both cameras
  of the new episode share one resolution and fps.
- **Parquet rows** = the source episode's rows **decimated to the 10 fps frame count**
  (every 3rd row of the 30 fps source, capped to the video's frame count), with three
  columns rewritten:
  - `episode_index` → the new episode index (`total_episodes` at merge time, incrementing)
  - `frame_index` → renumbered `0..length-1` (one row per resampled video frame)
  - `timestamp` → `frame_index / 10.0` (the 10 fps reality of the new episode's videos)

  Kept row `j` is the source row at frame index `3j`, so the state/action track stays
  in real time against the 10 fps video (the failure that motivated this gate:
  tested-status.md rule 9).
- **Metadata**: `meta/episodes.jsonl` and `meta/episodes_stats.jsonl` each gain one line
  (the source episode's line with the new index; `length` = the resampled frame count,
  which stage 2a recorded in `ep_<E>_frames.txt`); `meta/info.json` gets
  `total_episodes`/`total_videos`/`total_chunks` updated. Global `meta/stats.json` is left
  untouched.

Visual augmentation only changes pixels: the carried-over state/action values are the
source's own (a 3×-time-sampled subset — every kept value is a source value), and the
language annotations are carried over unchanged, so the merged dataset is a superset of
the original.

## Why augmentation rewrites timestamps (the 30→10 fps story)

Cosmos-Predict2's 480p/10fps pipeline generates videos at 10 fps. A 30 fps source episode
is resampled to 10 fps before conditioning (~1/3 the frames; a ~33 s episode → ~330
frames). The generated clip therefore has the **resampled** frame count, and the new
episode must be a 10 fps episode end to end: video at 10 fps, `length` = resampled count,
and the parquet decimated to one row per resampled frame (row `j` = source frame `3j`,
`frame_index` renumbered, `timestamp` = `j/10`) — the state/action values are the
source's own, sampled in real time; only the row density and time axis change.

The merge asserts the source episode's first `timestamp` is ~0 (`< 1e-6`) before
rewriting; `finish_sandwich` episodes start at 0. If a future dataset does not, the merge
fails loudly instead of producing a silently misaligned episode.

## The v2.1 file layout the merge writes

Produced by NVIDIA's `convert_v3_to_v2.py` (verified against its
`LEGACY_DATA_PATH_TEMPLATE` / `LEGACY_VIDEO_PATH_TEMPLATE` and `convert_episodes_metadata`):

```
<dataset>/                              # v2.1
├── meta/
│   ├── info.json                       # codebase_version v2.1, path templates,
│   │                                   #   total_episodes, total_chunks, total_videos, chunks_size
│   ├── episodes.jsonl                  # one line per episode: {episode_index, length, tasks, ...}
│   ├── episodes_stats.jsonl            # one line per episode: {episode_index, stats}
│   ├── tasks.jsonl                     # {task_index, task}
│   ├── stats.json                      # global stats
│   └── modality.json                   # attached in stage 1 (so100_dualcam)
├── data/chunk-000/episode_000000.parquet …   (per-episode parquet; chunks_size 1000)
└── videos/chunk-000/observation.images.front/episode_000000.mp4 …   (per-episode, per-camera)
```

New episode `N` goes into `chunk-{N // 1000}` directories (created on demand — with the
default 80+10 episodes everything stays in `chunk-000`).

## Why the merge is a separate workflow

Three reasons:

1. **Input plumbing.** It needs two inputs (the stage-1 dataset prefix and the stage-2a
   clips prefix) with the run IDs of both upstream workflows. Making it its own
   submission keeps the chain a simple sequence of three independently verified gates.
2. **Pool economics.** The merge is CPU work (parquet rewrites, two video resamples per
   clip) — a few minutes of a `gpu: 1` L40s task, not an H100 job.
3. **Re-runnability.** If the merge has a bug (metadata shape drift, name change), only
   the merge re-runs; the augmentation stage (~1.5 h at the shipped n_tasks: 2 default) is untouched.

## Two documented approximations

1. **Per-episode pixel stats for augmented episodes are copied from the source episode,
   not recomputed.** GR00T's loader validates the global `meta/stats.json` and reads
   per-episode *state/action* stats from `episodes_stats` — both unchanged by visual
   augmentation — so the stale pixel stats should be unused. If the loader errors on
   stale video stats, the fallback is recomputing `episodes_stats` rows for the new
   indices with lerobot's stats utilities (one more merge step).
2. **`info.json` video fps stays 30** (the source fps): v2.1 `info.json` fps describes
   the source camera rate; GR00T's decord backend fetches frames by the parquet's
   `timestamp` column, not `info.json` fps. The merged run logs the 10 fps reality.

Both are flagged in the workflow's log output; neither should be "fixed" silently.

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| Assertion `no augmented clips downloaded` | `stage2a_id` wrong, or stage-2a output prefix mismatch | Re-check `stage2a_id` and the bucket prefix (UI bucket browser or `osmo data list`); resubmit with corrected `--set` |
| Assertion `missing ep_<E>_frames.txt` | that episode's augment task never wrote its frame-count file (it was skipped or failed) | Check stage-2a logs for that episode's task; re-run stage 2a if needed, then the merge |
| Assertion `episode does not start at 0 (t0=…)` | the source dataset's timestamps are not episode-relative | Do not hand-edit: the merge's timestamp rewrite is wrong for that dataset; report it |
| Final sanity gate `n_pq != total_episodes` | converter layout drift (upstream changed the converter) | Pin the converter commit that matches the observed layout; never hand-edit metadata |
| Task OOM on `copytree` | dataset larger than expected (a different `dataset_repo`) | Raise `memory`/`storage` with `--set` — they are fixed in the YAML otherwise |

The merge writes `s3://<bucket>/oso-data/training/<workflow_id>/dataset/`; the input
prefixes stay (cleanup is ../SKILL.md's Phase 6 note).

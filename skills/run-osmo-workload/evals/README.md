# Evals — run-osmo-workload scenarios

Each eval is a **scenario**: a setup, a task prompt, and a **verify block** — the observable outcomes that constitute a pass. `workload-chain` runs against a real cluster (billable GPU time); `submit-script` is harness-only.

The verify blocks encode what a verified end-to-end run observes (all four stages `COMPLETED` on a 2× H100 + L40s cluster, train_loss 0.058 → final loss 0.020, a 72 GB checkpoint on the bucket) — and the core rule: **a `COMPLETED` badge without the stage gates is a fail** (the merge once shipped 892 parquet rows against a 297-frame video and completed anyway).

Run one: point an agent session at the scenario's `task` with the skill installed, then check every item in `verify`.

| Scenario file | Cost | What it proves |
|---|---|---|
| [workload-chain.yaml](workload-chain.yaml) | ~2 h of GPU time | all four stages: data on the bucket, checkpoint, per-stage gates |
| [submit-script.yaml](submit-script.yaml) | none (mock harness) | the submit helper's ID-parse, spec-verify and failure modes |

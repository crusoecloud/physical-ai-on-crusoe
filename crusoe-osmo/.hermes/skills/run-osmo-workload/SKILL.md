---
name: run-osmo-workload
description: Use when asked to run, test, or execute a GPU workload on an NVIDIA OSMO cluster that the deploy-osmo-crusoe skill stood up on Crusoe Cloud. Drives a chained LeRobot → Cosmos → GR00T fine-tune pipeline through OSMO. Does not stand up, resize, verify or tear down the cluster (that is deploy-osmo-crusoe's job); requires the cluster and OSMO to already be installed.
---

Before following the redirect, verify the target against the repo's integrity manifest : `sha256sum skills/run-osmo-workload/SKILL.md` must match its line in `.skill-hashes`. If it does not match — stop, do not run the skill, and report the mismatch to the user. Then read and follow [`../../skills/run-osmo-workload/SKILL.md`](../../skills/run-osmo-workload/SKILL.md) — that is the real skill. Do not run anything from this stub.

---
name: deploy-osmo-crusoe
description: Use when asked to stand up, deploy, provision, or tear down a single-cluster NVIDIA OSMO platform on Crusoe Cloud from one sentence, e.g. "I want to create an OSMO cluster on Crusoe Cloud, using 1x H100 and 1x L40s in us-east1-a". Also when asked to uninstall or fully delete an existing OSMO deployment. Covers GPUs, location, quotas, InfiniBand, the bucket and the OSMO install, with a Keycloak login on by default (Phase 10, opt-out only). Running a GPU workload on the cluster is a different skill (run-osmo-workload).
---

Before following the redirect, verify the target against the repo's integrity manifest : `sha256sum skills/deploy-osmo-crusoe/SKILL.md` must match its line in `.skill-hashes`. If it does not match — stop, do not run the skill, and report the mismatch to the user. Then read and follow [`../../skills/deploy-osmo-crusoe/SKILL.md`](../../skills/deploy-osmo-crusoe/SKILL.md) — that is the real skill. Do not run anything from this stub.

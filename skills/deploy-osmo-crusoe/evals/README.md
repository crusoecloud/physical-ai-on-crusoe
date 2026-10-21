# Evals — deploy-osmo-crusoe scenarios

Each eval is a **scenario**: a setup, a task prompt (what a user would say), and a **verify block** — the observable outcomes that constitute a pass. Scenarios run against a real agent session on a real Crusoe account (they create and delete billable infrastructure); the two script-level evals are harness-only and cost nothing to run.

The verify blocks encode what a verified end-to-end run observes (a 2× H100 cluster in `us-southcentral1-a` with the L40s pool, Keycloak enabled). A scenario passes when every observable in its verify block holds.

Run one: point an agent session at the scenario's `task` with the skill installed, then check every item in `verify`.

| Scenario file | Cost | What it proves |
|---|---|---|
| [deploy-cluster.yaml](deploy-cluster.yaml) | a cluster's lifetime, ~25 min | end-to-end deploy: checks → plan → provision → install → verify |
| [deploy-keycloak.yaml](deploy-keycloak.yaml) | second LB, ~12 min | the opt-in auth path enforces (302/401/200 by role) |
| [teardown-level2.yaml](teardown-level2.yaml) | deletes the cluster | full teardown; every resource verified absent by ID |
| [provision-script.yaml](provision-script.yaml) | none (mock harness) | the five create commands' flag contract |
| [ca-bundle-script.yaml](ca-bundle-script.yaml) | none (mock harness) | the CA build/fan-out gates |

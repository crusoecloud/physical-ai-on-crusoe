#!/usr/bin/env bash
# Provision the OSMO cluster's Crusoe resources (Phase 2 creates — billable).
#
# One home for the five create commands, so flag drift is caught here (the CLI
# versioned under this skill twice; verify flags with --help if reality moved).
# Runs the SAME gates the prose orders: pre-existence checks (create on an
# existing name errors), the IB-partition reuse-or-create rule, the no-lock
# default, and the never-delete-on-your-own rule. The cluster and bucket steps
# pre-check and skip what exists; the pools and key steps do NOT — the caller
# must check state (provision.md Phase 2) before re-running them after a
# partial failure, or the create errors on the existing resource.
#
# Usage:
#   scripts/provision_crusoe.sh <phase>   where <phase> is one of:
#     cluster     — the Kubernetes cluster (then wait STATE_RUNNING)
#     pools       — control + backend pools, then each GPU pool (IB-aware)
#     bucket      — bucket + versioning (object lock stays OFF)
#     key         — the org-scoped storage key (secret prints once: capture!)
#     creds        — get-credentials + node readiness check
#   Variables (all required by the phase that uses them; set in the caller):
#     CLUSTER_NAME LOCATION CLUSTER_VERSION SUBNET_ID SSH_PUBLIC_KEY_PATH
#     SSH_PUBLIC_KEY_PATH  POOLS (space-separated "name:type:nodes:ephemeral[:partition_id]")
#     BUCKET_NAME  IB_NETWORK_ID (for IB pools)
#
# Exit 0 on success; exit 1 with a clear message (nothing further was created).
# The caller does NOT re-run a step on failure without checking state first.

set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

[ $# -eq 1 ] || usage
PHASE="$1"

case "$PHASE" in
  cluster)
    : "${CLUSTER_NAME:?}" "${LOCATION:?}" "${CLUSTER_VERSION:?}" "${SUBNET_ID:?}"
    # Pre-existence: a create on an existing name errors; if a previous
    # attempt may have started, get — do not re-create.
    if crusoe kubernetes clusters get "$CLUSTER_NAME" --json >/dev/null 2>&1; then
      echo "cluster $CLUSTER_NAME already exists — resuming; not re-creating"
    else
      crusoe kubernetes clusters create \
        --name "$CLUSTER_NAME" --location "$LOCATION" \
        --cluster-version "$CLUSTER_VERSION" --subnet-id "$SUBNET_ID" \
        --add-ons nvidia_gpu_operator,nvidia_network_operator,crusoe_csi
    fi
    # Blocks ~8 min (may exceed a shell timeout); STATE_RUNNING per the
    # polling rule is the caller's gate (tool-routing.md#readiness-polling).
    ;;

  pools)
    : "${CLUSTER_NAME:?}" "${SSH_PUBLIC_KEY_PATH:?}"
    [ -f "$SSH_PUBLIC_KEY_PATH" ] || { echo "SSH public key not found: $SSH_PUBLIC_KEY_PATH" >&2; exit 1; }
    # Pool creates are NOT idempotent: a second run after a partial failure
    # errors with "already exists" on the first create.
    # Check which pools exist first; delete or skip accordingly.
    crusoe kubernetes nodepools create \
      --name osmo-control-pool --cluster-name "$CLUSTER_NAME" \
      --type c1a.8x --count 1 --keyfile "$SSH_PUBLIC_KEY_PATH" \
      --node-labels osmo-type=control

    crusoe kubernetes nodepools create \
      --name osmo-backend-pool --cluster-name "$CLUSTER_NAME" \
      --type c1a.4x --count 1 --keyfile "$SSH_PUBLIC_KEY_PATH" \
      --node-labels osmo-type=backend

    for spec in ${POOLS:-}; do
      IFS=: read -r name type nodes ephemeral partition <<<"$spec"
      extra=()
      # L40s: no partition, ephemeral false; IB pools: partition id required.
      [ -n "$partition" ] && extra+=(--transport-partition-id "$partition")
      [ -n "$ephemeral" ] && extra+=(--ephemeral-storage-for-containerd="$ephemeral")
      crusoe kubernetes nodepools create \
        --name "$name" --cluster-name "$CLUSTER_NAME" \
        --type "$type" --count "$nodes" --keyfile "$SSH_PUBLIC_KEY_PATH" \
        "${extra[@]+${extra[@]}}"
    done
    ;;

  bucket)
    : "${BUCKET_NAME:?}" "${LOCATION:?}"
    crusoe storage buckets create --name "$BUCKET_NAME" --location "$LOCATION"
    crusoe storage buckets enable-versioning "$BUCKET_NAME" --yes
    # Object lock stays OFF (irreversible; only when the user asked).
    ;;

  key)
    # The secret prints ONCE here — capture ACCESS_KEY_ID and ACCESS_KEY into
    # memory (they become OSMO_ACCESS_KEY_ID/OSMO_ACCESS_KEY at the install).
    # TTL : Crusoe storage keys are org-scoped (all buckets, all
    # projects); bucket-scoped keys do not exist. The compensating control is
    # a bounded lifetime: KEY_EXPIRY (RFC 3339) is REQUIRED so a leaked or
    # forgotten key dies on its own. The deploy summary must state it.
    : "${KEY_EXPIRY:?KEY_EXPIRY must be set (RFC 3339, e.g. <YYYY-MM-DD>T00:00:00Z — a bounded interval, default 30 days, after the deploy date)}"
    crusoe storage tokens create --alias osmo-workflow-data --expires-at "$KEY_EXPIRY"
    ;;

  creds)
    : "${CLUSTER_NAME:?}"
    crusoe kubernetes clusters get-credentials "$CLUSTER_NAME" --yes
    kubectl get nodes
    ;;

  *) echo "provision_crusoe.sh: unknown phase '$PHASE'" >&2; usage ;;
esac

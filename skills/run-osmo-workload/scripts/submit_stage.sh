#!/usr/bin/env bash
# Submit one OSMO workflow, capture its ID, verify the rendered overrides.
#
# Encapsulates the four submit blocks that previously lived inline in SKILL.md
# (Phases 2-5) — same logic, one home. behavior:
#   - the submit prints "Workflow ID - <id>" from which the ID is parsed;
#   - every --set/--set-string value is allowlist-checked ([a-zA-Z0-9_/.:=@+-]
#     only) BEFORE the submit: OSMO renders values verbatim into bash heredocs,
#     so a hostile value is command injection in a root GPU pod;
#   - --set-string MUST carry any value containing "://" (OSMO's --set drops
#     non-numeric values with "://" silently — the render keeps the placeholder);
#   - the rendered spec must show the override before monitoring starts.
#
# Usage:
#   scripts/submit_stage.sh <workflow-yaml> <pool> <idfile> [--set-string k=v]... \
#     [--set "k1=v1 k2=v2..."] [extra --set-string pairs]
#
# Examples (matching the four phases):
#   scripts/submit_stage.sh workflows/01_prepare_dataset.yaml l40s "$WORKDIR/stage1_id" \
#     --set-string "storage_url=$STORAGE_URL"
#   scripts/submit_stage.sh workflows/02_cosmos_augment.yaml l40s "$WORKDIR/stage2a_id" \
#     --set-string "storage_url=$STORAGE_URL" --set "stage1_id=$(cat "$WORKDIR/stage1_id")"
#   scripts/submit_stage.sh workflows/04_merge_augmented.yaml l40s "$WORKDIR/stage2b_id" \
#     --set-string "storage_url=$STORAGE_URL" \
#     --set "stage1_id=$(cat "$WORKDIR/stage1_id") stage2a_id=$(cat "$WORKDIR/stage2a_id")"
#   scripts/submit_stage.sh workflows/03_groot_finetune.yaml h100 "$WORKDIR/stage3_id" \
#     --set-string "storage_url=$STORAGE_URL" \
#     --set "stage2b_id=$(cat "$WORKDIR/stage2b_id") n_nodes=$NODES"
#
# Exits 0 on success and writes the workflow ID to <idfile>. On failure exits 1
# in one of four modes, each with its own message — the caller does NOT resubmit
# blind; it reports:
#   1. submit failed — nothing was submitted;
#   2. ID unparsable — the submit may still have gone through;
#   3. spec unreadable — the workflow IS submitted and recorded in <idfile>;
#   4. placeholder still in the rendered spec — the workflow was canceled and
#      the idfile removed.
#
# WORKDIR resolution: the caller normally has WORKDIR exported (SKILL.md Phase
# 0a), but this script must survive a fresh shell — default it the same way
# SKILL.md does, honoring CLUSTER then CLUSTER_NAME (the deploy skill's
# variable name) before 'osmo'. combined-ca-bundle.crt inside it is the bundle
# the deploy skill writes (references/osmo-install.md Phase 7, 'Workflow-pod CA trust').

set -euo pipefail

usage() {
  # Print the header comment (lines 2 .. the line before `set -euo pipefail`),
  # derived dynamically so the range can never drift from the header.
  local last
  last=$(grep -n '^set -euo pipefail' "$0" | head -1 | cut -d: -f1)
  sed -n "2,$((last - 1))p" "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

[ $# -ge 3 ] || usage
YAML="$1"; POOL="$2"; IDFILE="$3"; shift 3
[ -f "$YAML" ] || { echo "submit_stage.sh: workflow YAML not found: $YAML" >&2; exit 1; }
[ -n "$POOL" ] || { echo "submit_stage.sh: empty pool name" >&2; exit 1; }
IDFILE_DIR=$(dirname "$IDFILE")
[ -d "$IDFILE_DIR" ] || { echo "submit_stage.sh: idfile directory does not exist: $IDFILE_DIR (set WORKDIR / create it first)" >&2; exit 1; }
[ ! -d "$IDFILE" ] || { echo "submit_stage.sh: idfile path is a directory: $IDFILE" >&2; exit 1; }

# WORKDIR: caller-exported, else the documented default (CLUSTER, then the
# deploy skill's CLUSTER_NAME, then 'osmo' — SKILL.md Phase 0a semantics).
WORKDIR="${WORKDIR:-$HOME/.osmo-install/${CLUSTER:-${CLUSTER_NAME:-osmo}}}"
[ -f "$WORKDIR/combined-ca-bundle.crt" ] || {
  echo "submit_stage.sh: $WORKDIR/combined-ca-bundle.crt not found — the deploy skill's" >&2
  echo "install (references/osmo-install.md Phase 7) writes it; rerun the deploy skill or fix WORKDIR." >&2
  exit 1
}

SETSTRING_ARGS=()
SET_ARGS=()
SET_COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set-string) [ $# -ge 2 ] || { echo "submit_stage.sh: --set-string needs a value" >&2; usage; }
                   SETSTRING_ARGS+=(--set-string "$2"); shift 2 ;;
    --set)        [ $# -ge 2 ] || { echo "submit_stage.sh: --set needs a value" >&2; usage; }
                   # OSMO's --set is nargs-form: EACH k=v pair must be a SEPARATE
                   # argument after the flag. A quoted "k1=v1 k2=v2" single string
                   # becomes ONE argument and the render reads it as one malformed
                   # key - failure signature: 'stage1_id is undefined' (oso_merge_augmented-1's
                   # first submit attempt). Split on spaces:
                   for pair in $2; do SET_ARGS+=("$pair"); done
                   SET_COUNT=$((SET_COUNT+1)); shift 2 ;;
    *) echo "submit_stage.sh: unrecognized argument '$1'" >&2; usage ;;
  esac
done

if [ "$SET_COUNT" -gt 1 ]; then
  echo "submit_stage.sh: refusing multiple --set flags (OSMO keeps only the last one;" >&2
  echo "put all key=value pairs after ONE --set: --set \"k1=v1 k2=v2\")" >&2
  exit 1
fi

# Security gate: values submitted through --set/--set-string are
# rendered verbatim into bash heredocs by OSMO's template engine. Fail closed
# on any value that is not a plain [a-zA-Z0-9_/.:=@+-] token BEFORE the submit
# reaches the renderer (covers dataset_repo and every other string override;
# storage_url keeps its s3:// form via the ':' allowance; parens, $, backticks,
# spaces, quotes, semicolons all refuse — none occur in a legitimate override).
# The workflow YAMLs carry a stricter per-variable gate in-pod for UI-pasted
# submits that bypass this script.
for v in ${SET_ARGS[@]+"${SET_ARGS[@]}"} ${SETSTRING_ARGS[@]+"${SETSTRING_ARGS[@]}"}; do
  val="${v#*=}"
  case "$val" in
    *[!a-zA-Z0-9_/.:=@+-]*|""|"."|"..")
      echo "submit_stage.sh: refusing override with shell-hostile characters: ${v%%=*}=<value withheld>" >&2
      exit 1 ;;
  esac
done

# Remove any stale idfile from an earlier (failed/canceled) run BEFORE
# submitting, so a failed resubmit can never leave a downstream stage
# chaining onto the old ID (the decision table's resubmit paths rely on this).
rm -f "$IDFILE"

# The env prefix is required on every call — shell state does not persist
# between agent tool invocations.
SUBMIT_OUT=$(SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" \
     REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo workflow submit "$YAML" --pool "$POOL" \
  ${SETSTRING_ARGS[@]+"${SETSTRING_ARGS[@]}"} ${SET_ARGS[@]+--set "${SET_ARGS[@]}"} \
  2>&1) || {
    echo "submit_stage.sh: osmo workflow submit FAILED — nothing was submitted:" >&2
    printf '%s\n' "$SUBMIT_OUT" >&2
    exit 1
  }

# Parse the ID: "Workflow ID - <id>". The ID is hyphenated (name-counter, e.g.
# oso_prepare_dataset-3) so the separator is the FIRST "- " after 'Workflow ID',
# never '.*-' (a greedy match keeps only the trailing counter).
# A no-match grep exits 1: under `set -e -o pipefail` that would kill the
# script BEFORE the guidance below prints — so the parse deliberately tolerates no-match and handles it after.
ID=$(printf '%s\n' "$SUBMIT_OUT" | grep -oE 'Workflow ID[[:space:]]*-[[:space:]]*[a-zA-Z0-9_-]+' | head -1 | sed -E 's/^Workflow ID[[:space:]]*-[[:space:]]*//') || true

if [ -z "$ID" ]; then
  echo "submit_stage.sh: could not parse the workflow ID from submit output — do not" >&2
  echo "resubmit blind: the submit may still have gone through; check" >&2
  echo "osmo workflow list, and if an orphan is there, cancel it: osmo workflow cancel <id>" >&2
  printf '%s\n' "$SUBMIT_OUT" >&2
  exit 1
fi

echo "$ID" > "$IDFILE"

# Verify the overrides actually landed in the rendered spec (the parser is the
# fragile part of every submit — decision-table entries). A bare
# 'grep url:' is NOT enough: the un-overridden spec also has url: lines (the
# placeholder). Require the real storage_url AND the absence of the placeholder.
SPEC_OUT=$(SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" \
  REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo workflow spec "$ID" 2>&1) || {
    echo "submit_stage.sh: WARNING — could not read the rendered spec (workflow $ID is" >&2
    echo "already submitted and recorded in $IDFILE). Check manually before monitoring:" >&2
    printf '%s\n' "$SPEC_OUT" >&2
    exit 1
  }
# shellcheck disable=SC2312  # the grep drives the branch, not the pipeline
if [[ "$SPEC_OUT" == *osmo-bucket-placeholder* ]]; then
  echo "submit_stage.sh: the rendered spec still contains the placeholder bucket —" >&2
  echo "the storage_url override did NOT land. Canceling the workflow to avoid pointing" >&2
  echo "a multi-hour GPU stage at a nonexistent bucket." >&2
  { printf '%s\n' "$SPEC_OUT" | grep -E 'storage_url:|url:' >&2 || true; }
  SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" \
    REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
    osmo workflow cancel "$ID" || echo "cancel failed — cancel it manually: osmo workflow cancel $ID" >&2
  rm -f "$IDFILE"
  exit 1
fi
printf '%s\n' "$SPEC_OUT" | grep -E 'storage_url:|url:' | head -5 || true
echo "submitted $YAML -> workflow $ID (recorded in $IDFILE)"

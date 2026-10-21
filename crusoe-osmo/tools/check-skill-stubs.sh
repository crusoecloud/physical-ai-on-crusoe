#!/usr/bin/env bash
# Check that every harness pointer stub (.claude/skills/*/SKILL.md, .hermes/skills/*/SKILL.md)
# carries the same `name:` and `description:` frontmatter as the real skill under skills/.
# Harnesses trigger skills on the stub's description, so a description edited only in
# skills/<name>/SKILL.md would leave the harnesses matching on stale text.
#
# Usage: tools/check-skill-stubs.sh   (from anywhere in the repo; exit 1 on any drift)
set -euo pipefail
# Fail loudly if git is unavailable: the CI stub-drift job runs in python:3.12-slim
# (no git). A silent no-op cd made the job pass by luck from the repo root —
# from anywhere else it would check the wrong tree. Explicit check, explicit exit.
command -v git >/dev/null 2>&1 || { echo "check-skill-stubs.sh: git not found — install git (CI image must include it)"; exit 1; }
cd "$(git rev-parse --show-toplevel)"

field() {   # $1 = file, $2 = key; prints the frontmatter value (first --- block only)
  awk -v k="$2" 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit}
                 f && index($0, k": ")==1 {print substr($0, length(k)+3); exit}' "$1"
}

fail=0; checked=0
for stub in .claude/skills/*/SKILL.md .hermes/skills/*/SKILL.md; do
  [ -f "$stub" ] || continue
  name=$(basename "$(dirname "$stub")"); real="skills/$name/SKILL.md"
  if [ ! -f "$real" ]; then echo "DRIFT $stub: no $real"; fail=1; continue; fi
  for k in name description; do
    if [ "$(field "$stub" "$k")" != "$(field "$real" "$k")" ]; then
      echo "DRIFT $stub: '$k' differs from $real"; fail=1
    fi
  done
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || { echo "no stubs found"; exit 1; }
[ "$fail" = 0 ] && echo "OK: $checked stubs match their skills" || exit 1

#!/usr/bin/env bash
# Check that every harness pointer stub's redirect target actually resolves,
# from BOTH stub locations (.claude/skills/<name>/ and .hermes/skills/<name>/).
#
# Review finding (stub-path fragility): the stubs use relative paths
# (../../skills/<name>/SKILL.md) that assume the standard directory depth. If a
# stub is moved or a directory is renamed, the redirect breaks silently and a
# harness may fall back to its own defaults for GPU operations — no error, no
# hint. This test fails loudly instead. It deliberately keeps the relative paths
# (absolute paths would break checkout portability) and pins their behavior.
#
# Usage: tools/check-stub-paths.sh   (run from anywhere; exit 1 on any breakage)
set -euo pipefail
command -v git >/dev/null 2>&1 || { echo "check-stub-paths.sh: git not found (CI image must include it)"; exit 1; }
cd "$(git rev-parse --show-toplevel)"

fail=0; checked=0
for stub in .claude/skills/*/SKILL.md .hermes/skills/*/SKILL.md; do
  [ -f "$stub" ] || continue
  checked=$((checked + 1))
  dir=$(dirname "$stub")
  # every markdown link inside the stub must resolve from the stub's own
  # directory (relative paths resolve like a reader standing in the stub dir)
  while IFS= read -r target; do
    case "$target" in
      http*|mailto:*) continue ;;   # external links out of scope here
    esac
    path_only=${target%%#*}
    [ -n "$path_only" ] || continue
    if [ ! -e "$dir/$path_only" ]; then
      echo "BROKEN $stub: [$target] does not resolve from $dir"
      fail=1
    fi
  done < <(grep -oE '\]\(([^)#]+)' "$stub" | sed 's/^](//')
done
[ "$checked" -gt 0 ] || { echo "no stubs found"; exit 1; }
if [ "$fail" = 0 ]; then
  echo "OK: $checked stubs' redirect paths all resolve"
else
  exit 1
fi

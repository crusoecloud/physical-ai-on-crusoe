#!/usr/bin/env python3
"""Generate or verify .skill-hashes — the integrity manifest for skill entry files.

Both Claude Code and Hermes discover these skills through stub files that
redirect to the same canonical SKILL.md — without a check, a poisoned SKILL.md
(malicious PR or repo compromise) would propagate instructions to both
harnesses at once. This manifest pins the SHA256 of every file a harness can
be redirected into from a stub.

Usage:
    python3 tools/skill_hashes.py            # verify (exit 1 on any mismatch)
    python3 tools/skill_hashes.py --write   # regenerate .skill-hashes

CI (see .gitlab-ci.yml) runs the verify mode on every push and rejects a PR
whose SKILL.md/references change without a matching manifest update, which
must land in the same commit as the content change.
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / ".skill-hashes"
# Everything a stub redirects to, plus the stubs themselves (a stub is the
# first instruction a harness reads; tampering with it is equally lethal).
PATHS = sorted(
    list(ROOT.glob("skills/*/SKILL.md"))
    + list(ROOT.glob("skills/*/references/*.md"))
    + list(ROOT.glob("skills/*/scripts/*"))
    + list(ROOT.glob("skills/*/workflows/*"))
    + list(ROOT.glob("skills/*/assets/*"))
    + list(ROOT.glob(".claude/skills/*/SKILL.md"))
    + list(ROOT.glob(".hermes/skills/*/SKILL.md"))
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    write = "--write" in sys.argv[1:]
    lines = [f"{sha256(p)}  {p.relative_to(ROOT).as_posix()}" for p in PATHS if p.is_file()]
    if write:
        MANIFEST.write_text("\n".join(lines) + "\n")
        print(f".skill-hashes: wrote {len(lines)} entries")
        return 0
    if not MANIFEST.is_file():
        print(".skill-hashes missing — run: python3 tools/skill_hashes.py --write")
        return 1
    expected = dict(
        reversed(line.split("  ", 1)) for line in MANIFEST.read_text().splitlines() if line.strip()
    )
    bad = 0
    for p in PATHS:
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        want = expected.get(rel)
        got = sha256(p)
        if want is None:
            print(f"MISSING-HASH {rel} — regenerate: python3 tools/skill_hashes.py --write")
            bad += 1
        elif want != got:
            print(f"HASH-MISMATCH {rel}\n  manifest: {want}\n  actual:   {got}")
            print("  If this change is intentional, regenerate and commit the manifest with it.")
            bad += 1
    stale = set(expected) - {p.relative_to(ROOT).as_posix() for p in PATHS if p.is_file()}
    for rel in sorted(stale):
        print(f"STALE-HASH {rel} — file gone; regenerate the manifest")
        bad += 1
    print(f".skill-hashes: {'OK (' + str(len(lines)) + ' files)' if not bad else f'{bad} problem(s)'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

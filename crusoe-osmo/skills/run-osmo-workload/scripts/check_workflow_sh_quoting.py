#!/usr/bin/env python3
"""Static quoting check over the bash entry scripts inside every workflow YAML.

The OSMO renderer substitutes {{ var }} values verbatim into the `files.contents`
bash heredocs before the task starts. In bash, an unquoted substitution undergoes
word splitting (and, if a value contains shell metacharacters, command
execution). Rule: every {{ var }} that lands in executable bash must sit
inside double quotes.

Safe forms (skipped):
  - "{{ var }}"                — quoted (the required form for string vars)
  - {{ n_tasks }} etc.         — counters the renderer casts to digits
    (NUMERIC_OK below; the --set/--set-string gate in submit_stage.sh plus the
    in-pod `case` allowlist in every entry script bounds them anyway)
  - {% ... %}                  — jinja control tags, never a value
  - {{workflow_id}}, {{output}}, {{input:N}}, {{host:master}}
                               — OSMO system placeholders, renderer-owned
  - bash comment lines         — no execution semantics (the in-pod `case` gate
                                 still bounds the rendered value)
  - python heredoc bodies      — python string literals, not bash rules

Run it after every workflow-YAML edit (same battery as check_workflow_python.py):

    python3 scripts/check_workflow_sh_quoting.py

Exit 0 when every shell-context {{ var }} is safely quoted; exit 1 otherwise.
"""
import re
import pathlib
import sys

NUMERIC_OK = {
    "n_tasks", "n_aug", "max_episode", "t", "item", "n_nodes",
    "batch_size", "max_steps", "save_steps",
}
SYSTEM_OK = {"workflow_id", "output", "host:master"}
INPUT_OK = re.compile(r"input:\d+")
TOK = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_:.]*)\s*\}\}")
CONTENTS = re.compile(r"^(\s*)-\s*contents: \|\s*$")


def contents_blocks(text):
    """Yield the bash bodies of every `contents: |` block in the workflow YAML.

    A block starts at the `contents: |` line and runs while lines are indented
    deeper than that key. Blank lines keep the block open.
    """
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = CONTENTS.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        i += 1
        block = []
        while i < len(lines):
            line = lines[i]
            if line.strip() and (len(line) - len(line.lstrip())) <= indent:
                break
            block.append((i + 1, line))
            i += 1
        yield block


def check(text, label):
    bad = 0
    for block in contents_blocks(text):
        in_py = False
        for lineno, line in block:
            stripped = line.strip()
            if in_py:
                if stripped == "PY":
                    in_py = False
                continue
            if stripped.startswith("python") and "<<'PY'" in stripped:
                in_py = True
                continue
            if stripped.startswith("#"):
                continue
            for m in TOK.finditer(line):
                var = m.group(1)
                if var in NUMERIC_OK or var in SYSTEM_OK or INPUT_OK.fullmatch(var):
                    continue
                if line[: m.start()].count('"') % 2 == 1:
                    continue  # inside double quotes
                print(f"{label}:{lineno}: UNQUOTED {{{{ {var} }}}} in bash: {stripped[:90]}")
                bad += 1
    print(f"{label}: {'clean' if not bad else f'{bad} unquoted bash substitution(s)'}")
    return bad


if __name__ == "__main__":
    workflows = sorted(pathlib.Path(__file__).resolve().parent.parent.glob("workflows/*.yaml"))
    total = sum(check(p.read_text(), p.name) for p in workflows)
    sys.exit(1 if total else 0)

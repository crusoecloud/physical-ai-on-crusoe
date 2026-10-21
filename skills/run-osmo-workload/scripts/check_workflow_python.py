#!/usr/bin/env python3
"""Static smoke over the python heredocs inside every workflow YAML.

Catches syntax errors and load-time undefined names in the inline python blocks
without executing workflows - added after a review-fix round deleted a variable its own
new code used and nothing noticed until the next review. Run it after every
workflow-YAML edit:

    python3 scripts/check_workflow_python.py

Exit 0 when every heredoc in every workflow parses clean; exit 1 otherwise.
Knows nothing about jinja placeholders (the renderer quotes them as string
literals, so they never appear as identifiers).
"""
import re
import ast
import pathlib
import sys

HEREDOC = re.compile(r"python3? - <<'PY'\n(.*?)\n          PY", re.S)


def check(text, label):
    bad = 0
    for m in HEREDOC.finditer(text):
        code = re.sub(r'^          ', '', m.group(1), flags=re.M)
        try:
            tree = ast.parse(code)
        except SyntaxError as e:
            print(f"{label}: SYNTAX {e}")
            bad += 1
            continue
        known = set(dir(__builtins__)) | {'PY'}
        for n in ast.walk(tree):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                known.add(n.id)
            elif isinstance(n, ast.arg):
                known.add(n.arg)
            elif isinstance(n, ast.Import):
                for a in n.names:
                    known.add((a.asname or a.name).split('.')[0])
            elif isinstance(n, ast.ImportFrom):
                for a in n.names:
                    known.add(a.asname or a.name)
            elif isinstance(n, (ast.FunctionDef, ast.ClassDef)):
                known.add(n.name)
            elif isinstance(n, ast.comprehension) and isinstance(n.target, ast.Name):
                known.add(n.target.id)
        # Attribute roots are NOT auto-known: a bare root that is never bound
        # anywhere is a genuine undefined name (src.rglob with no src defined).
        missing = sorted({
            n.id for n in ast.walk(tree)
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)
            and n.id not in known
        })
        if missing:
            print(f"{label}: UNDEFINED {missing}")
            bad += 1
    print(f"{label}: {'clean' if not bad else f'{bad} bad block(s)'}")
    return bad


if __name__ == '__main__':
    workflows = sorted(pathlib.Path(__file__).resolve().parent.parent.glob('workflows/*.yaml'))
    total = sum(
        check(p.read_text(), p.name)
        for p in workflows
    )
    sys.exit(1 if total else 0)

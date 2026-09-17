import ast
import sys
import tokenize
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.glob("app/*.py"))

for f in files:
    src = f.read_text(encoding="utf-8")
    lines = src.splitlines()
    print(f"\n=== {f.relative_to(root)} ({len(lines)} lines) ===")

    try:
        tree = ast.parse(src)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                doc = ast.get_docstring(node, clean=False)
                if doc:
                    name = getattr(node, "name", "<module>")
                    lineno = getattr(node, "lineno", 0)
                    print(f"  [docstring @ {name}:{lineno}] {doc[:200]!r}")
    except SyntaxError as e:
        print(f"  !! syntax error: {e}")

    try:
        with open(f, "rb") as fh:
            for tok in tokenize.tokenize(fh.readline):
                if tok.type == tokenize.COMMENT:
                    line_no = tok.start[0]
                    print(f"  [comment @ {line_no}] {tok.string}")
    except Exception as e:
        print(f"  !! tokenize error: {e}")

# tools/build/remap_runtime_lexical_test.py
"""Frozen public path containment controls; no physical or native authority."""

import ast
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "tools/build/remap_runtime_patch.py"
CORPUS = ROOT / "tools/build/fixtures/remap_runtime_lexical48.json"
ROWS = json.loads(CORPUS.read_bytes())["cases"]
if len(ROWS) != 48:
    raise RuntimeError("The independently frozen lexical corpus is incomplete")
TREE = ast.parse(SOURCE.read_bytes())
INVENTORY = [
    node for node in TREE.body if isinstance(node, ast.FunctionDef) and node.name == "_inventory"
]
if len(INVENTORY) != 1:
    raise RuntimeError("The actual source inventory declaration is ambiguous")
CHECKS = [
    node
    for node in ast.walk(INVENTORY[0])
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "_require"
    and len(node.args) == 3
    and isinstance(node.args[2], ast.Constant)
    and node.args[2].value == "Source path escapes its checkout"
]
if len(CHECKS) != 1:
    raise RuntimeError("The actual lexical source guard is ambiguous")
CONDITION = compile(
    ast.Expression(CHECKS[0].args[0]), "<actual-inventory-lexical-boundary>", "eval"
)


class LexicalContainmentControls(unittest.TestCase):
    """Handwritten POSIX/Windows outcomes, including deliberately lexical parents."""


for index, row in enumerate(ROWS):

    def control(self, row=row):
        flavor, owner, raw_name, expected = row
        kind = PurePosixPath if flavor == "posix" else PureWindowsPath
        root = kind(owner)
        actual = eval(
            CONDITION, {"__builtins__": {"len": len}}, {"path": root / raw_name, "root": root}
        )
        self.assertIs(actual, expected, row)

    setattr(LexicalContainmentControls, f"test_{index:02d}_frozen_root_raw_name", control)


if __name__ == "__main__":
    unittest.main()

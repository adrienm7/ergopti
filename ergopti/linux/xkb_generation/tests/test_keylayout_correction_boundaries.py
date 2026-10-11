"""Portable boundary controls for the keylayout source consumed by Linux XKB."""

import ast
import itertools
from pathlib import Path
import re
import subprocess
import sys
import unittest

SOURCE_REL = "static/ergopti/macos/keylayout_generation/keylayout_correction.py"
ROOT = Path(__file__).resolve().parents[5]


def correction_phase(source):
    """Execute the actual correction body with recording downstream XML ports."""
    tree = ast.parse(Path(source).read_text(encoding="utf-8"))
    owners = [
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {"trim_boundary_empty_lines", "correct_keylayout"}
    ]
    if not any(node.name == "correct_keylayout" for node in owners):
        raise AssertionError("The actual correction owner is absent.")

    class Logger:
        def info(self, *_arguments):
            pass

    namespace = {
        "re": re,
        "logger": Logger(),
        "LOGS_INDENTATION": "\t",
        "EXTRA_KEYS": [],
        "KEYMAPSELECT_MAPINDEX_4": "",
        "KEYMAPSELECT_MAPINDEX_5": "",
        "KEYMAPSELECT_MAPINDEX_6": "",
    }
    for name in {
        node.func.id
        for owner in owners
        for node in ast.walk(owner)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    } - {"len", "enumerate", "trim_boundary_empty_lines"}:
        namespace[name] = lambda value, *_arguments: value
    module = ast.Module(body=owners, type_ignores=[])
    exec(compile(module, str(source), "exec"), namespace)
    return lambda value: namespace["correct_keylayout"](value, 1)


class KeylayoutBoundaryTests(unittest.TestCase):
    def test_existing_boundary_bytes_are_preserved(self):
        correct = correction_phase(ROOT / SOURCE_REL)
        alphabet = [" ", "\t", "\n", "\r", "\u2003", "X"]
        for size in range(5):
            for parts in itertools.product(alphabet, repeat=size):
                text = "".join(parts)
                expected = re.sub(r"^(\s*\n)+|((\s*\n)+)$", "", text)
                self.assertEqual(correct(text), expected, repr(text))
        for text in [
            "\n  <keyboard/>\n\n",
            "  <keyboard/>  ",
            "<keyboard/> \n",
            "\n <keyboard/>\n ",
            "",
        ]:
            self.assertEqual(correct(text), re.sub(r"^(\s*\n)+|((\s*\n)+)$", "", text))

    def test_large_unterminated_whitespace_finishes(self):
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(Path(__file__).resolve()),
                "--boundary-worker",
                str(ROOT / SOURCE_REL),
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "PASS exact long whitespace boundary\n")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--boundary-worker":
        value = "<keyboard/>" + " " * 131072
        if correction_phase(sys.argv[2])(value) != value:
            raise AssertionError("Unterminated whitespace was modified.")
        print("PASS exact long whitespace boundary")
    else:
        unittest.main()

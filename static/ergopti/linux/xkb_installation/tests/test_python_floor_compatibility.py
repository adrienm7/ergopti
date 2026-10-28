"""Guards that keep this directory importable on the oldest supported Python.

The installer declares its floor in ``install.sh`` (``MIN_PYTHON_MINOR``) and CI
runs the whole suite on that interpreter, because Ubuntu 20.04 ships 3.8.10 and
Rocky 9 ships 3.9.25 and both must be able to run a curl|bash install.

That CI job works, but it only speaks after a push. A ``str | None`` annotation
is evaluated at runtime before Python 3.10, so one such spelling in one file
makes the whole module fail to import: it cost a red branch and an extra commit
on 2026-09-06, taking down the Python 3.8 job and the real installs on rocky-9
and ubuntu-20.04 at once.

`from __future__ import annotations` defers every annotation to a string and has
worked since 3.7, so the modern spelling stays readable and the floor stays
honoured. These tests make that rule local and instant instead of a CI
round-trip, and they read the floor from install.sh rather than hardcoding it,
so raising the floor one day relaxes them automatically.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

INSTALLER_DIR = Path(__file__).resolve().parents[1]

# An annotation position (after `->` or a `:`) holding a PEP 604 union.
PEP_604_RE = re.compile(r"(?:->|:)\s*[A-Za-z_][\w\.\[\]\"']*\s*\|\s*[A-Za-z_\"']")
FUTURE_IMPORT = "from __future__ import annotations"

# PEP 604 unions are only evaluated lazily from this version onwards.
NATIVE_UNION_MINOR = 10


def python_floor() -> tuple[int, int]:
    """Read the floor the entrypoint enforces, so this stays a single source."""
    entrypoint = (INSTALLER_DIR / "install.sh").read_text(encoding="utf-8")
    major = re.search(r"^MIN_PYTHON_MAJOR=(\d+)", entrypoint, re.MULTILINE)
    minor = re.search(r"^MIN_PYTHON_MINOR=(\d+)", entrypoint, re.MULTILINE)
    if not major or not minor:
        raise AssertionError(
            "install.sh no longer declares MIN_PYTHON_MAJOR/MIN_PYTHON_MINOR; "
            "this guard cannot know which interpreter it is protecting"
        )
    return int(major.group(1)), int(minor.group(1))


def python_modules() -> list[Path]:
    """Every Python file shipped or exercised by the installer."""
    return sorted(path for path in INSTALLER_DIR.rglob("*.py") if "__pycache__" not in path.parts)


def parenthesized_with_lines(source: str) -> tuple[list[int], int]:
    """Lines of `with` statements whose parentheses enclose the whole item list.

    That spelling is Python 3.9+ grammar once it holds an `as` or several
    items. `with (expr):` and `with (a), b:` stay legal on 3.8, so the opening
    parenthesis only counts when its match closes after the last item. A 3.8
    parser reads `with (a, b):` as one tuple-valued manager, which is flagged
    too: a tuple is never a context manager. Returns the offending lines and
    the number of `with` statements scanned.
    """
    import ast
    import io
    import tokenize

    tree = ast.parse(source)
    tokens = [
        token
        for token in tokenize.generate_tokens(io.StringIO(source).readline)
        if token.type not in (tokenize.NL, tokenize.COMMENT)
    ]
    lines: list[int] = []
    count = 0
    for node in ast.walk(tree):
        if not isinstance(node, (ast.With, ast.AsyncWith)):
            continue
        count += 1
        last = node.items[-1]
        if len(node.items) == 1 and last.optional_vars is None:
            if isinstance(last.context_expr, ast.Tuple):
                lines.append(node.lineno)
            continue
        keyword = next(
            index
            for index, token in enumerate(tokens)
            if token.type == tokenize.NAME
            and token.string == "with"
            and token.start >= (node.lineno, node.col_offset)
        )
        if tokens[keyword + 1].string != "(":
            continue
        depth = 0
        for index in range(keyword + 1, len(tokens)):
            token = tokens[index]
            if token.type == tokenize.OP and token.string in "([{":
                depth += 1
            elif token.type == tokenize.OP and token.string in ")]}":
                depth -= 1
                if depth == 0:
                    closing = token.start
                    break
        end = last.optional_vars or last.context_expr
        if closing >= (end.end_lineno, end.end_col_offset):
            lines.append(node.lineno)
    return sorted(lines), count


class PythonFloorTests(unittest.TestCase):
    def setUp(self):
        self.floor = python_floor()
        self.modules = python_modules()
        # A guard that reads nothing passes for free.
        self.assertGreater(len(self.modules), 10, "the module scan found almost nothing")

    def test_the_declared_floor_is_below_native_unions(self):
        """The whole point of the rule below is that the floor predates PEP 604."""
        if self.floor >= (3, NATIVE_UNION_MINOR):
            self.skipTest(
                f"floor is Python {self.floor[0]}.{self.floor[1]}: PEP 604 unions "
                "are native, so deferring annotations is no longer required"
            )
        self.assertEqual(self.floor[0], 3)

    def test_every_module_using_pep_604_defers_its_annotations(self):
        if self.floor >= (3, NATIVE_UNION_MINOR):
            self.skipTest("floor already supports native unions")
        offenders: list[str] = []
        users = 0
        for path in self.modules:
            source = path.read_text(encoding="utf-8")
            # Comments and docstrings quote the forbidden spelling to explain
            # it; only real code lines are call sites.
            code = "\n".join(
                line for line in source.splitlines() if not line.lstrip().startswith("#")
            )
            if not PEP_604_RE.search(code):
                continue
            users += 1
            if FUTURE_IMPORT not in source:
                offenders.append(str(path.relative_to(INSTALLER_DIR)))
        self.assertGreater(
            users,
            0,
            "no module uses PEP 604 at all, so this guard proves nothing; either "
            "the pattern is genuinely gone or the detector broke",
        )
        self.assertEqual(
            offenders,
            [],
            "these modules use `X | Y` in an annotation without deferring it, so "
            f"they raise TypeError on Python {self.floor[0]}.{self.floor[1]} and "
            "fail to import at all: add "
            f"`{FUTURE_IMPORT}` at the top of each",
        )

    def test_no_parenthesized_context_managers_below_3_9(self):
        """(py38-paren-with) `with (a, b):` is a tuple, not two managers, on 3.8.

        The grammar check below cannot see this on every interpreter: from 3.12
        on, ``ast.parse(feature_version=(3, 8))`` accepts the parenthesized form,
        and on 3.8 itself ``with (a, b):`` parses as one tuple-valued manager
        that only fails at run time with ``AttributeError: __enter__``. Ruff's
        formatter produced 53 of them while the repository targeted py313, and
        they took down the floor job and the ubuntu-20.04/22.04 real installs.
        This structural scan answers the same on every interpreter.
        """
        if self.floor >= (3, 9):
            self.skipTest("floor already supports parenthesized context managers")
        offenders: list[str] = []
        scanned = 0
        for path in self.modules:
            relative = path.relative_to(INSTALLER_DIR)
            try:
                lines, count = parenthesized_with_lines(path.read_text(encoding="utf-8"))
            except SyntaxError as error:
                # On the floor itself the `as` spelling does not even parse.
                offenders.append(f"{relative}: {error}")
                continue
            scanned += count
            offenders.extend(f"{relative}:{line}" for line in lines)
        self.assertGreater(scanned, 0, "no `with` statement was scanned, so this proves nothing")
        self.assertEqual(
            offenders,
            [],
            "these `with` statements wrap their whole item list in parentheses, "
            f"which Python {self.floor[0]}.{self.floor[1]} rejects or reads as a "
            "tuple: write `with a, b:` and let the formatter break inside a call",
        )

    def test_the_parenthesized_with_detector_sees_both_shapes(self):
        """(py38-paren-with) The scan above must be able to fail."""
        # Parses on every interpreter: two managers from 3.9, one tuple on 3.8.
        tuple_shape = "with (\n    open(a),\n    open(b),\n):\n    pass\n"
        good = "with (a), open(b) as g:\n    pass\nwith (a):\n    pass\n"
        good_split = "with open(\n    a\n) as f, open(b):\n    pass\n"
        self.assertEqual(parenthesized_with_lines(tuple_shape), ([1], 1))
        self.assertEqual(parenthesized_with_lines(good), ([], 2))
        self.assertEqual(parenthesized_with_lines(good_split), ([], 1))
        if sys.version_info >= (3, 9):
            # 3.8 cannot parse these at all; the grammar test owns them there.
            as_shape = "with (\n    open(a) as f,\n    open(b),\n):\n    pass\n"
            as_single = "with (open(a) as f):\n    pass\n"
            self.assertEqual(parenthesized_with_lines(as_shape), ([1], 1))
            self.assertEqual(parenthesized_with_lines(as_single), ([1], 1))

    def test_every_module_compiles_under_the_floors_grammar(self):
        """Syntax that the floor's parser rejects never reaches a user."""
        import ast

        failures: list[str] = []
        for path in self.modules:
            try:
                ast.parse(
                    path.read_text(encoding="utf-8"),
                    filename=str(path),
                    feature_version=self.floor,
                )
            except SyntaxError as error:
                failures.append(f"{path.relative_to(INSTALLER_DIR)}: {error}")
            except ValueError:
                # feature_version below what this interpreter can model; the CI
                # job on the real floor is authoritative in that case.
                self.skipTest(
                    f"this interpreter ({sys.version_info.major}."
                    f"{sys.version_info.minor}) cannot model Python "
                    f"{self.floor[0]}.{self.floor[1]} grammar"
                )
        self.assertEqual(
            failures,
            [],
            f"these modules use syntax Python {self.floor[0]}.{self.floor[1]} "
            "cannot parse, so the installer dies before printing anything",
        )


if __name__ == "__main__":
    unittest.main()

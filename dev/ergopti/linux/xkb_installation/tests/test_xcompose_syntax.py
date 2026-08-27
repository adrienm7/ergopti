"""Syntax guard for the generated XCompose files.

A Compose string literal is double-quoted, with backslashes and double quotes
escaped. The generator once wrote ``"\\"`` for the backslash output and used
single quotes as a fallback delimiter; libxkbcommon reports an unterminated
string or an unrecognized token and drops the sequences that follow, so the
check runs over every installable file the repository ships.
"""

import re
import sys
import unittest
from pathlib import Path

LAYOUT_DIR = Path(__file__).resolve().parents[2]


class XComposeSyntaxGuard(unittest.TestCase):
    """Every installable Compose file must be a valid Compose file.

    An unescaped backslash or quote inside a string literal makes
    libxkbcommon report an unterminated string and drop the sequences that
    follow it; the ``"\\"`` output of dead_circumflex + underscore did exactly
    that in every shipped file.
    """

    STRING_RE = re.compile(r':\s*"((?:[^"\\]|\\.)*)"\s*(?:\S+)?\s*$')

    def test_every_installable_compose_line_has_a_terminated_string(self):
        checked = 0
        for version_dir in sorted(LAYOUT_DIR.glob("v*")):
            for compose in sorted(version_dir.glob("*.XCompose")):
                if "_plus_plus" in compose.name:
                    continue
                for number, line in enumerate(compose.read_text(encoding="utf-8").splitlines(), 1):
                    if ":" not in line or line.startswith(("#", "include")):
                        continue
                    checked += 1
                    self.assertRegex(line, self.STRING_RE, f"{compose.name}:{number}: {line!r}")
                    self.assertNotIn(": '", line, f"{compose.name}:{number}: single quotes are not Compose strings")
        self.assertGreater(checked, 1000)


if __name__ == "__main__":
    unittest.main()

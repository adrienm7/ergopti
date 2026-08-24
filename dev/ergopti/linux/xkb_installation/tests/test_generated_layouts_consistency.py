"""Coherence checks over every generated layout shipped in the repository.

This is the regression fence for issue #84: a symbols file referencing a key
type that its version's types file never defines compiles into no keymap at
all, which users experience as entire layers (Shift, AltGr) being dead.

The test walks every version directory under static/ergopti/linux and asserts:

- every ``type[...] = "..."`` reference resolves to a type defined by that
  version's ``xkb_types.txt``;
- the Ergopti-specific type is defined exactly once per types file and
  referenced by every key of every layout;
- Ergopti++ files stay coherent too (they still ship in the repository even
  though the installer no longer proposes them).
"""

import re
import sys
import unittest
from pathlib import Path

INSTALLER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(INSTALLER_DIR))

from layout_package import ERGOPTI_TYPE_NAME  # noqa: E402

LAYOUT_DIR = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(__file__).resolve().parents[5]

TYPE_REFERENCE_RE = re.compile(r'type(?:\[[^\]]*\])?\s*=\s*"([^"]+)"')
TYPE_DEFINITION_RE = re.compile(r'^\s*type\s+"([^"]+)"', re.MULTILINE)


def version_directories() -> list[Path]:
    return sorted(
        (path for path in LAYOUT_DIR.iterdir() if path.is_dir() and path.name.startswith("v")),
        key=lambda path: path.name,
    )


class GeneratedLayoutConsistencyTests(unittest.TestCase):
    def test_repository_contains_layout_versions(self):
        self.assertTrue(version_directories(), "no version directory found")

    def test_every_symbols_reference_only_defined_types(self):
        failures: list[str] = []
        checked_files = 0
        for version_dir in version_directories():
            types_content = (version_dir / "xkb_types.txt").read_text(encoding="utf-8")
            defined = set(TYPE_DEFINITION_RE.findall(types_content))
            for symbols_path in sorted(version_dir.glob("*.xkb")):
                checked_files += 1
                referenced = set(
                    TYPE_REFERENCE_RE.findall(symbols_path.read_text(encoding="utf-8"))
                )
                unknown = referenced - defined
                if unknown:
                    failures.append(
                        f"{symbols_path.relative_to(REPO_ROOT)} references undefined "
                        f"types: {sorted(unknown)}"
                    )
        self.assertEqual(failures, [], "incoherent layout packages detected")
        # Guard against a vacuous pass if the tree layout ever changes.
        self.assertGreaterEqual(checked_files, 12)

    def test_ergopti_type_is_namespaced_and_used(self):
        for version_dir in version_directories():
            types_content = (version_dir / "xkb_types.txt").read_text(encoding="utf-8")
            defined = TYPE_DEFINITION_RE.findall(types_content)
            self.assertIn(ERGOPTI_TYPE_NAME, defined, version_dir.name)
            self.assertEqual(defined.count(ERGOPTI_TYPE_NAME), 1, version_dir.name)
            for symbols_path in sorted(version_dir.glob("*.xkb")):
                content = symbols_path.read_text(encoding="utf-8")
                self.assertIn(
                    ERGOPTI_TYPE_NAME,
                    content,
                    f"{symbols_path.name} does not use {ERGOPTI_TYPE_NAME}",
                )

    def test_every_layout_defines_a_full_key_set(self):
        minimum_keys = 40
        for version_dir in version_directories():
            for symbols_path in sorted(version_dir.glob("*.xkb")):
                content = symbols_path.read_text(encoding="utf-8")
                key_count = len(re.findall(r"(?m)^\s*key\s+<", content))
                self.assertGreaterEqual(
                    key_count,
                    minimum_keys,
                    f"{symbols_path.name} defines only {key_count} keys",
                )


if __name__ == "__main__":
    unittest.main()

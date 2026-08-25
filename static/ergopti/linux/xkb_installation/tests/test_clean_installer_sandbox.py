"""End-to-end sandbox test for the clean installer.

Runs the real CLI (xkb_files_installer_clean.py) against temporary roots via
the ERGOPTI_XKB_* environment overrides, using the actual generated layout
files from the repository. Covers:

- a first installation produces the full package tree;
- re-running over an existing install is idempotent;
- leftovers from previous installer generations (bridge links in the legacy
  XKB tree and injected rules lines) are cleaned during install and uninstall;
- uninstall removes everything it installed.

The sandbox keeps every OS-specific step either out of scope (no XCompose, no
X11 bridge) or non-fatal by contract (activation commands may be absent), so
the test runs on any platform.
"""

import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

INSTALLER_DIR = Path(__file__).resolve().parents[1]
LAYOUT_VERSION_DIR = INSTALLER_DIR.parent / "v2_2_1"
sys.path.insert(0, str(INSTALLER_DIR))

import xkb_files_installer_clean as clean_installer  # noqa: E402
from layout_package import InstallerRoots  # noqa: E402


class CleanInstallerSandboxTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Path(self._tmp.name)
        self.extensions_root = self.sandbox / "xkeyboard-config.d"
        self.system_root = self.sandbox / "X11" / "xkb"
        self.cache_dir = self.sandbox / "cache"
        for directory in (self.system_root / "symbols", self.system_root / "rules"):
            directory.mkdir(parents=True)
        self.package_dir = self.extensions_root / "ergopti"
        self.env = {
            **os.environ,
            "ERGOPTI_XKB_EXTENSIONS_ROOT": str(self.extensions_root),
            "ERGOPTI_XKB_SYSTEM_ROOT": str(self.system_root),
            "ERGOPTI_XKB_CACHE_DIR": str(self.cache_dir),
            "PYTHONIOENCODING": "utf-8",
        }
        # Generation-2 leftovers that an upgrade must neutralise.
        stale_link = self.system_root / "symbols" / "Ergopti_v2_0_0_plus"
        stale_link.write_text("stale generation-2 bridge", encoding="utf-8")
        rules_file = self.system_root / "rules" / "evdev"
        rules_file.write_text(
            "! model = types\n"
            "  * = complete\n"
            "! layout = types\n"
            "  Ergopti_v2_0_0_plus = +Ergopti_v2_0_0_plus\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self._tmp.cleanup()

    def run_installer(self, *extra_args: str):
        command = [
            sys.executable,
            str(INSTALLER_DIR / "xkb_files_installer_clean.py"),
            "--xkb",
            str(LAYOUT_VERSION_DIR / "Ergopti_v2_2_1_plus.xkb"),
            "--types",
            str(LAYOUT_VERSION_DIR / "xkb_types.txt"),
            "--variant",
            "ergopti_plus",
            *extra_args,
        ]
        return subprocess.run(
            command,
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def read_installed_rules_evdev(self) -> str:
        return (self.system_root / "rules" / "evdev").read_text(encoding="utf-8")

    def assert_package_complete(self):
        symbols = self.package_dir / "symbols" / "ergopti"
        types = self.package_dir / "types" / "ergopti"
        registry = self.package_dir / "rules" / "evdev.xml"
        post = self.package_dir / "rules" / "evdev.post"
        for path in (symbols, types, registry, post):
            self.assertTrue(path.is_file(), f"missing installed file: {path}")
        symbols_content = symbols.read_text(encoding="utf-8")
        self.assertIn('xkb_symbols "default"', symbols_content)
        self.assertIn("ERGOPTI_SEVEN_LEVEL", symbols_content)
        self.assertEqual(post.read_text(encoding="utf-8").count("ergopti"), 2)
        names = [node.text for node in ET.parse(registry).getroot().iter("name")]
        self.assertEqual(names, ["ergopti"])

    def test_install_upgrades_from_previous_generation_and_uninstalls(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_package_complete()

        # Previous-generation artefacts are gone after the upgrade.
        self.assertFalse((self.system_root / "symbols" / "Ergopti_v2_0_0_plus").exists())
        self.assertNotIn("+Ergopti_v2_0_0_plus", self.read_installed_rules_evdev())
        # The stock model->types mapping survives the cleanup.
        self.assertIn("! model = types", self.read_installed_rules_evdev())

        # Idempotent reinstall.
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_package_complete()

        # Uninstall removes the package but leaves foreign content alone.
        result = self.run_installer("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse(self.package_dir.exists())
        self.assertTrue(
            (self.system_root / "rules" / "evdev").read_text(encoding="utf-8").strip()
        )

    def test_failed_compile_preserves_the_previous_package_byte_for_byte(self):
        """A rejected upgrade must not remove the layout that still works."""
        old_symbols = self.package_dir / "symbols" / "ergopti"
        old_symbols.parent.mkdir(parents=True)
        old_symbols.write_bytes(b"known-good-layout\n")
        old_types = self.package_dir / "types" / "ergopti"
        old_types.parent.mkdir()
        old_types.write_bytes(b"known-good-types\n")
        before = {
            path.relative_to(self.package_dir): path.read_bytes()
            for path in self.package_dir.rglob("*")
            if path.is_file()
        }
        roots = InstallerRoots(
            extensions_root=self.extensions_root,
            system_root=self.system_root,
            cache_dir=self.cache_dir,
            sandboxed=True,
        )

        def reject_staged_package(extensions_root, layout_id):
            self.assertEqual(layout_id, "ergopti")
            self.assertTrue(
                (extensions_root / "ergopti" / "symbols" / layout_id).is_file()
            )
            return False

        with mock.patch("builtins.print"), mock.patch.object(
            clean_installer,
            "compile_validation",
            side_effect=reject_staged_package,
        ):
            with self.assertRaises(SystemExit):
                clean_installer.install_clean(
                    symbols_path=LAYOUT_VERSION_DIR / "Ergopti_v2_2_1_plus.xkb",
                    types_path=LAYOUT_VERSION_DIR / "xkb_types.txt",
                    xcompose_path=None,
                    variant="ergopti_plus",
                    support_x11=False,
                    roots=roots,
                )

        after = {
            path.relative_to(self.package_dir): path.read_bytes()
            for path in self.package_dir.rglob("*")
            if path.is_file()
        }
        self.assertEqual(after, before)

    def test_failed_package_swap_restores_the_previous_package(self):
        old_symbols = self.package_dir / "symbols" / "ergopti"
        old_symbols.parent.mkdir(parents=True)
        old_symbols.write_bytes(b"known-good-layout\n")
        staged_package = self.sandbox / "stage" / "ergopti"
        staged_symbols = staged_package / "symbols" / "ergopti"
        staged_symbols.parent.mkdir(parents=True)
        staged_symbols.write_bytes(b"candidate-layout\n")
        real_rename = Path.rename

        def fail_candidate_rename(source, target):
            if source == staged_package:
                raise OSError("injected candidate rename failure")
            return real_rename(source, target)

        with mock.patch.object(Path, "rename", autospec=True, side_effect=fail_candidate_rename):
            with self.assertRaisesRegex(OSError, "candidate rename failure"):
                clean_installer.commit_staged_package(staged_package, self.package_dir)

        self.assertEqual(old_symbols.read_bytes(), b"known-good-layout\n")
        self.assertFalse(self.package_dir.with_name(".ergopti.rollback").exists())


if __name__ == "__main__":
    unittest.main()

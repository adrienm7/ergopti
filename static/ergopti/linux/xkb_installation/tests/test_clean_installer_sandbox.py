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
from pathlib import Path

INSTALLER_DIR = Path(__file__).resolve().parents[1]
LAYOUT_VERSION_DIR = INSTALLER_DIR.parent / "v2_2_1"
sys.path.insert(0, str(INSTALLER_DIR))


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


if __name__ == "__main__":
    unittest.main()

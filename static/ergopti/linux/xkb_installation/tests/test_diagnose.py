"""Tests for the diagnostic report.

The report is what a user pastes into a bug report, so its contract is: it
runs anywhere, without privileges and without any XKB tool, never stops
before its last section, and names the state of both installation methods.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

INSTALLER_DIR = Path(__file__).resolve().parents[1]
LAYOUT_VERSION_DIR = INSTALLER_DIR.parent / "v2_2_1"
sys.path.insert(0, str(INSTALLER_DIR))

import xkb_diagnose as diagnose  # noqa: E402


class DiagnoseReportTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Path(self._tmp.name)
        self.extensions_root = self.sandbox / "xkeyboard-config.d"
        self.system_root = self.sandbox / "X11" / "xkb"
        self.home = self.sandbox / "home"
        for directory in (self.extensions_root, self.system_root / "symbols", self.system_root / "rules", self.home):
            directory.mkdir(parents=True)
        self.env = {
            **os.environ,
            "ERGOPTI_XKB_EXTENSIONS_ROOT": str(self.extensions_root),
            "ERGOPTI_XKB_SYSTEM_ROOT": str(self.system_root),
            "ERGOPTI_XKB_CACHE_DIR": str(self.sandbox / "cache"),
            "ERGOPTI_XKB_USER_HOME": str(self.home),
            "XDG_SESSION_TYPE": "wayland",
            "XDG_CURRENT_DESKTOP": "Hyprland",
            "PATH": str(self.sandbox / "empty-bin"),
            "PYTHONIOENCODING": "utf-8",
        }
        (self.sandbox / "empty-bin").mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def run_report(self):
        return subprocess.run(
            [sys.executable, str(INSTALLER_DIR / "xkb_diagnose.py")],
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def test_the_report_runs_to_its_end_without_any_tool(self):
        result = self.run_report()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        for title in (
            "=== Système ===",
            "=== Session graphique ===",
            "=== Outils et versions ===",
            "=== Arborescence XKB ===",
            "=== Méthode Legacy (fichiers système) ===",
            "=== Réglages de bureau ===",
            "=== Compilation des dispositions installées ===",
            "===== Fin du diagnostic =====",
        ):
            self.assertIn(title, result.stdout)
        self.assertIn("xkbcli", result.stdout)
        self.assertIn("absent", result.stdout)
        self.assertIn("Bureau reconnu", result.stdout)
        self.assertIn("compositor", result.stdout)
        self.assertIn("hyprland.conf", result.stdout)

    def test_installed_artefacts_of_both_methods_are_listed(self):
        package = self.extensions_root / "ergopti"
        (package / "rules").mkdir(parents=True)
        (package / "symbols").mkdir()
        (package / "symbols" / "ergopti").write_text("symbols", encoding="utf-8")
        (package / "rules" / "evdev.post").write_text("! layout = types\n  ergopti = +ergopti\n", encoding="utf-8")
        symbols_fr = self.system_root / "symbols" / "fr"
        symbols_fr.write_text('xkb_symbols "basic" { };\nxkb_symbols "Ergopti_v2_2_1" { };\n', encoding="utf-8")
        symbols_fr.with_name("fr.1").write_text("pristine", encoding="utf-8")
        (self.system_root / "symbols" / "Ergopti_v2_0_0").write_text("stale bridge", encoding="utf-8")
        (self.home / ".XCompose").write_text('include "%L"\n# Ergopti managed XCompose\ninclude "/pkg/ergopti.XCompose"\n', encoding="utf-8")

        result = self.run_report()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ergopti = +ergopti", result.stdout)
        self.assertIn("Sections Legacy dans symbols/fr: Ergopti_v2_2_1", result.stdout)
        self.assertIn("sauvegardes : fr.1", result.stdout)
        self.assertIn("Ergopti_v2_0_0", result.stdout)
        self.assertIn("Ergopti managed XCompose", result.stdout)
        self.assertIn("ni xkbcli ni xkbcomp", result.stdout)

    def test_a_crashing_section_does_not_stop_the_report(self):
        printed: list[str] = []

        def explode():
            raise RuntimeError("probe failure")

        with mock.patch("builtins.print", side_effect=lambda *a, **k: printed.append(" ".join(str(p) for p in a))):
            diagnose.guarded("Section test", explode)
        output = "\n".join(printed)
        self.assertIn("Section test", output)
        self.assertIn("probe failure", output)

    def test_legacy_variants_are_read_from_the_symbols_file(self):
        symbols_fr = self.system_root / "symbols" / "fr"
        symbols_fr.write_text('xkb_symbols "Ergopti_v2_2_1" {\n};\nxkb_symbols "Ergopti_v2_2_1_plus" {\n};\n', encoding="utf-8")
        self.assertEqual(diagnose.legacy_variants(self.system_root), ["Ergopti_v2_2_1", "Ergopti_v2_2_1_plus"])
        self.assertEqual(diagnose.legacy_variants(self.sandbox / "missing"), [])


if __name__ == "__main__":
    unittest.main()

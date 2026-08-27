"""End-to-end sandbox test for the legacy installer.

Runs the real CLI (xkb_files_installer_legacy.py) against a temporary system
tree through the ERGOPTI_XKB_* overrides. The fixture mirrors the shape of the
real xkeyboard-config files the installer edits: a single-section
``types/extra``, a ``symbols/fr`` file, and the two registries.

Covers the failure that made the legacy method ship dead Shift/AltGr layers:
the custom type must land *inside* the ``xkb_types`` section, and any step
that leaves the tree unusable must roll every touched file back.
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

import xkb_files_installer_legacy as legacy  # noqa: E402
from layout_package import InstallerRoots, LayoutSpec  # noqa: E402

SYMBOLS_FR = """// French layouts
partial default alphanumeric_keys
xkb_symbols "basic" {
    include "latin"
    name[Group1]="French";
};

partial alphanumeric_keys
xkb_symbols "oss" {
    include "fr(basic)"
    name[Group1]="French (alt.)";
};
"""

TYPES_EXTRA = """default partial xkb_types "default" {

    // Definitions for extra types

    virtual_modifiers LevelThree;

    type "FOUR_LEVEL_X" {
        modifiers = Shift + Control + Alt + LevelThree;
        map[None] = Level1;
        map[Shift] = Level2;
        map[LevelThree] = Level3;
        level_name[Level1] = "Base";
    };
};
"""

EVDEV_LST = """! model
  pc105           Generic 105-key PC

! layout
  fr              French

! variant
  oss             fr: French (alt.)

! option
  grp             Switching to another layout
"""

EVDEV_XML = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xkbConfigRegistry SYSTEM "xkb.dtd">
<xkbConfigRegistry version="1.1">
  <layoutList>
    <layout>
      <configItem>
        <name>fr</name>
        <shortDescription>fr</shortDescription>
        <description>French</description>
      </configItem>
      <variantList>
        <variant>
          <configItem>
            <name>oss</name>
            <description>French (alt.)</description>
          </configItem>
        </variant>
      </variantList>
    </layout>
  </layoutList>
</xkbConfigRegistry>
"""


class LegacyInstallerSandboxTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Path(self._tmp.name)
        self.system_root = self.sandbox / "X11" / "xkb"
        self.extensions_root = self.sandbox / "xkeyboard-config.d"
        self.cache_dir = self.sandbox / "cache"
        self.home = self.sandbox / "home"
        self.home.mkdir()
        for directory in ("symbols", "types", "rules"):
            (self.system_root / directory).mkdir(parents=True)
        self.paths = legacy.legacy_paths(self.system_root)
        self.paths.symbols_fr.write_text(SYMBOLS_FR, encoding="utf-8")
        self.paths.types_extra.write_text(TYPES_EXTRA, encoding="utf-8")
        self.paths.evdev_lst.write_text(EVDEV_LST, encoding="utf-8")
        self.paths.evdev_xml.write_text(EVDEV_XML, encoding="utf-8")
        self.originals = {path: path.read_bytes() for path in self.paths.touched()}
        # No XKB compiler on the PATH: the sandbox exercises the file edits,
        # test_xkb_toolchain.py exercises the real compilers when present.
        self.env = {
            **os.environ,
            "ERGOPTI_XKB_EXTENSIONS_ROOT": str(self.extensions_root),
            "ERGOPTI_XKB_SYSTEM_ROOT": str(self.system_root),
            "ERGOPTI_XKB_CACHE_DIR": str(self.cache_dir),
            "ERGOPTI_XKB_USER_HOME": str(self.home),
            "PATH": str(self.sandbox / "empty-bin"),
            "PYTHONIOENCODING": "utf-8",
        }
        (self.sandbox / "empty-bin").mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def roots(self) -> InstallerRoots:
        return InstallerRoots(
            extensions_root=self.extensions_root,
            system_root=self.system_root,
            cache_dir=self.cache_dir,
            sandboxed=True,
        )

    def run_installer(self, *extra_args: str, with_layout: bool = True):
        command = [sys.executable, str(INSTALLER_DIR / "xkb_files_installer_legacy.py")]
        if with_layout:
            command += [
                "--xkb",
                str(LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb"),
                "--types",
                str(LAYOUT_VERSION_DIR / "xkb_types.txt"),
            ]
        command += list(extra_args)
        return subprocess.run(
            command,
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def assert_type_inside_section(self):
        extra = self.paths.types_extra.read_text(encoding="utf-8")
        self.assertEqual(extra.count('type "ERGOPTI_SEVEN_LEVEL"'), 1)
        # An appended block ends with its own "};": only a column-zero "};"
        # after the block proves it sits inside the section (issue #84).
        block_end = extra.index("};", extra.index('type "ERGOPTI_SEVEN_LEVEL"')) + 2
        self.assertRegex(extra[block_end:], r"(?m)^\};\s*$")
        self.assertEqual(extra.count("xkb_types"), 1)
        self.assertIn('type "FOUR_LEVEL_X"', extra)

    @unittest.skipIf(sys.platform == "win32", "the legacy CLI refuses to run on Windows")
    def test_install_is_idempotent_and_uninstall_restores_the_tree(self):
        (self.home / ".XCompose").write_text("user compose\n", encoding="utf-8")
        compose = self.sandbox / "Ergopti.XCompose"
        compose.write_text('<Multi_key> <e> : "ergopti"\n', encoding="utf-8")

        result = self.run_installer("--skip-activation", "--xcompose", str(compose), "--force-xcompose")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Desktop activation identifier: fr+Ergopti_v2_2_1", result.stderr + result.stdout)
        self.assert_type_inside_section()
        symbols = self.paths.symbols_fr.read_text(encoding="utf-8")
        self.assertEqual(symbols.count('xkb_symbols "Ergopti_v2_2_1"'), 1)
        self.assertIn('xkb_symbols "oss"', symbols)
        lst = self.paths.evdev_lst.read_text(encoding="utf-8")
        self.assertRegex(lst, r"! variant\n  Ergopti_v2_2_1 +fr: ")
        self.assertIn("<name>Ergopti_v2_2_1</name>", self.paths.evdev_xml.read_text(encoding="utf-8"))
        for path, original in self.originals.items():
            backup = path.with_name(f"{path.name}.1")
            self.assertEqual(backup.read_bytes(), original, f"{backup} is not the pristine copy")
        self.assertEqual((self.home / ".XCompose").read_text(encoding="utf-8"), '<Multi_key> <e> : "ergopti"\n')
        self.assertEqual((self.home / ".XCompose.1").read_text(encoding="utf-8"), "user compose\n")

        result = self.run_installer("--skip-activation", "--xcompose", str(compose), "--force-xcompose")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_type_inside_section()
        symbols = self.paths.symbols_fr.read_text(encoding="utf-8")
        self.assertEqual(symbols.count('xkb_symbols "Ergopti_v2_2_1"'), 1)
        self.assertEqual(
            self.paths.evdev_lst.read_text(encoding="utf-8").count("Ergopti_v2_2_1"), 1
        )

        result = self.run_installer("--uninstall", "--skip-activation", with_layout=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original, f"{path} was not restored")
            self.assertFalse(
                path.with_name(f"{path.name}.1").exists(),
                f"{path.name}.1 must not linger once the pristine content is back",
            )
        self.assertEqual(
            (self.home / ".XCompose").read_text(encoding="utf-8"),
            "user compose\n",
            "the user's own Compose file must come back from the sandbox home, not root's",
        )
        self.assertFalse((self.home / ".XCompose.1").exists())

    @unittest.skipIf(sys.platform == "win32", "the legacy CLI refuses to run on Windows")
    def test_a_compose_file_created_from_nothing_is_removed_on_uninstall(self):
        """Without a previous ``~/.XCompose`` there is nothing to restore; the
        file the installer wrote must go instead of staying forever."""
        compose = self.sandbox / "Ergopti.XCompose"
        compose.write_text('include "%L"\n<Multi_key> <e> : "ergopti"\n', encoding="utf-8")
        result = self.run_installer("--skip-activation", "--xcompose", str(compose), "--force-xcompose")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.home / ".XCompose").read_bytes(), compose.read_bytes())
        self.assertEqual(
            (self.home / ".XCompose.1").read_text(encoding="utf-8"), legacy.XCOMPOSE_ABSENT_SENTINEL
        )
        result = self.run_installer("--uninstall", "--skip-activation", with_layout=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse((self.home / ".XCompose").exists())
        self.assertFalse((self.home / ".XCompose.1").exists())

    def test_a_tree_that_does_not_compile_is_rolled_back(self):
        roots = self.roots()
        with mock.patch.dict(os.environ, self.env, clear=False), mock.patch.object(
            legacy, "compile_check", return_value=False
        ):
            with self.assertRaises(legacy.LegacyInstallError):
                legacy.perform_install(
                    roots,
                    LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb",
                    None,
                    LAYOUT_VERSION_DIR / "xkb_types.txt",
                )
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original, f"{path} was left modified")
            self.assertFalse(path.with_name(f"{path.name}.1").exists(), "a fresh backup must not linger")

    def test_an_unverified_tree_is_kept_with_a_warning(self):
        roots = self.roots()
        with mock.patch.dict(os.environ, self.env, clear=False), mock.patch.object(
            legacy, "compile_check", return_value=None
        ), self.assertLogs(level="WARNING") as logs:
            spec = legacy.perform_install(
                roots,
                LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb",
                None,
                LAYOUT_VERSION_DIR / "xkb_types.txt",
            )
        self.assertEqual(spec, LayoutSpec("fr", "Ergopti_v2_2_1"))
        self.assertTrue(any("could not be verified" in line for line in logs.output))
        self.assert_type_inside_section()

    def test_the_types_edit_alone_places_the_block_inside_the_section(self):
        backup = legacy.update_xkb_types_file(LAYOUT_VERSION_DIR / "xkb_types.txt", self.paths.types_extra)
        self.assertIsNotNone(backup)
        self.assert_type_inside_section()

    def test_uninstall_restores_the_desktop_users_compose_file(self):
        """Under sudo, ``Path.home()`` is root's home; the backup lives in the
        desktop user's home, which the sandbox override stands in for."""
        (self.home / ".XCompose").write_text("ergopti compose\n", encoding="utf-8")
        (self.home / ".XCompose.1").write_text("user compose\n", encoding="utf-8")
        with mock.patch.dict(os.environ, self.env, clear=False), mock.patch.object(
            legacy, "purge_cache"
        ):
            self.assertTrue(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual((self.home / ".XCompose").read_text(encoding="utf-8"), "user compose\n")

    def test_uninstall_after_a_package_upgrade_keeps_the_new_system_file(self):
        """A distribution upgrade of xkeyboard-config replaces ``types/extra``
        with its own pristine copy; restoring the older ``.1`` backup over it
        would downgrade the file. Only the stale backups may go."""
        pristine = self.paths.types_extra.read_bytes()
        backup = legacy.update_xkb_types_file(LAYOUT_VERSION_DIR / "xkb_types.txt", self.paths.types_extra)
        self.assertIsNotNone(backup)
        upgraded = pristine + b"\n// upgraded by the package manager\n"
        self.paths.types_extra.write_bytes(upgraded)
        with mock.patch.dict(os.environ, self.env, clear=False), mock.patch.object(
            legacy, "purge_cache"
        ):
            self.assertTrue(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual(self.paths.types_extra.read_bytes(), upgraded)
        self.assertFalse(backup.exists(), "the stale backup must not linger")

    def test_the_lst_edit_only_rewrites_the_variant_section(self):
        """A leftover line with the same name in another section must not be
        turned into the variant entry: desktops read variants from the
        ``! variant`` section only."""
        self.paths.evdev_lst.write_text(
            "! layout\n  fr              French\n  Ergopti_v2_2_1  Ergopti (stale layout entry)\n"
            "\n! variant\n  oss             fr: French (alt.)\n\n! option\n",
            encoding="utf-8",
        )
        legacy.update_lst_file(self.paths.evdev_lst, "Ergopti_v2_2_1", "Français — Ergopti")
        content = self.paths.evdev_lst.read_text(encoding="utf-8")
        layout_section = content[: content.index("! variant")]
        variant_section = content[content.index("! variant") : content.index("! option")]
        self.assertIn("Ergopti (stale layout entry)", layout_section)
        self.assertIn("Ergopti_v2_2_1  fr: Français — Ergopti", variant_section)
        self.assertEqual(variant_section.count("Ergopti_v2_2_1"), 1)
        # Re-registering updates the variant line in place.
        legacy.update_lst_file(self.paths.evdev_lst, "Ergopti_v2_2_1", "Français — Ergopti v2")
        content = self.paths.evdev_lst.read_text(encoding="utf-8")
        self.assertEqual(content.count("Ergopti_v2_2_1"), 2)
        self.assertIn("Ergopti v2", content)

    def test_install_removes_a_conflicting_clean_package(self):
        package = self.extensions_root / "ergopti" / "symbols"
        package.mkdir(parents=True)
        (package / "ergopti").write_text("clean", encoding="utf-8")
        with mock.patch.dict(os.environ, self.env, clear=False):
            legacy.remove_conflicting_clean_package(self.roots())
        self.assertFalse((self.extensions_root / "ergopti").exists())


if __name__ == "__main__":
    unittest.main()

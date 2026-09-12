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

import errno
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

    def test_partial_system_writes_restore_every_target_and_preserve_backup_history(self):
        for target_index in range(4):
            for existing_history in (False, True):
                for interruption in (False, True):
                    with self.subTest(target=target_index, history=existing_history, interruption=interruption):
                        fixture = LegacyInstallerSandboxTests()
                        fixture.setUp()
                        try:
                            targets = list(fixture.paths.touched())
                            target = targets[target_index]
                            if existing_history:
                                for path in targets:
                                    path.with_name(path.name + ".1").write_bytes(b"older installation backup\n")
                            previous_backups = {
                                backup: backup.read_bytes()
                                for path in targets for backup in legacy.find_backups(path)
                            }
                            original_write = Path.write_text
                            original_xml_write = legacy.ET.ElementTree.write

                            def fail_write():
                                original_write(target, "", encoding="utf-8")
                                if interruption:
                                    raise KeyboardInterrupt("injected interruption after truncation")
                                raise OSError(errno.ENOSPC, "injected full filesystem after truncation")

                            def write_text(path, content, *args, **kwargs):
                                if path == target:
                                    fail_write()
                                return original_write(path, content, *args, **kwargs)

                            def write_xml(tree, file, *args, **kwargs):
                                if Path(file) == target:
                                    fail_write()
                                return original_xml_write(tree, file, *args, **kwargs)

                            expected_error = KeyboardInterrupt if interruption else legacy.LegacyInstallError
                            with mock.patch.dict(os.environ, fixture.env), mock.patch.object(
                                Path, "write_text", write_text
                            ), mock.patch.object(legacy.ET.ElementTree, "write", write_xml), mock.patch.object(
                                legacy, "compile_check"
                            ) as compiler:
                                with self.assertRaises(expected_error):
                                    legacy.perform_install(
                                        fixture.roots(), LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb",
                                        None, LAYOUT_VERSION_DIR / "xkb_types.txt",
                                    )
                                compiler.assert_not_called()
                            for path, original in fixture.originals.items():
                                self.assertEqual(path.read_bytes(), original, f"{path.name}: partial write survived rollback")
                            remaining_backups = {
                                backup: backup.read_bytes()
                                for path in targets for backup in legacy.find_backups(path)
                            }
                            self.assertEqual(remaining_backups, previous_backups)
                        finally:
                            fixture.tearDown()

    def test_failed_backup_copy_does_not_publish_a_truncated_pristine_backup(self):
        target = self.paths.symbols_fr
        journal = []

        def fail_copy(source, destination):
            Path(destination).write_bytes(b"partial backup")
            raise OSError(errno.ENOSPC, "injected partial backup copy")

        with mock.patch.object(legacy.shutil, "copy", fail_copy):
            with self.assertRaises(legacy.LegacyInstallError):
                legacy.backup_file(target, journal)
        self.assertEqual(target.read_bytes(), self.originals[target])
        self.assertEqual(journal, [])
        self.assertEqual(legacy.find_backups(target), [], "a partial .1 must never become the pristine backup")
        self.assertEqual(list(target.parent.glob(".*.ergopti-backup-*")), [])

    def test_backup_publication_preserves_a_concurrently_claimed_number(self):
        target = self.paths.symbols_fr
        first = target.with_name(target.name + ".1")
        journal = []
        original_link = os.link
        attempts = []

        def claim_first_number(source, destination):
            attempts.append(destination)
            if len(attempts) == 1:
                first.write_bytes(b"concurrent owner backup\n")
            return original_link(source, destination)

        with mock.patch.object(legacy.os, "link", claim_first_number):
            backup = legacy.backup_file(target, journal)
        self.assertEqual(attempts, [first, target.with_name(target.name + ".2")])
        self.assertEqual(first.read_bytes(), b"concurrent owner backup\n")
        self.assertEqual(backup.read_bytes(), self.originals[target])
        self.assertEqual(journal, [(target, backup)])
        self.assertEqual(list(target.parent.glob(".*.ergopti-backup-*")), [])

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

    @unittest.skipIf(sys.platform == "win32", "the legacy CLI refuses to run on Windows")
    def test_uninstall_refusal_reaches_the_cli_exit_code(self):
        with mock.patch.dict(os.environ, self.env), mock.patch.object(
            legacy, "deactivate_desktop_entries", return_value=legacy.CleanupStatus.FAILED
        ):
            self.assertNotEqual(legacy.main(["--uninstall"]), legacy.EXIT_OK)
        for path, original in self.originals.items():
            self.assertEqual(path.read_bytes(), original)

    def test_uninstall_restore_failure_keeps_the_backup_and_reports_failure(self):
        for path in self.paths.touched():
            path.with_name(path.name + ".1").write_bytes(self.originals[path])
            path.write_bytes(self.originals[path] + b"\n// Ergopti installation\n")
        failed_target = self.paths.types_extra
        original_copy = legacy.shutil.copy

        def fail_one_restore(source, destination):
            if destination == failed_target:
                raise OSError(errno.EACCES, "injected restore refusal")
            return original_copy(source, destination)

        with mock.patch.dict(os.environ, self.env), mock.patch.object(
            legacy.shutil, "copy", fail_one_restore
        ):
            self.assertFalse(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual(failed_target.with_name(failed_target.name + ".1").read_bytes(), self.originals[failed_target])
        self.assertIn(b"Ergopti", failed_target.read_bytes())
        with mock.patch.dict(os.environ, self.env):
            self.assertTrue(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual(failed_target.read_bytes(), self.originals[failed_target])

    def test_unreadable_system_file_does_not_erase_its_recovery_backup(self):
        target = self.paths.types_extra
        backup = target.with_name(target.name + ".1")
        backup.write_bytes(self.originals[target])
        target.write_bytes(self.originals[target] + b"\n// Ergopti installation\n")
        original_read = Path.read_text

        def refuse_target_read(path, *args, **kwargs):
            if path == target:
                raise OSError(errno.EACCES, "injected unreadable system file")
            return original_read(path, *args, **kwargs)

        with mock.patch.dict(os.environ, self.env), mock.patch.object(Path, "read_text", refuse_target_read):
            self.assertFalse(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual(backup.read_bytes(), self.originals[target])
        with mock.patch.dict(os.environ, self.env):
            self.assertTrue(legacy.uninstall_legacy(self.roots(), deactivate_desktop=False))
        self.assertEqual(target.read_bytes(), self.originals[target])

    @unittest.skipIf(sys.platform == "win32", "the legacy CLI refuses to run on Windows")
    def test_migration_retires_the_clean_package_only_after_legacy_verification(self):
        for failure in ("missing-system-file", "malformed-registry", "compiler-rejection", None):
            with self.subTest(failure=failure):
                fixture = LegacyInstallerSandboxTests()
                fixture.setUp()
                try:
                    package = fixture.extensions_root / "ergopti"
                    (package / "symbols").mkdir(parents=True)
                    previous = package / "symbols" / "ergopti"
                    previous.write_bytes(b"previous clean package\n")
                    if failure == "missing-system-file":
                        fixture.paths.symbols_fr.unlink()
                    elif failure == "malformed-registry":
                        fixture.paths.evdev_xml.write_text("<invalid", encoding="utf-8")
                    before = {path: path.read_bytes() for path in fixture.paths.touched() if path.exists()}
                    arguments = [
                        "--xkb", str(LAYOUT_VERSION_DIR / "Ergopti_v2_2_1.xkb"),
                        "--types", str(LAYOUT_VERSION_DIR / "xkb_types.txt"), "--skip-activation",
                    ]
                    with mock.patch.dict(os.environ, fixture.env), mock.patch.object(
                        legacy, "compile_check", return_value=failure != "compiler-rejection"
                    ) as compiler:
                        code = legacy.main(arguments)
                    if failure is None:
                        self.assertEqual(code, 0)
                        compiler.assert_called_once()
                        self.assertFalse(package.exists())
                        fixture.assert_type_inside_section()
                    else:
                        self.assertNotEqual(code, 0)
                        self.assertTrue(previous.exists(), "failed migration removed the prior clean package")
                        self.assertEqual(previous.read_bytes(), b"previous clean package\n")
                        for path, content in before.items():
                            self.assertEqual(path.read_bytes(), content)
                finally:
                    fixture.tearDown()


if __name__ == "__main__":
    unittest.main()

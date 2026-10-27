# tools/test/linux_uninstall_transaction_test.py

"""Exercise real installed uninstall rollback without touching a user prefix."""

import errno
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
DRIVER = ROOT / "static/ergopti_plus/linux"
FAULT_TOOLS = r"""#!/bin/bash
set -eu
program="${0##*/}"
last="${!#}"
case "$program:$ERGOPTI_TEST_FAULT" in
    mktemp:allocation-refusal)
        if [ "$1" = -d ]; then printf '%s\n' "$ERGOPTI_TEST_FOREIGN"; exit 73; fi ;;
    mktemp:restore-allocation-refusal)
        if [[ "$last" == */.ergopti-restore.* ]]; then printf '%s\n' "$ERGOPTI_TEST_FOREIGN"; exit 74; fi ;;
    cp:snapshot-refusal|cp:snapshot-corrupt)
        if [[ "$last" == */.ergopti-uninstall.*/* ]]; then
            if [ "$ERGOPTI_TEST_FAULT" = snapshot-refusal ]; then exit 76; fi
            /bin/cp "$@"
            printf 'corrupted snapshot\n' >> "$last"
            exit 0
        fi ;;
    rm:cleanup-refusal)
        if [ "$1" = -rf ] && [[ "$last" == */.ergopti-uninstall.* ]]; then
            printf 'cleanup\n' >> "$ERGOPTI_TEST_CALLS"
            exit 75
        fi ;;
    rm:manifest-refusal|rm:rollback-refusal)
        if [ "$last" = "$ERGOPTI_TEST_MANIFEST" ]; then exit 73; fi ;;
    find:catalog-refusal)
        if [ "$last" = -print0 ]; then /bin/find "$@"; exit 73; fi ;;
    stat:mode-refusal) exit 74 ;;
    ln:rollback-refusal)
        if [ "$last" = "$ERGOPTI_TEST_RUNTIME" ]; then exit 74; fi ;;
esac
if [ "$program" = rm ] && [ "$last" = "$ERGOPTI_TEST_LOCALE" ]; then
    case "$ERGOPTI_TEST_FAULT" in
        payload-refusal|mode-refusal|restore-allocation-refusal) exit 73 ;;
        incumbent-file) printf 'foreign incumbent\n' > "$ERGOPTI_TEST_RUNTIME"; exit 73 ;;
        incumbent-directory) /bin/mkdir "$ERGOPTI_TEST_RUNTIME"; exit 73 ;;
        incumbent-link) /bin/ln -s "$ERGOPTI_TEST_FOREIGN" "$ERGOPTI_TEST_RUNTIME"; exit 73 ;;
    esac
fi
exec "/bin/$program" "$@"
"""


def digest(contents):
    """Return the canonical ownership digest of native file bytes."""
    return hashlib.sha256(contents).hexdigest()


class UninstallTransactionTests(unittest.TestCase):
    """Keep failures, recovery copies and installed retry in one private fixture."""

    def setUp(self):
        self.assertNotEqual(os.geteuid(), 0, "native permission refusal needs a nonroot user")
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-uninstall-transaction-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.prefix = self.home / "prefix"
        self.library = self.prefix / "lib/ergopti"
        self.runtime = self.library / "linux/ergopti_hotstrings.lua"
        self.locale = self.library / "_shared/data/locales/en.json"
        self.wrapper = self.prefix / "bin/ergopti-hotstrings"
        self.manifest = self.library / ".ergopti-owned-files"
        self.installed = self.library / "linux/uninstall.sh"
        source = self.root / "source"
        for relative in ["uninstall.sh", "install/config_home.sh", "install/desktop_entry.sh"]:
            destination = source / "linux" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(DRIVER / relative, destination)
        (source / "linux/ergopti_hotstrings.lua").write_bytes(b"-- shipped runtime\n")
        (source / "linux/ergopti_hotstrings.lua").chmod(0o751)
        (source / "linux/modified.lua").write_bytes(b"-- original shipped bytes\n")
        (source / "_shared/data/locales").mkdir(parents=True)
        (source / "_shared/data/locales/en.json").write_bytes(b'{"en":"English"}\n')
        shutil.copytree(source / "linux", self.library / "linux")
        shutil.copytree(source / "_shared", self.library / "_shared")
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_text(
            '#!/bin/bash\nDRIVER_ROOT="' + str(self.library) + '/linux"\n'
            'exec luajit "${DRIVER_ROOT}/ergopti_hotstrings.lua" "$@"\n'
        )
        self.wrapper.chmod(0o750)
        writer = subprocess.run(
            [
                "/bin/bash",
                str(DRIVER / "install/ownership.sh"),
                str(source / "linux"),
                str(source / "_shared"),
                str(self.library),
            ],
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(writer.returncode, 0, writer.stderr)
        with self.manifest.open("ab") as receipt:
            receipt.write((digest(self.wrapper.read_bytes()) + "\t@wrapper\n").encode())
        self.manifest.chmod(0o640)
        self.modified = self.library / "linux/modified.lua"
        self.modified.write_bytes(b"-- personal modified payload\n")
        self.personal = self.home / ".config/ergopti_plus/personal.toml"
        self.personal.parent.mkdir(parents=True)
        self.personal.write_bytes(b'personal="keep"\n')
        self.foreign = self.prefix / "lib/another-app/keep"
        self.foreign.parent.mkdir()
        self.foreign.write_bytes(b"foreign application bytes\n")
        self.unknown = self.library / "personal.txt"
        self.unknown.write_bytes(b"unlisted personal bytes\n")
        self.tools = self.root / "fault-tools"
        self.tools.mkdir()
        for name in ["rm", "cp", "ln", "mktemp", "stat", "find"]:
            program = self.tools / name
            program.write_text(FAULT_TOOLS)
            program.chmod(0o755)
        self.calls = self.root / "calls"
        self.before = self.files()
        self.keep = {
            path: (path.read_bytes(), path.stat().st_ino)
            for path in [self.personal, self.foreign, self.modified, self.unknown]
        }

    def tearDown(self):
        if self.locale.parent.exists():
            self.locale.parent.chmod(0o755)
        self.temporary.cleanup()

    def files(self):
        """Compare bytes and modes while allowing restored files to get new inodes."""
        return {
            str(path.relative_to(self.home)): (
                digest(path.read_bytes()),
                path.stat().st_mode & 0o777,
            )
            for path in self.home.rglob("*")
            if path.is_file() and not path.is_symlink()
        }

    def run_installed(self, fault=None, foreign=None, action="--yes", config_home=None):
        """Execute the actual installed script with only named fault ports replaced."""
        if config_home is None:
            config_home = self.home / ".config"
        environment = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(config_home),
            "PATH": (str(self.tools) + ":" if fault else "") + "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "ERGOPTI_TEST_FAULT": fault or "",
            "ERGOPTI_TEST_RUNTIME": str(self.runtime),
            "ERGOPTI_TEST_LOCALE": str(self.locale),
            "ERGOPTI_TEST_MANIFEST": str(self.manifest),
            "ERGOPTI_TEST_FOREIGN": str(foreign or self.foreign),
            "ERGOPTI_TEST_CALLS": str(self.calls),
        }
        result = subprocess.run(
            ["/bin/bash", str(self.installed), "--prefix", str(self.prefix), action],
            cwd=self.root,
            env=environment,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertGreaterEqual(result.returncode, 0, "uninstall must finish without a signal")
        return result

    def assert_personal_untouched(self):
        """Unknown and modified files retain both exact bytes and original inodes."""
        for path, (contents, inode) in self.keep.items():
            self.assertEqual(path.read_bytes(), contents)
            self.assertEqual(path.stat().st_ino, inode)

    def assert_clean_recovery(self):
        """Ordinary rollback removes its complete private snapshots."""
        self.assertEqual(list(self.library.glob(".ergopti-uninstall.*")), [])

    def assert_retained_recovery(self):
        """Every retained numeric snapshot has a durable original path and digest."""
        stages = list(self.library.glob(".ergopti-uninstall.*"))
        self.assertEqual(len(stages), 1)
        stage = stages[0]
        paths = (stage / "paths").read_bytes().split(b"\0")
        self.assertEqual(paths.pop(), b"")
        digests = (stage / "digests").read_text().splitlines()
        self.assertGreater(len(paths), 4)
        self.assertEqual(len(paths), len(digests))
        expected_paths = {
            os.fsencode(path)
            for path in [
                self.runtime,
                self.locale,
                self.wrapper,
                self.manifest,
                self.installed,
                self.library / "linux/install/config_home.sh",
                self.library / "linux/install/desktop_entry.sh",
            ]
        }
        self.assertEqual(
            set(paths), expected_paths, "recovery paths must match independently known originals"
        )
        for index, (original, recorded_digest) in enumerate(zip(paths, digests)):
            relative = str(Path(os.fsdecode(original)).relative_to(self.home))
            expected_digest, expected_mode = self.before[relative]
            snapshot = stage / str(index)
            self.assertEqual(recorded_digest, expected_digest)
            self.assertEqual(digest(snapshot.read_bytes()), expected_digest)
            self.assertEqual(snapshot.stat().st_mode & 0o777, expected_mode)
        runtime_index = paths.index(os.fsencode(self.runtime))
        self.assertEqual((stage / str(runtime_index)).stat().st_mode & 0o777, 0o751)
        self.assertEqual((stage / str(runtime_index)).read_bytes(), b"-- shipped runtime\n")
        return stage

    def assert_successful_retry(self, config_home=None):
        """The documented installed command works after the refusal is repaired."""
        result = self.run_installed(config_home=config_home)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in [self.runtime, self.locale, self.wrapper, self.manifest, self.installed]:
            self.assertFalse(path.exists(), str(path))
        self.assert_personal_untouched()
        self.assert_clean_recovery()

    def test_native_permission_failure_restores_installed_script_and_retry(self):
        self.locale.parent.chmod(0o555)
        refused = self.run_installed()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn(b"Permission denied", refused.stderr)
        self.assertEqual(
            self.files(),
            self.before,
            "(uninstall-unlink-rollback) restore every removed owned file",
        )
        self.assert_personal_untouched()
        self.assert_clean_recovery()
        self.locale.parent.chmod(0o755)
        self.assert_successful_retry()

    def test_unsearchable_owned_tree_refuses_before_mutation(self):
        source = self.root / "source"
        source_hidden = source / "linux/unsearchable/owned.lua"
        source_hidden.parent.mkdir()
        source_hidden.write_bytes(b"-- additional owned payload\n")
        hidden = self.library / "linux/unsearchable/owned.lua"
        hidden.parent.mkdir()
        shutil.copy2(source_hidden, hidden)
        writer = subprocess.run(
            [
                "/bin/bash",
                str(DRIVER / "install/ownership.sh"),
                str(source / "linux"),
                str(source / "_shared"),
                str(self.library),
            ],
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(writer.returncode, 0, writer.stderr)
        with self.manifest.open("ab") as receipt:
            receipt.write((digest(self.wrapper.read_bytes()) + "\t@wrapper\n").encode())
        self.manifest.chmod(0o640)
        original = self.files()
        hidden_relative = str(hidden.relative_to(self.home))
        hidden.parent.chmod(0o000)
        try:
            for action in ["--check", "--yes"]:
                result = self.run_installed(action=action)
                self.assertIn(b"Permission denied", result.stderr)
                self.assertNotEqual(
                    result.returncode,
                    0,
                    "(uninstall-tree-admission) an unreadable owned subtree cannot authorize removal",
                )
                self.assertIn(b"code=scan-refused", result.stderr)
                for relative, expected in original.items():
                    if relative == hidden_relative:
                        continue
                    path = self.home / relative
                    self.assertTrue(path.is_file(), relative)
                    self.assertEqual(
                        (digest(path.read_bytes()), path.stat().st_mode & 0o777), expected
                    )
                self.assert_personal_untouched()
                self.assert_clean_recovery()
        finally:
            hidden.parent.chmod(0o755)
        self.assertEqual(self.files(), original)
        self.assert_successful_retry()
        self.assertFalse(hidden.exists(), "the repaired ordinary owned file must be removed")

    def test_external_parent_catalog_refuses_hidden_owned_startup(self):
        config_home = self.home / "config\\literal\nlinefeed$(touch catalog-executed)"
        unit = config_home / "systemd/user/ergopti-hotstrings.service"
        unit.parent.mkdir(parents=True)
        command = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; ergopti_systemd_exec "$2"',
                "service-owner",
                str(DRIVER / "install/desktop_entry.sh"),
                str(self.wrapper),
            ],
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(command.returncode, 0, command.stderr)
        unit.write_bytes(b"[Service]\n" + command.stdout)
        unit.chmod(0o640)
        with self.manifest.open("ab") as receipt:
            receipt.write((digest(unit.read_bytes()) + "\t@unit\n").encode())
        original = self.files()
        unit_relative = str(unit.relative_to(self.home))
        unit_inode = unit.stat().st_ino
        for denied_parent in [unit.parent, config_home]:
            denied_parent.chmod(0o000)
            try:
                with self.assertRaises(PermissionError) as denied:
                    unit.lstat()
                self.assertEqual(denied.exception.errno, errno.EACCES)
                for action in ["--check", "--yes"]:
                    result = self.run_installed(action=action, config_home=config_home)
                    self.assertFalse((self.root / "catalog-executed").exists())
                    self.assertNotEqual(
                        result.returncode,
                        0,
                        "(uninstall-parent-admission) a hidden owned startup source cannot be absence",
                    )
                    self.assertIn(b"code=invalid-source", result.stderr)
                    for relative, expected in original.items():
                        if relative == unit_relative:
                            continue
                        path = self.home / relative
                        self.assertTrue(path.is_file(), relative)
                        self.assertEqual(
                            (digest(path.read_bytes()), path.stat().st_mode & 0o777), expected
                        )
                    self.assert_personal_untouched()
                    self.assert_clean_recovery()
            finally:
                denied_parent.chmod(0o755)
        self.assertEqual(self.files(), original)
        self.assertEqual(unit.stat().st_ino, unit_inode)
        # Complete-looking stdout cannot replace the actual scanner's failed status.
        for action in ["--check", "--yes"]:
            result = self.run_installed("catalog-refusal", action=action, config_home=config_home)
            self.assertEqual(
                result.returncode, 73, "the actual scanner failure must remain explicit"
            )
            self.assertIn(b"code=invalid-source", result.stderr)
            self.assertEqual(self.files(), original)
            self.assert_personal_untouched()
            self.assert_clean_recovery()
        self.assert_successful_retry(config_home=config_home)
        self.assertFalse((self.root / "catalog-executed").exists())
        self.assertFalse(unit.exists(), "the repaired owned startup source must be removed")

    def test_payload_unlink_failure_restores_all_bytes_and_modes(self):
        result = self.run_installed("payload-refusal")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.files(), self.before)
        self.assert_clean_recovery()
        self.assert_successful_retry()

    def test_manifest_unlink_failure_restores_payload_and_receipt(self):
        result = self.run_installed("manifest-refusal")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.files(), self.before)
        self.assert_clean_recovery()
        self.assert_successful_retry()

    def test_failed_allocator_stdout_cannot_authorize_foreign_cleanup(self):
        result = self.run_installed("allocation-refusal", self.foreign.parent)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.files(), self.before)
        self.assert_personal_untouched()
        self.assert_clean_recovery()

    def test_snapshot_copy_failure_precedes_all_unlinks(self):
        result = self.run_installed("snapshot-refusal")
        self.assertEqual(result.returncode, 76, result.stderr)
        self.assertEqual(self.files(), self.before)
        self.assert_clean_recovery()

    def test_corrupt_snapshot_refuses_before_all_unlinks(self):
        result = self.run_installed("snapshot-corrupt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"code=snapshot-refused", result.stderr)
        self.assertEqual(self.files(), self.before)
        self.assert_clean_recovery()

    def test_rollback_link_refusal_retains_complete_recovery(self):
        result = self.run_installed("rollback-refusal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"code=rollback-failed", result.stderr)
        self.assertIn(b"code=recovery-retained", result.stderr)
        self.assertFalse(self.runtime.exists())
        self.assertTrue(
            self.wrapper.exists(),
            "the final wrapper record must restore after a refused runtime restore",
        )
        self.assert_retained_recovery()
        self.assert_personal_untouched()

    def test_rollback_preserves_foreign_file_directory_and_link(self):
        for kind in ["file", "directory", "link"]:
            with self.subTest(kind=kind):
                result = self.run_installed("incumbent-" + kind)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"code=recovery-retained", result.stderr)
                if kind == "file":
                    self.assertEqual(self.runtime.read_bytes(), b"foreign incumbent\n")
                elif kind == "directory":
                    self.assertTrue(self.runtime.is_dir())
                    self.assertEqual(list(self.runtime.iterdir()), [])
                else:
                    self.assertTrue(self.runtime.is_symlink())
                    self.assertEqual(self.runtime.readlink(), self.foreign)
                stage = self.assert_retained_recovery()
                self.assert_personal_untouched()
                # Restore only this owned test fixture between independent fault ports.
                if kind == "directory":
                    self.runtime.rmdir()
                else:
                    self.runtime.unlink()
                paths = (stage / "paths").read_bytes().split(b"\0")[:-1]
                shutil.copy2(stage / str(paths.index(os.fsencode(self.runtime))), self.runtime)
                shutil.rmtree(stage)

    def test_unverified_incumbent_mode_retains_recovery(self):
        result = self.run_installed("mode-refusal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"code=recovery-retained", result.stderr)
        self.assert_retained_recovery()
        self.assert_personal_untouched()

    def test_restore_allocation_failure_preserves_foreign_stdout_path(self):
        result = self.run_installed("restore-allocation-refusal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"code=recovery-retained", result.stderr)
        self.assert_retained_recovery()
        self.assert_personal_untouched()

    def test_postcommit_cleanup_is_attempted_once_and_retains_snapshot(self):
        result = self.run_installed("cleanup-refusal")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"code=cleanup-failed", result.stderr)
        self.assertEqual(self.calls.read_bytes(), b"cleanup\n")
        for path in [self.runtime, self.locale, self.wrapper, self.manifest, self.installed]:
            self.assertFalse(path.exists(), "postcommit cleanup failure cannot claim rollback")
        self.assert_retained_recovery()
        self.assert_personal_untouched()


if __name__ == "__main__":
    unittest.main(verbosity=2)

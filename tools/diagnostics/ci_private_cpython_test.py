# tools/diagnostics/ci_private_cpython_test.py
"""Actual private CPython/stdlib execution and explicit native ownership models.

Portable direct-child execution proves standard venv copying on this host. It
does not admit Darwin WNOWAIT, libproc, Mach-O loading or native group census.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

import ci_private_cpython as source


class PrivateCPythonControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.parent = self.root / "private-parent"
        self.parent.mkdir(mode=0o700)
        inputs = self.root / "inputs"
        inputs.mkdir(mode=0o700)
        for name in ("ci_private_cpython.py", "macos_owned_process.py"):
            shutil.copyfile(Path(source.__file__).with_name(name), inputs / name)
            (inputs / name).chmod(0o600)
        path = inputs / "ci_private_cpython.py"
        self.subject = types.ModuleType("private_test_subject")
        self.subject.__file__ = str(path)
        exec(compile(path.read_bytes(), str(path), "exec"), self.subject.__dict__)
        self.real_base = Path(sys._base_executable).resolve(strict=True)
        self.base_before = source.identity(self.real_base.stat())
        self.base_hash = hashlib.sha256(self.real_base.read_bytes()).hexdigest()
        self.effect = lambda _arguments: None
        self.calls = []

    def actual_direct_child(self, arguments, _owned, stdout, stderr, deadline):
        """Execute the real copied interpreter, with ordinary direct-child reaping."""
        self.calls.append(arguments)
        completed = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            timeout=deadline - time.monotonic(),
        )
        self.assertEqual(completed.returncode, 0)
        self.effect(arguments)
        return {
            "kind": "actual_portable_direct_child",
            "native_group_census": False,
            "platform": sys.platform,
            "closed": True,
        }

    def prepare(self):
        return self.subject.prepare(self.parent, smoke=self.actual_direct_child)

    def receipt(self):
        return next(self.parent.glob("cpython-*/selection.json"))

    def unchanged_base(self):
        self.assertEqual(source.identity(self.real_base.stat()), self.base_before)
        self.assertEqual(hashlib.sha256(self.real_base.read_bytes()).hexdigest(), self.base_hash)

    def test_actual_standard_copies_execute_same_cpython_and_stdlib(self):
        selected = Path(self.prepare())
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][:4], [str(selected / "python3"), "-I", "-B", "-c"])
        packet = json.loads(self.receipt().read_bytes())
        self.assertFalse(packet["authority_granted"])
        self.assertFalse(packet["ownership"]["native_group_census"])
        self.assertEqual(packet["original_image_sha256"], self.base_hash)
        self.assertEqual(packet["smoke"]["version"], list(sys.version_info[:3]))
        self.assertEqual(packet["smoke"]["base_prefix"], sys.base_prefix)
        self.assertEqual(packet["smoke"]["stdlib"], source.sysconfig.get_path("stdlib"))
        self.assertEqual(packet["smoke"]["nonreaping_apis"], list(source.WAIT_NAMES))
        self.assertEqual(stat.S_IMODE(selected.parent.stat().st_mode), 0o700)
        for name in (
            "python",
            "python3",
            f"python{sys.version_info.major}.{sys.version_info.minor}",
        ):
            info = (selected / name).lstat()
            self.assertTrue(stat.S_ISREG(info.st_mode))
            self.assertEqual(info.st_uid, os.geteuid())
            self.assertEqual(info.st_nlink, 1)
            self.assertEqual(info.st_mode & 0o022, 0)
            self.assertEqual(
                hashlib.sha256((selected / name).read_bytes()).hexdigest(),
                self.base_hash,
            )
        self.unchanged_base()

    def test_genuine_mode775_copy_only_is_restricted_and_original_remains_exact(self):
        copied = self.root / "genuine-copied-interpreter"
        shutil.copyfile(self.real_base, copied)
        copied.chmod(0o775)
        before = copied.stat()
        original = self.subject.PinnedFile(self.real_base, source.MAX_IMAGE_BYTES, bootstrap=True)
        try:
            self.subject.restrict_copy(copied, original)
            after = copied.stat()
            self.assertEqual((before.st_dev, before.st_ino), (after.st_dev, after.st_ino))
            self.assertEqual(stat.S_IMODE(after.st_mode), 0o755)
            self.assertEqual(copied.read_bytes(), original.body)
            original.current()
        finally:
            original.close()
        self.unchanged_base()

    def test_copy_alias_is_refused_without_changing_target_permissions(self):
        copied = self.root / "image"
        shutil.copyfile(self.real_base, copied)
        copied.chmod(0o775)
        alias = self.root / "alias"
        alias.symlink_to(copied)
        original = self.subject.PinnedFile(self.real_base, source.MAX_IMAGE_BYTES, bootstrap=True)
        try:
            with self.assertRaises(OSError):
                self.subject.restrict_copy(alias, original)
        finally:
            original.close()
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o775)

    def test_copy_hardlink_is_refused_without_changing_linked_image(self):
        copied = self.root / "image"
        shutil.copyfile(self.real_base, copied)
        copied.chmod(0o775)
        os.link(copied, self.root / "linked")
        original = self.subject.PinnedFile(self.real_base, source.MAX_IMAGE_BYTES, bootstrap=True)
        try:
            with self.assertRaisesRegex(ValueError, "ordinary file"):
                self.subject.restrict_copy(copied, original)
        finally:
            original.close()
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o775)

    def test_copy_different_bytes_are_refused_before_permission_change(self):
        copied = self.root / "image"
        copied.write_bytes(b"different executable bytes")
        copied.chmod(0o775)
        original = self.subject.PinnedFile(self.real_base, source.MAX_IMAGE_BYTES, bootstrap=True)
        try:
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                self.subject.restrict_copy(copied, original)
        finally:
            original.close()
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o775)

    def test_source_alias_parent_and_source_hardlink_are_refused(self):
        file = self.root / "ordinary"
        file.write_bytes(b"independent bytes")
        file.chmod(0o600)
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "parent alias"):
            self.subject.PinnedFile(alias / file.name, 100)
        os.link(file, self.root / "linked")
        with self.assertRaisesRegex(ValueError, "ordinary file"):
            self.subject.PinnedFile(file, 100)

    def test_held_image_replacement_is_refused(self):
        file = self.root / "ordinary"
        file.write_bytes(b"independent bytes")
        file.chmod(0o600)
        held = self.subject.PinnedFile(file, 100)
        try:
            replacement = self.root / "replacement"
            replacement.write_bytes(held.body)
            replacement.chmod(0o600)
            replacement.replace(file)
            with self.assertRaisesRegex(ValueError, "held input changed"):
                held.current()
        finally:
            held.close()

    def test_held_image_in_place_change_is_refused(self):
        file = self.root / "ordinary"
        file.write_bytes(b"independent bytes")
        file.chmod(0o600)
        held = self.subject.PinnedFile(file, 100)
        try:
            file.write_bytes(b"independEnt bytes")
            with self.assertRaisesRegex(ValueError, "held input changed"):
                held.current()
        finally:
            held.close()

    def test_private_parent_alias_is_refused_before_child_execution(self):
        alias = self.root / "alias"
        alias.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "directory alias"):
            self.subject.prepare(alias, smoke=self.actual_direct_child)
        self.assertEqual(self.calls, [])

    def test_parent_mode755_is_refused_before_venv_creation(self):
        self.parent.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "directory owner"):
            self.prepare()
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assertEqual(self.calls, [])

    def test_copied_binary_replacement_after_real_smoke_prevents_selection(self):
        def replace(arguments):
            file = Path(arguments[0])
            replacement = file.with_name("replacement")
            shutil.copyfile(file, replacement)
            replacement.chmod(0o755)
            replacement.replace(file)

        self.effect = replace
        with self.assertRaisesRegex(ValueError, "held input changed"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])
        self.unchanged_base()

    def test_current_setup_source_change_after_real_smoke_prevents_selection(self):
        def change(_arguments):
            file = Path(self.subject.__file__)
            file.write_bytes(file.read_bytes() + b"\n# source changed after acquisition\n")

        self.effect = change
        with self.assertRaisesRegex(ValueError, "held input changed"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_current_guardian_change_after_real_smoke_prevents_selection(self):
        def change(_arguments):
            file = Path(self.subject.__file__).with_name("macos_owned_process.py")
            file.write_bytes(file.read_bytes() + b"\n# guardian changed after acquisition\n")

        self.effect = change
        with self.assertRaisesRegex(ValueError, "held input changed"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_venv_new_file_after_real_smoke_prevents_selection(self):
        self.effect = lambda args: Path(args[0]).with_name("unexpected").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_version_base_prefix_and_stdlib_mismatches_are_refused(self):
        for key in ("version", "base_prefix", "stdlib"):
            with self.subTest(key=key):

                def altered(arguments, owned, stdout, stderr, deadline):
                    ownership = self.actual_direct_child(arguments, owned, stdout, stderr, deadline)
                    stdout.flush()
                    stdout.seek(0)
                    packet = json.loads(stdout.read())
                    packet[key] = [0, 0, 0] if key == "version" else "/different-independent-value"
                    stdout.seek(0)
                    stdout.truncate()
                    stdout.write(json.dumps(packet).encode())
                    stdout.flush()
                    return ownership

                with self.assertRaisesRegex(ValueError, "runtime or stdlib differs"):
                    self.subject.prepare(self.parent, smoke=altered)
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_replaced_smoke_output_is_refused(self):
        def replace(arguments):
            file = Path(arguments[0]).parents[2] / "smoke.stdout"
            replacement = file.with_name("other.stdout")
            replacement.write_bytes(file.read_bytes())
            replacement.chmod(0o600)
            replacement.replace(file)

        self.effect = replace
        with self.assertRaisesRegex(ValueError, "smoke output replaced"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_nonempty_stderr_is_refused_even_after_successful_actual_execution(self):
        def stderr(arguments):
            (Path(arguments[0]).parents[2] / "smoke.stderr").write_bytes(b"unexpected stderr")

        self.effect = stderr
        with self.assertRaisesRegex(ValueError, "stderr refused"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_real_child_failure_prevents_selection(self):
        def failed(arguments, _owned, stdout, stderr, deadline):
            result = subprocess.run(
                arguments[:3] + ["-c", "raise SystemExit(7)"],
                stdout=stdout,
                stderr=stderr,
                timeout=deadline - time.monotonic(),
            )
            self.assertEqual(result.returncode, 7)
            raise ValueError("actual child failed")

        with self.assertRaisesRegex(ValueError, "actual child failed"):
            self.subject.prepare(self.parent, smoke=failed)
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_late_smoke_deadline_refuses_selection(self):
        def late(arguments, owned, stdout, stderr, deadline):
            result = self.actual_direct_child(arguments, owned, stdout, stderr, deadline)
            self.subject.check_deadline(deadline - source.SUCCESS_SECONDS)
            return result

        with self.assertRaisesRegex(ValueError, "deadline exhausted"):
            self.subject.prepare(self.parent, smoke=late)
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_exclusive_receipt_collision_preserves_existing_bytes(self):
        marker = b"existing independent bytes"

        def collision(arguments):
            file = Path(arguments[0]).parents[2] / "selection.json"
            file.write_bytes(marker)
            file.chmod(0o600)

        self.effect = collision
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(self.receipt().read_bytes(), marker)

    def test_late_descriptor_close_failure_prevents_selection(self):
        real = self.subject.PinnedFile.close
        failed = [False]

        def close(pin):
            real(pin)
            if pin.path.name == "selection.json" and not failed[0]:
                failed[0] = True
                raise OSError("injected late close failure")

        with mock.patch.object(self.subject.PinnedFile, "close", close):
            with self.assertRaisesRegex(OSError, "late close failure"):
                self.prepare()
        self.assertTrue(failed[0])
        self.assertTrue(self.receipt().is_file())

    def test_cli_unsupported_host_has_no_selection_stdout(self):
        with (
            mock.patch.object(self.subject.sys, "platform", "linux"),
            mock.patch.object(self.subject.sys, "argv", ["setup", str(self.parent)]),
            mock.patch("builtins.print") as printed,
        ):
            self.assertEqual(self.subject.main(), 1)
        self.assertEqual(printed.call_count, 1)
        self.assertEqual(printed.call_args.kwargs["file"], sys.stderr)
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_unknown_directory_link_never_becomes_inventory_authority(self):
        def link(arguments):
            environment = Path(arguments[0]).parents[1]
            (environment / "unknown-alias").symlink_to("lib", target_is_directory=True)

        self.effect = link
        with self.assertRaisesRegex(ValueError, "tree alias refused"):
            self.prepare()
        self.assertEqual(list(self.parent.glob("cpython-*/selection.json")), [])

    def test_standard_link_cannot_escape_to_an_external_directory(self):
        environment = self.root / "independent-standard-layout"
        environment.mkdir(mode=0o700)
        (environment / "lib").mkdir(mode=0o700)
        (environment / "lib64").symlink_to(self.parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "tree alias refused"):
            self.subject.tree_paths(environment)

    def test_standard_link_replacement_is_refused_without_traversing_it(self):
        environment = self.root / "independent-standard-layout"
        environment.mkdir(mode=0o700)
        (environment / "lib").mkdir(mode=0o700)
        link = environment / "lib64"
        link.symlink_to("lib", target_is_directory=True)
        if sys.platform == "darwin":
            with self.assertRaisesRegex(ValueError, "tree alias refused"):
                self.subject.tree_paths(environment)
        else:
            before = self.subject.tree_paths(environment)
            self.assertNotIn(link, before[0])
            self.assertNotIn(link, before[1])
            self.assertEqual(before[2][0][2], "lib")
            replacement = environment / "replacement"
            replacement.symlink_to("lib", target_is_directory=True)
            replacement.replace(link)
            self.assertNotEqual(self.subject.tree_paths(environment), before)

    def test_held_bytes_are_revalidated_after_the_final_read(self):
        file = self.root / "ordinary"
        file.write_bytes(b"independent bytes")
        file.chmod(0o600)
        held = self.subject.PinnedFile(file, 100)
        real_read = os.read
        changed = [False]

        def read(fd, amount):
            part = real_read(fd, amount)
            if fd == held.fd and part and not changed[0]:
                changed[0] = True
                file.write_bytes(held.body)
                file.chmod(0o640)
            return part

        try:
            with mock.patch.object(self.subject.os, "read", read):
                with self.assertRaisesRegex(ValueError, "held input changed"):
                    held.current()
            self.assertTrue(changed[0])
        finally:
            held.close()

    def test_bootstrap_source_change_during_copy_restriction_is_refused(self):
        original_file = self.root / "genuine-bootstrap-copy"
        copied = self.root / "genuine-runtime-copy"
        for path in (original_file, copied):
            shutil.copyfile(self.real_base, path)
            path.chmod(0o775)
        original = self.subject.PinnedFile(original_file, source.MAX_IMAGE_BYTES, bootstrap=True)
        real_chmod = os.fchmod

        def changed(fd, mode):
            real_chmod(fd, mode)
            original_file.chmod(0o755)

        try:
            with mock.patch.object(self.subject.os, "fchmod", changed):
                with self.assertRaisesRegex(ValueError, "held input changed"):
                    self.subject.restrict_copy(copied, original)
        finally:
            original.close()
        self.unchanged_base()

    def test_setup_source_alias_and_fixed_refusal_diagnostics_never_publish_path(self):
        alias = self.root / "setup-alias.py"
        alias.symlink_to(Path(self.subject.__file__))
        with mock.patch.object(self.subject, "__file__", str(alias)):
            with self.assertRaisesRegex(ValueError, "setup source alias refused"):
                self.prepare()
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.parent.iterdir()), [])

        # These endpoint-declared Darwin CLI refusals never enter native APIs.
        # Expected codes are handwritten; arbitrary exception values stay private.
        class PrivatePayload:
            def __str__(self):
                raise AssertionError("Private exception payload must not be stringified")

        class PrivateValueError(ValueError):
            pass

        cases = (
            (
                ValueError("Private CPython setup source alias refused"),
                "setup-source-alias",
            ),
            (
                ValueError("Private CPython executed runtime or stdlib differs"),
                "runtime-or-stdlib",
            ),
            (ValueError("Private CPython venv inventory changed"), "venv-inventory"),
            (ValueError("Private CPython smoke failed"), "smoke-execution"),
            (ValueError("Private CPython held input changed"), "input-currentness"),
            (ValueError("Private CPython setup deadline exhausted"), "deadline"),
            (ValueError("private unrecognized payload"), None),
            (TimeoutError("private timeout payload"), None),
            (ValueError(PrivatePayload()), None),
            (PrivateValueError("Private CPython held input changed"), None),
            (
                ValueError("Private CPython held input changed", "private extra argument"),
                None,
            ),
        )
        for failure, expected in cases:
            with self.subTest(expected=expected):
                with (
                    mock.patch.object(self.subject.sys, "platform", "darwin"),
                    mock.patch.object(self.subject.sys, "version_info", (3, 13, 0)),
                    mock.patch.object(self.subject.sys, "argv", ["setup", str(self.parent)]),
                    mock.patch.object(self.subject, "prepare", side_effect=failure),
                    mock.patch("builtins.print") as printed,
                ):
                    self.assertEqual(self.subject.main(), 1)
                self.assertEqual(printed.call_count, 1)
                self.assertEqual(printed.call_args.kwargs["file"], sys.stderr)
                message = printed.call_args.args[0]
                self.assertNotIn("private", message)
                if expected is None:
                    self.assertEqual(
                        message, "Private CPython setup refused; PATH was not selected"
                    )
                else:
                    self.assertIn("reason=" + expected, message)

    def test_setup_source_parent_alias_is_refused_before_creation_or_execution(self):
        alias = self.root / "source-parent-alias"
        alias.symlink_to(Path(self.subject.__file__).parent, target_is_directory=True)
        with mock.patch.object(self.subject, "__file__", str(alias / "ci_private_cpython.py")):
            with self.assertRaisesRegex(ValueError, "setup source alias refused"):
                self.prepare()
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.parent.iterdir()), [])


class NativeSmokeModels(unittest.TestCase):
    """Handwritten guardian endpoints, never native retirement evidence."""

    def setUp(self):
        self.events = []
        self.receipt = {
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "escaped_sessions_managed": False,
        }
        self.group = types.SimpleNamespace(process=types.SimpleNamespace(returncode=0))
        self.group.wait_for_exit = lambda timeout: self.events.append(("wait", timeout))
        self.group.settle = lambda timeout: self.events.append(("settle", timeout)) or True
        self.group.receipt = lambda: dict(self.receipt)
        self.owned = types.SimpleNamespace(
            NativeProcessGroups=lambda: "explicit-modeled-native",
            OwnedProcessInterrupted=RuntimeError,
        )

        def acquired(arguments, native, register, **options):
            self.assertEqual(arguments, ["genuine-staged-copy", "-I"])
            self.assertEqual(native, "explicit-modeled-native")
            self.assertEqual(set(options), {"stdout", "stderr"})
            register(self.group)
            self.events.append(("registered", None))
            return self.group

        self.owned.acquire_owned = acquired

    def run_smoke(self):
        return source.native_smoke(
            ["genuine-staged-copy", "-I"],
            self.owned,
            "out",
            "err",
            time.monotonic() + 25,
        )

    def test_registered_owned_group_uses_original_budgets_and_retires_before_receipt(
        self,
    ):
        result = self.run_smoke()
        self.assertEqual([name for name, _ in self.events], ["registered", "wait", "settle"])
        self.assertGreater(self.events[1][1], 0)
        self.assertLessEqual(self.events[1][1], 25)
        self.assertLessEqual(self.events[1][1], 35)
        self.assertEqual(self.events[2][1], 3)
        self.assertEqual(result, self.receipt)
        self.assertEqual(
            (source.SUCCESS_SECONDS, source.OBSERVER_SECONDS, source.RETIRE_SECONDS),
            (25, 35, 10),
        )

    def test_wait_failure_still_retires_registered_group(self):
        def failed(_timeout):
            raise TimeoutError("modeled observer failure")

        self.group.wait_for_exit = failed
        with self.assertRaisesRegex(ValueError, "smoke failed"):
            self.run_smoke()
        self.assertEqual(self.events[-1], ("settle", 3))

    def test_registration_interruption_still_retires_acquired_group(self):
        real = self.owned.acquire_owned

        def interrupted(*args, **kwargs):
            real(*args, **kwargs)
            raise self.owned.OwnedProcessInterrupted("explicit acquisition-time interruption")

        self.owned.acquire_owned = interrupted
        with self.assertRaisesRegex(ValueError, "smoke failed"):
            self.run_smoke()
        self.assertEqual(self.events[-1], ("settle", 3))

    def test_group_debt_and_failed_retirement_never_return_receipt(self):
        self.group.settle = lambda timeout: False
        with self.assertRaisesRegex(ValueError, "retirement failed"):
            self.run_smoke()

    def test_lost_reservation_live_group_or_unclosed_receipt_is_refused(self):
        for key, value in (
            ("closed", False),
            ("reservation_lost", True),
            ("live_group_members", [42]),
            ("escaped_sessions_managed", True),
        ):
            with self.subTest(key=key):
                old = self.receipt[key]
                self.receipt[key] = value
                with self.assertRaisesRegex(ValueError, "completion refused"):
                    self.run_smoke()
                self.receipt[key] = old

    def test_real_worker_status_is_not_replaced_with_success(self):
        self.group.process.returncode = 9
        with self.assertRaisesRegex(ValueError, "completion refused"):
            self.run_smoke()


if __name__ == "__main__":
    unittest.main()

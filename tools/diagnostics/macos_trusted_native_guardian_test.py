# tools/diagnostics/macos_trusted_native_guardian_test.py
"""Real bundle-shaped namespace and POSIX peer; no Darwin signature credit."""

import importlib.util
import os
from pathlib import Path
import shutil
import signal
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


@unittest.skipUnless(os.name == "posix", "Trusted native guardian is macOS-only")
class TrustedGuardianControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binary = self.root / "Native.app/Contents/MacOS/ErgoptiPlus"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"independent executable bytes")
        self.binary.chmod(0o755)
        self.platform = (
            self.root / "Native.app/Contents/Resources/static/ergopti_plus/macos/platform"
        )
        (self.platform / "network").mkdir(parents=True)
        for name in ("trusted_native_guardian.py", "suspended_image_owner.py"):
            shutil.copyfile(
                ROOT / "static/ergopti_plus/macos/platform" / name, self.platform / name
            )
        shutil.copyfile(
            SOURCE / "static/ergopti_plus/macos/platform/network/native_http.py",
            self.platform / "network/native_http.py",
        )
        self.guardian = load(
            "trusted_native_guardian", self.platform / "trusted_native_guardian.py"
        )
        self.owner = load(
            "trusted_native_guardian_owner", self.platform / "suspended_image_owner.py"
        )
        actual = self.binary.stat()
        environment = patch.dict(
            os.environ,
            {
                "ERGOPTI_LAUNCHER_EXECUTABLE": str(self.binary),
                "ERGOPTI_LAUNCHER_DEVICE": str(actual.st_dev),
                "ERGOPTI_LAUNCHER_INODE": str(actual.st_ino),
            },
        )
        environment.start()
        self.addCleanup(environment.stop)
        self.context = None
        self.addCleanup(self.close)

    def close(self):
        if self.context is not None:
            self.context.close()

    def acquire(self):
        self.context = self.guardian.TrustedNativeGuardian.acquire(
            self.binary,
            register=lambda value: setattr(self, "context", value),
            progress=lambda: None,
        )
        return self.context

    def test_exact_default_bundle_path_has_retained_readonly_binding(self):
        context = self.acquire()
        context.validate(progress=lambda: None)
        self.assertEqual(context.path, self.binary)
        self.assertFalse(os.get_inheritable(context._descriptor))
        with self.assertRaises(OSError):
            os.write(context._descriptor, b"foreign")

    def test_foreign_path_cannot_supply_outgoing_override(self):
        foreign = self.root / "foreign"
        foreign.write_bytes(b"same UI claim")
        with self.assertRaisesRegex(self.guardian.GuardianRefusal, "helper"):
            self.guardian.TrustedNativeGuardian.acquire(
                foreign, register=lambda value: None, progress=lambda: None
            )

    def test_missing_original_launcher_identity_refuses(self):
        with patch.dict(os.environ, {"ERGOPTI_LAUNCHER_INODE": "0"}):
            with self.assertRaises(Exception):
                self.acquire()

    def test_replaced_named_executable_refuses_held_original(self):
        context = self.acquire()
        held = self.binary.with_suffix(".held")
        self.binary.rename(held)
        self.binary.write_bytes(held.read_bytes())
        self.binary.chmod(0o755)
        with self.assertRaises(Exception):
            context.validate(progress=lambda: None)
        self.assertEqual(os.pread(context._descriptor, 4096, 0), held.read_bytes())

    def test_in_place_change_refuses_even_if_mtime_restored(self):
        context = self.acquire()
        before = self.binary.stat()
        self.binary.write_bytes(b"different executable bytes")
        os.utime(self.binary, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaisesRegex(self.guardian.GuardianRefusal, "helper"):
            context.validate(progress=lambda: None)

    def test_link_count_and_writable_namespace_are_not_relaxed(self):
        context = self.acquire()
        os.link(self.binary, self.root / "foreign-link")
        with self.assertRaisesRegex(self.guardian.GuardianRefusal, "helper"):
            context.validate(progress=lambda: None)
        (self.root / "foreign-link").unlink()
        self.binary.chmod(0o777)
        with self.assertRaisesRegex(self.guardian.GuardianRefusal, "helper"):
            context.validate(progress=lambda: None)

    def test_owner_bound_context_cannot_close_before_guardian_physical_ack(self):
        context = self.acquire()
        operation = SimpleNamespace(_guardian_retirement_proven=False)
        context.bind_operation(operation)
        with self.assertRaisesRegex(self.guardian.GuardianRefusal, "cleanup"):
            context.close()
        self.assertIsNotNone(context._descriptor)
        operation._guardian_retirement_proven = True
        context.close()
        self.assertIsNone(context._descriptor)

    def test_sigint_after_close_latches_debt_without_reclosing_reused_fd(self):
        context = self.acquire()
        old = context._descriptor
        actual_close = os.close

        def close(descriptor):
            actual_close(descriptor)
            os.kill(os.getpid(), signal.SIGINT)

        with patch.object(self.guardian.os, "close", close):
            with self.assertRaisesRegex(self.guardian.GuardianRefusal, "cleanup"):
                context.close()
        replacement = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        self.assertEqual(replacement, old)
        try:
            with self.assertRaisesRegex(self.guardian.GuardianRefusal, "cleanup"):
                context.close()
            os.fstat(replacement)
        finally:
            actual_close(replacement)
        self.context = None

    def test_default_role_refuses_explicit_override_before_any_child(self):
        sessions = self.owner.EmptySession.acquire(
            self.root / "sessions", {"token": "a" * 64}, register=lambda value: None
        )
        registered = []
        try:
            with self.assertRaisesRegex(self.owner.ImageRefusal, "source"):
                self.owner.SuspendedImageOwner(
                    self.binary,
                    {"remaining_ms": 1000, "outgoing_worker": str(self.binary)},
                    sessions,
                    lambda: None,
                    None,
                    register=registered.append,
                )
            operation = registered[0]
            self.assertIsNone(operation.process)
            self.assertFalse(operation._spawn_attempted)
            self.assertTrue(operation.settle())
        finally:
            sessions.retire()

    def test_default_real_peer_retires_helper_fd_only_after_guardian_eof_reap(self):
        fixture_module = load(
            "trusted_default_peer", SOURCE / "tools/diagnostics/macos_suspended_image_owner_test.py"
        )
        fixture = fixture_module.ActualOwnerControls("runTest")
        fixture.setUp()
        fixture.build()
        # Keep the real independent peer code in the exact admitted bundle path;
        # this proves pipe/process lifecycle only, never native code signing.
        self.binary.write_bytes(fixture.binary.read_bytes())
        self.binary.chmod(0o755)
        fixture.mode.write_text("normal")
        mode = self.root / "Native.app/mode"
        mode.write_text("normal")
        sessions = self.owner.EmptySession.acquire(
            self.root / "sessions", {"token": "a" * 64}, register=lambda value: None
        )
        operation = None
        try:
            operation = self.owner.SuspendedImageOwner(
                self.binary,
                {
                    "remaining_ms": 3000,
                    "device": "1",
                    "inode": "9007199254740993",
                    "session_path": str(sessions.path),
                },
                sessions,
                lambda: None,
                None,
                register=lambda value: None,
            )
            operation.start()
            self.assertTrue(operation.active)
            self.assertIsNotNone(operation._default_guardian._descriptor)
            self.assertTrue(operation.settle(timeout=5))
            self.assertTrue(operation.physically_retired)
            self.assertTrue(operation._guardian_retirement_proven)
            self.assertIsNone(operation._default_guardian._descriptor)
        finally:
            if operation is not None:
                operation.settle(timeout=5)
            sessions.retire()
            fixture.doCleanups()


if __name__ == "__main__":
    unittest.main()

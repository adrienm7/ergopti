# tools/diagnostics/macos_suspended_image_owner_test.py
"""Actual POSIX owners and protocol peers; no Darwin mapping/signing credit."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

PACKET = Path(__file__).resolve().parents[2]


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


WORKER = load("qualified_outgoing", Path(__file__).with_name("macos_qualified_outgoing_worker.py"))
OWNER = load(
    "suspended_owner", PACKET / "static/ergopti_plus/macos/platform/suspended_image_owner.py"
)

PEER = r"""
import json, os, pathlib, subprocess, sys, time
request = json.loads(sys.stdin.readline())
session = pathlib.Path(request['session_path'])
if session.read_bytes() != b'':
    raise SystemExit(90)
mode = pathlib.Path(__file__).parent.parent.parent / 'mode'
kind = mode.read_text()
if kind == 'refuse':
    print('V1 REFUSED 116', flush=True)
    raise SystemExit(0)
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
try:
    inode = request['inode'] if kind != 'wrong-image' else '7'
    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], inode, flush=True)
    if kind == 'stderr':
        os.write(2, b'x' * 100000)
    while True:
        line = sys.stdin.readline()
        if line == 'ACTIVATE\n':
            assert json.loads(session.read_bytes())['token'] == 'a' * 64
            print('V1 ACTIVE', flush=True)
            if kind == 'garbage': print('unqualified child receipt', flush=True)
        elif line == 'CANCEL\n' or line == '':
            child.terminate()
            child.wait()
            if kind != 'missing-outgoing': print('V1 OUTGOING_CLOSED 0', flush=True)
            print('V1 RETIRED 143 1 1 0 0 0 0', flush=True)
            if kind == 'held-eof':
                release = mode.with_name('release')
                while not release.exists(): time.sleep(.01)
            break
finally:
    if child.poll() is None:
        child.terminate()
        child.wait()
"""


@unittest.skipUnless(os.name == "posix", "Native POSIX source ownership is unavailable on Windows")
class ActualOwnerControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binary = self.root / "OwnedOutgoingHTTP.app/Contents/MacOS/ErgoptiPlus"
        self.binary.parent.mkdir(parents=True)
        self.original = self.root / "original.swift"
        self.original.write_bytes(b"independent source input")
        self.copied = self.root / "copy.swift"
        self.copied.write_bytes(self.original.read_bytes())
        self.fingerprint = hashlib.sha256(self.original.read_bytes()).hexdigest()
        self.records = []
        self.worker = None
        self.operation = None
        self.session = None
        self.mode = self.root / "OwnedOutgoingHTTP.app/mode"
        self.mode.write_text("normal")
        self.addCleanup(self.retire)

    def retire(self):
        if self.operation is not None:
            self.mode.with_name("release").touch()
            self.operation.settle(timeout=5)
            if self.operation._protocol_debt:
                # This known independent peer always reaps its own child before
                # exit. Test cleanup may release fixture FDs, while the actual
                # controller continues to reject the malformed native receipt.
                self.operation.process.wait(timeout=5)
                for name in ("stdin", "stdout", "stderr"):
                    self.operation._close_stream(name)
                self.operation._close_selector()
                self.session._operation = None
                self.worker._operation = None
        if self.session is not None:
            self.session.retire()
        if self.worker is not None:
            self.worker.close()

    def build(self):
        def execute(arguments, **keywords):
            self.records.append((arguments, keywords))
            if arguments[0] == "/usr/bin/xcrun":
                self.binary.write_text("#!" + sys.executable + "\n" + PEER)
                self.binary.chmod(0o755)

        self.worker = WORKER.OwnedOutgoingWorkerQualification.build(
            self.binary,
            [(self.original, self.copied, self.fingerprint)],
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-parse-as-library",
                str(self.copied),
                "-o",
                str(self.binary),
            ],
            execute,
            register=lambda owner: setattr(self, "worker", owner),
        )
        return self.worker

    def empty_session(self):
        self.session = OWNER.EmptySession.acquire(
            self.root / "sessions",
            {"token": "a" * 64},
            register=lambda owner: setattr(self, "session", owner),
        )
        return self.session

    def guardian(self, *, source_check=lambda: None, mode="normal", inode="9007199254740993"):
        self.build()
        self.mode.write_text(mode)
        self.empty_session()
        fields = self.worker.fields()
        request = {
            "version": 1,
            "remaining_ms": 3000,
            "device": "1",
            "inode": inode,
            "session_path": str(self.session.path),
            **fields,
        }
        self.operation = OWNER.SuspendedImageOwner(
            self.binary,
            request,
            self.session,
            source_check,
            self.worker,
            register=lambda owner: setattr(self, "operation", owner),
        )
        return self.operation

    def test_compiler_source_sign_and_verify_are_owned_in_order(self):
        fields = self.build().fields()
        self.assertEqual(self.records[0][1], {"timeout": 90})
        self.assertEqual([row[0][1] for row in self.records], ["swiftc", "--force", "--verify"])
        self.assertEqual(
            fields["outgoing_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest()
        )
        self.assertEqual(os.pread(self.worker._output, 2, 0), b"#!")
        with self.assertRaises(OSError):
            os.write(self.worker._output, b"changed")

    def test_existing_signature_and_ui_identity_cannot_construct_qualification(self):
        unqualified = WORKER.OwnedOutgoingWorkerQualification()
        with self.assertRaisesRegex(WORKER.QualificationRefusal, "state"):
            unqualified.fields()

    def test_foreign_replaced_worker_refuses_original_context(self):
        self.build()
        self.binary.unlink()
        self.binary.write_bytes(b"foreign worker")
        self.binary.chmod(0o755)
        with self.assertRaisesRegex(WORKER.QualificationRefusal, "worker"):
            self.worker.fields()
        self.assertEqual(self.binary.read_bytes(), b"foreign worker")

    def test_changed_source_and_copy_refuse_even_when_worker_stays_signed(self):
        self.build()
        self.copied.write_bytes(b"changed copy")
        with self.assertRaisesRegex(WORKER.QualificationRefusal, "source"):
            self.worker.fields()

    def test_actual_mutation_during_retained_worker_hash_refuses_after_read(self):
        self.build()
        actual_pread = os.pread
        changed = False

        def mutate(descriptor, size, offset):
            nonlocal changed
            original = actual_pread(descriptor, size, offset)
            if descriptor == self.worker._output and original and not changed:
                changed = True
                data = self.binary.read_bytes()
                self.binary.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
            return original

        with patch.object(WORKER.os, "pread", side_effect=mutate):
            with self.assertRaisesRegex(WORKER.QualificationRefusal, "bytes"):
                self.worker.fields()
        self.assertTrue(changed)

    def test_source_changed_during_compile_refuses_before_sign(self):
        def execute(*arguments, **keywords):
            self.records.append((arguments, keywords))
            self.copied.write_bytes(b"compiler boundary mutation")

        with self.assertRaisesRegex(WORKER.QualificationRefusal, "source"):
            WORKER.OwnedOutgoingWorkerQualification.build(
                self.binary,
                [(self.original, self.copied, self.fingerprint)],
                [
                    "/usr/bin/xcrun",
                    "swiftc",
                    "-parse-as-library",
                    str(self.copied),
                    "-o",
                    str(self.binary),
                ],
                execute,
                register=lambda owner: setattr(self, "worker", owner),
            )
        self.assertEqual(len(self.records), 1)
        self.assertEqual(self.worker._inputs, [])

    def test_close_refuses_live_bound_guardian(self):
        self.build()
        live = SimpleNamespace(physically_retired=False)
        self.worker.bind_operation(live)
        with self.assertRaisesRegex(WORKER.QualificationRefusal, "cleanup"):
            self.worker.close()
        self.assertIsNotNone(self.worker._output)
        live.physically_retired = True

    def test_real_sigint_close_records_debt_and_closes_other_owned_fds(self):
        self.build()
        descriptors = [row[1] for row in self.worker._inputs] + [self.worker._output]
        actual_close = os.close
        first = True

        def interrupted(descriptor):
            nonlocal first
            actual_close(descriptor)
            if first:
                first = False
                signal.raise_signal(signal.SIGINT)

        with patch.object(WORKER.os, "close", side_effect=interrupted):
            with self.assertRaisesRegex(WORKER.QualificationRefusal, "cleanup"):
                self.worker.close()
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        with self.assertRaisesRegex(WORKER.QualificationRefusal, "cleanup"):
            self.worker.close()
        self.worker = None

    def test_session_is_exact_empty_private_canonical_name_before_image(self):
        self.empty_session()
        self.assertRegex(self.session.path.name, r"^daemon-[a-f0-9]{32}\.json$")
        self.assertEqual(self.session.path.read_bytes(), b"")
        self.assertEqual(self.session.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.session.directory.stat().st_mode & 0o777, 0o700)

    def test_session_unready_or_foreign_operation_never_receives_key(self):
        self.empty_session()
        operation = SimpleNamespace(image_ready=False, physically_retired=False)
        self.session.bind_operation(operation)
        with self.assertRaisesRegex(OWNER.ImageRefusal, "state"):
            self.session.release_key(operation)
        with self.assertRaisesRegex(OWNER.ImageRefusal, "state"):
            self.session.release_key(SimpleNamespace(image_ready=True, physically_retired=False))
        self.assertEqual(self.session.path.read_bytes(), b"")
        operation.physically_retired = True

    def test_source_refusal_before_private_key_write_keeps_empty_file(self):
        self.empty_session()

        def refuse():
            raise OWNER.ImageRefusal("source")

        operation = SimpleNamespace(
            image_ready=True, physically_retired=False, recheck_source=refuse
        )
        self.session.bind_operation(operation)
        with self.assertRaisesRegex(OWNER.ImageRefusal, "source"):
            self.session.release_key(operation)
        self.assertEqual(self.session.path.read_bytes(), b"")
        operation.physically_retired = True

    def test_actual_peer_ready_activation_child_identity_and_exact_reap(self):
        operation = self.guardian()
        operation.start()
        self.assertTrue(operation.image_ready)
        self.assertTrue(operation.active)
        self.assertNotEqual(operation.listener["pid"], operation.process.pid)
        self.assertEqual(operation.listener["inode"], "9007199254740993")
        self.assertEqual(json.loads(self.session.path.read_bytes())["token"], "a" * 64)
        self.assertFalse(operation.physically_retired)
        self.assertTrue(operation.settle())
        self.assertEqual(operation.process.returncode, 0)
        self.assertEqual(operation._eof, {"stdout", "stderr"})
        self.assertTrue(operation.physically_retired)

    def test_wrong_mapped_identity_never_releases_private_key(self):
        operation = self.guardian(mode="wrong-image")
        with self.assertRaisesRegex(OWNER.ImageRefusal, "protocol"):
            operation.start()
        self.assertEqual(self.session.path.read_bytes(), b"")
        operation.settle()
        self.assertFalse(operation.physically_retired)

    def test_replaced_worker_refuses_before_payload_acquisition(self):
        operation = self.guardian()
        self.binary.unlink()
        self.binary.write_bytes(b"foreign replacement")
        self.binary.chmod(0o755)
        with patch.object(OWNER.subprocess, "Popen") as constructor:
            with self.assertRaisesRegex(WORKER.QualificationRefusal, "worker"):
                operation.start()
            constructor.assert_not_called()
        self.assertEqual(self.session.path.read_bytes(), b"")

    def test_replacement_after_image_ready_refuses_before_key(self):
        checks = 0

        def source_check():
            nonlocal checks
            checks += 1
            if checks == 2:
                raise OWNER.ImageRefusal("source")

        operation = self.guardian(source_check=source_check)
        with self.assertRaisesRegex(OWNER.ImageRefusal, "source"):
            operation.start()
        self.assertTrue(operation.image_ready)
        self.assertFalse(operation.active)
        self.assertEqual(self.session.path.read_bytes(), b"")
        self.assertTrue(operation.settle())

    def test_private_session_name_replacement_preserves_foreign_file(self):
        self.empty_session()
        self.session.path.unlink()
        self.session.path.write_bytes(b"foreign session")
        with self.assertRaisesRegex(OWNER.ImageRefusal, "session"):
            self.session.validate()
        with self.assertRaisesRegex(OWNER.ImageRefusal, "session"):
            self.session.retire()
        self.assertEqual(self.session.path.read_bytes(), b"foreign session")
        # Only close fixture-owned references; never ask production retirement
        # to remove the replacement name or silently declare namespace success.
        self.session._created = False

    def test_partial_actual_private_write_keeps_exact_prefix_cleanup(self):
        self.empty_session()
        operation = SimpleNamespace(
            image_ready=True,
            physically_retired=False,
            recheck_source=lambda: None,
            progress=lambda: None,
        )
        self.session.bind_operation(operation)
        actual_write = os.write
        count = 0

        def partial(descriptor, data):
            nonlocal count
            count += 1
            if count == 1:
                return actual_write(descriptor, data[:7])
            raise OSError("independent write refusal")

        with patch.object(OWNER.os, "write", side_effect=partial):
            with self.assertRaisesRegex(OSError, "write refusal"):
                self.session.release_key(operation)
        self.assertEqual(self.session._written, self.session.path.read_bytes())
        self.assertEqual(len(self.session._written), 7)
        operation.physically_retired = True

    def test_session_sigint_close_keeps_debt_and_never_recloses_reused_fd(self):
        self.empty_session()
        descriptors = [self.session._file_fd, self.session._directory_fd]
        actual_close = os.close
        first = True
        reused = None

        def interrupted(descriptor):
            nonlocal first, reused
            actual_close(descriptor)
            if first:
                first = False
                reused = os.open(self.original, os.O_RDONLY)
                self.assertEqual(reused, descriptor)
                signal.raise_signal(signal.SIGINT)

        with patch.object(OWNER.os, "close", side_effect=interrupted):
            with self.assertRaisesRegex(OWNER.ImageRefusal, "cleanup"):
                self.session.retire()
        self.assertIsNotNone(os.fstat(reused))
        with self.assertRaisesRegex(OWNER.ImageRefusal, "cleanup"):
            self.session.retire()
        self.assertIsNotNone(os.fstat(reused))
        with self.assertRaises(OSError):
            os.fstat(descriptors[1])
        actual_close(reused)
        self.session = None

    def test_actual_retired_marker_without_eof_never_releases_owner(self):
        operation = self.guardian(mode="held-eof")
        operation.start()
        self.assertFalse(operation.settle(timeout=0.15))
        self.assertIsNotNone(operation._retired)
        self.assertFalse(operation.physically_retired)
        self.assertIsNone(operation.process.poll())
        self.mode.with_name("release").touch()
        self.assertTrue(operation.settle(timeout=3))

    def test_actual_refused_no_child_still_needs_guardian_reap_and_eof(self):
        operation = self.guardian(mode="refuse")
        with self.assertRaisesRegex(OWNER.ImageRefusal, "admission"):
            operation.start()
        self.assertEqual(self.session.path.read_bytes(), b"")
        self.assertFalse(operation.settle())
        self.assertTrue(operation.physically_retired)
        self.assertEqual(operation.process.returncode, 0)

    def test_actual_stderr_is_drained_but_remains_bounded_private(self):
        operation = self.guardian(mode="stderr")
        operation.start()
        self.assertTrue(operation.settle())
        self.assertEqual(len(operation._buffers["stderr"]), 65536)

    def test_missing_outgoing_close_never_qualifies_native_retirement(self):
        operation = self.guardian(mode="missing-outgoing")
        operation.start()
        self.assertFalse(operation.settle())
        self.assertFalse(operation.physically_retired)
        # The independent peer has physically reaped its child. A rejected native
        # receipt remains debt; test finalization reaps the exact peer separately.
        operation.process.wait(timeout=3)
        for name in ("stdin", "stdout", "stderr"):
            operation._close_stream(name)
        operation._close_selector()
        self.operation = None
        self.session._operation = None
        self.worker._operation = None


@unittest.skipUnless(os.name == "posix", "Actual private POSIX process owners required")
class ListenerEventControls(unittest.TestCase):
    setUp = ActualOwnerControls.setUp
    retire = ActualOwnerControls.retire
    build = ActualOwnerControls.build
    empty_session = ActualOwnerControls.empty_session
    guardian = ActualOwnerControls.guardian

    # Reuse the original fixture methods through composition, never inherit its
    # test names into a second discovery cohort.
    def run(self, result=None):
        return unittest.TestCase.run(self, result)

    def event_owner(self, event, *, start=True):
        script = PEER.replace(
            "print('V1 ACTIVE', flush=True)",
            "print('V1 ACTIVE', flush=True)\n            "
            + event.replace("NONCE", "session.name[7:-5]"),
        )
        with patch.dict(globals(), {"PEER": script}):
            operation = self.guardian()
        operation.request["listener_event"] = True
        if start:
            operation.start()
        return operation

    def test_listener_event_complete_nonce_precedes_retirement(self):
        operation = self.event_owner("print('V1 LISTENER_BOUND', NONCE, flush=True)")
        operation.wait_listener_bound()
        self.assertTrue(operation.listener_bound)
        self.assertFalse(operation.physically_retired)
        self.assertTrue(operation.settle(timeout=5))
        self.assertTrue(operation.physically_retired)

    def test_listener_event_wrong_nonce_never_grants_observation(self):
        operation = self.event_owner(
            "print('V1 LISTENER_BOUND', '0' * 32, flush=True)", start=False
        )
        with self.assertRaises(OWNER.ImageRefusal):
            operation.start()
            operation.wait_listener_bound()
        self.assertFalse(operation.listener_bound)
        self.assertTrue(operation._protocol_debt)

    def test_listener_event_missing_complete_lf_preserves_original_clock(self):
        operation = self.event_owner(
            "sys.stdout.write('V1 LISTENER_BOUND ' + NONCE); sys.stdout.flush()"
        )
        operation._startup_deadline = 0
        with self.assertRaisesRegex(OWNER.ImageRefusal, "deadline"):
            operation.wait_listener_bound()
        self.assertFalse(operation.listener_bound)
        self.assertFalse(operation.physically_retired)

    def test_listener_event_duplicate_frame_refuses_not_ready(self):
        operation = self.event_owner("print('V1 LISTENER_BOUND', NONCE, flush=True)")
        operation.wait_listener_bound()
        with self.assertRaises(OWNER.ImageRefusal):
            operation._parse(("V1 LISTENER_BOUND " + self.session.path.name[7:-5]).encode())
        self.assertTrue(operation._protocol_debt)

    def test_listener_event_without_optional_request_refuses(self):
        operation = self.guardian()
        operation.start()
        with self.assertRaisesRegex(OWNER.ImageRefusal, "state"):
            operation.wait_listener_bound()
        self.assertFalse(operation.listener_bound)

    def test_listener_event_retirement_started_cannot_revive_daemon(self):
        operation = self.event_owner("print('V1 LISTENER_BOUND', NONCE, flush=True)")
        operation._retirement_started = True
        with self.assertRaisesRegex(OWNER.ImageRefusal, "state"):
            operation.wait_listener_bound()
        self.assertFalse(operation.physically_retired)


class DaemonLogProtocolControls(unittest.TestCase):
    """Literal protocol/settlement controls; no native guardian execution credit."""

    def operation(self, *, configured=True):
        value = object.__new__(OWNER.SuspendedImageOwner)
        value.request = {"log_directory": "/private/tmp/logs"} if configured else {}
        value._logs_closed = None
        value._retired = value._refused = value._failure = value._close_debt = None
        value._outgoing_closed = 0
        value._bootstrap_closed = None
        value.bootstrap = None
        value._protocol_debt = value._retirement_started = False
        value.image_ready = value.active = False
        value.physically_retired = False
        value._spawn_attempted = True
        value._guardian_retirement_proven = False
        value._default_guardian = None
        value._selector = None
        value._eof = {"stdout", "stderr"}
        value._buffers = {"stdout": bytearray(), "stderr": bytearray()}
        value.process = SimpleNamespace(
            stdin=None,
            stdout=None,
            stderr=None,
            _child_created=True,
            returncode=0,
            wait=lambda **kwargs: 0,
        )
        return value

    def test_log_closure_preserves_original_native_status(self):
        operation = self.operation()
        operation._parse(b"V1 LOGS_CLOSED 0")
        operation._parse(b"V1 RETIRED 143 1 1 0 0 0 0")
        self.assertEqual(operation._retired, (143, (0, 0, 0)))
        self.assertEqual(operation._logs_closed, 0)
        self.assertFalse(operation.physically_retired)
        self.assertTrue(operation.settle())
        self.assertTrue(operation.physically_retired)

    def test_configured_log_requires_its_own_closed_packet(self):
        operation = self.operation()
        with self.assertRaisesRegex(OWNER.ImageRefusal, "protocol"):
            operation._parse(b"V1 RETIRED 0 1 1 0 0 0 0")
        self.assertIsNone(operation._retired)
        self.assertTrue(operation._protocol_debt)
        self.assertFalse(operation.physically_retired)

    def test_unconfigured_log_packet_cannot_add_authority(self):
        operation = self.operation(configured=False)
        with self.assertRaisesRegex(OWNER.ImageRefusal, "protocol"):
            operation._parse(b"V1 LOGS_CLOSED 0")
        self.assertIsNone(operation._logs_closed)
        self.assertTrue(operation._protocol_debt)

    def test_duplicate_log_close_receipt_refuses(self):
        operation = self.operation()
        operation._parse(b"V1 LOGS_CLOSED 0")
        with self.assertRaisesRegex(OWNER.ImageRefusal, "protocol"):
            operation._parse(b"V1 LOGS_CLOSED 0")
        self.assertIsNone(operation._retired)
        self.assertTrue(operation._protocol_debt)

    def test_log_close_receipt_has_exact_fields_and_decimal(self):
        for wire in (
            b"V1 LOGS_CLOSED -1",
            b"V1 LOGS_CLOSED 01",
            b"V1 LOGS_CLOSED true",
            b"V1 LOGS_CLOSED 2147483648",
            b"V1 LOGS_CLOSED 0 0",
        ):
            with self.subTest(wire=wire):
                operation = self.operation()
                with self.assertRaisesRegex(OWNER.ImageRefusal, "protocol"):
                    operation._parse(wire)
                self.assertIsNone(operation._logs_closed)
                self.assertTrue(operation._protocol_debt)

    def test_log_write_failure_never_becomes_successful_settlement(self):
        operation = self.operation()
        operation._parse(b"V1 LOGS_CLOSED 5")
        operation._parse(b"V1 RETIRED 0 1 1 0 0 0 0")
        self.assertEqual(operation._retired[0], 0, "the real process status stays intact")
        self.assertTrue(operation.settle(), "known physical closure is not task success")
        self.assertTrue(operation.physically_retired)
        self.assertIsNone(operation._failure, "known writes must not invent unknown close debt")
        self.assertEqual(operation.log_write_errno, 5)
        self.assertEqual(operation.public_receipt()["log_write_errno"], 5)
        self.assertTrue(operation.settle())
        self.assertEqual(
            operation.log_write_errno, 5, "a later close cannot erase the write failure"
        )
        subject = load(
            "daily_log_serve",
            PACKET / "static/ergopti_plus/macos/modules/llm/managed_ollama_serve.py",
        )
        retired = []
        caller = SimpleNamespace(
            operation=operation,
            cancelled=False,
            _caller_input=None,
            _log_directory="/private/tmp/logs",
            retire=lambda timeout: retired.append(timeout) or True,
        )
        with self.assertRaisesRegex(subject.ServeRefusal, "logging"):
            subject.ServeOwner.wait(caller, 2)
        self.assertEqual(retired, [2], "the original retirement must precede the write refusal")


if __name__ == "__main__":
    unittest.main()

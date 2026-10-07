#!/usr/bin/env python3
# tools/diagnostics/macos_sparkle_archive_fixture_test.py

"""Real loopback transport controls; native updater admission is separate."""

import contextlib
import ctypes
import errno
import hashlib
import io
import http.client
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import socket
import threading
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


HELPER = Path(__file__).with_name("macos_sparkle_archive_fixture.py")
NONCE = "a" * 32


class PrivateSparkleTransportTests(unittest.TestCase):
    def testNumericLoopbackConstructionNeverConsultsDNS(self):
        spec = importlib.util.spec_from_file_location("private_sparkle_numeric_bind", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        original = helper.http.server.HTTPServer.__init__
        acquired = []

        def capture(server, *args, **kwargs):
            original(server, *args, **kwargs)
            acquired.append(server)

        handlers = {
            number: helper.signal.getsignal(number)
            for number in [helper.signal.SIGTERM, helper.signal.SIGINT]
        }
        try:
            with (
                mock.patch.object(helper, "private_directory", return_value=self.root),
                mock.patch.object(
                    helper.socket, "getfqdn", side_effect=RuntimeError("DNS consulted")
                ) as dns,
                mock.patch.object(helper.http.server.HTTPServer, "__init__", capture),
                mock.patch.object(
                    helper, "publish", side_effect=RuntimeError("publication boundary")
                ),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                with self.assertRaisesRegex(RuntimeError, "publication boundary"):
                    helper.serve(str(self.root), NONCE)
                dns.assert_not_called()
            self.assertEqual(len(acquired), 1)
            server = acquired[0]
            self.assertEqual(server.server_address[0], "127.0.0.1")
            self.assertGreater(server.server_address[1], 0)
            self.assertEqual(server.server_name, "127.0.0.1")
            self.assertEqual(server.server_port, server.server_address[1])
            self.assertEqual(server.socket.fileno(), -1)
            self.assertFalse((self.root / "server-start.json").exists())
        finally:
            for number, handler in handlers.items():
                helper.signal.signal(number, handler)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="ergopti-private-sparkle-")).resolve()
        self.root.chmod(0o700)
        self.child = None

    def tearDown(self):
        if self.child is not None:
            if self.child.poll() is None:
                self.child.terminate()
            try:
                # Also closes registered captures when the child exited before
                # readiness or before this control observed its failure.
                self.child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                # Retain the directory even after an exact-child kill: forced
                # retirement is a failed control, not an admissible cleanup.
                self.child.kill()
                self.child.communicate(timeout=5)
                self.fail("Private transport fixture retained after retirement debt")
        shutil.rmtree(self.root)

    def start(self):
        self.child = subprocess.Popen(
            [sys.executable, str(HELPER), "serve", str(self.root), NONCE],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        target = self.root / "server-start.json"
        deadline = time.monotonic() + 5
        while not target.exists() and self.child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(target.exists(), "The real server must publish its readiness receipt")
        packet = json.loads(target.read_bytes())
        self.assertEqual(packet["nonce"], NONCE)
        self.assertEqual(packet["pid"], self.child.pid)
        return packet["port"]

    @unittest.skipUnless(
        hasattr(os, "O_NOFOLLOW"), "POSIX private-file admission needs a native host"
    )
    def testActualLoopbackBytesAndMutableFeedHaveIndependentDigestReceipts(self):
        original = b"independent first feed\n"
        replacement = b"independent retry feed\n"
        archive = b"independent archive byte fixture\x00\xff"
        (self.root / "feed.xml").write_bytes(original)
        (self.root / "archive.tar.xz").write_bytes(archive)
        port = self.start()
        for name, expected in [("feed.xml", original), ("archive.tar.xz", archive)]:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            connection.request("GET", "/" + name)
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(response.read(), expected)
            connection.close()
        (self.root / "replacement").write_bytes(replacement)
        os.replace(self.root / "replacement", self.root / "feed.xml")
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/feed.xml")
        self.assertEqual(connection.getresponse().read(), replacement)
        connection.close()
        for index, expected in enumerate([original, archive, replacement], 1):
            packet = json.loads((self.root / ("request-%06d.json" % index)).read_bytes())
            self.assertEqual(packet["nonce"], NONCE)
            self.assertEqual(packet["bytes"], len(expected))
            self.assertEqual(packet["sha256"], hashlib.sha256(expected).hexdigest())
        self.child.terminate()
        stdout, stderr = self.child.communicate(timeout=5)
        self.assertEqual((self.child.returncode, stdout, stderr), (0, b"", b""))
        terminal = json.loads((self.root / "server-retired.json").read_bytes())
        self.assertEqual(terminal, {"nonce": NONCE, "pid": self.child.pid, "requests": 3})

    @unittest.skipUnless(
        hasattr(os, "O_NOFOLLOW"), "POSIX private-file admission needs a native host"
    )
    def testUnknownAndTraversalRoutesCannotReadAnyOtherPrivateFile(self):
        sentinel = b"independent forbidden source"
        (self.root / "private-input").write_bytes(sentinel)
        port = self.start()
        for path in [
            "/private-input",
            "/../private-input",
            "/%2e%2e/private-input",
            "/feed.xml?foreign=1",
        ]:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            connection.request("GET", path)
            response = connection.getresponse()
            self.assertEqual(response.status, 404)
            self.assertNotIn(sentinel, response.read())
            connection.close()
        self.assertFalse(list(self.root.glob("request-*.json")))

    @unittest.skipUnless(
        hasattr(os, "O_NOFOLLOW"), "POSIX private-file admission needs a native host"
    )
    def testActualSymlinkResourceRefusesAndPhysicallyRetiresServer(self):
        sentinel = self.root / "foreign-input"
        sentinel.write_bytes(b"foreign bytes")
        (self.root / "archive.tar.xz").symlink_to(sentinel)
        port = self.start()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/archive.tar.xz")
        with self.assertRaises(http.client.RemoteDisconnected):
            connection.getresponse()
        connection.close()
        stdout, stderr = self.child.communicate(timeout=5)
        self.assertEqual(
            (self.child.returncode, stdout, stderr), (1, b"", b"Private Sparkle fixture refused.\n")
        )
        self.assertFalse(list(self.root.glob("request-*.json")))
        self.assertTrue((self.root / "server-retired.json").exists())
        self.assertEqual(sentinel.read_bytes(), b"foreign bytes")

    def testInvalidSessionRefusesWithoutPublishingReadiness(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "serve", str(self.root), "invalid-session"],
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"", b"Private Sparkle fixture refused.\n"),
        )
        self.assertFalse((self.root / "server-start.json").exists())

    @unittest.skipIf(
        sys.platform == "darwin", "Actual macOS census is exercised by mandatory XCTest"
    )
    def testOtherPlatformsCannotClaimNativeProcessRetirement(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "census", str(self.root)],
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (1, b"", b"Private Sparkle fixture refused.\n"),
        )

    @unittest.skipUnless(hasattr(os, "geteuid"), "Private directory identity needs a POSIX host")
    def testReadinessPublicationFailureClosesRealBoundSocketAndPreservesPriorFile(self):
        spec = importlib.util.spec_from_file_location("private_sparkle_helper", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        original = helper.http.server.HTTPServer.__init__
        acquired = []

        def capture(server, *args, **kwargs):
            original(server, *args, **kwargs)
            acquired.append(server)

        prior = b"independent preexisting readiness receipt"
        (self.root / "server-start.json").write_bytes(prior)
        # These invoke the real socket acquisition and native close; only the
        # acquisition observer is installed, not a transport or close stub.
        handlers = {
            number: helper.signal.getsignal(number)
            for number in [helper.signal.SIGTERM, helper.signal.SIGINT]
        }
        try:
            with mock.patch.object(helper.http.server.HTTPServer, "__init__", capture):
                with self.assertRaises(FileExistsError):
                    helper.serve(str(self.root), NONCE)
        finally:
            for number, handler in handlers.items():
                helper.signal.signal(number, handler)
        self.assertEqual(len(acquired), 1)
        self.assertEqual(acquired[0].socket.fileno(), -1)
        self.assertEqual((self.root / "server-start.json").read_bytes(), prior)
        terminal = json.loads((self.root / "server-retired.json").read_bytes())
        self.assertEqual(terminal["requests"], 0)

    @unittest.skipUnless(hasattr(os, "geteuid"), "Private directory identity needs a POSIX host")
    def testSignalRegistrationFailureAlsoClosesRealSocketBeforeAnyReadiness(self):
        spec = importlib.util.spec_from_file_location("private_sparkle_helper", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        original = helper.http.server.HTTPServer.__init__
        acquired = []

        def capture(server, *args, **kwargs):
            original(server, *args, **kwargs)
            acquired.append(server)

        with mock.patch.object(helper.http.server.HTTPServer, "__init__", capture):
            with mock.patch.object(
                helper.signal, "signal", side_effect=RuntimeError("independent signal refusal")
            ):
                with self.assertRaisesRegex(RuntimeError, "independent signal refusal"):
                    helper.serve(str(self.root), NONCE)
        self.assertEqual(len(acquired), 1)
        self.assertEqual(acquired[0].socket.fileno(), -1)
        self.assertFalse((self.root / "server-start.json").exists())
        self.assertEqual(
            json.loads((self.root / "server-retired.json").read_bytes())["requests"], 0
        )


class NativeCensusDiagnosticControls(unittest.TestCase):
    """Model diagnostic projection only; these do not qualify Darwin census."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("sparkle_census_diagnostic", HELPER)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)

    def testPathRefusalKeepsStrictPolicyAndCapturesOnlyFreshErrno(self):
        helper = self.helper
        library = mock.Mock()
        observed = []

        def refuse(*_args):
            observed.append(ctypes.get_errno())
            ctypes.set_errno(errno.ESRCH)
            return 0

        library.proc_pidpath = mock.Mock(side_effect=refuse)
        inventory = subprocess.CompletedProcess([], 0, stdout="91234 1000\n")
        with (
            mock.patch.object(helper.sys, "platform", "darwin"),
            mock.patch.object(
                helper, "private_directory", return_value=Path("/private/SECRET_NOT_EXPORTED")
            ),
            mock.patch.object(helper.ctypes, "CDLL", return_value=library),
            mock.patch.object(helper.os, "geteuid", return_value=1000, create=True),
            mock.patch.object(helper.subprocess, "run", return_value=inventory),
        ):
            for effect in [None, ProcessLookupError(), PermissionError("SECRET_NOT_EXPORTED")]:
                ctypes.set_errno(999)
                with mock.patch.object(helper.os, "kill", side_effect=effect) as probe:
                    if effect is None:
                        with self.assertRaises(helper.NativeCensusRefusal) as caught:
                            helper.census(["/private/SECRET_NOT_EXPORTED"])
                        self.assertEqual(caught.exception.packet["path_errno"], errno.ESRCH)
                    elif isinstance(effect, ProcessLookupError):
                        self.assertEqual(helper.census(["/private/SECRET_NOT_EXPORTED"]), [])
                    else:
                        with self.assertRaises(PermissionError):
                            helper.census(["/private/SECRET_NOT_EXPORTED"])
                    probe.assert_called_once_with(91234, 0)
        self.assertEqual(observed, [0, 0, 0])

    def testActualEntrypointExportsOnlyFixedFactsAndNeverPrivateExceptionText(self):
        helper = self.helper
        for failure in [
            helper.NativeCensusRefusal(errno.ESRCH),
            RuntimeError("PRIVATE_KEY_ARGV_PATH"),
        ]:
            stdout, stderr = io.StringIO(), io.StringIO()
            with (
                mock.patch.object(helper, "main", side_effect=failure),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                status = helper.entrypoint(["census", "/PRIVATE_KEY_ARGV_PATH"])
            self.assertEqual(status, 1)
            self.assertEqual(stderr.getvalue(), "Private Sparkle fixture refused.\n")
            self.assertNotIn("PRIVATE_KEY_ARGV_PATH", stdout.getvalue() + stderr.getvalue())
            if isinstance(failure, helper.NativeCensusRefusal):
                self.assertEqual(
                    json.loads(stdout.getvalue()),
                    {
                        "schema": 1,
                        "code": "path-unavailable",
                        "helper_pid": os.getpid(),
                        "path_errno": errno.ESRCH,
                    },
                )
                self.assertLessEqual(len(stdout.getvalue().encode()), 512)
            else:
                self.assertEqual(stdout.getvalue(), "")

    def testUnsupportedNativeDiagnosticValuesCannotBecomePublicFacts(self):
        for value in [-1, 4096, True, "PRIVATE_KEY_ARGV_PATH"]:
            with self.assertRaisesRegex(RuntimeError, "Native Sparkle diagnostic refused"):
                self.helper.NativeCensusRefusal(value)


class NativeBSDDiagnosticControls(unittest.TestCase):
    """Independent official-ABI byte fixtures; no Darwin execution is claimed."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("sparkle_bsd_diagnostic", HELPER)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)

    def library(self, *, status=5, pid=91234, owner=1000, returned=136, native_errno=0):
        # Independent proc_info.h record:136 bytes; status4, pid12, uid20.
        # Private names are deliberately present in the native record.
        record = bytearray(136)
        struct.pack_into("<I", record, 4, status)
        struct.pack_into("<I", record, 12, pid)
        struct.pack_into("<I", record, 20, owner)
        record[48:64] = b"PRIVATE_NAME_1234"[:16]
        record[64:96] = b"PRIVATE_KEY_PATH_ARGV_NOT_EXPOSED!"[:32]
        self.assertEqual(len(record), 136)
        library = mock.Mock()
        observed = []

        def observe(actual_pid, flavor, argument, buffer, size):
            observed.append((actual_pid, flavor, argument, size, ctypes.get_errno()))
            ctypes.memmove(buffer, bytes(record), 136)
            ctypes.set_errno(native_errno)
            return returned

        library.proc_pidinfo = mock.Mock(side_effect=observe)
        return library, observed

    def census_refusal(self, library):
        helper = self.helper
        library.proc_pidpath = mock.Mock(side_effect=self.path_refusal)
        inventory = subprocess.CompletedProcess([], 0, stdout="91234 1000\n")
        with (
            mock.patch.object(helper.sys, "platform", "darwin"),
            mock.patch.object(helper, "private_directory", return_value=Path("/PRIVATE_KEY_PATH")),
            mock.patch.object(helper.ctypes, "CDLL", return_value=library),
            mock.patch.object(helper.os, "geteuid", return_value=1000, create=True),
            mock.patch.object(helper.subprocess, "run", return_value=inventory),
            mock.patch.object(helper.os, "kill") as present,
        ):
            with self.assertRaises(helper.NativeCensusRefusal) as caught:
                helper.census(["/PRIVATE_KEY_PATH"])
            present.assert_called_once_with(91234, 0)
        return caught.exception

    @staticmethod
    def path_refusal(*_args):
        ctypes.set_errno(errno.ESRCH)
        return 0

    def testExactZombieSnapshotRemainsAFailedCensusAndUsesNonzeroArgument(self):
        library, observed = self.library()
        ctypes.set_errno(777)
        failure = self.census_refusal(library)
        self.assertEqual(observed, [(91234, 3, 1, 136, 0)])
        self.assertEqual(
            library.proc_pidinfo.argtypes,
            [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int],
        )
        self.assertEqual(library.proc_pidinfo.restype, ctypes.c_int)
        self.assertEqual(
            failure.packet,
            {
                "schema": 2,
                "code": "path-unavailable",
                "helper_pid": os.getpid(),
                "path_errno": errno.ESRCH,
                "bsd_bytes": 136,
                "bsd_errno": 0,
                "bsd_state": "zombie",
            },
        )

    def testRunnableSleepingStoppedAndCreatingDoNotBecomeZombieOrSuccess(self):
        for status, state in [(1, "creating"), (2, "runnable"), (3, "sleeping"), (4, "stopped")]:
            with self.subTest(status=status):
                library, _ = self.library(status=status)
                self.assertEqual(self.census_refusal(library).packet["bsd_state"], state)

    def testFreshPermissionErrorAndShortReadKeepTheOriginalPathErrno(self):
        for returned, native_errno in [(0, errno.EPERM), (0, errno.EACCES), (135, 0)]:
            with self.subTest(returned=returned, native_errno=native_errno):
                library, observed = self.library(returned=returned, native_errno=native_errno)
                failure = self.census_refusal(library)
                self.assertEqual(failure.packet["path_errno"], errno.ESRCH)
                self.assertEqual(failure.packet["bsd_errno"], native_errno)
                self.assertEqual(failure.packet["bsd_bytes"], returned)
                self.assertEqual(failure.packet["bsd_state"], "unavailable")
                self.assertEqual(observed, [(91234, 3, 1, 136, 0)])

    def testForeignOrUnsupportedRecordsCannotIdentifyAZombie(self):
        for changes, state in [
            ({"pid": 91235}, "identity-refused"),
            ({"owner": 1001}, "identity-refused"),
            ({"status": 6}, "state-refused"),
        ]:
            with self.subTest(changes=changes):
                library, _ = self.library(**changes)
                self.assertEqual(self.census_refusal(library).packet["bsd_state"], state)

    def testWrongABIOrNativeDiagnosticExceptionDoesNotReplaceStrictRefusal(self):
        library, _ = self.library()
        with mock.patch.object(self.helper.ctypes, "sizeof", return_value=128):
            failure = self.census_refusal(library)
        self.assertEqual(failure.packet["bsd_state"], "abi-refused")
        library.proc_pidinfo.assert_not_called()
        library, _ = self.library()
        library.proc_pidinfo.side_effect = RuntimeError("PRIVATE_KEY_PATH_ARGV")
        failure = self.census_refusal(library)
        self.assertEqual(failure.packet["bsd_state"], "diagnostic-refused")
        self.assertEqual(failure.packet["path_errno"], errno.ESRCH)

    def testEntrypointPublishesOnlyTheFixedBoundedSnapshotAndStillExitsOne(self):
        library, _ = self.library()
        failure = self.census_refusal(library)
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(self.helper, "main", side_effect=failure),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = self.helper.entrypoint(["census", "/PRIVATE_KEY_PATH_ARGV"])
        self.assertEqual(status, 1)
        self.assertEqual(stderr.getvalue(), "Private Sparkle fixture refused.\n")
        self.assertEqual(
            set(json.loads(stdout.getvalue())),
            {"schema", "code", "helper_pid", "path_errno", "bsd_bytes", "bsd_errno", "bsd_state"},
        )
        self.assertLessEqual(len(stdout.getvalue().encode()), 512)
        self.assertNotIn("PRIVATE", stdout.getvalue() + stderr.getvalue())

    def testMalformedOrPrivateDiagnosticFieldsCannotBecomePublicFacts(self):
        valid = {"bsd_bytes": 136, "bsd_errno": 0, "bsd_state": "zombie"}
        cases = [
            dict(valid, extra="PRIVATE_KEY_PATH"),
            dict(valid, bsd_bytes=True),
            dict(valid, bsd_errno=-1),
            dict(valid, bsd_errno=4096),
            dict(valid, bsd_state="PRIVATE_KEY_PATH"),
            dict(valid, bsd_state=True),
            dict(valid, bsd_bytes=0),
            dict(valid, bsd_errno=errno.EPERM),
        ]
        for packet in cases:
            with self.subTest(packet=packet):
                with self.assertRaisesRegex(RuntimeError, "Native Sparkle diagnostic refused"):
                    self.helper.NativeCensusRefusal(errno.ESRCH, packet)


class AcceptedSocketStopControls(unittest.TestCase):
    """Real loopback EOF/close; filesystem and Windows signal ports are modeled."""

    def observe_stop(
        self, partial=False, native_signal=False, shutdown_refused=False, publication_cut=False
    ):
        spec = importlib.util.spec_from_file_location("sparkle_accepted_socket_control", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        ready, accepted, headers = threading.Event(), threading.Event(), threading.Event()
        ports, publications, captures, failures, peers = [], [], [], [], []
        handlers = {}
        old_handlers = {
            number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)
        }
        original_finish = helper.http.server.HTTPServer.finish_request
        original_parse = helper.http.server.BaseHTTPRequestHandler.parse_request
        original_shutdown = socket.socket.shutdown
        original_setattr = object.__setattr__
        shutdown_calls = []

        def publish(file, value):
            publications.append((file.name, value))
            if file.name == "server-start.json":
                ports.append(value["port"])
                ready.set()

        def finish(server, request, address):
            self.assertIs(server.active_request, request)
            captures.append((server, request))
            accepted.set()
            return original_finish(server, request, address)

        def install(number, callback):
            handlers[number] = callback

        def parse(handler):
            # The real request line has already been read. This additive witness
            # prevents a partial-header mutant from passing on an earlier EOF.
            headers.set()
            return original_parse(handler)

        def publish_attribute(server, name, value):
            original_setattr(server, name, value)
            if name == "active_request" and value is not None:
                captures.append((server, value))
                accepted.set()
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            elif (
                name == "active_stop_attempted"
                and value is False
                and getattr(server, "active_request", None) is not None
            ):
                handlers[signal.SIGTERM](signal.SIGTERM, None)

        def shutdown(request, how):
            if how == socket.SHUT_RDWR:
                shutdown_calls.append(request)
            if shutdown_refused and how == socket.SHUT_RDWR:
                failures.append("shutdown-refused")
                raise OSError(errno.EPERM, "controlled accepted-socket shutdown refusal")
            return original_shutdown(request, how)

        def peer():
            try:
                if not ready.wait(2):
                    raise AssertionError("owned loopback server did not acquire readiness")
                with socket.create_connection(("127.0.0.1", ports[0]), timeout=2) as client:
                    if partial:
                        client.sendall(b"GET /feed.xml HTTP/1.1\r\nHost: 127.0.0.1\r\n")
                    if not accepted.wait(2):
                        raise AssertionError("actual accepted socket did not enter its exact owner")
                    if partial and not headers.wait(2):
                        raise AssertionError("actual request line did not reach header parsing")
                    if native_signal:
                        os.kill(os.getpid(), signal.SIGTERM)
                    else:
                        # Explicit Windows/portable signal port: invoke the actual
                        # installed stop callback, never pretend native SIGTERM.
                        handlers[signal.SIGTERM](signal.SIGTERM, None)
                    try:
                        peers.append(client.recv(1))
                    except TimeoutError:
                        if not shutdown_refused:
                            raise
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=peer)
        raised = None
        filesystem_root = Path.cwd().resolve()
        try:
            with (
                mock.patch.object(helper, "private_directory", return_value=filesystem_root),
                mock.patch.object(helper, "publish", side_effect=publish),
                mock.patch.object(helper.http.server.HTTPServer, "finish_request", finish),
                mock.patch.object(
                    helper.http.server.BaseHTTPRequestHandler, "parse_request", parse
                ),
                mock.patch.object(socket.socket, "shutdown", shutdown),
                mock.patch.object(
                    helper.os,
                    "open",
                    side_effect=AssertionError("post-stop resource read is forbidden"),
                ) as reads,
            ):
                with contextlib.ExitStack() as scope:
                    if publication_cut:
                        scope.enter_context(
                            mock.patch.object(
                                helper.http.server.HTTPServer, "__setattr__", publish_attribute
                            )
                        )
                    if not native_signal:
                        scope.enter_context(
                            mock.patch.object(helper.signal, "signal", side_effect=install)
                        )
                    worker.start()
                    try:
                        helper.serve(str(filesystem_root), NONCE)
                    except BaseException as error:
                        raised = error
                    worker.join(2)
                    self.assertFalse(
                        worker.is_alive(),
                        "an acquired native peer must physically finish before fixture disposal",
                    )
                reads.assert_not_called()
        finally:
            if native_signal:
                for number, callback in old_handlers.items():
                    signal.signal(number, callback)
        self.assertEqual(len(captures), 1)
        server, request = captures[0]
        self.assertEqual(request.fileno(), -1, "the exact accepted socket must actually close")
        self.assertEqual(
            server.socket.fileno(), -1, "the exact listening socket must actually close"
        )
        self.assertIsNone(server.active_request)
        if publication_cut:
            self.assertEqual(
                shutdown_calls,
                [request],
                "accepted shutdown must be attempted exactly once across publication",
            )
        self.assertEqual(
            [name for name, _ in publications], ["server-start.json", "server-retired.json"]
        )
        self.assertEqual(publications[-1][1], {"nonce": NONCE, "pid": os.getpid(), "requests": 0})
        if shutdown_refused:
            self.assertIsInstance(raised, RuntimeError)
            self.assertEqual(str(raised), "Private Sparkle accepted-socket stop refused")
            self.assertIsInstance(server.stop_failure, OSError)
            self.assertEqual(
                failures,
                ["shutdown-refused"],
                "stop may not retry a refused native socket operation",
            )
        else:
            self.assertIsNone(raised)
            self.assertEqual(failures, [])
            self.assertEqual(
                peers, [b""], "the owned live peer must witness real EOF without closing first"
            )

    def testStopAtCapabilityPublicationCannotResetAndRepeatActualSocketShutdown(self):
        self.observe_stop(publication_cut=True)

    def testModeledStopInterruptsActualIdleAcceptedSocketAndClosesBothOwners(self):
        self.observe_stop()

    def testModeledStopInterruptsPartialHeadersWithoutReadingOrPublishingResource(self):
        self.observe_stop(partial=True)

    def testRefusedAcceptedShutdownRemainsFailureAfterActualSocketRetirement(self):
        self.observe_stop(shutdown_refused=True)

    @unittest.skipUnless(
        os.name == "posix",
        "Native SIGTERM is POSIX; modeled callback/real EOF controls remain mandatory on Windows",
    )
    def testActualPOSIXSignalInterruptsBothIdleAndPartialHeaderReads(self):
        for partial in (False, True):
            with self.subTest(partial=partial):
                self.observe_stop(partial=partial, native_signal=True)

    def observe_admitted_response_stop(self, native_signal=False):
        spec = importlib.util.spec_from_file_location("sparkle_response_stop_control", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        ready = threading.Event()
        ports, publications, captures, failures, responses, cuts = [], [], [], [], [], []
        handlers = {}
        old_handlers = {
            number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)
        }
        original_finish = helper.http.server.HTTPServer.finish_request
        original_headers = helper.http.server.BaseHTTPRequestHandler.end_headers

        def publish(file, value):
            publications.append((file.name, value))
            if file.name == "server-start.json":
                ports.append(value["port"])
                ready.set()

        def finish(server, request, address):
            captures.append((server, request))
            return original_finish(server, request, address)

        def install(number, callback):
            handlers[number] = callback

        def headers(handler):
            # The real headers have reached the peer; the real body write still
            # follows this additive cut. Neither operation is replaced or retried.
            result = original_headers(handler)
            cuts.append("headers-written-body-pending")
            if native_signal:
                os.kill(os.getpid(), signal.SIGTERM)
            else:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            return result

        def peer():
            try:
                if not ready.wait(2):
                    raise AssertionError("owned response server did not acquire readiness")
                with socket.create_connection(("127.0.0.1", ports[0]), timeout=2) as client:
                    client.sendall(b"GET /feed.xml HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
                    chunks = []
                    while True:
                        chunk = client.recv(4096)
                        if not chunk:
                            responses.append(b"".join(chunks))
                            break
                        chunks.append(chunk)
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=peer)
        raised = None
        with tempfile.TemporaryDirectory(prefix="sparkle-response-stop-") as temporary:
            filesystem_root = Path(temporary).resolve()
            (filesystem_root / "feed.xml").write_bytes(b"abc")
            try:
                with contextlib.ExitStack() as scope:
                    scope.enter_context(
                        mock.patch.object(helper, "private_directory", return_value=filesystem_root)
                    )
                    scope.enter_context(mock.patch.object(helper, "publish", side_effect=publish))
                    scope.enter_context(
                        mock.patch.object(helper.http.server.HTTPServer, "finish_request", finish)
                    )
                    scope.enter_context(
                        mock.patch.object(
                            helper.http.server.BaseHTTPRequestHandler, "end_headers", headers
                        )
                    )
                    if os.name != "posix":
                        # Windows has no O_NOFOLLOW. This filesystem flag is an
                        # explicit host seam; the socket and body writes are real.
                        scope.enter_context(
                            mock.patch.object(helper.os, "O_NOFOLLOW", 0, create=True)
                        )
                    if not native_signal:
                        scope.enter_context(
                            mock.patch.object(helper.signal, "signal", side_effect=install)
                        )
                    worker.start()
                    try:
                        helper.serve(str(filesystem_root), NONCE)
                    except BaseException as error:
                        raised = error
                    worker.join(2)
                    self.assertFalse(
                        worker.is_alive(), "owned response peer must finish before disposal"
                    )
            finally:
                if native_signal:
                    for number, callback in old_handlers.items():
                        signal.signal(number, callback)
        self.assertEqual(cuts, ["headers-written-body-pending"])
        self.assertEqual(len(captures), 1)
        server, request = captures[0]
        self.assertEqual(request.fileno(), -1)
        self.assertEqual(server.socket.fileno(), -1)
        self.assertIsNone(getattr(server, "active_request", None))
        self.assertIsNone(raised, "stopping must preserve an already admitted real body write")
        self.assertEqual(failures, [])
        self.assertEqual(len(responses), 1)
        actual_headers, body = responses[0].split(b"\r\n\r\n", 1)
        self.assertTrue(actual_headers.startswith(b"HTTP/1.0 200 "))
        self.assertIn(b"Content-Length: 3", actual_headers)
        self.assertEqual(body, b"abc", "the real response body must complete before EOF")
        self.assertEqual(
            [name for name, _ in publications],
            ["server-start.json", "request-000001.json", "server-retired.json"],
        )
        self.assertEqual(
            publications[1][1],
            {
                "nonce": NONCE,
                "path": "/feed.xml",
                "bytes": 3,
                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            },
        )
        self.assertEqual(publications[2][1], {"nonce": NONCE, "pid": os.getpid(), "requests": 1})

    def testModeledStopPreservesAdmittedResponseBodyAndExactSocketRetirement(self):
        self.observe_admitted_response_stop()

    @unittest.skipUnless(
        os.name == "posix",
        "Native SIGTERM is POSIX; modeled stop with real body remains mandatory on Windows",
    )
    def testActualPOSIXSignalPreservesAdmittedResponseBodyAndExactSocketRetirement(self):
        self.observe_admitted_response_stop(native_signal=True)


class SparkleStartupDiagnosticTests(unittest.TestCase):
    def testActualEntrypointTypedPhaseAndSecondaryExportFailurePreserveRefusal(self):
        spec = importlib.util.spec_from_file_location("sparkle_startup_diagnostic", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        failure = RuntimeError("PRIVATE_EXCEPTION_TEXT")
        stdout, stderr = io.StringIO(), io.StringIO()
        # Call actual serve admission, not a replacement of entrypoint or its collector.
        with (
            mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
            mock.patch.object(helper, "private_directory", side_effect=failure),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(helper.entrypoint(["serve", "/PRIVATE", NONCE]), 1)
        self.assertEqual(stdout.getvalue(), "")
        lines = [
            line
            for line in stderr.getvalue().splitlines()
            if not line.startswith("Sparkle server progress: ")
        ]
        self.assertEqual(lines[0], "Private Sparkle fixture refused.")
        self.assertEqual(len(lines), 2)
        packet = json.loads(lines[1].removeprefix("Sparkle server diagnostic: "))
        self.assertEqual(
            packet,
            {
                "schema": 1,
                "pid": os.getpid(),
                "phase": "directory-admission",
                "exception_type": "RuntimeError",
            },
        )
        self.assertNotIn("PRIVATE", stderr.getvalue())
        self.assertLessEqual(len(lines[1].split(": ", 1)[1].encode("utf-8")), 512)
        # The real collector fails during JSON encoding, after the primary refusal.
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
            mock.patch.object(helper, "private_directory", side_effect=failure),
            mock.patch.object(helper.json, "dumps", side_effect=OSError("PRIVATE_SECONDARY")),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(helper.entrypoint(["serve", "/PRIVATE", NONCE]), 1)
        self.assertEqual(
            (stdout.getvalue(), stderr.getvalue()), ("", "Private Sparkle fixture refused.\n")
        )
        # Even option admission is a secondary observer operation, not an error replacement.
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(helper, "private_directory", side_effect=failure),
            mock.patch.object(helper.os.environ, "get", side_effect=OSError("PRIVATE_OPTION")),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(helper.entrypoint(["serve", "/PRIVATE", NONCE]), 1)
        self.assertEqual(
            (stdout.getvalue(), stderr.getvalue()), ("", "Private Sparkle fixture refused.\n")
        )
        # Opt-out and census retain the old exact output contract.
        for argv, environment in [
            (["serve", "/PRIVATE", NONCE], {}),
            (["census", "/PRIVATE"], {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
        ]:
            stdout, stderr = io.StringIO(), io.StringIO()
            with (
                mock.patch.dict(helper.os.environ, environment, clear=True),
                mock.patch.object(helper, "main", side_effect=failure),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                self.assertEqual(helper.entrypoint(argv), 1)
            self.assertEqual(
                (stdout.getvalue(), stderr.getvalue()), ("", "Private Sparkle fixture refused.\n")
            )


class SparkleProgressDiagnosticTests(unittest.TestCase):
    def load_helper(self):
        spec = importlib.util.spec_from_file_location("sparkle_progress_control", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        return helper

    def testOptInProgressCarriesOnlyClosedPhaseAndPIDAtActualAdmissionCut(self):
        helper = self.load_helper()
        failure = RuntimeError("PRIVATE_PATH_EXCEPTION")
        stream = io.StringIO()
        with (
            mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
            mock.patch.object(helper, "private_directory", side_effect=failure),
            contextlib.redirect_stderr(stream),
        ):
            self.assertEqual(helper.entrypoint(["serve", "/PRIVATE_PATH", NONCE]), 1)
        rows = [
            json.loads(row.removeprefix("Sparkle server progress: "))
            for row in stream.getvalue().splitlines()
            if row.startswith("Sparkle server progress: ")
        ]
        self.assertEqual(
            rows,
            [
                {"schema": 1, "pid": os.getpid(), "phase": "entry"},
                {"schema": 1, "pid": os.getpid(), "phase": "directory-admission"},
            ],
        )
        self.assertNotIn("PRIVATE", stream.getvalue())
        self.assertNotIn(NONCE, stream.getvalue())
        self.assertTrue(all(len(json.dumps(row).encode()) <= 512 for row in rows))

    def testProgressOptionAndWriteFailureCannotChangePrimaryRefusal(self):
        helper = self.load_helper()
        failure = RuntimeError("PRIVATE_PRIMARY")
        with (
            mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
            mock.patch.object(helper, "private_directory", side_effect=failure),
            mock.patch.object(helper.json, "dumps", side_effect=OSError("PRIVATE_SECONDARY")),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(helper.entrypoint(["serve", "/PRIVATE", NONCE]), 1)
        for cancellation in [KeyboardInterrupt(), SystemExit(73)]:
            with (
                mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
                mock.patch.object(helper.json, "dumps", side_effect=cancellation),
            ):
                with self.assertRaises(type(cancellation)) as received:
                    helper.server_phase("entry")
                self.assertIs(received.exception, cancellation)

    def testProgressOptOutInvalidPhaseAndCensusCannotPublishPrivateCheckpoint(self):
        helper = self.load_helper()
        stream = io.StringIO()
        with mock.patch.dict(helper.os.environ, {}, clear=True), contextlib.redirect_stderr(stream):
            helper.server_phase("socket-bind")
        self.assertEqual(stream.getvalue(), "")
        with self.assertRaises(ValueError):
            helper.server_phase("/PRIVATE")
        with (
            mock.patch.dict(helper.os.environ, {"ERGOPTI_SPARKLE_SERVER_DIAGNOSTICS": "1"}),
            mock.patch.object(helper, "main", side_effect=RuntimeError("PRIVATE")),
            contextlib.redirect_stderr(stream),
        ):
            self.assertEqual(helper.entrypoint(["census", "/PRIVATE"]), 1)
        self.assertNotIn("Sparkle server progress:", stream.getvalue())


if __name__ == "__main__":
    unittest.main()

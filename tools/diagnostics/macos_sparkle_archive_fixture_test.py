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
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


HELPER = Path(__file__).with_name("macos_sparkle_archive_fixture.py")
NONCE = "a" * 32


class PrivateSparkleTransportTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()

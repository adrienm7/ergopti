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


if __name__ == "__main__":
    unittest.main()

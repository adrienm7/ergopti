"""Portable physical peers and passive owned-child receiving facts."""

import hashlib
import re
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
import urllib.request
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "static/ergopti_plus/macos/tests/support"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WIRE = load("receiving_fact_wire", SUPPORT / "native_http_wire_fixture.py")
CLIENT = load("receiving_fact_client", SUPPORT / "native_http_wire_client_receiving.py")


class NativeHTTPReceivingFactsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

    def wait_counter(self, name, value):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if self.fixture.receiving_facts()[name] == value:
                return
            time.sleep(0.01)
        self.assertEqual(self.fixture.receiving_facts()[name], value)

    def proxy(self):
        raw = socket.create_connection(("127.0.0.1", self.fixture.ports["first"]), timeout=3)
        raw.sendall(
            f"CONNECT {self.fixture.host}:{self.fixture.origin_port} HTTP/1.1\r\n\r\n".encode()
        )
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            part = raw.recv(1)
            self.assertTrue(part)
            header.extend(part)
        self.assertIn(b"200 Connection Established", header)
        return raw

    def test01RealProxyTLSOriginCountsWithoutChangingOriginalRecords(self):
        context = ssl.create_default_context(cafile=str(self.fixture.ca))
        with self.proxy() as raw:
            with context.wrap_socket(raw, server_hostname=self.fixture.host) as tls:
                tls.sendall(b"GET /alpha?case=one HTTP/1.0\r\n\r\n")
                response = bytearray()
                while part := tls.recv(4096):
                    response.extend(part)
        self.assertEqual(response.split(b"\r\n\r\n", 1)[1], b"owned\x00native\xffwire")
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertEqual(
            snapshot["records"],
            [
                {"event": "connect", "route": "first"},
                {"event": "origin", "route": "first", "path": "/alpha?case=one"},
            ],
        )
        facts = self.fixture.receiving_facts()
        for key in (
            "accept_proxy",
            "accept_origin",
            "handshake_started",
            "handshake_complete",
            "request_origin",
            "connect_complete",
        ):
            self.assertEqual(facts[key], 1)
        self.assertEqual(facts["handshake_refused"], 0)

    def test02ActualUntrustedHandshakeHasNoOriginRequest(self):
        with self.proxy() as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                ssl.create_default_context().wrap_socket(raw, server_hostname=self.fixture.host)
        self.wait_counter("handshake_refused", 1)
        self.assertEqual(self.fixture.stats()["active"], 0)
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["handshake_started"], 1)
        self.assertEqual(facts["handshake_complete"], 0)
        self.assertEqual(facts["request_origin"], 0)

    def test03MalformedConnectIsObservedWithoutRelaxingStrictRecipient(self):
        with socket.create_connection(("127.0.0.1", self.fixture.ports["first"]), timeout=3) as raw:
            raw.sendall(b"CONNECT wrong.invalid:443 HTTP/1.0\r\n\r\n")
            self.assertEqual(raw.recv(1), b"")
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["connect_refused"], 1)
        self.assertEqual(facts["connect_complete"], 0)
        self.assertEqual(self.fixture.stats()["records"], [])

    def test04ActualPACRequestCountsRemainSeparateFromTLS(self):
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(self.fixture.pac_url, timeout=3) as response:
            self.assertEqual(response.read().decode(), self.fixture.pac)
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_pac"], 1)
        self.assertEqual(facts["request_pac"], 1)
        self.assertEqual(facts["handshake_started"], 0)
        self.assertEqual(self.fixture.stats()["records"], [])

    def test05PassiveOwnerFactsRequireActualReapAndBothPipeClosures(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "pass"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        receiver = SimpleNamespace(_process=process, _closed=False)
        try:
            facts = CLIENT.worker_receiving_facts(receiver)
            self.assertEqual(facts["settled"], 0)
            process.communicate(timeout=3)
            facts = CLIENT.worker_receiving_facts(receiver)
            self.assertEqual(facts["reaped"], 1)
            self.assertEqual(facts["exit_complete"], 1)
            self.assertEqual(facts["exit_deadline"], 0)
            self.assertEqual(facts["exit_killed"], 0)
            self.assertEqual(facts["stdin_closed"], 1)
            self.assertEqual(facts["stdout_closed"], 1)
            self.assertEqual(facts["settled"], 0)
            receiver._closed = True
            self.assertEqual(CLIENT.worker_receiving_facts(receiver)["settled"], 1)
            receiver._process = SimpleNamespace(
                returncode=None, stdin=process.stdin, stdout=process.stdout
            )
            self.assertEqual(CLIENT.worker_receiving_facts(receiver)["settled"], 0)
            receiver._process = process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout):
                stream.close()

    def test06CountersAreFixedBoundedAndSnapshotsCannotAlterOwner(self):
        self.fixture.receiving_counts["accept_proxy"] = 65535
        self.fixture._receive("accept_proxy")
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_proxy"], 65535)
        facts["accept_proxy"] = 0
        self.assertEqual(self.fixture.receiving_facts()["accept_proxy"], 65535)
        with self.assertRaises(WIRE.FixtureFailure):
            self.fixture._receive("unapproved")
        self.assertEqual(
            set(facts),
            {
                "version",
                "active",
                "accept_origin",
                "accept_proxy",
                "accept_socks",
                "accept_pac",
                "handshake_started",
                "handshake_complete",
                "handshake_refused",
                "request_origin",
                "request_pac",
                "connect_complete",
                "connect_refused",
            },
        )
        self.assertTrue(all(type(value) is int and 0 <= value <= 65535 for value in facts.values()))

    def test07RestorationRefusalRemainsPrimaryWhenDiagnosticOutputFails(self):
        primary = RuntimeError("controlled restoration refusal")

        def refused():
            raise primary

        fixture = SimpleNamespace(
            close=refused,
            closed=False,
            trust_attempted=True,
            keychain_created=True,
            receiving_facts=lambda: {"active": 2},
        )
        owner = SimpleNamespace(fixture=fixture)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(RuntimeError) as refusal:
                CLIENT.RealNativeClientReceiving.tearDownClass.__func__(owner)
        self.assertIs(refusal.exception, primary)
        self.assertEqual(
            json.loads(output.getvalue().removeprefix("# native_http_fixture_closure ")),
            {
                "version": 1,
                "closed": 0,
                "trust_unsettled": 1,
                "keychain_unsettled": 1,
                "active": 2,
            },
        )
        with mock.patch("builtins.print", side_effect=BrokenPipeError()):
            with self.assertRaises(RuntimeError) as refusal:
                CLIENT.RealNativeClientReceiving.tearDownClass.__func__(owner)
        self.assertIs(refusal.exception, primary)

    def test08Actual407RefusalCannotClaimCompletedConnect(self):
        with socket.create_connection(("127.0.0.1", self.fixture.ports["auth"]), timeout=3) as raw:
            raw.sendall(
                f"CONNECT {self.fixture.host}:{self.fixture.origin_port} HTTP/1.1\r\n\r\n".encode()
            )
            response = bytearray()
            while part := raw.recv(4096):
                response.extend(part)
        self.assertTrue(response.startswith(b"HTTP/1.1 407 Proxy Authentication Required\r\n"))
        self.assertIn(b'Proxy-Authenticate: Basic realm="owned"\r\n', response)
        self.assertEqual(self.fixture.stats()["active"], 0)
        self.assertEqual(self.fixture.stats()["records"], [{"event": "connect", "route": "auth"}])
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_proxy"], 1)
        self.assertEqual(facts["connect_refused"], 1)
        self.assertEqual(facts["connect_complete"], 0)
        self.assertEqual(facts["accept_origin"], 0)
        self.assertEqual(facts["handshake_started"], 0)
        self.assertEqual(facts["request_origin"], 0)


class NativeHTTPStageReceiptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix="ergopti-http-stage-control-")
        self.addCleanup(self.root.cleanup)
        self.target = Path(self.root.name) / "stages"
        self.receipt = CLIENT.WorkerStageReceipt(self.target)
        self.addCleanup(self.close_receipt)
        self.receiver = SimpleNamespace(_process=None, _closed=True)

    def close_receipt(self):
        self.receipt.close()

    def write(self, data):
        with self.target.open("ab") as output:
            output.write(data)

    def test01ActualChildWritesFixedStagesAndMustBeReapedBeforeObservation(self):
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys,time;open(sys.argv[1],'ab').write(b'entry\\narguments\\n');time.sleep(.1)",
                str(self.target),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.receiver._process = process
        try:
            self.assertEqual(
                self.receipt.facts(self.receiver), {"state": "unsettled", "stages": []}
            )
            process.communicate(timeout=3)
            self.assertEqual(
                self.receipt.facts(self.receiver),
                {"state": "observed", "stages": ["entry", "arguments"]},
            )
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout):
                stream.close()

    def test02MalformedPrivateBytesNeverBecomeRawDiagnosticPayload(self):
        for body in (
            b"private-url-secret\n",
            b"entry\nentry\n",
            b"arguments\nentry\n",
            b"entry",
            b"\xff\n",
            b"x" * 257,
        ):
            with self.subTest(body=body):
                os.ftruncate(self.receipt.descriptor, 0)
                self.write(body)
                self.assertEqual(
                    self.receipt.facts(self.receiver),
                    {"state": "refused", "stages": []},
                )
        os.ftruncate(self.receipt.descriptor, 0)
        self.assertEqual(self.receipt.facts(self.receiver), {"state": "empty", "stages": []})

    def test03ExactFDRefusesReplacementAndClosePreservesForeignName(self):
        descriptor = self.receipt.descriptor
        identity = os.fstat(descriptor)
        with mock.patch.object(
            CLIENT.os, "close", side_effect=OSError("controlled before-close refusal")
        ):
            with self.assertRaises(OSError):
                self.receipt.close()
        self.assertEqual(self.receipt.descriptor, descriptor)
        self.assertFalse(self.receipt.closed)
        self.assertTrue(self.receipt.close_uncertain)
        self.assertTrue(self.target.exists())
        self.assertEqual(os.fstat(descriptor).st_ino, identity.st_ino)
        with mock.patch.object(CLIENT.os, "close") as close:
            with self.assertRaises(RuntimeError):
                self.receipt.close()
            close.assert_not_called()
        # This test's controlled refusal provably never called the real close.
        # Test cleanup is not a production retry permission for an uncertain FD.
        os.close(descriptor)
        self.target.unlink()
        self.receipt = CLIENT.WorkerStageReceipt(self.target)
        descriptor = self.receipt.descriptor
        real_close = os.close
        reused = []

        def closed_then_refused(value):
            real_close(value)
            replacement = os.open(self.target, os.O_RDWR)
            if replacement != value:
                os.dup2(replacement, value)
                real_close(replacement)
                replacement = value
            reused.append(replacement)
            raise OSError("controlled error after actual closure")

        with mock.patch.object(CLIENT.os, "close", side_effect=closed_then_refused):
            with self.assertRaises(OSError):
                self.receipt.close()
        self.assertEqual(reused, [descriptor])
        self.assertEqual(os.fstat(descriptor).st_ino, self.receipt.identity.st_ino)
        self.assertTrue(self.receipt.close_uncertain)
        self.assertEqual(self.receipt.facts(self.receiver), {"state": "refused", "stages": []})
        with self.assertRaises(RuntimeError):
            self.receipt.retire_name(self.receiver, self.target.with_name("uncertain-next"))
        with mock.patch.object(CLIENT.os, "close") as close:
            with self.assertRaises(RuntimeError):
                self.receipt.close()
            close.assert_not_called()
        self.assertEqual(os.fstat(descriptor).st_ino, self.receipt.identity.st_ino)
        self.assertTrue(self.target.exists())
        real_close(descriptor)
        self.target.unlink()
        self.receipt = CLIENT.WorkerStageReceipt(self.target)
        self.target.unlink()
        self.target.write_bytes(b"foreign-preserved")
        self.assertEqual(self.receipt.facts(self.receiver), {"state": "refused", "stages": []})
        self.receipt.close()
        self.assertTrue(self.receipt.closed)
        self.assertEqual(self.target.read_bytes(), b"foreign-preserved")

    def test04RetiredWorkerKeepsDistinctFDReceiptAcrossNextExclusiveChild(self):
        self.write(b"entry\narguments\n")
        self.receiver._process = SimpleNamespace(
            returncode=0,
            stdin=SimpleNamespace(closed=True),
            stdout=SimpleNamespace(closed=True),
        )
        previous = self.target.with_name("previous")
        self.receipt.retire_name(self.receiver, previous)
        next_receipt = CLIENT.WorkerStageReceipt(self.target)
        try:
            self.target.write_bytes(b"entry\n")
            self.assertEqual(self.receipt.facts(self.receiver)["stages"], ["entry", "arguments"])
            self.assertEqual(next_receipt.facts(self.receiver)["stages"], ["entry"])
        finally:
            next_receipt.close()

    def test05UnsettledPhysicalWorkerCannotTransferItsDiagnosticName(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import sys;sys.stdin.buffer.read()"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.receiver._process = process
        self.receiver._closed = False
        self.receiver._fixture_stage_receipt = self.receipt
        descriptor = self.receipt.descriptor
        try:
            with self.assertRaises(RuntimeError):
                self.receipt.retire_name(self.receiver, self.target.with_name("next"))
            owner = SimpleNamespace(
                receiving_workers=[self.receiver],
                receiving_start=0,
                fixture=SimpleNamespace(receiving_facts=lambda: {"version": 1, "active": 0}),
            )
            with contextlib.redirect_stdout(io.StringIO()) as output:
                CLIENT.RealNativeClientReceiving.report_receiving_facts(owner)
            fact = json.loads(output.getvalue().removeprefix("# native_http_receiving "))
            self.assertEqual(fact["stage_receipts"]["unsettled"], 1)
            self.assertEqual(fact["stage_closure_unsettled"], 1)
            self.assertEqual(sum(fact["entry_stages"].values()), 0)
            self.assertEqual(self.receipt.descriptor, descriptor)
            self.assertEqual(os.fstat(descriptor).st_ino, self.receipt.identity.st_ino)
            self.assertTrue(self.target.exists())
            process.communicate(timeout=3)
            self.assertEqual(self.receipt.facts(self.receiver)["state"], "unsettled")
            self.receiver._closed = True
            self.assertEqual(self.receipt.facts(self.receiver)["state"], "empty")
            original_stdout = process.stdout
            process.stdout = SimpleNamespace(closed=False)
            self.assertEqual(self.receipt.facts(self.receiver)["state"], "unsettled")
            process.stdout = original_stdout
            original_stdin = process.stdin
            process.stdin = SimpleNamespace(closed=False)
            self.assertEqual(self.receipt.facts(self.receiver)["state"], "unsettled")
            process.stdin = original_stdin
            self.receipt.close()
            self.assertTrue(self.receipt.closed)
            self.assertFalse(self.target.exists())
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout):
                stream.close()

    def test06ActualCommandExitAndDeadlineKeepFixedPhaseWithoutPrivateArguments(self):
        owner = WIRE.WireFixture.__new__(WIRE.WireFixture)
        owner.groups = None
        owner.command_file_debt = []
        with self.assertRaises(WIRE.FixtureFailure):
            owner._command([sys.executable, "-c", "raise SystemExit(7)", "private-secret"])
        self.assertEqual(owner.command_fact, {"phase": "exit", "status": 7})
        with self.assertRaises(subprocess.TimeoutExpired):
            owner._command(
                [sys.executable, "-c", "import time;time.sleep(5)", "private-secret"],
                timeout=0.1,
            )
        self.assertEqual(owner.command_fact, {"phase": "deadline", "status": None})
        self.assertNotIn("private-secret", json.dumps(owner.command_fact))

    def test07RestorationReceiptPrintFailureNeverReplacesOriginalException(self):
        owner = WIRE.WireFixture.__new__(WIRE.WireFixture)
        owner.command_fact = {"phase": "exit", "status": 1}
        with contextlib.redirect_stdout(io.StringIO()) as output:
            owner._report_restoration_failure("trust")
        self.assertEqual(
            json.loads(output.getvalue().removeprefix("# native_http_restoration_failure ")),
            {"version": 1, "operation": "trust", "phase": "exit", "status": 1},
        )
        for exception in (BrokenPipeError(), ValueError("closed stdout")):
            with mock.patch("builtins.print", side_effect=exception):
                owner._report_restoration_failure("trust")
        output = io.StringIO()
        output.close()
        with contextlib.redirect_stdout(output):
            owner._report_restoration_failure("trust")
        primary = RuntimeError("controlled restoration refusal")

        def refused():
            raise primary

        fixture_owner = SimpleNamespace(
            fixture=SimpleNamespace(
                close=refused,
                closed=False,
                trust_attempted=True,
                keychain_created=False,
                receiving_facts=lambda: {"active": 0},
            )
        )
        with contextlib.redirect_stdout(output):
            with self.assertRaises(RuntimeError) as refusal:
                CLIENT.RealNativeClientReceiving.tearDownClass.__func__(fixture_owner)
        self.assertIs(refusal.exception, primary)

    def test08ActualRetiredChildReportsAllClosedInternalLabelsWithinOriginalBound(self):
        labels = (
            "entry",
            "arguments",
            "stdin_eof",
            "request",
            "settings",
            "policy",
            "execute",
            "settings_provider",
            "proxy_copy",
            "proxy_copied",
            "pac_url",
            "pac_script",
            "pac_callback",
            "pac_source",
            "pac_wait",
            "pac_done",
            "routes_done",
            "session_resume",
            "session_wait",
            "first_frame",
            "session_invalid",
            "session_done",
            "returned",
        )
        raw = ("\n".join(labels) + "\n").encode("ascii")
        self.assertLessEqual(len(raw), 256)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import os,sys;data=sys.stdin.buffer.read();fd=os.open(sys.argv[1],os.O_WRONLY|os.O_APPEND);os.write(fd,data);os.close(fd)",
                str(self.target),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.receiver._process = process
        try:
            self.assertEqual(self.receipt.facts(self.receiver)["state"], "unsettled")
            process.communicate(raw, timeout=3)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(
                self.receipt.facts(self.receiver),
                {"state": "observed", "stages": list(labels)},
            )
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout):
                stream.close()

    def test09InternalCallbackInterleavingPreservesOriginalOrderAndClosedGrammar(self):
        valid = b"entry\nproxy_copy\narguments\npac_callback\npac_source\nfirst_frame\nreturned\n"
        self.write(valid)
        self.assertEqual(
            self.receipt.facts(self.receiver)["stages"],
            valid.decode("ascii").splitlines(),
        )
        for invalid in (
            b"entry\npac_wait\npac_wait\n",
            b"arguments\npac_callback\nentry\n",
            b"entry\nprivate-URL-or-certificate\n",
        ):
            with self.subTest(payload=invalid):
                os.ftruncate(self.receipt.descriptor, 0)
                self.write(invalid)
                self.assertEqual(
                    self.receipt.facts(self.receiver),
                    {"state": "refused", "stages": []},
                )

    def test10FixtureFlagCannotChangeReleaseOperationsOrMoveCausalBoundaries(self):
        worker = SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        source = worker.read_text(encoding="utf-8")
        blocks = re.findall(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            source,
            re.MULTILINE | re.DOTALL,
        )
        labels = tuple(
            re.search(r'managedHTTPFixtureStage\("([a-z_]+)"\)', block).group(1) for block in blocks
        )
        self.assertEqual(
            set(labels),
            {
                "proxy_copy",
                "proxy_copied",
                "pac_url",
                "pac_script",
                "pac_source",
                "pac_wait",
                "pac_callback",
                "pac_done",
                "routes_done",
                "session_resume",
                "session_wait",
                "session_invalid",
                "session_done",
            },
        )
        self.assertEqual(len(labels), 13)
        release = re.sub(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            "",
            source,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertEqual(
            hashlib.sha256(release.encode("utf-8")).hexdigest(),
            "68659ddec98c9a427244b315b69c17750b743eab2cdd3688308690a66d1c6e98",
        )
        copy = "CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()"
        self.assertLess(source.index('managedHTTPFixtureStage("proxy_copy")'), source.index(copy))
        self.assertLess(source.index(copy), source.index('managedHTTPFixtureStage("proxy_copied")'))
        self.assertLess(
            source.index('managedHTTPFixtureStage("pac_script")'),
            source.index("source = CFNetworkExecuteProxyAutoConfigurationScript"),
        )
        self.assertLess(
            source.index('managedHTTPFixtureStage("pac_url")'),
            source.index("source = CFNetworkExecuteProxyAutoConfigurationURL"),
        )
        self.assertLess(
            source.index('managedHTTPFixtureStage("pac_wait")'),
            source.index("CFRunLoopRunInMode"),
        )
        self.assertLess(
            source.index('managedHTTPFixtureStage("session_resume")'),
            source.index("owned.dataTask(with: native).resume()"),
        )
        self.assertLess(
            source.index('managedHTTPFixtureStage("session_wait")'),
            source.index("completion.wait()"),
        )
        self.assertLess(
            source.index("completion.wait()"),
            source.index('managedHTTPFixtureStage("session_done")'),
        )
        fixture = (SUPPORT / "native_http_fixture_main.swift").read_text(encoding="utf-8")
        self.assertIn("guard lock.try() else { return }", fixture)
        self.assertIn("defer { lock.unlock() }", fixture)
        self.assertNotIn("lock.lock()", fixture)
        self.assertIn("FixtureHTTPObservation.owner?.mark(stage)", fixture)
        compiler = (SUPPORT / "native_http_wire_client_receiving.py").read_text(encoding="utf-8")
        self.assertIn(
            '"-D",\n                    "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",',
            compiler,
        )


class NativeAdminTrustObservationTests(unittest.TestCase):
    # These controls exercise real portable children and restoration arbitration;
    # they do not substitute for the public Security APIs on macOS.
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

    def receipt(self, **changes):
        fields = {
            "version": 1,
            "export_status": 0,
            "entry_count": 1,
            "owned_status": 0,
            "owned_present": 1,
        }
        fields.update(changes)
        return json.dumps(fields).encode()

    def test19StrictCountOnlyReceiptRejectsMalformedAndInconsistentClaims(self):
        source = (SUPPORT / "native_http_fixture_main.swift").read_text(encoding="utf-8")
        query = source.split("private func fixtureAdminTrustQuery() -> Int32 {", 1)[1].split(
            "// Fixed lexical stages", 1
        )[0]
        self.assertEqual(
            re.findall(r"\b(Sec\w+)\(", query),
            [
                "SecCertificateCreateWithData",
                "SecTrustSettingsCopyTrustSettings",
                "SecTrustSettingsCreateExternalRepresentation",
            ],
        )
        self.assertIn("Darwin.read(STDIN_FILENO", query)
        self.assertIn('Set(fields.keys) == Set(["trustVersion", "trustList"])', query)
        self.assertIn("CFGetTypeID(version) != CFBooleanGetTypeID()", query)
        self.assertIn("SecTrustSettingsCopyTrustSettings(certificate, .admin", query)
        self.assertIn("SecTrustSettingsCreateExternalRepresentation(.admin", query)
        main = source.split("func fixtureMain() -> Int32 {", 1)[1]
        self.assertLess(
            main.index("fixtureAdminTrustQuery()"), main.index("let stages = FixtureStages")
        )
        self.assertEqual(WIRE.WireFixture._admin_trust_fact(self.receipt())["entry_count"], 1)
        self.assertEqual(
            WIRE.WireFixture._admin_trust_fact(
                self.receipt(
                    export_status=-25263, entry_count=0, owned_status=-25300, owned_present=0
                )
            )["owned_present"],
            0,
        )
        self.assertIsNone(
            WIRE.WireFixture._admin_trust_fact(
                self.receipt(
                    export_status=-36, entry_count=None, owned_status=-36, owned_present=None
                )
            )["entry_count"]
        )
        refused = [
            b"[]",
            b"null",
            b"{}",
            b"{",
            b"x" * 1025,
            self.receipt(version=True),
            self.receipt(version=2),
            self.receipt(entry_count=True),
            self.receipt(entry_count=-1),
            self.receipt(entry_count=65536),
            self.receipt(entry_count=0),
            self.receipt(owned_present=True),
            self.receipt(owned_present=0),
            self.receipt(owned_status=True),
            self.receipt(export_status=2**31),
            self.receipt(export_status=-36),
            self.receipt(export_status=-25263),
            self.receipt(owned_status=-25300),
            self.receipt(owned_status=-36),
            self.receipt(raw_certificate="private certificate"),
            self.receipt().replace(b'"version": 1', b'"version": 1, "version": 1'),
        ]
        for raw in refused:
            with self.subTest(raw_length=len(raw)):
                with self.assertRaises(WIRE.FixtureFailure):
                    WIRE.WireFixture._admin_trust_fact(raw)

    def command_control(self, query_body, removal_failure=None):
        original = self.fixture._command
        received, removals, children = [], [], []
        real_popen = subprocess.Popen

        def acquire(*arguments, **options):
            child = real_popen(*arguments, **options)
            child.controlled_output = options["stdout"]
            child.controlled_errors = options["stderr"]
            children.append(child)
            return child

        def command(arguments, input_bytes=b"", **options):
            if arguments[0] == "portable-owned-query":
                received.append(input_bytes)
                return original([sys.executable, "-B", "-c", query_body], input_bytes, **options)
            removals.append((arguments, options, time.monotonic()))
            if removal_failure is not None:
                raise removal_failure
            return 0, b""

        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.trust_query_executable = "portable-owned-query"
        return command, acquire, received, removals, children

    def test20ActualQueryIsReapedBeforeReceiptAndConsumesOriginalRemovalBudget(self):
        body = (
            "import sys,time; data=sys.stdin.buffer.read(); time.sleep(.08); sys.stdout.buffer.write("
            + repr(self.receipt())
            + ")"
        )
        command, acquire, received, removals, children = self.command_control(body)
        output = io.StringIO()
        before = time.monotonic()
        with mock.patch.object(self.fixture, "_command", side_effect=command):
            with mock.patch.object(WIRE.subprocess, "Popen", side_effect=acquire):
                with contextlib.redirect_stdout(output):
                    self.fixture.trust(False)
        after = time.monotonic()
        self.assertEqual(received, [ssl.PEM_cert_to_DER_cert(self.fixture.ca.read_text())])
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].returncode, 0)
        self.assertTrue(children[0].stdin.closed)
        self.assertTrue(children[0].controlled_output.closed)
        self.assertTrue(children[0].controlled_errors.closed)
        self.assertEqual(len(removals), 1)
        arguments, options, invoked = removals[0]
        self.assertEqual(arguments[3:5], ["remove-trusted-cert", "-d"])
        self.assertGreaterEqual(options["deadline"], before + 15)
        self.assertLessEqual(options["deadline"], after + 15)
        self.assertLess(options["deadline"] - invoked, 14.95)
        self.assertFalse(self.fixture.trust_attempted)
        self.assertEqual(json.loads(output.getvalue().split(" ", 2)[2])["observed"], 1)

    def test21RefusedOrMalformedQueryDoesNotPayFailedRemovalDebt(self):
        for body in (
            "import sys; sys.stdin.buffer.read(); sys.exit(7)",
            "import sys; sys.stdin.buffer.read(); print('{}')",
        ):
            primary = RuntimeError("original controlled removal refusal")
            command, acquire, _, removals, children = self.command_control(body, primary)
            output = io.StringIO()
            with mock.patch.object(self.fixture, "_command", side_effect=command):
                with mock.patch.object(WIRE.subprocess, "Popen", side_effect=acquire):
                    with contextlib.redirect_stdout(output):
                        with self.assertRaises(RuntimeError) as refusal:
                            self.fixture.trust(False)
            self.assertIs(refusal.exception, primary)
            self.assertTrue(self.fixture.trust_attempted)
            self.assertEqual(len(removals), 1)
            self.assertIsNotNone(children[0].returncode)
            self.assertTrue(children[0].stdin.closed)
            self.assertEqual(
                json.loads(output.getvalue().split(" ", 2)[2]), {"version": 1, "observed": 0}
            )
        self.fixture.native = False
        self.fixture.trust_attempted = False

    def test22ExhaustedOriginalBudgetCannotAcquireRemovalOrRetireDebt(self):
        self.fixture.native = True
        self.fixture.trust_attempted = True
        deadlines = []

        def observe(deadline):
            deadlines.append(deadline)

        with mock.patch.object(self.fixture, "_observe_admin_trust", side_effect=observe):
            with mock.patch.object(WIRE.time, "monotonic", side_effect=[100.0, 115.0]):
                with mock.patch.object(self.fixture, "_command") as command:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        self.fixture.trust(False)
        self.assertEqual(deadlines, [115.0])
        command.assert_not_called()
        self.assertTrue(self.fixture.trust_attempted)
        self.assertEqual(self.fixture.command_fact, {"phase": "deadline", "status": None})
        self.fixture.native = False
        self.fixture.trust_attempted = False

    def test23UnsettledQueryAndClosedOutputPreserveOriginalClosureAuthority(self):
        self.fixture.trust_query_executable = "portable-owned-query"
        primary = RuntimeError("original controlled query closure refusal")

        def refuse(*arguments, **options):
            self.fixture.command_fact = {"phase": "settle", "status": None}
            raise primary

        with mock.patch.object(self.fixture, "_command", side_effect=refuse):
            with mock.patch("builtins.print") as output:
                with self.assertRaises(RuntimeError) as refusal:
                    self.fixture._observe_admin_trust(time.monotonic() + 15)
        self.assertIs(refusal.exception, primary)
        output.assert_not_called()
        self.fixture.command_fact = None
        for failure in (
            OSError("closed controlled output"),
            ValueError("closed controlled output"),
        ):
            with mock.patch.object(self.fixture, "_command", return_value=(0, self.receipt())):
                with mock.patch("builtins.print", side_effect=failure):
                    self.fixture._observe_admin_trust(time.monotonic() + 15)

    def test24CommandAbsoluteDeadlineRefusesAcquisitionAndClosesActualTimedChild(self):
        arguments = [sys.executable, "-B", "-c", "import time; time.sleep(30)"]
        with mock.patch.object(WIRE.subprocess, "Popen") as acquire:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.fixture._command(arguments, deadline=time.monotonic() - 1)
        acquire.assert_not_called()
        real_popen = subprocess.Popen
        children = []

        def capture(*arguments, **options):
            child = real_popen(*arguments, **options)
            children.append(child)
            return child

        with mock.patch.object(WIRE.subprocess, "Popen", side_effect=capture):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.fixture._command(arguments, deadline=time.monotonic() + 0.05)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].returncode)
        self.assertTrue(children[0].stdin.closed)
        self.assertEqual(self.fixture.command_fact["phase"], "deadline")

    def test25RealTemporaryOutputCloseRefusalRetainsExactOwnerAndTrustDebt(self):
        original = self.fixture._command
        primary = RuntimeError("controlled exact output close refusal")
        real_temporary_file = tempfile.TemporaryFile
        held, removals = [], []
        body = (
            "import sys;sys.stdin.buffer.read();sys.stdout.buffer.write("
            + repr(self.receipt())
            + ")"
        )

        class RetainedOutput:
            allow_close = False

            def __init__(self, owner):
                self.owner = owner

            def __getattr__(self, name):
                return getattr(self.owner, name)

            def close(self):
                if not self.allow_close:
                    raise primary
                self.owner.close()

        def allocate(*arguments, **options):
            owner = real_temporary_file(*arguments, **options)
            if not held:
                owner = RetainedOutput(owner)
                held.append(owner)
            return owner

        def command(arguments, input_bytes=b"", **options):
            if arguments[0] == "portable-owned-query":
                return original([sys.executable, "-B", "-c", body], input_bytes, **options)
            removals.append(arguments)
            return 0, b""

        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.trust_query_executable = "portable-owned-query"
        with mock.patch.object(self.fixture, "_command", side_effect=command):
            with mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=allocate):
                with mock.patch("builtins.print") as output:
                    with self.assertRaises(RuntimeError) as refusal:
                        self.fixture.trust(False)
        self.assertIs(refusal.exception, primary)
        output.assert_not_called()
        self.assertEqual(removals, [])
        self.assertTrue(self.fixture.trust_attempted)
        self.assertEqual(self.fixture.command_file_debt, [{"stream": held[0], "uncertain": False}])
        self.assertFalse(held[0].closed)
        os.fstat(held[0].fileno())
        self.assertEqual(self.fixture.command_fact["phase"], "settle")
        self.assertFalse(self.fixture._retire_command_files())
        with mock.patch.object(WIRE.subprocess, "Popen") as acquire:
            with self.assertRaises(WIRE.FixtureFailure):
                original([sys.executable, "-B", "-c", "pass"])
        acquire.assert_not_called()
        self.assertEqual(self.fixture.command_file_debt, [{"stream": held[0], "uncertain": False}])
        held[0].allow_close = True
        self.assertTrue(self.fixture._retire_command_files())
        self.assertTrue(held[0].closed)
        self.assertEqual(self.fixture.command_file_debt, [])
        self.fixture.native = False
        self.fixture.trust_attempted = False

    def test26RealGroupedStdinRefusalPreservesPrimaryAndExactPipeAfterPhysicalReap(self):
        # The controlled group adapter kills/reaps real portable children. It is
        # deliberately not evidence about Darwin LibProc ownership.
        primary = RuntimeError("controlled exact stdin close refusal")
        write_primary = RuntimeError("controlled exact stdin write refusal")
        original = self.fixture._command
        real_popen = subprocess.Popen
        held, children, removals = [], [], []
        fail_write = False

        class RetainedInput:
            allow_close = False

            def __init__(self, owner):
                self.owner = owner

            def __getattr__(self, name):
                return getattr(self.owner, name)

            def write(self, data):
                if fail_write:
                    raise write_primary
                count = self.owner.write(data)
                self.owner.flush()
                return count

            def close(self):
                if not self.allow_close:
                    raise primary
                self.owner.close()

        class OwnedControl:
            def __init__(self, child):
                self.process = child

            def wait_for_exit(self, timeout):
                self.process.wait(timeout=timeout)

            def settle(self):
                if self.process.poll() is None:
                    self.process.kill()
                self.process.wait()
                return True

        class ControlledGroups:
            def acquire_owned(self, arguments, native_groups, register, **options):
                child = real_popen(arguments, **options)
                child.stdin = RetainedInput(child.stdin)
                held.append(child.stdin)
                children.append(child)
                register(OwnedControl(child))

        def command(arguments, input_bytes=b"", **options):
            if arguments[0] == "portable-owned-query":
                return original(
                    [sys.executable, "-B", "-c", "import sys;sys.stdin.buffer.read()"],
                    input_bytes,
                    **options,
                )
            removals.append(arguments)
            return 0, b""

        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.trust_query_executable = "portable-owned-query"
        self.fixture.groups = ControlledGroups()
        self.fixture.native_groups = None
        for fail_write in (False, True):
            with mock.patch.object(self.fixture, "_command", side_effect=command):
                with mock.patch("builtins.print") as output:
                    with self.assertRaises(RuntimeError) as refusal:
                        self.fixture.trust(False)
            self.assertIs(refusal.exception, write_primary if fail_write else primary)
            output.assert_not_called()
            self.assertTrue(self.fixture.trust_attempted)
            self.assertEqual(removals, [])
            self.assertIsNotNone(children[-1].returncode)
            self.assertFalse(held[-1].closed)
            os.fstat(held[-1].fileno())
            self.assertEqual(
                self.fixture.command_file_debt, [{"stream": held[-1], "uncertain": False}]
            )
            self.assertEqual(self.fixture.command_fact["phase"], "settle")
            held[-1].allow_close = True
            self.assertTrue(self.fixture._retire_command_files())
            self.assertTrue(held[-1].closed)
        self.fixture.groups = None
        self.fixture.native = False
        self.fixture.trust_attempted = False

    def test27RetiredCloseMarkerCannotPayPhysicalUncertaintyOrAuthorizeAnotherClose(self):
        original = self.fixture._command
        primary = OSError("controlled retired marker before physical close")
        real_temporary_file = tempfile.TemporaryFile
        held, removals = [], []

        class RetiredMarker:
            marker = False
            close_calls = 0

            def __init__(self, owner):
                self.owner = owner

            def __getattr__(self, name):
                return getattr(self.owner, name)

            @property
            def closed(self):
                return self.marker

            def close(self):
                self.close_calls += 1
                self.marker = True
                raise primary

        def allocate(*arguments, **options):
            owner = real_temporary_file(*arguments, **options)
            if not held:
                owner = RetiredMarker(owner)
                held.append(owner)
            return owner

        def command(arguments, input_bytes=b"", **options):
            if arguments[0] == "portable-owned-query":
                return original(
                    [sys.executable, "-B", "-c", "import sys;sys.stdin.buffer.read()"],
                    input_bytes,
                    **options,
                )
            removals.append(arguments)
            return 0, b""

        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.trust_query_executable = "portable-owned-query"
        with mock.patch.object(self.fixture, "_command", side_effect=command):
            with mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=allocate):
                with mock.patch("builtins.print") as output:
                    with self.assertRaises(OSError) as refusal:
                        self.fixture.trust(False)
        self.assertIs(refusal.exception, primary)
        output.assert_not_called()
        self.assertEqual(removals, [])
        self.assertTrue(self.fixture.trust_attempted)
        self.assertTrue(held[0].closed)
        self.assertFalse(held[0].owner.closed)
        os.fstat(held[0].owner.fileno())
        debt = [{"stream": held[0], "uncertain": True}]
        self.assertEqual(self.fixture.command_file_debt, debt)
        self.assertFalse(self.fixture._retire_command_files())
        with mock.patch.object(WIRE.subprocess, "Popen") as acquire:
            with self.assertRaises(WIRE.FixtureFailure):
                original([sys.executable, "-B", "-c", "pass"])
        acquire.assert_not_called()
        self.fixture.native = False
        self.fixture.trust_attempted = False
        with self.assertRaises(WIRE.FixtureFailure):
            self.fixture.close()
        self.assertFalse(self.fixture.closed)
        self.assertTrue(self.fixture.root.exists())
        self.assertEqual(self.fixture.command_file_debt, debt)
        self.assertEqual(held[0].close_calls, 1)
        # Only this control retains independent authority over the underlying
        # real file. It physically retires that file before releasing its ledger.
        held[0].owner.close()
        self.assertTrue(held[0].owner.closed)
        self.fixture.command_file_debt = []

    def test28PortableCommunicateRetiredStdinMarkerKeepsNativeCloseUncertainty(self):
        primary = OSError("controlled communicate close uncertainty")
        real_popen = subprocess.Popen
        held, children = [], []

        class RetiredInput:
            marker = False
            close_calls = 0

            def __init__(self, owner):
                self.owner = owner

            def __getattr__(self, name):
                return getattr(self.owner, name)

            @property
            def closed(self):
                return self.marker

            def close(self):
                self.close_calls += 1
                self.marker = True
                raise primary

        def acquire(*arguments, **options):
            child = real_popen(*arguments, **options)
            child.stdin = RetiredInput(child.stdin)
            held.append(child.stdin)
            children.append(child)
            return child

        with mock.patch.object(WIRE.subprocess, "Popen", side_effect=acquire):
            with self.assertRaises(OSError) as refusal:
                self.fixture._command(
                    [sys.executable, "-B", "-c", "import sys;sys.stdin.buffer.read()"]
                )
        self.assertIs(refusal.exception, primary)
        self.assertIsNotNone(children[0].returncode)
        self.assertTrue(held[0].closed)
        self.assertFalse(held[0].owner.closed)
        os.fstat(held[0].owner.fileno())
        debt = [{"stream": held[0], "uncertain": True}]
        self.assertEqual(self.fixture.command_file_debt, debt)
        self.assertEqual(self.fixture.command_fact["phase"], "settle")
        self.assertFalse(self.fixture._retire_command_files())
        with mock.patch.object(WIRE.subprocess, "Popen") as next_acquisition:
            with self.assertRaises(WIRE.FixtureFailure):
                self.fixture._command([sys.executable, "-B", "-c", "pass"])
        next_acquisition.assert_not_called()
        self.assertEqual(held[0].close_calls, 1)
        held[0].owner.close()
        self.assertTrue(held[0].owner.closed)
        self.fixture.command_file_debt = []


if __name__ == "__main__":
    unittest.main()

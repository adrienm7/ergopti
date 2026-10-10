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
import threading
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


# Finite approved source-acquisition hunks compose before the independent
# ownership repair. These spans never replace the historical whole-source pin.
PAC_SOURCE_ACQUISITION_INVERSE = (
    (
        "\tstatic func routes(url: URL, budget: TimeInterval, maximumSelections: Int,\n\t\tsettingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() },\n\t\tcertificates: [SecCertificate] = [],\n\t\tdiscoveryMetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {\n\t\tguard budget.isFinite, budget > 0 else { return nil }\n\t\tlet deadline = ProcessInfo.processInfo.systemUptime + budget\n\t\tguard !ManagedPACSource.hasDebt, let settings = settingsProvider(),\n\t\t\tProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\tlet dictionary = (settings as AnyObject) as? [String: Any]\n\t\tlet discoveryEnabled = (dictionary?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? NSNumber)?.boolValue == true\n",
        "\tstatic func routes(url: URL, budget: TimeInterval, maximumSelections: Int,\n\t\tsettingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() },\n\t\tdiscoveryMetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {\n\t\tguard let settings = settingsProvider() else { return nil }\n\t\tlet dictionary = (settings as AnyObject) as? [String: Any]\n\t\tlet discoveryEnabled = (dictionary?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? NSNumber)?.boolValue == true\n",
    ),
    (
        "\t\t})\n\t\tvar routes: [[String: Any]] = []\n\t\tfor candidate in candidates {\n\t\t\tguard let kind = candidate[kCFProxyTypeKey as String] as? String else { return nil }\n\t\t\tif kind == kCFProxyTypeAutoConfigurationURL as String {\n\t\t\t\tguard let pacURL = candidate[kCFProxyAutoConfigurationURLKey as String] as? URL,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: pacURL, script: nil, deadline: deadline, certificates: certificates),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n\t\t\t\troutes.append(contentsOf: expanded)\n\t\t\t} else if kind == kCFProxyTypeAutoConfigurationJavaScript as String {\n\t\t\t\tguard let script = candidate[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: nil, script: script, deadline: deadline, certificates: certificates),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n\t\t\t\troutes.append(contentsOf: expanded)\n",
        "\t\t})\n\t\tvar routes: [[String: Any]] = []\n\t\tlet deadline = ProcessInfo.processInfo.systemUptime + budget\n\t\tfor candidate in candidates {\n\t\t\tguard let kind = candidate[kCFProxyTypeKey as String] as? String else { return nil }\n\t\t\tif kind == kCFProxyTypeAutoConfigurationURL as String {\n\t\t\t\tguard let pacURL = candidate[kCFProxyAutoConfigurationURLKey as String] as? URL,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: pacURL, script: nil, deadline: deadline),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n\t\t\t\troutes.append(contentsOf: expanded)\n\t\t\t} else if kind == kCFProxyTypeAutoConfigurationJavaScript as String {\n\t\t\t\tguard let script = candidate[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: nil, script: script, deadline: deadline),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n\t\t\t\troutes.append(contentsOf: expanded)\n",
    ),
    (
        "\t\t\t!hasNativePAC {\n\t\t\tguard let discovered = discover(url: url, deadline: deadline,\n\t\t\t\tmaximumSelections: maximumSelections, certificates: certificates, metadataProvider: discoveryMetadataProvider) else { return nil }\n\t\t\troutes = discovered\n\t\t}\n",
        "\t\t\t!hasNativePAC {\n\t\t\tguard let discovered = discover(url: url, deadline: deadline,\n\t\t\t\tmaximumSelections: maximumSelections, metadataProvider: discoveryMetadataProvider) else { return nil }\n\t\t\troutes = discovered\n\t\t}\n",
    ),
    (
        "\n\tstatic func discover(url: URL, deadline: TimeInterval, maximumSelections: Int,\n\t\tcertificates: [SecCertificate] = [],\n\t\tmetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {\n\t\tguard !ManagedPACSource.hasDebt, ProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\tlet metadata = metadataProvider()\n\t\tguard let endpoints = discoveryURLs(dhcpOption: metadata.dhcpOption, searchDomains: metadata.searchDomains),\n\t\t\t!endpoints.isEmpty, endpoints.count <= maximumSelections else { return nil }\n\t\tfor endpoint in endpoints {\n\t\t\tguard !ManagedPACSource.hasDebt, ProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\t\tif let result = evaluate(url: url, pacURL: endpoint, script: nil, deadline: deadline, certificates: certificates),\n\t\t\t\t!result.isEmpty, result.count <= maximumSelections { return result }\n\t\t}\n",
        "\n\tstatic func discover(url: URL, deadline: TimeInterval, maximumSelections: Int,\n\t\tmetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {\n\t\tlet metadata = metadataProvider()\n\t\tguard let endpoints = discoveryURLs(dhcpOption: metadata.dhcpOption, searchDomains: metadata.searchDomains),\n\t\t\t!endpoints.isEmpty, endpoints.count <= maximumSelections else { return nil }\n\t\tfor endpoint in endpoints {\n\t\t\tguard ProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\t\tif let result = evaluate(url: url, pacURL: endpoint, script: nil, deadline: deadline),\n\t\t\t\t!result.isEmpty, result.count <= maximumSelections { return result }\n\t\t}\n",
    ),
    (
        "\t}\n\n\tstatic func evaluate(url: URL, pacURL: URL?, script: String?, deadline: TimeInterval,\n\t\tcertificates: [SecCertificate] = []) -> [[String: Any]]? {\n\t\tguard !ManagedPACSource.hasDebt, ProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\tlet source: String\n\t\tif let pacURL, script == nil {\n\t\t\tguard let acquired = ManagedPACSource.load(pacURL, deadline: deadline, certificates: certificates) else { return nil }\n\t\t\tsource = acquired\n\t\t} else if pacURL == nil, let script { source = script }\n\t\telse { return nil }\n\t\tguard ProcessInfo.processInfo.systemUptime < deadline,\n\t\t\tlet bound = try? ManagedPACSource.bind(source, url: url) else { return nil }\n\t\treturn evaluateNative(url: url, pacURL: nil, script: bound, deadline: deadline)\n\t}\n\n\t/// Keep the raw public framework boundary observable independently of the\n\t/// production binding. This does not acquire a PAC through an owned session.\n\tstatic func evaluateNative(url: URL, pacURL: URL?, script: String?, deadline: TimeInterval) -> [[String: Any]]? {\n\t\tguard ProcessInfo.processInfo.systemUptime < deadline else { return nil }\n\t\tlet result = ManagedPACResult()\n\t\tvar context = CFStreamClientContext(version: 0,\n",
        "\t}\n\n\tstatic func evaluate(url: URL, pacURL: URL?, script: String?, deadline: TimeInterval) -> [[String: Any]]? {\n\t\tlet result = ManagedPACResult()\n\t\tvar context = CFStreamClientContext(version: 0,\n",
    ),
    (
        '\t\t\tguard let selected = ManagedProxyLookup.routes(url: request.url,\n\t\t\t\tbudget: min(lookupRemaining ?? request.idleTimeout, request.idleTimeout),\n\t\t\t\tmaximumSelections: maximumSelections, settingsProvider: settingsProvider, certificates: certificates,\n\t\t\t\tdiscoveryMetadataProvider: discoveryMetadataProvider)\n\t\t\telse { return refuse(reason: "unavailable", status: 78, output: output) }\n',
        '\t\t\tguard let selected = ManagedProxyLookup.routes(url: request.url,\n\t\t\t\tbudget: min(lookupRemaining ?? request.idleTimeout, request.idleTimeout),\n\t\t\t\tmaximumSelections: maximumSelections, settingsProvider: settingsProvider,\n\t\t\t\tdiscoveryMetadataProvider: discoveryMetadataProvider)\n\t\t\telse { return refuse(reason: "unavailable", status: 78, output: output) }\n',
    ),
)


def pac_source_acquisition_projection(source):
    """Invert only one complete enrolled request-owned PAC source repair."""
    if "ManagedPACSource." not in source:
        return source
    if any(source.count(new) != 1 for new, old in PAC_SOURCE_ACQUISITION_INVERSE):
        raise ValueError("PAC source acquisition enrollment refused")
    projected = source
    for new, old in PAC_SOURCE_ACQUISITION_INVERSE:
        projected = projected.replace(new, old, 1)
    if "ManagedPACSource." in projected:
        raise ValueError("PAC source acquisition projection refused")
    return projected


# Preserve the diagnostic-only release pin across the separately reviewed PAC
# ownership repair afb1f15d. Each complete, unique span must be enrolled before
# any inversion; the whole historical hash still protects every unrelated byte.
PAC_OWNERSHIP_INVERSE = (
    (
        "\t\t// A native PAC callback owns the complete choice list. Initial fallback\n\t\t// entries cannot add DIRECT or fixed proxies that the script omitted.\n\t\tlet hasNativePAC = candidates.contains(where: {\n\t\t\tlet kind = $0[kCFProxyTypeKey as String] as? String\n\t\t\treturn kind == kCFProxyTypeAutoConfigurationURL as String\n\t\t\t\t|| kind == kCFProxyTypeAutoConfigurationJavaScript as String\n\t\t})\n",
        "",
    ),
    (
        "\t\t\t\tguard let pacURL = candidate[kCFProxyAutoConfigurationURLKey as String] as? URL,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: pacURL, script: nil, deadline: deadline),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n",
        "\t\t\t\tguard let pacURL = candidate[kCFProxyAutoConfigurationURLKey as String] as? URL,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: pacURL, script: nil, deadline: deadline) else { return nil }\n",
    ),
    (
        "\t\t\t\tguard let script = candidate[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: nil, script: script, deadline: deadline),\n\t\t\t\t\t!expanded.isEmpty else { return nil }\n",
        "\t\t\t\tguard let script = candidate[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,\n\t\t\t\t\tlet expanded = evaluate(url: url, pacURL: nil, script: script, deadline: deadline) else { return nil }\n",
    ),
    (
        "\t\t\t} else if !hasNativePAC { routes.append(candidate) }\n",
        "\t\t\t} else { routes.append(candidate) }\n",
    ),
    (
        "\t\tif discoveryEnabled,\n\t\t\t!hasNativePAC {\n",
        "\t\tif discoveryEnabled,\n\t\t\t!candidates.contains(where: {\n\t\t\t\tlet kind = $0[kCFProxyTypeKey as String] as? String\n\t\t\t\treturn kind == kCFProxyTypeAutoConfigurationURL as String\n\t\t\t\t\t|| kind == kCFProxyTypeAutoConfigurationJavaScript as String\n\t\t\t}) {\n",
    ),
)
HISTORICAL_HTTP_RELEASE_SHA256 = "68659ddec98c9a427244b315b69c17750b743eab2cdd3688308690a66d1c6e98"


# Admit only the complete reviewed DEBUG certificate-code observation. The
# original whole-source hash still rejects every byte outside this exact inverse.
DEBUG_CERTIFICATE_FAILURE_INVERSE = (
    'func managedHTTPFailure(_ error: NSError) -> String {\n\tguard error.domain == NSURLErrorDomain else { return "unavailable" }\n\tlet code = error.code\n\tswitch code {\n\tcase NSURLErrorTimedOut: return "deadline"\n\tcase NSURLErrorCancelled: return "cancelled"\n\tcase NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "offline"\n\tcase NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "offline"\n\tcase NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,\n\t\tNSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,\n\t\tNSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,\n\t\tNSURLErrorClientCertificateRequired:\n\t\t#if DEBUG\n\t\t_ = fputs("# native_http_certificate_code domain=NSURLErrorDomain code=\\(code)\\n", stderr)\n\t\t#endif\n\t\treturn "certificate"\n\tcase NSURLErrorUserAuthenticationRequired: return "unavailable"\n\tcase NSURLErrorCannotConnectToHost: return "connect"\n\tdefault: return "unavailable"\n\t}\n}',
    'func managedHTTPFailure(_ error: NSError) -> String {\n\tguard error.domain == NSURLErrorDomain else { return "unavailable" }\n\tswitch error.code {\n\tcase NSURLErrorTimedOut: return "deadline"\n\tcase NSURLErrorCancelled: return "cancelled"\n\tcase NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "offline"\n\tcase NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "offline"\n\tcase NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,\n\t\tNSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,\n\t\tNSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,\n\t\tNSURLErrorClientCertificateRequired: return "certificate"\n\tcase NSURLErrorUserAuthenticationRequired: return "unavailable"\n\tcase NSURLErrorCannotConnectToHost: return "connect"\n\tdefault: return "unavailable"\n\t}\n}',
)


def debug_certificate_failure_projection(source):
    """Invert one exact diagnostic function or preserve one exact original."""
    diagnostic, original = DEBUG_CERTIFICATE_FAILURE_INVERSE
    if source.count("func managedHTTPFailure(") != 1:
        raise ValueError("Certificate diagnostic function identity refused")
    if source.count(original) == 1 and diagnostic not in source:
        return source
    if source.count(diagnostic) != 1 or original in source:
        raise ValueError("Certificate diagnostic enrollment refused")
    return source.replace(diagnostic, original, 1)


def historical_pac_ownership_projection(source):
    """Accept the exact legacy source or the complete approved ownership repair."""
    source = debug_certificate_failure_projection(source)
    source = pac_source_acquisition_projection(source)
    if hashlib.sha256(source.encode("utf-8")).hexdigest() == HISTORICAL_HTTP_RELEASE_SHA256:
        return source
    if any(source.count(new) != 1 or (old and old in source) for new, old in PAC_OWNERSHIP_INVERSE):
        raise ValueError("PAC ownership source enrollment refused")
    projected = source
    for new, old in PAC_OWNERSHIP_INVERSE:
        projected = projected.replace(new, old, 1)
    if hashlib.sha256(projected.encode("utf-8")).hexdigest() != HISTORICAL_HTTP_RELEASE_SHA256:
        raise ValueError("Historical HTTP release source refused")
    return projected


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
        with contextlib.redirect_stderr(io.StringIO()) as output:
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
        with contextlib.redirect_stderr(output):
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

    def test07bRestorationProducerPreservesActualJSONResponseStream(self):
        # A separate producer channel is ineffective if the native parent discards it.
        swift = (
            ROOT
            / "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedHTTPWireTests.swift"
        ).read_text(encoding="utf-8")
        active = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", swift)
        startup = re.search(
            r"final class ManagedWireFixture \{([\s\S]*?)try process\.run\(\)", active
        )
        self.assertIsNotNone(startup, "The actual Swift fixture startup must be inspected")
        assignments = re.findall(
            r"process\.(standard(?:Input|Output|Error))\s*=\s*([^\n]+)", startup.group(1)
        )
        self.assertEqual(
            assignments,
            [
                ("standardInput", "input"),
                ("standardOutput", "output"),
                ("standardError", "FileHandle.standardError"),
            ],
            "The XCTest parent must retain diagnostics separately from fixture JSON replies",
        )
        owner = WIRE.WireFixture.__new__(WIRE.WireFixture)
        for operation, fact, expected in (
            (
                "trust",
                {"phase": "exit", "status": 1},
                {"version": 1, "operation": "trust", "phase": "exit", "status": 1},
            ),
            (
                "keychain",
                None,
                {"version": 1, "operation": "keychain", "phase": "unknown", "status": None},
            ),
        ):
            with self.subTest(operation=operation):
                owner.command_fact = fact
                response = '{"version": 1, "trusted": true}\n'
                output = io.StringIO()
                errors = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    print(response, end="")
                    owner._report_restoration_failure(operation)
                self.assertEqual(output.getvalue(), response)
                self.assertEqual(json.loads(output.getvalue()), {"version": 1, "trusted": True})
                lines = errors.getvalue().splitlines()
                self.assertEqual(len(lines), 1)
                self.assertTrue(lines[0].startswith("# native_http_restoration_failure "))
                self.assertEqual(
                    json.loads(lines[0].removeprefix("# native_http_restoration_failure ")),
                    expected,
                )
                self.assertIs(owner.command_fact, fact)

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
        release = historical_pac_ownership_projection(release)
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


class NativeSelectedRouteObservationTests(unittest.TestCase):
    def owner(self, body):
        temporary = tempfile.TemporaryDirectory(prefix="ergopti-selected-route-")
        self.addCleanup(temporary.cleanup)
        target = Path(temporary.name) / "stages"
        receipt = CLIENT.WorkerStageReceipt(target)
        self.addCleanup(receipt.close)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import os,sys;fd=os.open(sys.argv[1],os.O_WRONLY|os.O_APPEND);os.write(fd,sys.stdin.buffer.read());os.close(fd)",
                str(target),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        receiver = SimpleNamespace(_process=process, _closed=False, _fixture_stage_receipt=receipt)
        self.assertEqual(receipt.facts(receiver), {"state": "unsettled", "stages": []})
        process.communicate(body, timeout=3)
        self.assertEqual(process.returncode, 0)
        receiver._closed = True
        return receipt, receiver

    def report(self, receiver):
        owner = SimpleNamespace(
            receiving_workers=[receiver],
            receiving_start=0,
            fixture=SimpleNamespace(receiving_facts=lambda: {"version": 1, "active": 0}),
        )
        with contextlib.redirect_stdout(io.StringIO()) as output:
            CLIENT.RealNativeClientReceiving.report_receiving_facts(owner)
        return json.loads(output.getvalue().removeprefix("# native_http_receiving "))

    def test29ActualClosedChildReportsOneCompactRoutePlanWithinOriginal256(self):
        expected = {
            b"r0": "sole_direct",
            b"r1": "sole_default_refused",
            b"r2": "default_refused_with_successor",
            b"r3": "other_http_first",
            b"r4": "socks_first",
            b"r5": "unknown",
        }
        for token, kind in expected.items():
            with self.subTest(kind=kind):
                body = ("\n".join(CLIENT.ALL_STAGES) + "\n").encode() + token + b"\n"
                self.assertEqual(len(body), 254)
                receipt, receiver = self.owner(body)
                self.assertEqual(receipt.facts(receiver)["state"], "observed")
                facts = self.report(receiver)
                self.assertEqual(
                    facts["selected_route"],
                    {
                        label: int(label == kind)
                        for label in (
                            "sole_direct",
                            "sole_default_refused",
                            "default_refused_with_successor",
                            "other_http_first",
                            "socks_first",
                            "unknown",
                        )
                    },
                )
                self.assertEqual(facts["settled"], 1)
                self.assertTrue(receipt.closed)

    def test30MultiplePlansAndPrivatePayloadRefuseWhileAbsentPlanStaysUnknown(self):
        for body in (
            b"entry\nr1\nr2\n",
            b"entry\nr6\n",
            b"entry\nroute=http://private-secret\n",
            b"x" * 257,
        ):
            with self.subTest(body=body):
                receipt, receiver = self.owner(body)
                self.assertEqual(receipt.facts(receiver), {"state": "refused", "stages": []})
                facts = self.report(receiver)
                self.assertEqual(facts["selected_route"]["unknown"], 1)
                self.assertEqual(sum(facts["selected_route"].values()), 1)
                self.assertNotIn("private-secret", json.dumps(facts))
        receipt, receiver = self.owner(b"entry\narguments\n")
        facts = self.report(receiver)
        self.assertEqual(facts["selected_route"]["unknown"], 1)
        self.assertEqual(facts["selected_route"]["sole_default_refused"], 0)

    def test31RealAuthoredPACDistinguishesFullURLAndAuthorityOnlyDefault(self):
        fixture = WIRE.WireFixture(native=False)
        self.addCleanup(fixture.close)
        full = f"https://{fixture.host}:{fixture.origin_port}/certificate?case=seven"
        authority = f"https://{fixture.host}:{fixture.origin_port}/"
        request = {
            "script": fixture.pac,
            "full": full,
            "authority": authority,
            "host": fixture.host,
        }
        program = "const vm=require('node:vm');const value=JSON.parse(process.argv[1]);const context=vm.createContext({});vm.runInContext(value.script,context,{timeout:1000});process.stdout.write(JSON.stringify([context.FindProxyForURL(value.full,value.host),context.FindProxyForURL(value.authority,value.host)]));"
        result = subprocess.run(
            ["node", "-e", program, json.dumps(request)],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        )
        routes = json.loads(result.stdout)
        self.assertEqual(
            routes[0],
            f"PROXY 127.0.0.1:{fixture.ports['first']}; PROXY 127.0.0.1:{fixture.ports['second']}",
        )
        self.assertEqual(routes[1], f"PROXY 127.0.0.1:{fixture.ports['refused']}")
        self.assertTrue(
            fixture.pac.endswith(f'return "PROXY 127.0.0.1:{fixture.ports["refused"]}"; }}')
        )
        self.assertEqual(fixture.receiving_facts()["accept_proxy"], 0)
        self.assertEqual(fixture.receiving_facts()["accept_origin"], 0)
        # This proves the authored script distinction. CFNetwork URL delivery
        # is unexecuted here and cannot be inferred from the JavaScript result.

    def test32ActualRouteArrayObservationKeepsReleaseOperationsAndNonblockingOwner(self):
        worker = (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text()
        fixture = (SUPPORT / "native_http_fixture_main.swift").read_text()
        self.assertIn(
            'managedHTTPFixtureStage("routes_done")\n\t\tmanagedHTTPFixtureRoutes(routes)\n\t\t#endif',
            worker,
        )
        release = re.sub(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            "",
            worker,
            flags=re.MULTILINE | re.DOTALL,
        )
        release = historical_pac_ownership_projection(release)
        self.assertEqual(
            hashlib.sha256(release.encode()).hexdigest(),
            "68659ddec98c9a427244b315b69c17750b743eab2cdd3688308690a66d1c6e98",
        )
        observer = fixture[fixture.index("\tfunc routes(_ routes:") : fixture.index("\n\tdeinit")]
        self.assertIn("guard lock.try() else { return }", observer)
        self.assertIn('seen.insert("route_plan").inserted', observer)
        self.assertIn('token = routes.count == 1 ? "r1" : "r2"', observer)
        self.assertIn("port.intValue == expected", observer)
        self.assertIn('host == "127.0.0.1"', observer)
        self.assertIn('var token = "r5"', observer)
        self.assertNotIn("lock.lock()", observer)
        self.assertNotIn("Darwin.open", observer)
        self.assertNotIn("session", observer)
        self.assertEqual(observer.count("Darwin.write"), 1)
        binding = fixture[
            fixture.index("\tfunc bindDefaultRoute") : fixture.index("\n\tfunc routes")
        ]
        self.assertIn('settings["ProxyAutoConfigJavaScript"]', binding)
        self.assertIn("script.utf8.prefix(65_537).count <= 65_536", binding)
        self.assertIn("script.hasSuffix(suffix)", binding)
        self.assertIn("options: .backwards", binding)
        self.assertIn("digits.utf8.allSatisfy({ (48...57).contains($0) })", binding)
        self.assertNotIn("Data(contentsOf:", binding)
        self.assertLess(
            fixture.index("stages.bindDefaultRoute(settings: settings)"),
            fixture.index("let status = ManagedHTTPWorker.execute"),
        )


class NativeAdminAuthorizationObservationTests(unittest.TestCase):
    # Literal public-CLI receipts qualify receiving only. The actual Apple
    # authorization operation must execute in the native macOS lane.
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

    def test33StrictPublicAuthorizationGrammarRejectsUnknownOutputAndFalseStatuses(self):
        fact = WIRE.WireFixture._admin_authorization_fact(255, b"NO (-60007) \n")
        self.assertEqual(
            fact,
            {
                "version": 1,
                "observed": 1,
                "command_status": 255,
                "authorization_status": -60007,
                "interaction_allowed": 0,
            },
        )
        self.assertEqual(
            WIRE.WireFixture._admin_authorization_fact(
                0, b'YES (0) { 1: "com.apple.trust-settings.admin" } \n'
            )["authorization_status"],
            0,
        )
        for status, raw in (
            (0, b"NO (-60007) \n"),
            (255, b"NO (0) \n"),
            (255, b"NO (2147483648) \n"),
            (True, b"NO (-60007) \n"),
            (255, b"NO (-60007)"),
            (255, b"NO (-60007) \nprivate diagnostic"),
            (255, b"x" * 1025),
            (0, b'YES (0) { 1: "another-right" } \n'),
            (0, b'YES (0) { 2: "com.apple.trust-settings.admin" } \n'),
            (0, b'YES (0) { 1: "com.apple.trust-settings.admin" (cannot-preauthorize) } \n'),
        ):
            with self.subTest(status=status, length=len(raw)):
                with self.assertRaises(WIRE.FixtureFailure):
                    WIRE.WireFixture._admin_authorization_fact(status, raw)

    def controller(self, body, removal_failure=None):
        original = self.fixture._command
        commands, removals, children = [], [], []
        real_popen = subprocess.Popen

        def acquire(*arguments, **options):
            child = real_popen(*arguments, **options)
            child.controlled_output = options["stdout"]
            child.controlled_errors = options["stderr"]
            children.append(child)
            return child

        def command(arguments, **options):
            if arguments[3] == "authorize":
                commands.append((arguments, options))
                return original([sys.executable, "-B", "-c", body], **options)
            removals.append((arguments, options, time.monotonic()))
            if removal_failure is not None:
                raise removal_failure
            return 0, b""

        return command, acquire, commands, removals, children

    def test34ActualMergedOutputAndClosedChildReceiveFixedNoninteractiveStatus(self):
        body = "import sys;sys.stdin.buffer.read();sys.stdout.write('NO (');sys.stdout.flush();sys.stderr.write('-60007) ');sys.stderr.flush();sys.stdout.write('\\n');sys.stdout.flush();sys.exit(255)"
        command, acquire, commands, _, children = self.controller(body)
        output = io.StringIO()
        started = time.monotonic()
        with mock.patch.object(self.fixture, "_command", side_effect=command):
            with mock.patch.object(WIRE.subprocess, "Popen", side_effect=acquire):
                with contextlib.redirect_stdout(output):
                    self.fixture._observe_admin_authorization(started + 15)
        self.assertEqual(
            commands[0][0],
            [
                "/usr/bin/sudo",
                "-n",
                "/usr/bin/security",
                "authorize",
                "-P",
                "com.apple.trust-settings.admin",
            ],
        )
        self.assertEqual(len(commands), 1)
        self.assertTrue(commands[0][1]["tolerate"])
        self.assertTrue(commands[0][1]["merge_errors"])
        self.assertLessEqual(commands[0][1]["deadline"], time.monotonic() + 2)
        self.assertEqual(children[0].returncode, 255)
        self.assertTrue(children[0].stdin.closed)
        self.assertTrue(children[0].controlled_output.closed)
        self.assertTrue(children[0].controlled_errors.closed)
        self.assertIs(children[0].controlled_output, children[0].controlled_errors)
        fact = json.loads(output.getvalue().split(" ", 2)[2])
        self.assertEqual(fact["observed"], 1)
        self.assertEqual(fact["authorization_status"], -60007)
        self.assertEqual(fact["interaction_allowed"], 0)

    def test35PublicAuthorizationConsumesSameRemovalBudgetWithoutChangingMandatoryVerdict(self):
        body = "import sys,time;sys.stdin.buffer.read();time.sleep(.08);sys.stderr.write('NO (-60007) \\n');sys.exit(255)"
        primary = RuntimeError("original controlled trust removal refusal")
        command, acquire, _, removals, children = self.controller(body, primary)
        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.authorization_observation = True
        started = time.monotonic()
        with mock.patch.object(self.fixture, "_command", side_effect=command):
            with mock.patch.object(WIRE.subprocess, "Popen", side_effect=acquire):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(RuntimeError) as refusal:
                        self.fixture.trust(False)
        self.assertIs(refusal.exception, primary)
        self.assertTrue(self.fixture.trust_attempted)
        self.assertEqual(len(removals), 1)
        self.assertEqual(removals[0][0][3:5], ["remove-trusted-cert", "-d"])
        self.assertGreaterEqual(removals[0][1]["deadline"], started + 15)
        self.assertLess(removals[0][1]["deadline"] - removals[0][2], 14.95)
        self.assertNotIn("tolerate", removals[0][1])
        self.assertIsNotNone(children[0].returncode)
        self.fixture.native = False
        self.fixture.trust_attempted = False

    def test36UnknownReceiptAndClosedOutputCannotEraseExactClosureFailure(self):
        output = io.StringIO()
        with mock.patch.object(
            self.fixture, "_command", return_value=(255, b"private unknown output")
        ):
            with contextlib.redirect_stdout(output):
                self.fixture._observe_admin_authorization(time.monotonic() + 15)
        self.assertEqual(
            json.loads(output.getvalue().split(" ", 2)[2]),
            {"version": 1, "observed": 0, "interaction_allowed": 0},
        )
        self.assertNotIn("private", output.getvalue())
        primary = RuntimeError("original controlled authorization child closure refusal")

        def refused(*arguments, **options):
            self.fixture.command_fact = {"phase": "settle", "status": None}
            raise primary

        with mock.patch.object(self.fixture, "_command", side_effect=refused):
            with mock.patch("builtins.print") as printing:
                with self.assertRaises(RuntimeError) as refusal:
                    self.fixture._observe_admin_authorization(time.monotonic() + 15)
        self.assertIs(refusal.exception, primary)
        printing.assert_not_called()
        for failure in (
            OSError("closed controlled output"),
            ValueError("closed controlled output"),
        ):
            with mock.patch.object(self.fixture, "_command", return_value=(255, b"NO (-60007) \n")):
                with mock.patch("builtins.print", side_effect=failure):
                    self.fixture._observe_admin_authorization(time.monotonic() + 15)


class NativeServerRetirementTests(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.cleanup_owned_control)

    def cleanup_owned_control(self):
        if self.fixture.closed:
            return
        # Only this test owns the deliberately refused operation's original
        # sockets and threads. This direct teardown does not pay production debt.
        for server in self.fixture.started_servers:
            server.shutdown()
        for state in getattr(self.fixture, "server_shutdowns", ()):
            if state["worker"].ident is not None:
                state["worker"].join()
        for _, worker in getattr(self.fixture, "server_threads", ()):
            worker.join()
        for server in self.fixture.servers:
            server.server_close()
        self.fixture.refused.close()
        import shutil

        shutil.rmtree(self.fixture.root)

    def test37ActualIndependentShutdownRequestsMeetBeforeAnyListenerClosure(self):
        servers = tuple(self.fixture.started_servers)
        self.assertEqual(len(servers), 6)
        barrier = threading.Barrier(len(servers))
        shutdowns = []
        closers = []
        with contextlib.ExitStack() as stack:
            for server in servers:
                original_shutdown = server.shutdown
                original_close = server.server_close

                def shutdown(owned=server, original=original_shutdown):
                    barrier.wait(timeout=2)
                    original()
                    shutdowns.append(owned)

                def close(owned=server, original=original_close):
                    self.assertEqual(len(shutdowns), len(servers))
                    self.assertTrue(
                        all(not row["worker"].is_alive() for row in self.fixture.server_shutdowns)
                    )
                    self.assertTrue(
                        all(not worker.is_alive() for _, worker in self.fixture.server_threads)
                    )
                    original()
                    closers.append(owned)

                stack.enter_context(mock.patch.object(server, "shutdown", side_effect=shutdown))
                stack.enter_context(mock.patch.object(server, "server_close", side_effect=close))
            self.fixture.close()
        self.assertTrue(self.fixture.closed)
        self.assertEqual(set(shutdowns), set(servers))
        self.assertEqual(closers, list(servers))
        self.assertTrue(all(server.socket.fileno() == -1 for server in servers))
        self.assertFalse(self.fixture.root.exists())

    def test38FailedExactShutdownKeepsItsWorkerAndNamespaceWithoutSuccess(self):
        primary = RuntimeError("controlled public shutdown refusal")
        original = self.fixture.started_servers[0].shutdown
        with mock.patch.object(self.fixture.started_servers[0], "shutdown", side_effect=primary):
            with self.assertRaises(RuntimeError) as refusal:
                self.fixture.close()
        self.assertIs(refusal.exception, primary)
        retained = tuple(self.fixture.server_shutdowns)
        workers = tuple(state["worker"] for state in retained)
        self.assertFalse(self.fixture.closed)
        self.assertTrue(self.fixture.root.exists())
        self.assertIs(retained[0]["failure"], primary)
        with mock.patch.object(WIRE.threading.Thread, "start") as acquire:
            with self.assertRaises(RuntimeError) as refusal:
                self.fixture.close()
        acquire.assert_not_called()
        self.assertIs(refusal.exception, primary)
        self.assertEqual(tuple(state["worker"] for state in self.fixture.server_shutdowns), workers)
        self.assertTrue(all(server.socket.fileno() >= 0 for server in self.fixture.servers))
        original()

    def test39InterruptedJoinCanOnlyRetryTheSamePhysicalShutdownWorkers(self):
        original_join = threading.Thread.join
        primary = KeyboardInterrupt()
        interrupted = []

        def join(worker, *arguments, **options):
            if not interrupted:
                interrupted.append(worker)
                raise primary
            return original_join(worker, *arguments, **options)

        with mock.patch.object(WIRE.threading.Thread, "join", side_effect=join, autospec=True):
            with self.assertRaises(KeyboardInterrupt) as refusal:
                self.fixture.close()
        self.assertIs(refusal.exception, primary)
        workers = tuple(state["worker"] for state in self.fixture.server_shutdowns)
        self.assertEqual(len(workers), 6)
        self.assertFalse(self.fixture.closed)
        self.assertTrue(self.fixture.root.exists())
        with mock.patch.object(WIRE.threading.Thread, "start") as acquire:
            self.fixture.close()
        acquire.assert_not_called()
        self.assertEqual(tuple(state["worker"] for state in self.fixture.server_shutdowns), workers)
        self.assertTrue(all(not worker.is_alive() for worker in workers))
        self.assertTrue(self.fixture.closed)

    def test40StartRefusalRetainsExactWorkerAndCannotAcquireAfterDebt(self):
        primary = RuntimeError("controlled shutdown worker start refusal")
        with mock.patch.object(WIRE.threading.Thread, "start", side_effect=primary):
            with self.assertRaises(RuntimeError) as refusal:
                self.fixture.close()
        self.assertIs(refusal.exception, primary)
        retained = self.fixture.server_shutdowns[0]
        self.assertFalse(retained["started"])
        self.assertIsNone(retained["worker"].ident)
        self.assertFalse(self.fixture.closed)
        self.assertTrue(self.fixture.root.exists())
        with mock.patch.object(WIRE.threading.Thread, "start") as acquire:
            with self.assertRaises(RuntimeError) as refusal:
                self.fixture.close()
        acquire.assert_not_called()
        self.assertIs(refusal.exception, primary)
        self.assertIs(retained["failure"], primary)
        self.assertEqual(self.fixture.server_shutdowns, [retained])
        self.assertTrue(all(server.socket.fileno() >= 0 for server in self.fixture.servers))
        self.cleanup_owned_control()

        # A real native thread may exist while public start acknowledgement and
        # ident are absent. Only this control releases its bootstrap gate.
        original_thread = threading.Thread
        entered = threading.Event()
        release = threading.Event()
        target_entered = threading.Event()
        held = []
        acknowledgement_failure = KeyboardInterrupt("controlled serving start acknowledgement")

        class HeldBootstrap(original_thread):
            def __init__(self, *arguments, **options):
                super().__init__(*arguments, **options)
                held.append(self)

            def _bootstrap(self):
                entered.set()
                release.wait()
                super()._bootstrap()

            def start(self):
                with mock.patch.object(self._started, "wait", side_effect=acknowledgement_failure):
                    super().start()

            def run(self):
                target_entered.set()
                super().run()

        self.fixture = WIRE.WireFixture.__new__(WIRE.WireFixture)
        try:
            with mock.patch.object(WIRE.threading, "Thread", HeldBootstrap):
                with self.assertRaises(KeyboardInterrupt) as refusal:
                    self.fixture.__init__(native=False)
            self.assertIs(refusal.exception, acknowledgement_failure)
            self.assertTrue(entered.wait(2))
            self.assertIsNone(held[0].ident)
            self.assertFalse(held[0]._started.is_set())
            self.assertIs(self.fixture.server_starts[0]["worker"], held[0])
            self.assertIs(self.fixture.server_starts[0]["failure"], acknowledgement_failure)
            self.assertFalse(self.fixture.closed)
            self.assertTrue(self.fixture.root.exists())
            self.assertTrue(all(server.socket.fileno() >= 0 for server in self.fixture.servers))
            with mock.patch.object(WIRE.threading.Thread, "start") as acquire:
                with self.assertRaises(KeyboardInterrupt) as refusal:
                    self.fixture.close()
            acquire.assert_not_called()
            self.assertIs(refusal.exception, acknowledgement_failure)
        finally:
            release.set()
            self.assertTrue(held[0]._started.wait(2))
            self.assertTrue(target_entered.wait(2))
            self.fixture.servers[0].shutdown()
            held[0].join(2)
            self.assertFalse(held[0].is_alive())


class HistoricalPACOwnershipProjectionTests(unittest.TestCase):
    @staticmethod
    def release_source():
        source = (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text(encoding="utf-8")
        return pac_source_acquisition_projection(
            re.sub(
                r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
                "",
                source,
                flags=re.MULTILINE | re.DOTALL,
            )
        )

    def test41CompleteApprovedRepairAndExactLegacyKeepOriginalWholePin(self):
        source = self.release_source()
        legacy = historical_pac_ownership_projection(source)
        self.assertEqual(
            hashlib.sha256(legacy.encode()).hexdigest(), HISTORICAL_HTTP_RELEASE_SHA256
        )
        self.assertEqual(historical_pac_ownership_projection(legacy), legacy)
        approved = legacy
        for new, old in PAC_OWNERSHIP_INVERSE:
            if old:
                self.assertEqual(approved.count(old), 1)
                approved = approved.replace(old, new, 1)
            else:
                anchor = "\t\tvar routes: [[String: Any]] = []\n"
                self.assertEqual(approved.count(anchor), 1)
                approved = approved.replace(anchor, new + anchor, 1)
        self.assertEqual(historical_pac_ownership_projection(approved), legacy)

    def test42EveryPartialOrMalformedOwnershipSpanRefusesBeforeHistoricalAdmission(self):
        source = self.release_source()
        for new, old in PAC_OWNERSHIP_INVERSE:
            with self.subTest(span=new):
                self.assertEqual(source.count(new), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(new, old, 1))
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(
                        source.replace(new, new + "// unapproved\n", 1)
                    )

    def test43DuplicateAndHybridEnrollmentCannotNormalizeOutUnapprovedSource(self):
        source = self.release_source()
        for new, old in PAC_OWNERSHIP_INVERSE:
            with self.subTest(span=new):
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(new, new + new, 1))
                if old:
                    with self.assertRaises(ValueError):
                        historical_pac_ownership_projection(source.replace(new, new + old, 1))

    def test44UnrelatedCallbackRoutingDeadlineAndLegacyDriftRemainWholeHashProtected(self):
        source = self.release_source()
        legacy = historical_pac_ownership_projection(source)
        for before, after in (
            (
                "routes.append(contentsOf: expanded)",
                "routes.append(contentsOf: expanded.reversed())",
            ),
            (
                "let deadline = ProcessInfo.processInfo.systemUptime + budget",
                "let deadline = ProcessInfo.processInfo.systemUptime + budget + 1",
            ),
            ("CFRunLoopRunInMode", "UnapprovedRunLoopRunInMode"),
            ("URLSession(configuration:", "UnapprovedSession(configuration:"),
        ):
            for candidate in (source, legacy):
                with self.subTest(change=before, legacy=candidate == legacy):
                    self.assertIn(before, candidate)
                    with self.assertRaises(ValueError):
                        historical_pac_ownership_projection(candidate.replace(before, after, 1))


class PACSourceAcquisitionProjectionTests(unittest.TestCase):
    @staticmethod
    def raw_source():
        source = (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text()
        return re.sub(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            "",
            source,
            flags=re.MULTILINE | re.DOTALL,
        )

    def test45CompleteSourceOwnerKeepsImmutableHistoricalPin(self):
        source = self.raw_source()
        legacy = historical_pac_ownership_projection(source)
        self.assertEqual(
            hashlib.sha256(legacy.encode()).hexdigest(), HISTORICAL_HTTP_RELEASE_SHA256
        )
        self.assertNotIn("ManagedPACSource.", legacy)

    def test46EveryPartialSourceOwnerSpanRefuses(self):
        source = self.raw_source()
        for new, old in PAC_SOURCE_ACQUISITION_INVERSE:
            with self.subTest(span=new):
                self.assertEqual(source.count(new), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(new, old, 1))

    def test47DuplicateAndAlteredSourceOwnerSpansRefuse(self):
        source = self.raw_source()
        for new, old in PAC_SOURCE_ACQUISITION_INVERSE:
            with self.subTest(span=new):
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(new, new + new, 1))
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(
                        source.replace(new, new + "// unapproved\n", 1)
                    )

    def test48NativeTrustAndOriginalDeadlineCannotDriftUnderEnrollment(self):
        source = self.raw_source()
        for before, after in (
            (
                "let deadline = ProcessInfo.processInfo.systemUptime + budget",
                "let deadline = ProcessInfo.processInfo.systemUptime + budget + 1",
            ),
            ("certificates: certificates", "certificates: []"),
            ("CFNetworkExecuteProxyAutoConfigurationScript", "UnapprovedScriptRuntime"),
        ):
            self.assertIn(before, source)
            with self.assertRaises(ValueError):
                historical_pac_ownership_projection(source.replace(before, after, 1))


class NativeTrustRemovalDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.cleanup_fixture)

    def cleanup_fixture(self):
        # No native trust mutation occurs through these explicit POSIX ports.
        self.fixture.native = False
        self.fixture.trust_attempted = False
        self.fixture.close()

    def test45CanonicalPublicCalleeProjectionCannotExportMessageOrGuessOSStatus(self):
        raw = b"SecTrustSettingsRemoveTrustSettings: private-certificate https://private.invalid/key\n"
        fact = WIRE.WireFixture._security_failure_fact(raw)
        self.assertEqual(fact, {"version": 1, "observed": 1, "category": "trust_settings_remove"})
        self.assertNotIn("private", json.dumps(fact))
        self.assertNotIn("https", json.dumps(fact))
        self.assertNotIn("status", fact)
        for unknown in (
            b"",
            b"SecTrustSettingsRemoveTrustSettings: \n",
            b"security: SecTrustSettingsRemoveTrustSettings: refusal\n",
            b"SecTrustSettingsSetTrustSettings: refusal\n",
            b"Error reading file /private/certificate.pem\n",
            raw + raw,
            raw[:-1],
            raw.replace(b"private", b"\x00"),
            b"SecTrustSettingsRemoveTrustSettings: " + b"x" * 1024 + b"\n",
            "SecTrustSettingsRemoveTrustSettings: refusal\n",
        ):
            with self.subTest(length=len(unknown)):
                self.assertEqual(
                    WIRE.WireFixture._security_failure_fact(unknown),
                    {"version": 1, "observed": 0, "category": None},
                )

    def test46RealFailingChildProjectsOnlyAfterExactFilesAndChildAreRetired(self):
        children = []
        acquire = subprocess.Popen

        def owned_child(*args, **options):
            child = acquire(*args, **options)
            child.output_owner, child.error_owner = options["stdout"], options["stderr"]
            children.append(child)
            return child

        output = io.StringIO()
        command = [
            sys.executable,
            "-B",
            "-c",
            "import sys; sys.stderr.write('SecTrustSettingsRemoveTrustSettings: private-certificate-url\\n'); sys.exit(1)",
        ]
        with mock.patch.object(WIRE.subprocess, "Popen", side_effect=owned_child):
            with contextlib.redirect_stdout(output):
                with self.assertRaises(WIRE.FixtureFailure):
                    self.fixture._command(command, security_failure_observation=True)
        self.assertEqual(self.fixture.command_fact, {"phase": "exit", "status": 1})
        self.assertEqual(len(children), 1)
        child = children[0]
        self.assertEqual(child.returncode, 1)
        self.assertTrue(
            child.stdin.closed and child.output_owner.closed and child.error_owner.closed
        )
        receipt = json.loads(output.getvalue().split(" ", 2)[2])
        self.assertEqual(
            receipt,
            {
                "version": 1,
                "observed": 1,
                "category": "trust_settings_remove",
                "phase": "exit",
                "status": 1,
            },
        )
        self.assertNotIn("private-certificate", output.getvalue())
        create_file = tempfile.TemporaryFile
        reads, files = [], []

        class ObservedFile:
            def __init__(self, owner):
                self.owner = owner

            def __getattr__(self, name):
                return getattr(self.owner, name)

            def read(self, size=-1):
                raw = self.owner.read(size)
                reads.append((size, len(raw)))
                return raw

        def bounded_file(*args, **options):
            value = ObservedFile(create_file(*args, **options))
            files.append(value)
            return value

        actual_print = print

        def publication(*args, **options):
            self.assertTrue(all(value.closed for value in files))
            self.assertIsNotNone(children[-1].returncode)
            self.assertTrue(children[-1].stdin.closed)
            actual_print(*args, **options)

        large_command = [
            sys.executable,
            "-B",
            "-c",
            "import sys; sys.stderr.buffer.write(b'x' * (2 * 1024 * 1024)); sys.exit(1)",
        ]
        bounded_output = io.StringIO()
        with mock.patch.object(WIRE.subprocess, "Popen", side_effect=owned_child):
            with mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=bounded_file):
                with mock.patch("builtins.print", side_effect=publication):
                    with contextlib.redirect_stdout(bounded_output):
                        with self.assertRaises(WIRE.FixtureFailure):
                            self.fixture._command(large_command, security_failure_observation=True)
        self.assertEqual(reads, [(1025, 1025)])
        self.assertEqual(
            json.loads(bounded_output.getvalue().split(" ", 2)[2]),
            {"version": 1, "observed": 0, "category": None, "phase": "exit", "status": 1},
        )
        for refusal in (OSError("closed diagnostic output"), KeyboardInterrupt()):
            with mock.patch("builtins.print", side_effect=refusal):
                with self.assertRaises(WIRE.FixtureFailure) as primary:
                    self.fixture._command(command, security_failure_observation=True)
            self.assertEqual(self.fixture.command_fact, {"phase": "exit", "status": 1})
            self.assertIs(primary.exception.__cause__, refusal)

    def test47FreshAfterQueryConsumesOriginalClockAndPreservesRemovalAndClosureDebt(self):
        import sys as system

        native_monotonic = time.monotonic
        real_command = self.fixture._command
        ca_der = ssl.PEM_cert_to_DER_cert(self.fixture.ca.read_text())
        query_receipt = {
            "version": 1,
            "export_status": 0,
            "entry_count": 1,
            "owned_status": -25300,
            "owned_present": 0,
        }
        query_body = (
            "import sys; sys.stdin.buffer.read(); sys.stdout.buffer.write("
            + repr(json.dumps(query_receipt).encode())
            + ")"
        )
        remove_body = "import sys; sys.stderr.write('SecTrustSettingsRemoveTrustSettings: private-message\\n'); sys.exit(1)"
        for expire, close_uncertain in ((False, False), (True, False), (False, True)):
            with self.subTest(expire=expire, close_uncertain=close_uncertain):
                self.fixture.native = True
                self.fixture.trust_attempted = True
                self.fixture.trust_query_executable = "portable-owned-query"
                self.fixture.command_fact = None
                offset = [0.0]
                calls, observations, children, close_debt = [], [], [], []
                primary_remove = []
                acquire, create_file = subprocess.Popen, tempfile.TemporaryFile
                original_observe = self.fixture._observe_admin_trust

                def observe(deadline, *, after=False):
                    observations.append((deadline, after))
                    return original_observe(deadline, after=after)

                def child(*args, **options):
                    value = acquire(*args, **options)
                    value.output_owner, value.error_owner = options["stdout"], options["stderr"]
                    children.append(value)
                    return value

                class UncertainClosedFile:
                    def __init__(self, owner):
                        self.owner = owner

                    def __getattr__(self, name):
                        return getattr(self.owner, name)

                    def close(self):
                        self.owner.close()
                        raise OSError("controlled after-query physical close uncertainty")

                files = []

                def temporary(*args, **options):
                    value = create_file(*args, **options)
                    if close_uncertain and len(calls) == 3 and len(files) % 2 == 1:
                        value = UncertainClosedFile(value)
                        close_debt.append(value)
                    files.append(value)
                    return value

                def command(arguments, input_bytes=b"", **options):
                    calls.append((arguments, options))
                    if arguments[0] == "portable-owned-query":
                        self.assertEqual(input_bytes, ca_der)
                        return real_command(
                            [system.executable, "-B", "-c", query_body], input_bytes, **options
                        )
                    self.assertEqual(
                        arguments,
                        [
                            "/usr/bin/sudo",
                            "-n",
                            "/usr/bin/security",
                            "remove-trusted-cert",
                            "-d",
                            str(self.fixture.ca),
                        ],
                    )
                    self.assertTrue(options["security_failure_observation"])
                    try:
                        return real_command([system.executable, "-B", "-c", remove_body], **options)
                    except WIRE.FixtureFailure as refusal:
                        primary_remove.append(refusal)
                        if expire:
                            offset[0] = 16.0
                        raise

                output = io.StringIO()
                try:
                    with mock.patch.object(
                        WIRE.time, "monotonic", side_effect=lambda: native_monotonic() + offset[0]
                    ):
                        with mock.patch.object(self.fixture, "_command", side_effect=command):
                            with mock.patch.object(
                                self.fixture, "_observe_admin_trust", side_effect=observe
                            ):
                                with mock.patch.object(WIRE.subprocess, "Popen", side_effect=child):
                                    with mock.patch.object(
                                        WIRE.tempfile, "TemporaryFile", side_effect=temporary
                                    ):
                                        with contextlib.redirect_stdout(output):
                                            with self.assertRaises(WIRE.FixtureFailure) as refusal:
                                                self.fixture.trust(False)
                    self.assertIs(refusal.exception, primary_remove[0])
                    self.assertTrue(self.fixture.trust_attempted)
                    self.assertEqual(self.fixture.command_fact, {"phase": "exit", "status": 1})
                    self.assertEqual([after for _, after in observations], [False, True])
                    self.assertEqual(observations[0][0], observations[1][0])
                    self.assertEqual(calls[1][1]["deadline"], observations[0][0])
                    self.assertEqual(len(children), 2 if expire else 3)
                    self.assertTrue(
                        all(
                            child.returncode is not None
                            and child.stdin.closed
                            and child.output_owner.closed
                            and child.error_owner.closed
                            for child in children
                        )
                    )
                    if close_uncertain:
                        self.assertIsInstance(refusal.exception.__cause__, OSError)
                        self.assertEqual(len(close_debt), 1)
                        self.assertTrue(close_debt[0].closed)
                        self.assertTrue(
                            any(
                                debt["stream"] is close_debt[0] and debt["uncertain"]
                                for debt in self.fixture.command_file_debt
                            )
                        )
                        self.assertFalse(self.fixture._retire_command_files())
                    else:
                        after_line = next(
                            line
                            for line in output.getvalue().splitlines()
                            if line.startswith("# native_http_admin_trust_after ")
                        )
                        after = json.loads(after_line.split(" ", 2)[2])
                        self.assertEqual(after["observed"], 0 if expire else 1)
                        if not expire:
                            self.assertEqual(after["owned_status"], -25300)
                    self.assertNotIn("private-message", output.getvalue())
                finally:
                    # Retire only this test's exact already-closed injected debt;
                    # the production owner never promotes uncertainty to success.
                    self.fixture.command_file_debt[:] = [
                        debt
                        for debt in self.fixture.command_file_debt
                        if debt["stream"] not in close_debt
                    ]
                    for value in files:
                        if not value.closed:
                            value.close()
                    self.fixture.native = False
                    self.fixture.trust_attempted = False


class NativeTrustRemovalOriginalDeadlineTests(unittest.TestCase):
    """Actual trust method over explicit recording ports; no native store or child."""

    def setUp(self):
        self.fixture = WIRE.WireFixture.__new__(WIRE.WireFixture)
        self.fixture.native = True
        self.fixture.trust_attempted = True
        self.fixture.trust_removal_deadline = None
        self.fixture.authorization_observation = False
        self.fixture.command_fact = None
        self.fixture.ca = Path("owned-inert-certificate.pem")

    def test52ExpiredRetryCannotAcquireOrRenewAndPreservesOriginalNativeFailure(self):
        original = RuntimeError("owned native removal refused")
        fact = {"phase": "exit", "status": 1}
        ca = self.fixture.ca
        deadlines = []

        def refuse(arguments, **options):
            deadlines.append(options["deadline"])
            self.assertEqual(arguments[3:5], ["remove-trusted-cert", "-d"])
            self.assertEqual(arguments[-1], str(ca))
            self.fixture.command_fact = fact
            raise original

        with mock.patch.object(WIRE.time, "monotonic", return_value=100.0):
            with mock.patch.object(self.fixture, "_observe_admin_trust"):
                with mock.patch.object(self.fixture, "_command", side_effect=refuse):
                    with self.assertRaises(RuntimeError) as error:
                        self.fixture.trust(False)
        self.assertIs(error.exception, original)
        self.assertTrue(self.fixture.trust_attempted)
        with mock.patch.object(WIRE.time, "monotonic", return_value=115.0):
            with mock.patch.object(self.fixture, "_observe_admin_trust") as observe:
                with mock.patch.object(self.fixture, "_command", side_effect=refuse) as command:
                    with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)) as retry:
                        self.fixture.trust(False)
        self.assertIsInstance(retry.exception, subprocess.TimeoutExpired)
        observe.assert_not_called()
        command.assert_not_called()
        self.assertEqual(deadlines, [115.0])
        self.assertIs(self.fixture.command_fact, fact)
        self.assertIs(self.fixture.ca, ca)
        self.assertTrue(self.fixture.trust_attempted)

    def test53RetryWithinBudgetKeepsTheExactOriginalDeadline(self):
        deadlines = []
        original = RuntimeError("owned native removal refused")

        def refuse(arguments, **options):
            deadlines.append(options["deadline"])
            self.fixture.command_fact = {"phase": "exit", "status": 1}
            raise original

        for tick in (100.0, 114.0):
            with mock.patch.object(WIRE.time, "monotonic", return_value=tick):
                with mock.patch.object(self.fixture, "_observe_admin_trust"):
                    with mock.patch.object(self.fixture, "_command", side_effect=refuse):
                        with self.assertRaises(RuntimeError) as error:
                            self.fixture.trust(False)
                        self.assertIs(error.exception, original)
        self.assertEqual(deadlines, [115.0, 115.0])
        self.assertTrue(self.fixture.trust_attempted)
        self.assertEqual(self.fixture.trust_removal_deadline, 115.0)

    def test54AcknowledgedRemovalAlonePermitsANewTrustCycleBudget(self):
        deadlines = []

        def acknowledge(arguments, **options):
            deadlines.append(options["deadline"])
            return 0, b""

        for tick in (100.0, 200.0):
            with mock.patch.object(WIRE.time, "monotonic", return_value=tick):
                with mock.patch.object(self.fixture, "_observe_admin_trust"):
                    with mock.patch.object(self.fixture, "_command", side_effect=acknowledge):
                        self.fixture.trust(False)
            self.assertFalse(self.fixture.trust_attempted)
            self.assertIsNone(self.fixture.trust_removal_deadline)
            # A separate recording acquisition is represented explicitly; no
            # native grant is executed or inferred by this portable control.
            self.fixture.trust_attempted = True
        self.assertEqual(deadlines, [115.0, 215.0])


class TrustInstallObservationControls(unittest.TestCase):
    """Actual trust/command bodies over a recording child; no native acquisition."""

    def receive(self, *, settle=True, timeout=True, raw=b"private output", logging_failure=False):
        fixture = WIRE.WireFixture.__new__(WIRE.WireFixture)
        fixture.native = True
        fixture.ca = Path("private-owner/ca.pem")
        fixture.keychain = Path("private-owner/owned.keychain-db")
        fixture.command_file_debt = []
        fixture.trust_attempted = False
        child = SimpleNamespace(pid=7729, returncode=None, stdin=io.BytesIO())
        primary = subprocess.TimeoutExpired("owned native child", 15)
        owner = SimpleNamespace(process=child, reaped=False, capture_read_attempts=0)
        calls = []

        class HostileCapture(io.BytesIO):
            def seek(self, *arguments):
                if not owner.reaped:
                    owner.capture_read_attempts += 1
                    raise AssertionError("Live child still owns the shared capture offset")
                return super().seek(*arguments)

            def read(self, *arguments):
                if not owner.reaped:
                    owner.capture_read_attempts += 1
                    raise AssertionError("Live child still owns the writable capture")
                return super().read(*arguments)

        def wait(timeout):
            calls.append(("wait", timeout))
            if timeout == 15 and receive_timeout:
                raise primary
            child.returncode = 0

        receive_timeout = timeout

        def retire():
            calls.append(("settle",))
            owner.reaped = settle
            if settle and child.returncode is None:
                child.returncode = -15
            return settle

        owner.wait_for_exit = wait
        owner.settle = retire

        def acquire(arguments, native, register, **ports):
            calls.append(("argv", arguments))
            register(owner)
            ports["stdout"].write(b"private-owner/ca.pem personal@example.test")
            ports["stderr"].write(raw)
            return owner

        fixture.groups = SimpleNamespace(acquire_owned=acquire)
        fixture.native_groups = object()
        output = io.StringIO()
        protocol_output = io.StringIO()
        failure = None
        capture_port = (
            mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=HostileCapture)
            if not settle
            else contextlib.nullcontext()
        )
        with (
            capture_port,
            contextlib.redirect_stderr(output),
            contextlib.redirect_stdout(protocol_output),
        ):
            with mock.patch.object(WIRE.time, "monotonic", side_effect=[100.0, 115.25]):
                with (
                    mock.patch("builtins.print", side_effect=RuntimeError("recording log refusal"))
                    if logging_failure
                    else contextlib.nullcontext()
                ):
                    try:
                        fixture.trust(True)
                    except BaseException as caught:
                        failure = caught
        self.assertEqual(
            protocol_output.getvalue(),
            "",
            "Passive facts must not corrupt the Swift JSON reply pipe",
        )
        return fixture, child, owner, primary, failure, output.getvalue(), calls

    def testTimeoutPreservesPrimaryDebtAndBoundedPrivateOutput(self):
        fixture, child, owner, primary, failure, output, calls = self.receive()
        self.assertIs(failure, primary)
        self.assertTrue(fixture.trust_attempted)
        self.assertEqual(fixture.command_fact, {"phase": "deadline", "status": None})
        self.assertEqual(
            calls[0][1],
            [
                "/usr/bin/sudo",
                "-n",
                "/usr/bin/security",
                "add-trusted-cert",
                "-d",
                "-r",
                "trustRoot",
                "-k",
                str(fixture.keychain),
                str(fixture.ca),
            ],
        )
        self.assertEqual(calls[1:], [("wait", 15), ("settle",)])
        self.assertTrue(child.stdin.closed)
        self.assertTrue(owner.reaped)
        self.assertIn("# native_http_trust_install ", output)
        fact = json.loads(output.removeprefix("# native_http_trust_install "))
        self.assertEqual(
            (fact["action"], fact["domain"], fact["keychain"]),
            ("add_trusted_cert", "admin", "owned_private"),
        )
        self.assertEqual((fact["pid"], fact["exit_status"], fact["elapsed_ms"]), (7729, -15, 15250))
        self.assertEqual(
            (fact["child_settled"], fact["streams_closed"], fact["phase"]), (True, True, "deadline")
        )
        self.assertEqual(failure.trust_install_output["stderr"], b"private output")
        self.assertEqual(
            fact["stderr"]["bounded_sha256"], hashlib.sha256(b"private output").hexdigest()
        )
        self.assertEqual(fact["stderr"]["category"], "unknown")
        for secret in ("private-owner", "personal@example.test", "private output", "ca.pem"):
            self.assertNotIn(secret, output)

    def testFailedRetirementCannotAdvertiseChildACK(self):
        fixture, child, owner, primary, failure, output, calls = self.receive(settle=False)
        self.assertIs(failure, primary)
        self.assertTrue(fixture.trust_attempted)
        self.assertFalse(owner.reaped)
        self.assertEqual(
            owner.capture_read_attempts, 0, "No capture seek/read before exact child retirement"
        )
        self.assertEqual(failure.trust_install_output, {})
        self.assertIn("# native_http_trust_install ", output)
        fact = json.loads(output.removeprefix("# native_http_trust_install "))
        self.assertEqual(fixture.command_fact["phase"], "settle")
        self.assertFalse(fact["child_settled"])
        self.assertEqual(fact["stdout"], {"observed": False})
        self.assertEqual(fact["stderr"], {"observed": False})
        self.assertFalse(fact["streams_closed"])
        self.assertIsNone(fact["exit_status"])
        self.assertEqual(calls[-1], ("settle",))

    def testClosedStderrCategoriesAndTruncationNeverInferCause(self):
        vectors = [
            (b"", "empty"),
            (
                b"SecTrustSettingsSetTrustSettings: User interaction is not allowed.\n",
                "user_interaction_required",
            ),
            (b"security: SecKeychainUnlock: The keychain is locked.\n", "keychain_locked"),
            (b"SecKeychainItemImport: Access denied.\n", "access_denied"),
            (b"SecTrustSettingsSetTrustSettings: Authorization denied.\n", "access_denied"),
            (b"SecTrustSettingsSetTrustSettings: private-owner personal@example.test\n", "unknown"),
            (b"personal: Access denied.\n", "unknown"),
            (b"SecKeychainUnlock: The keychain is locked.\n" + b"X" * 1024, "unknown"),
        ]
        for raw, expected in vectors:
            with self.subTest(category=expected, bytes=len(raw)):
                fixture, _, _, primary, failure, output, _ = self.receive(raw=raw)
                self.assertIs(failure, primary)
                self.assertIn("# native_http_trust_install ", output)
                fact = json.loads(output.removeprefix("# native_http_trust_install "))["stderr"]
                self.assertEqual(fact["category"], expected)
                self.assertEqual(fact["captured_bytes"], min(1024, len(raw)))
                self.assertEqual(fact["truncated"], len(raw) > 1024)
                self.assertEqual(failure.trust_install_output["stderr"], raw[:1024])
                self.assertEqual(fact["bounded_sha256"], hashlib.sha256(raw[:1024]).hexdigest())
                self.assertTrue(fixture.trust_attempted)

    def testObserverFailureKeepsOriginalTimeoutAndSuccessStaysExact(self):
        fixture, _, _, primary, failure, _, _ = self.receive(logging_failure=True)
        self.assertIs(failure, primary)
        self.assertTrue(fixture.trust_attempted)
        self.assertEqual(str(failure.__cause__), "recording log refusal")
        fixture, child, _, _, failure, output, _ = self.receive(timeout=False)
        self.assertIsNone(failure)
        self.assertTrue(fixture.trust_attempted)
        self.assertEqual(fixture.command_fact, {"phase": "complete", "status": 0})
        self.assertIn("# native_http_trust_install ", output)
        fact = json.loads(output.removeprefix("# native_http_trust_install "))
        self.assertEqual(fact["exit_status"], 0)
        self.assertTrue(fact["child_settled"])


if __name__ == "__main__":
    unittest.main()

"""Portable physical peers and passive owned-child receiving facts."""

import hashlib
import shutil
import signal
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


# Closed inverse for the complete reviewed failed-C-frame diagnostic overlay.
# Every span is literal and unique. Existing PAC/diagnostic inverses and their
# historical whole-source oracles remain unchanged after this first projection.
NATIVE_FAILURE_STAGE_INVERSE = (
    (
        '// BEGIN GENERATED NATIVE HTTP FAILURE STAGES\n// Generated from static/ergopti_plus/_shared/modules/network/native_http_failure_stages.json; do not edit this span.\nenum ManagedHTTPFailureStage: String, CaseIterable {\n\tcase policyLoad = "native_policy_load"\n\tcase selectionBound = "native_selection_bound"\n\tcase proxyLookup = "native_proxy_lookup"\n\tcase proxyDictionary = "native_proxy_dictionary"\n\tcase routeEmpty = "native_route_empty"\n\tcase certificateLoad = "native_certificate_load"\n\tcase lookupDeadline = "native_lookup_deadline"\n\tcase dispatchDeadline = "native_dispatch_deadline"\n\tcase sessionTerminal = "native_session_terminal"\n\n\tfunc permits(reason: String) -> Bool {\n\t\tswitch self {\n\t\tcase .policyLoad: return ["unavailable"].contains(reason)\n\t\tcase .selectionBound: return ["unavailable"].contains(reason)\n\t\tcase .proxyLookup: return ["unavailable"].contains(reason)\n\t\tcase .proxyDictionary: return ["proxy"].contains(reason)\n\t\tcase .routeEmpty: return ["unavailable"].contains(reason)\n\t\tcase .certificateLoad: return ["certificate"].contains(reason)\n\t\tcase .lookupDeadline: return ["deadline"].contains(reason)\n\t\tcase .dispatchDeadline: return ["deadline"].contains(reason)\n\t\tcase .sessionTerminal: return ["deadline", "cancelled", "offline", "certificate", "proxy", "connect", "unavailable", "protocol", "content_encoding"].contains(reason)\n\t\t}\n\t}\n}\n// END GENERATED NATIVE HTTP FAILURE STAGES\n\n',
        "",
    ),
    (
        '\t\tvar terminal: [String: Any] = ["version": 1, "success": success, "reason": failure ?? "complete"]\n\t\tif !success, let failure, ManagedHTTPFailureStage.sessionTerminal.permits(reason: failure) {\n\t\t\tterminal["native_refusal_stage"] = ManagedHTTPFailureStage.sessionTerminal.rawValue\n\t\t}\n\t\tlet sent = json(tag: 67, object: terminal)\n',
        '\t\tlet sent = json(tag: 67, object: ["version": 1, "success": success, "reason": failure ?? "complete"])\n',
    ),
    (
        '\tprivate static func refuse(reason: String, status: Int32, stage: ManagedHTTPFailureStage, output: (Data) -> Bool) -> Int32 {\n\t\tguard stage.permits(reason: reason) else { return 74 }\n\t\tguard let json = try? JSONSerialization.data(withJSONObject: ["version": 1, "success": false, "reason": reason,\n\t\t\t"native_refusal_stage": stage.rawValue]),\n\t\t\tlet frame = ManagedHTTPFrame.encode(tag: 67, bytes: json) else { return 74 }\n\t\treturn output(frame) ? status : 74\n\t}\n\n\tprivate static func stdout(',
        '\tprivate static func refuse(reason: String, status: Int32, output: (Data) -> Bool) -> Int32 {\n\t\tguard let json = try? JSONSerialization.data(withJSONObject: ["version": 1, "success": false, "reason": reason]),\n\t\t\tlet frame = ManagedHTTPFrame.encode(tag: 67, bytes: json) else { return 74 }\n\t\treturn output(frame) ? status : 74\n\t}\n\n\tprivate static func stdout(',
    ),
    (
        '\t\telse { return refuse(reason: "unavailable", status: 78, stage: .policyLoad, output: stdout) }\n',
        '\t\telse { return refuse(reason: "unavailable", status: 78, output: stdout) }\n',
    ),
    (
        '\t\tcatch { return refuse(reason: "certificate", status: 74, stage: .certificateLoad, output: output) }\n',
        '\t\tcatch { return refuse(reason: "certificate", status: 74, output: output) }\n',
    ),
    (
        '\t\tguard maximumSelections > 0 else { return refuse(reason: "unavailable", status: 78, stage: .selectionBound, output: output) }\n',
        '\t\tguard maximumSelections > 0 else { return refuse(reason: "unavailable", status: 78, output: output) }\n',
    ),
    (
        '\t\t\tif let lookupRemaining, lookupRemaining <= 0 { return refuse(reason: "deadline", status: 75, stage: .lookupDeadline, output: output) }\n',
        '\t\t\tif let lookupRemaining, lookupRemaining <= 0 { return refuse(reason: "deadline", status: 75, output: output) }\n',
    ),
    (
        '\t\t\telse { return refuse(reason: "unavailable", status: 78, stage: .proxyLookup, output: output) }\n',
        '\t\t\telse { return refuse(reason: "unavailable", status: 78, output: output) }\n',
    ),
    (
        '\t\t\tguard let proxy = ManagedProxyLookup.dictionary(route: route) else { return refuse(reason: "proxy", status: 78, stage: .proxyDictionary, output: output) }\n',
        '\t\t\tguard let proxy = ManagedProxyLookup.dictionary(route: route) else { return refuse(reason: "proxy", status: 78, output: output) }\n',
    ),
    (
        '\t\t\tif let remaining, remaining <= 0 { return refuse(reason: "deadline", status: 75, stage: .dispatchDeadline, output: output) }\n',
        '\t\t\tif let remaining, remaining <= 0 { return refuse(reason: "deadline", status: 75, output: output) }\n',
    ),
    (
        '\t\treturn refuse(reason: "unavailable", status: 78, stage: .routeEmpty, output: output)\n',
        '\t\treturn refuse(reason: "unavailable", status: 78, output: output)\n',
    ),
)
NATIVE_FAILURE_STAGE_MARKERS = (
    "GENERATED NATIVE HTTP FAILURE STAGES",
    "ManagedHTTPFailureStage",
    "native_refusal_stage",
)


# Closed inverse for the reviewed bare CFNetwork proxy-connection failover repair.
# It composes before every other projection, so each historical whole-source pin
# still covers every byte outside these three exact spans.
PROXY_CONNECTION_FAILURE_INVERSE = (
    (
        "/// macOS 15 reports a proxy whose TCP connect is refused as the bare CFNetwork\n"
        "/// kCFErrorHTTPSProxyConnectionFailure (310), or kCFErrorHTTPProxyConnectionFailure\n"
        "/// (306) for plain HTTP, with no NSURLErrorDomain wrapper and no POSIX cause.\n"
        "/// Both fail before any proxy reply: a CONNECT that the proxy answers with an\n"
        "/// error is the separate code 311\n"
        "/// (kCFStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod).\n"
        "func managedHTTPProxyConnectionFailed(_ error: NSError) -> Bool {\n"
        "\treturn error.domain == kCFErrorDomainCFNetwork as String\n"
        "\t\t&& [CFNetworkErrors.cfErrorHTTPSProxyConnectionFailure, .cfErrorHTTPProxyConnectionFailure]\n"
        "\t\t\t.contains { error.code == Int($0.rawValue) }\n"
        "}\n\n",
        "",
    ),
    (
        '\tif managedHTTPProxyConnectionFailed(error) { return "connect" }\n',
        "",
    ),
    (
        "\t\t\t\t// The bare proxy connection failure names the proxy route itself, so\n"
        "\t\t\t\t// it does not depend on metrics for a connection that never opened.\n"
        "\t\t\t\t// The same code ends a CONNECT the proxy answered with 407: a proxy\n"
        "\t\t\t\t// that replied is never a refused route and never fails over.\n"
        "\t\t\t\tif managedHTTPProxyConnectionFailed(native) {\n"
        '\t\t\t\t\tif proxyAuthenticationObserved { failure = "proxy" }\n'
        "\t\t\t\t\telse { refusedTCPConnect = true; proxyObserved = true }\n"
        "\t\t\t\t\tbreak\n"
        "\t\t\t\t}\n",
        "",
    ),
)


def proxy_connection_failure_projection(source):
    """Invert the complete reviewed repair, or keep a source that has none of it."""
    marker = "managedHTTPProxyConnectionFailed"
    if marker not in source:
        return source
    if source.count(marker) != 3 or any(
        source.count(new) != 1 for new, _ in PROXY_CONNECTION_FAILURE_INVERSE
    ):
        raise ValueError("Proxy connection failover enrollment refused")
    for new, old in PROXY_CONNECTION_FAILURE_INVERSE:
        source = source.replace(new, old, 1)
    return source


def native_failure_stage_projection(source):
    """Invert one complete closed overlay, preserving unrelated source bytes."""
    source = proxy_connection_failure_projection(source)
    if not any(marker in source for marker in NATIVE_FAILURE_STAGE_MARKERS):
        return source
    if any(
        source.count(new) != 1 or (legacy and legacy in source)
        for new, legacy in NATIVE_FAILURE_STAGE_INVERSE
    ):
        raise ValueError("Native failure-stage enrollment refused")
    projected = source
    for new, legacy in NATIVE_FAILURE_STAGE_INVERSE:
        projected = projected.replace(new, legacy, 1)
    if any(marker in projected for marker in NATIVE_FAILURE_STAGE_MARKERS):
        raise ValueError("Native failure-stage projection refused")
    return projected


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
    source = native_failure_stage_projection(source)
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
    source = native_failure_stage_projection(source)
    diagnostic, original = DEBUG_CERTIFICATE_FAILURE_INVERSE
    if source.count("func managedHTTPFailure(") != 1:
        raise ValueError("Certificate diagnostic function identity refused")
    if source.count(original) == 1 and diagnostic not in source:
        return source
    if source.count(diagnostic) != 1 or original in source:
        raise ValueError("Certificate diagnostic enrollment refused")
    return source.replace(diagnostic, original, 1)


# One complete diagnostic-only observation composes before the existing
# certificate/PAC inverses. Every helper, call and challenge span is literal and
# unique; the original historical whole-source pin still protects all other bytes.
TRUST_CAUSE_DIAGNOSTIC_INVERSE = (
    '#if DEBUG || ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n/// Observations of an already-delivered error only. No message, URL, certificate\n/// or arbitrary userInfo key is read; the original failure policy is unchanged.\nfunc managedHTTPNativeErrorFacts(_ error: NSError) -> [String] {\n\tfunc integer(_ value: Any?) -> Int32? {\n\t\tguard let number = value as? NSNumber,\n\t\t\tCFGetTypeID(number) != CFBooleanGetTypeID(),\n\t\t\t["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),\n\t\t\tnumber.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max)\n\t\telse { return nil }\n\t\treturn Int32(exactly: number.int64Value)\n\t}\n\tvar current = error\n\tvar seen = Set<ObjectIdentifier>()\n\tvar result: [String] = []\n\tlet cfNetworkDomain: String = kCFErrorDomainCFNetwork as String\n\twhile result.count < 4 && seen.insert(ObjectIdentifier(current)).inserted {\n\t\tlet domain: String\n\t\tswitch current.domain {\n\t\tcase NSURLErrorDomain: domain = "url"\n\t\tcase NSPOSIXErrorDomain: domain = "posix"\n\t\tcase NSOSStatusErrorDomain: domain = "osstatus"\n\t\tcase cfNetworkDomain: domain = "cfnetwork"\n\t\tdefault: domain = "unknown"\n\t\t}\n\t\tlet code = domain == "unknown" ? nil : Int32(exactly: current.code)\n\t\tvar streamDomain: Int32?\n\t\tvar streamCode: Int32?\n\t\tif domain == "cfnetwork" || domain == "url" {\n\t\t\tif let admittedDomain = integer(current.userInfo["_kCFStreamErrorDomainKey"]),\n\t\t\t\tlet admittedCode = integer(current.userInfo["_kCFStreamErrorCodeKey"]) {\n\t\t\t\tstreamDomain = admittedDomain; streamCode = admittedCode\n\t\t\t}\n\t\t}\n\t\tresult.append("# native_http_error_chain node=\\(result.count) domain=\\(domain) code=\\(code.map(String.init) ?? "none") stream_domain=\\(streamDomain.map(String.init) ?? "none") stream_code=\\(streamCode.map(String.init) ?? "none")")\n\t\tguard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }\n\t\tcurrent = underlying\n\t}\n\treturn result\n}\n#endif\n\n',
    '\t#if DEBUG || ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n\tfor fact in managedHTTPNativeErrorFacts(error) { _ = fputs(fact + "\\n", stderr) }\n\t#endif\n',
    '\t\t#if DEBUG || ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n\t\tif challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {\n\t\t\t_ = fputs("# native_http_trust_challenge mode=\\(certificates.isEmpty ? "system" : "extra")\\n", stderr)\n\t\t}\n\t\t#endif\n',
    '\t\t\t\t#if DEBUG || ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n\t\t\t\t_ = fputs("# native_http_extra_trust result=refused\\n", stderr)\n\t\t\t\t#endif\n',
    '\t\t\t#if DEBUG || ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n\t\t\t_ = fputs("# native_http_extra_trust result=accepted\\n", stderr)\n\t\t\t#endif\n',
)
TRUST_CAUSE_DIAGNOSTIC_MARKERS = (
    "managedHTTPNativeErrorFacts",
    "native_http_error_chain",
    "native_http_trust_challenge",
    "native_http_extra_trust",
)


def trust_cause_diagnostic_projection(source):
    """Invert all five exact observation spans together, or retain legacy bytes."""
    source = native_failure_stage_projection(source)
    if not any(marker in source for marker in TRUST_CAUSE_DIAGNOSTIC_MARKERS):
        return source
    if any(source.count(span) != 1 for span in TRUST_CAUSE_DIAGNOSTIC_INVERSE):
        raise ValueError("Trust cause diagnostic enrollment refused")
    projected = source
    for span in TRUST_CAUSE_DIAGNOSTIC_INVERSE:
        projected = projected.replace(span, "", 1)
    if any(marker in projected for marker in TRUST_CAUSE_DIAGNOSTIC_MARKERS):
        raise ValueError("Trust cause diagnostic projection refused")
    return projected


def historical_pac_ownership_projection(source):
    """Accept the exact legacy source or the complete approved ownership repair."""
    source = native_failure_stage_projection(source)
    source = trust_cause_diagnostic_projection(source)
    source = tls_failure_diagnostic_projection(source)
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


TLS_FAILURE_DIAGNOSTIC_INVERSE = (
    (
        '/// Projects only closed native status facts from the already completed request.\n/// No trust evaluation, certificate text or private NSError payload is acquired.\nfunc managedHTTPTLSDiagnostic(_ error: NSError, additionalAnchorCount: Int) -> [String: Any] {\n\tprecondition(additionalAnchorCount >= 0)\n\tlet cfNetworkDomain = kCFErrorDomainCFNetwork as String\n\tvar native = error\n\tvar seen = Set<ObjectIdentifier>()\n\tvar causes: [[String: Any]] = []\n\tvar termination = "complete"\n\twhile true {\n\t\tguard seen.insert(ObjectIdentifier(native)).inserted else { termination = "cycle"; break }\n\t\tguard causes.count < 8 else { termination = "depth"; break }\n\t\tlet domain: String\n\t\tswitch native.domain {\n\t\tcase NSURLErrorDomain: domain = "url"\n\t\tcase NSOSStatusErrorDomain: domain = "security"\n\t\tcase cfNetworkDomain: domain = "cfnetwork"\n\t\tcase NSPOSIXErrorDomain: domain = "posix"\n\t\tdefault: domain = "other"\n\t\t}\n\t\tlet code = domain == "other" ? nil : Int32(exactly: native.code)\n\t\tvar kind = "unknown"\n\t\tif domain == "security", let code {\n\t\t\tswitch code {\n\t\t\tcase errSSLHostNameMismatch: kind = "hostname_mismatch"\n\t\t\tcase errSSLCertExpired: kind = "certificate_expired"\n\t\t\tcase errSSLCertNotYetValid: kind = "certificate_not_yet_valid"\n\t\t\tcase errSSLUnknownRootCert: kind = "unknown_root"\n\t\t\tcase errSSLXCertChainInvalid: kind = "certificate_chain_invalid"\n\t\t\tdefault: break\n\t\t\t}\n\t\t} else if domain == "url", let code {\n\t\t\tswitch Int(code) {\n\t\t\tcase NSURLErrorServerCertificateUntrusted: kind = "certificate_untrusted"\n\t\t\tcase NSURLErrorServerCertificateHasBadDate: kind = "certificate_date_invalid"\n\t\t\tcase NSURLErrorServerCertificateNotYetValid: kind = "certificate_not_yet_valid"\n\t\t\tcase NSURLErrorServerCertificateHasUnknownRoot: kind = "unknown_root"\n\t\t\tdefault: break\n\t\t\t}\n\t\t}\n\t\tvar cause: [String: Any] = ["domain": domain, "code": NSNull(), "kind": kind]\n\t\tif let code { cause["code"] = Int(code) }\n\t\t// These optional integers were delivered with the completed NSError.\n\t\t// No SecTrust getter may trigger a new evaluation for this observation.\n\t\tcause["stream_domain"] = NSNull()\n\t\tcause["stream_code"] = NSNull()\n\t\tif domain == "url" || domain == "cfnetwork" {\n\t\t\tfor (field, key) in [("stream_domain", "_kCFStreamErrorDomainKey"), ("stream_code", "_kCFStreamErrorCodeKey")] {\n\t\t\t\tif let value = native.userInfo[key] as? NSNumber,\n\t\t\t\t\tCFGetTypeID(value) != CFBooleanGetTypeID(),\n\t\t\t\t\tlet integer = Int32(exactly: value.doubleValue) { cause[field] = Int(integer) }\n\t\t\t}\n\t\t}\n\t\tcauses.append(cause)\n\t\tguard let underlying = native.userInfo[NSUnderlyingErrorKey] else { break }\n\t\tguard let next = underlying as? NSError else { termination = "unavailable"; break }\n\t\tnative = next\n\t}\n\treturn ["version": 1, "trust_mode": additionalAnchorCount == 0 ? "native_default" : "added_anchors",\n\t\t"additional_anchor_count": additionalAnchorCount, "causes": causes, "chain_termination": termination]\n}\n\n',
        "",
    ),
    (
        '\t\t#if DEBUG\n\t\tif failure == "certificate", let error = error as NSError?,\n\t\t\tlet bytes = try? JSONSerialization.data(withJSONObject:\n\t\t\t\tmanagedHTTPTLSDiagnostic(error, additionalAnchorCount: certificates.count), options: [.sortedKeys]),\n\t\t\tlet text = String(data: bytes, encoding: .utf8) {\n\t\t\t_ = fputs("# native_http_tls_failure \\(text)\\n", stderr)\n\t\t}\n\t\t#endif\n',
        "",
    ),
)


def tls_failure_diagnostic_projection(source):
    """Accept an absent observation or its two exact complete reviewed spans."""
    source = native_failure_stage_projection(source)
    marker = "func managedHTTPTLSDiagnostic("
    if marker not in source and "# native_http_tls_failure " not in source:
        return source
    if source.count(marker) != 1 or any(
        source.count(new) != 1 for new, _ in TLS_FAILURE_DIAGNOSTIC_INVERSE
    ):
        raise ValueError("TLS diagnostic enrollment refused")
    for new, old in TLS_FAILURE_DIAGNOSTIC_INVERSE:
        source = source.replace(new, old, 1)
    return source


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

    def test07bFixtureDiagnosticsStayOutOfActualJSONResponseStream(self):
        # A separate diagnostic channel is ineffective if the native parent discards it.
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
        receiving = (SUPPORT / "native_http_wire_client_receiving.py").read_text(encoding="utf-8")
        self.assertIn('"native_http_fixture_builder.py"', receiving)
        self.assertIn("cls.build = builder.OwnedFixtureBuild(cls.fixture)", receiving)
        self.assertIn("cls.build.build()", receiving)
        # The source-bound builder now owns compilation; inspect its real argv.
        compiler = (SUPPORT / "native_http_fixture_builder.py").read_text(encoding="utf-8")
        self.assertIn(
            '"-D",\n                "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",',
            compiler,
        )
        import ast

        compiler = ast.parse(
            (SUPPORT / "native_http_fixture_builder.py").read_text(encoding="utf-8")
        )
        builder = next(
            node
            for node in compiler.body
            if isinstance(node, ast.ClassDef) and node.name == "OwnedFixtureBuild"
        )
        build = next(
            node
            for node in builder.body
            if isinstance(node, ast.FunctionDef) and node.name == "build"
        )
        compiler_calls = [
            node
            for node in ast.walk(build)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and ast.unparse(node.func) == "self._command"
            and node.args
            and isinstance(node.args[0], ast.List)
            and len(node.args[0].elts) >= 5
            and isinstance(node.args[0].elts[0], ast.Constant)
            and node.args[0].elts[0].value == "/usr/bin/xcrun"
        ]
        self.assertEqual(len(compiler_calls), 1)
        self.assertEqual(
            [node.value for node in compiler_calls[0].args[0].elts[:5]],
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-parse-as-library",
                "-D",
                "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",
            ],
        )
        caller = ast.parse(
            (SUPPORT / "native_http_wire_client_receiving.py").read_text(encoding="utf-8")
        )
        receiving = next(
            node
            for node in caller.body
            if isinstance(node, ast.ClassDef) and node.name == "RealNativeClientReceiving"
        )
        bootstrap = next(
            node
            for node in receiving.body
            if isinstance(node, ast.FunctionDef) and node.name == "setUpClass"
        )
        calls = [node for node in ast.walk(bootstrap) if isinstance(node, ast.Call)]
        fixed_loads = [
            node
            for node in calls
            if ast.unparse(node.func) == "importlib.util.spec_from_file_location"
        ]
        self.assertEqual(
            [(ast.unparse(node.args[0]), ast.unparse(node.args[1])) for node in fixed_loads],
            [
                (
                    "'owned_native_http_build'",
                    "Path(__file__).with_name('native_http_fixture_builder.py')",
                ),
                ("'actual_native_managed_http'", "native / 'managed_http.py'"),
            ],
        )
        for expression in (
            "importlib.util.module_from_spec(build_spec)",
            "build_spec.loader.exec_module(builder)",
            "builder.OwnedFixtureBuild(cls.fixture)",
            "cls.build.build()",
        ):
            self.assertEqual(sum(ast.unparse(node) == expression for node in calls), 1)


class NativeCommandClosureDebtTests(unittest.TestCase):
    # These controls exercise real portable children and closure arbitration;
    # they do not substitute for native Darwin process ownership.
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

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

    def test25RealTemporaryOutputCloseRefusalRetainsExactOwnerDebt(self):
        original = self.fixture._command
        primary = RuntimeError("controlled exact output close refusal")
        real_temporary_file = tempfile.TemporaryFile
        held = []
        body = "import sys;sys.stdin.buffer.read();sys.stdout.buffer.write(b'owned')"

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

        with mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=allocate):
            with mock.patch("builtins.print") as output:
                with self.assertRaises(RuntimeError) as refusal:
                    original([sys.executable, "-B", "-c", body])
        self.assertIs(refusal.exception, primary)
        output.assert_not_called()
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

    def test26RealGroupedStdinRefusalPreservesPrimaryAndExactPipeAfterPhysicalReap(self):
        # The controlled group adapter kills/reaps real portable children. It is
        # deliberately not evidence about Darwin LibProc ownership.
        primary = RuntimeError("controlled exact stdin close refusal")
        write_primary = RuntimeError("controlled exact stdin write refusal")
        original = self.fixture._command
        real_popen = subprocess.Popen
        held, children = [], []
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

        self.fixture.native = True
        self.fixture.groups = ControlledGroups()
        self.fixture.native_groups = None
        for fail_write in (False, True):
            with mock.patch("builtins.print") as output:
                with self.assertRaises(RuntimeError) as refusal:
                    original(
                        [sys.executable, "-B", "-c", "import sys;sys.stdin.buffer.read()"],
                        b"owned input",
                    )
            self.assertIs(refusal.exception, write_primary if fail_write else primary)
            output.assert_not_called()
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

    def test27RetiredCloseMarkerCannotPayPhysicalUncertaintyOrAuthorizeAnotherClose(self):
        original = self.fixture._command
        primary = OSError("controlled retired marker before physical close")
        real_temporary_file = tempfile.TemporaryFile
        held = []

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

        with mock.patch.object(WIRE.tempfile, "TemporaryFile", side_effect=allocate):
            with mock.patch("builtins.print") as output:
                with self.assertRaises(OSError) as refusal:
                    original([sys.executable, "-B", "-c", "import sys;sys.stdin.buffer.read()"])
        self.assertIs(refusal.exception, primary)
        output.assert_not_called()
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

        # Reject every partial, duplicate or altered approved diagnostic span;
        # an unrelated release mutation still reaches the original whole pin.
        for new, old in TLS_FAILURE_DIAGNOSTIC_INVERSE:
            self.assertEqual(source.count(new), 1)
            for replacement in (old, new + new, new + "// unapproved\n"):
                with self.subTest(diagnostic=new[:80], replacement=replacement[:80]):
                    with self.assertRaises(ValueError):
                        historical_pac_ownership_projection(source.replace(new, replacement, 1))


class PACSourceAcquisitionProjectionTests(unittest.TestCase):
    @staticmethod
    def raw_source():
        source = (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text()
        return re.sub(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            "",
            native_failure_stage_projection(source),
            flags=re.MULTILINE | re.DOTALL,
        )

    def _assert_closed_failure_stage_overlay(self):
        # Read the actual staged producer. No historical source file replaces
        # this input: only the complete, closed literal overlay may disappear.
        source = (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text()
        projected = native_failure_stage_projection(source)
        self.assertEqual(len(NATIVE_FAILURE_STAGE_INVERSE), 11)
        self.assertEqual(
            hashlib.sha256(projected.encode()).hexdigest(),
            "621bead52172608f1ae40cb57713c718734f3c2c43f063485932ac9e560cc647",
        )
        self.assertEqual(native_failure_stage_projection(projected), projected)
        for new, legacy in NATIVE_FAILURE_STAGE_INVERSE:
            with self.subTest(overlay=new):
                self.assertEqual(source.count(new), 1)
                for replacement in (legacy, new[:-1], new + new):
                    with self.subTest(replacement=replacement):
                        with self.assertRaises(ValueError):
                            native_failure_stage_projection(source.replace(new, replacement, 1))
                if legacy:
                    with self.assertRaises(ValueError):
                        native_failure_stage_projection(source.replace(new, new + legacy, 1))
        for before, after in (
            ("stage: .selectionBound", "stage: .policyLoad"),
            (
                "if !success, let failure, ManagedHTTPFailureStage",
                "if success, let failure, ManagedHTTPFailureStage",
            ),
            ("guard stage.permits(reason: reason) else", "guard true else"),
            ('"native_refusal_stage": stage.rawValue', '"native_refusal_stage": reason'),
        ):
            with self.subTest(mismatch=before):
                self.assertEqual(source.count(before), 1)
                with self.assertRaises(ValueError):
                    native_failure_stage_projection(source.replace(before, after, 1))
        with self.assertRaises(ValueError):
            native_failure_stage_projection(
                source + "\n// native_refusal_stage unenrolled sibling\n"
            )
        # Bytes outside the exact overlay remain owned by the unchanged whole
        # historical oracle, even after a complete valid inverse.
        candidate = source + "\n// unrelated unapproved bytes\n"
        release = re.sub(
            r"^[ \t]*#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS\n.*?^[ \t]*#endif\n",
            "",
            candidate,
            flags=re.MULTILINE | re.DOTALL,
        )
        with self.assertRaises(ValueError):
            historical_pac_ownership_projection(release)

    def test45CompleteSourceOwnerKeepsImmutableHistoricalPin(self):
        source = self.raw_source()
        legacy = historical_pac_ownership_projection(source)
        self.assertEqual(
            hashlib.sha256(legacy.encode()).hexdigest(), HISTORICAL_HTTP_RELEASE_SHA256
        )
        self.assertNotIn("ManagedPACSource.", legacy)
        self._assert_closed_failure_stage_overlay()

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


class TrustCauseDiagnosticEnrollmentTests(unittest.TestCase):
    @staticmethod
    def source():
        return (
            SUPPORT.parents[1] / "launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift"
        ).read_text(encoding="utf-8")

    def test58CompleteDiagnosticInverseKeepsExactPreimageAndHistoricalWholePin(self):
        source = self.source()
        self.assertEqual(len(TRUST_CAUSE_DIAGNOSTIC_INVERSE), 5)
        original = trust_cause_diagnostic_projection(tls_failure_diagnostic_projection(source))
        self.assertEqual(
            hashlib.sha256(original.encode()).hexdigest(),
            "761b1a636bfc69d987545a30502db5a7c549e76c9b674630fc27bb4b157febc7",
        )
        self.assertEqual(trust_cause_diagnostic_projection(original), original)
        released = HistoricalPACOwnershipProjectionTests.release_source()
        legacy = historical_pac_ownership_projection(released)
        self.assertEqual(
            hashlib.sha256(legacy.encode()).hexdigest(),
            "68659ddec98c9a427244b315b69c17750b743eab2cdd3688308690a66d1c6e98",
        )
        self.assertEqual(historical_pac_ownership_projection(legacy), legacy)

    def test59EveryMissingAndPartialObservationSpanRefuses(self):
        source = HistoricalPACOwnershipProjectionTests.release_source()
        for span in TRUST_CAUSE_DIAGNOSTIC_INVERSE:
            with self.subTest(span=span):
                self.assertEqual(source.count(span), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(span, "", 1))
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(span, span[:-1], 1))

    def test60DuplicateObservationAndUnenrolledSiblingCannotDisappear(self):
        source = HistoricalPACOwnershipProjectionTests.release_source()
        for span in TRUST_CAUSE_DIAGNOSTIC_INVERSE:
            with self.subTest(span=span):
                self.assertEqual(source.count(span), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(span, span + span, 1))
        with self.assertRaises(ValueError):
            historical_pac_ownership_projection(
                source + "\n// native_http_error_chain unenrolled sibling\n"
            )

    def test61RawMessageDomainAndUnboundedErrorHelpersRemainUnenrolled(self):
        source = HistoricalPACOwnershipProjectionTests.release_source()
        for before, after in (
            (
                'result.append("# native_http_error_chain node=',
                'result.append(current.localizedDescription + "# native_http_error_chain node=',
            ),
            ('default: domain = "unknown"', "default: domain = current.domain"),
            ("while result.count < 4 &&", "while result.count < 400 &&"),
            ("current.userInfo[NSUnderlyingErrorKey]", 'current.userInfo["raw-private-value"]'),
        ):
            with self.subTest(change=before):
                self.assertEqual(source.count(before), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(before, after, 1))

    def test62ChangedFunctionalReturnAndOtherUnapprovedBytesKeepHistoricalRefusal(self):
        source = HistoricalPACOwnershipProjectionTests.release_source()
        for before, after in (
            (
                'case NSURLErrorTimedOut: return "deadline"',
                'case NSURLErrorTimedOut: return "certificate"',
            ),
            ('\t\treturn "certificate"\n', '\t\treturn "unavailable"\n'),
            ("return Int32(exactly: number.int64Value)", "return Int32(0)"),
        ):
            with self.subTest(change=before):
                self.assertEqual(source.count(before), 1)
                with self.assertRaises(ValueError):
                    historical_pac_ownership_projection(source.replace(before, after, 1))
        original = trust_cause_diagnostic_projection(source)
        with self.assertRaises(ValueError):
            historical_pac_ownership_projection(original + "\n// unapproved\n")


NATIVE_GUARD_CLEANUP = []


class NativeCommandGuardProtocolModel:
    """No native executable runs; exact Popen handles retire every actual child."""

    def __init__(
        self,
        ack=True,
        primary=None,
        partial=False,
        refuse=False,
        exit_status=0,
        uncertain_capture=False,
    ):
        self.ack = ack
        self.primary = primary
        self.partial = partial
        self.refuse = refuse
        self.exit_status = exit_status
        self.uncertain_capture = uncertain_capture
        self.children = []
        self.arguments = []

    def acquire_owned(self, arguments, native, register, **options):
        self.arguments.append(arguments)
        if self.refuse:
            raise self.primary
        unsettled = self.ack is False
        body = "import time; time.sleep(60)" if unsettled else "import sys; sys.stdin.buffer.read()"
        if self.exit_status:
            body += "; sys.exit(" + str(self.exit_status) + ")"
        process = subprocess.Popen(
            [sys.executable, "-I", "-B", "-c", body], start_new_session=True, **options
        )
        process.output_capture = options["stdout"]
        process.error_capture = options["stderr"]
        if self.uncertain_capture:
            stream = process.stdin

            class UncertainClose:
                def __getattr__(self, name):
                    return getattr(stream, name)

                def close(self):
                    stream.close()
                    raise OSError("EXPLICIT physical descriptor closed but ACK refused")

            process.stdin = UncertainClose()
        model = self

        class Owner:
            reaped = False

            def __init__(self):
                self.process = process
                self.settle_calls = 0

            def wait_for_exit(self, timeout):
                if unsettled:
                    if model.primary is None:
                        model.primary = subprocess.TimeoutExpired(
                            "EXPLICIT modeled owned wait", timeout
                        )
                    raise model.primary
                process.wait(timeout=timeout)

            def settle(self):
                self.settle_calls += 1
                ack = False if unsettled else model.ack
                if isinstance(ack, BaseException):
                    raise ack
                if ack is True:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                    self.reaped = True
                return ack

        owner = Owner()
        self.children.append(owner)
        register(owner)
        if self.partial:
            raise self.primary
        return owner


def native_guard_actual_main_handlers():
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    captured = {}

    class Stop(Exception):
        pass

    def stop(*args, **kwargs):
        captured.update({sig: signal.getsignal(sig) for sig in previous})
        raise Stop()

    try:
        with (
            mock.patch.object(WIRE, "WireFixture", side_effect=stop),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            try:
                WIRE.main()
            except Stop:
                pass
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    assert len(captured) == 2 and all(callable(value) for value in captured.values())
    return captured


class NativeCommandGuardTests(unittest.TestCase):
    def setUp(self):
        self.out, self.err = io.StringIO(), io.StringIO()
        self.stdout = contextlib.redirect_stdout(self.out)
        self.stderr = contextlib.redirect_stderr(self.err)
        self.stdout.__enter__()
        self.stderr.__enter__()
        self.fixture = WIRE.WireFixture(native=False)
        self.root = self.fixture.root
        self.model = None
        self.close_called = False

    def activate(self, **options):
        self.model = NativeCommandGuardProtocolModel(**options)
        self.fixture.native = True
        self.fixture.groups = self.model
        self.fixture.native_groups = object()
        return self.model

    def close_refuses(self):
        self.close_called = True
        with self.assertRaisesRegex(
            WIRE.FixtureFailure, "^Owned native fixture restoration refused$"
        ):
            self.fixture.close()
        self.assertFalse(self.fixture.closed)
        self.assertTrue(self.root.is_dir())

    def assert_owner_debt(self, owner):
        self.assertEqual(len(self.fixture.command_group_debt), 1)
        self.assertIs(self.fixture.command_group_debt[0], owner)
        self.assertEqual(owner.settle_calls, 1)

    def tearDown(self):
        before_outer = {
            "fixture_closed_before_outer_cleanup": self.fixture.closed,
            "root_exists_before_outer_cleanup": self.root.exists(),
            "child_live_before_outer_cleanup": []
            if self.model is None
            else [owner.process.poll() is None for owner in self.model.children],
            "retained_owner_count_before_outer_cleanup": len(
                getattr(self.fixture, "command_group_debt", ())
            ),
        }
        try:
            if not self.close_called and not self.fixture.closed:
                try:
                    self.fixture.close()
                except WIRE.FixtureFailure:
                    pass
            children = [] if self.model is None else self.model.children
            for owner in children:
                process = owner.process
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                if process.stdin is not None and not process.stdin.closed:
                    process.stdin.close()
                for capture in (process.output_capture, process.error_capture):
                    if not capture.closed:
                        capture.close()
            assert all(owner.process.returncode is not None for owner in children)
            # Outer private test owner removes only after exact real child reaps.
            # This does not pay the modeled native ACK debt or clear its record.
            if self.root.exists():
                self.fixture._retire_servers()
                shutil.rmtree(self.root)
            NATIVE_GUARD_CLEANUP.append(
                {
                    "test": self.id(),
                    **before_outer,
                    "actual_children": len(children),
                    "all_exact_outer_children_reaped": True,
                    "settle_calls": [owner.settle_calls for owner in children],
                }
            )
        finally:
            self.stderr.__exit__(None, None, None)
            self.stdout.__exit__(None, None, None)

    def test_unsettled_actual_child_retains_root_and_refuses_new_capture(self):
        model = self.activate(ack=False)
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.fixture._command(["EXPLICIT-MODELED-COMMAND"])
        self.assertIs(caught.exception, model.primary)
        owner = model.children[0]
        self.assertIsNone(owner.process.poll())
        self.assertEqual(self.fixture.command_file_debt, [])
        self.close_refuses()
        self.assertIsNone(owner.process.poll())
        self.assert_owner_debt(owner)
        with mock.patch.object(
            WIRE.tempfile,
            "TemporaryFile",
            side_effect=AssertionError("capture must not be acquired"),
        ):
            with self.assertRaisesRegex(
                WIRE.FixtureFailure, "^Native fixture child closure debt remains$"
            ):
                self.fixture._command(["SECOND-MUST-NOT-ACQUIRE"])
        self.assertEqual(len(model.arguments), 1)

    def test_partial_registration_failure_retains_exact_owner_and_primary(self):
        primary = RuntimeError("EXACT partial registration primary")
        model = self.activate(ack=False, partial=True, primary=primary)
        with self.assertRaises(RuntimeError) as caught:
            self.fixture._command(["EXPLICIT-PARTIAL-REGISTRATION"])
        self.assertIs(caught.exception, primary)
        self.assert_owner_debt(model.children[0])
        self.close_refuses()

    def test_refusal_before_registration_fabricates_no_owner_debt(self):
        primary = RuntimeError("EXACT acquisition refusal")
        model = self.activate(refuse=True, primary=primary)
        with self.assertRaises(RuntimeError) as caught:
            self.fixture._command(["EXPLICIT-ACQUISITION-REFUSAL"])
        self.assertIs(caught.exception, primary)
        self.assertEqual(model.children, [])
        self.assertEqual(getattr(self.fixture, "command_group_debt", []), [])
        self.fixture.close()
        self.assertTrue(self.fixture.closed)
        self.assertFalse(self.root.exists())

    def test_none_ack_refuses(self):
        model = self.activate(ack=None)
        with self.assertRaisesRegex(WIRE.FixtureFailure, "^Native fixture child closure refused$"):
            self.fixture._command(["EXPLICIT-UNKNOWN-NONE-ACK"])
        self.assert_owner_debt(model.children[0])
        self.close_refuses()

    def test_truthy_string_ack_refuses(self):
        model = self.activate(ack="unknown")
        with self.assertRaisesRegex(WIRE.FixtureFailure, "^Native fixture child closure refused$"):
            self.fixture._command(["EXPLICIT-UNKNOWN-STRING-ACK"])
        self.assert_owner_debt(model.children[0])
        self.close_refuses()

    def test_truthy_integer_ack_refuses(self):
        model = self.activate(ack=1)
        with self.assertRaisesRegex(WIRE.FixtureFailure, "^Native fixture child closure refused$"):
            self.fixture._command(["EXPLICIT-UNKNOWN-INTEGER-ACK"])
        self.assert_owner_debt(model.children[0])
        self.close_refuses()

    def test_settle_exception_preserves_original_wait_primary_and_owner(self):
        primary = RuntimeError("EXACT original wait primary")
        model = self.activate(ack=False, primary=primary)

        def refuse():
            owner.settle_calls += 1
            raise OSError("EXACT settlement refusal")

        original_acquire = model.acquire_owned

        def acquire(*args, **kwargs):
            nonlocal owner
            value = original_acquire(*args, **kwargs)
            owner = value
            owner.settle = refuse
            return value

        owner = None
        model.acquire_owned = acquire
        with self.assertRaises(RuntimeError) as caught:
            self.fixture._command(["EXPLICIT-WAIT-AND-SETTLE-REFUSAL"])
        self.assertIs(caught.exception, primary)
        self.assert_owner_debt(owner)
        self.close_refuses()

    def test_ordinary_success_strong_ack_leaves_no_group_debt(self):
        model = self.activate()
        self.assertEqual(
            self.fixture._command(["EXPLICIT-SUCCESS"], input_bytes=b"owned input"), (0, b"")
        )
        self.assertEqual(getattr(self.fixture, "command_group_debt", []), [])
        self.assertEqual(self.fixture.command_file_debt, [])
        self.assertEqual(model.children[0].settle_calls, 1)
        self.assertIsNotNone(model.children[0].process.returncode)
        self.fixture.close()
        self.assertTrue(self.fixture.closed)
        self.assertFalse(self.root.exists())

    def test_strong_child_ack_does_not_pay_distinct_capture_debt(self):
        model = self.activate(uncertain_capture=True)
        with self.assertRaisesRegex(OSError, "physical descriptor closed"):
            self.fixture._command(["EXPLICIT-CAPTURE-DEBT"])
        self.assertEqual(getattr(self.fixture, "command_group_debt", []), [])
        self.assertEqual(len(self.fixture.command_file_debt), 1)
        self.assertTrue(self.fixture.command_file_debt[0]["uncertain"])
        self.assertTrue(self.fixture.command_file_debt[0]["stream"].closed)
        self.assertEqual(model.children[0].settle_calls, 1)
        self.close_refuses()
        self.assertEqual(len(self.fixture.command_file_debt), 1)

    def registration_signal(self, sig):
        model = self.activate(ack=False)
        handlers = native_guard_actual_main_handlers()
        previous = signal.signal(sig, handlers[sig])
        fired = []
        source = Path(WIRE.__file__).resolve()
        lines = source.read_text().splitlines()

        def trace(frame, event, arg):
            if (
                event == "line"
                and frame.f_code.co_filename == str(source)
                and frame.f_code.co_name == "register"
                and lines[frame.f_lineno - 1].strip() == "self.command_group_debt.append(value)"
                and not fired
            ):
                fired.append(True)
                os.kill(os.getpid(), sig)
            return trace

        previous_trace = sys.gettrace()
        try:
            sys.settrace(trace)
            with self.assertRaisesRegex(WIRE.FixtureFailure, "^Native fixture cancelled$"):
                self.fixture._command(["EXPLICIT-REGISTRATION-SIGNAL"])
        finally:
            sys.settrace(previous_trace)
            signal.signal(sig, previous)
        self.assertEqual(fired, [True])
        self.assert_owner_debt(model.children[0])
        self.close_refuses()
        self.assertIsNone(model.children[0].process.poll())

    def test_real_sigint_before_registration_persistence_retains_owner(self):
        self.registration_signal(signal.SIGINT)

    def test_real_sigterm_before_registration_persistence_retains_owner(self):
        self.registration_signal(signal.SIGTERM)


# Fixed-path independent-builder portable enrollment. The exact selector refuses
# missing/extra controls; no native clock/factory role is activated by these tests.
NATIVE_FIXTURE_BUILD_CONTROLS = load(
    "native_http_fixture_builder_controls",
    ROOT / "tools/test/macos_native_http_fixture_builder_controls.py",
)
(
    NativeFixtureBuilderControls,
    NativeFixtureAliasDuringReadControls,
) = NATIVE_FIXTURE_BUILD_CONTROLS.enrolled_cases()


# Fixed-path caller root ownership receiving: original native test bodies remain
# unchanged; these software controls confer no native execution qualification.
NATIVE_CLIENT_ROOT_CONTROLS = load(
    "native_http_client_root_controls",
    ROOT / "tools/test/macos_native_http_client_root_controls.py",
)
(
    NativeClientRootReplacementControls,
    NativeClientRootCleanupControls,
) = NATIVE_CLIENT_ROOT_CONTROLS.enrolled_cases()


# Fixed-path clock frame/context enrollment. These portable13 controls do not
# execute the native TestCase or qualify Darwin samples, recipe or clock epoch.
NATIVE_FIXTURE_CLOCK_CONTROLS = load(
    "macos_native_http_clock_contract_controls",
    ROOT / "tools/test/macos_native_http_clock_contract_controls.py",
)
(
    NativeFixtureClockFrameContractControls,
    NativeFixtureClockContextContractControls,
) = NATIVE_FIXTURE_CLOCK_CONTROLS.enrolled_cases()


if __name__ == "__main__":
    unittest.main()

// Tests/ErgoptiPlusTests/ManagedHTTPWorkerTests.swift
// Literal request/protocol vectors and genuine native CFNetwork PAC execution.

import CFNetwork
import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

/// A genuine NSError reference cycle; no native networking or trust call runs.
private final class ManagedHTTPCyclicDiagnosticError: NSError, @unchecked Sendable {
	override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

final class ManagedHTTPWorkerTests: XCTestCase {
	private var request: [String: Any] {
		return ["version": 1, "url": "https://origin.example/path?case=one", "method": "GET",
			"headers": [["Accept-Encoding", "identity"]], "timeout": 30,
			"idle_timeout": 10, "direct": false]
	}

	func testExactURLAndOptionalAbsoluteBudgetRemainSeparateFromReadIdleTimeout() throws {
		let parsed = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: request)))
		XCTAssertEqual(parsed.url.absoluteString, "https://origin.example/path?case=one")
		XCTAssertEqual(parsed.timeout, 30)
		XCTAssertEqual(parsed.idleTimeout, 10)
		var unbounded = request
		unbounded["timeout"] = NSNull()
		let idleOnly = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: unbounded)))
		XCTAssertNil(idleOnly.timeout, "An existing read inactivity cap is never relabeled as a total model-transfer cap")
		XCTAssertEqual(idleOnly.idleTimeout, 10)
	}

	func testInvalidRequestsRefuseBeforeAnyNativeDispatch() throws {
		let vectors: [(String, Any)] = [
			("version", true), ("version", 1.5), ("url", "https://name:secret@origin.example/path"),
			("url", "file:///tmp/reserved"), ("url", "https://origin.example/path#fragment"),
			("method", "POST"), ("idle_timeout", true), ("idle_timeout", 0), ("timeout", -1),
			("direct", 1), ("headers", [["X-Test", "line\nbreak"]]),
			("headers", [["X-Test", "one"], ["x-test", "two"]]), ("headers", [["Bad(Name", "reserved"]])
		]
		for (key, value) in vectors {
			var invalid = request
			invalid[key] = value
			XCTAssertNil(ManagedHTTPRequest.parse(try JSONSerialization.data(withJSONObject: invalid)), "Refuse invalid \(key)")
		}
	}

	func testBinaryFrameLengthAndNULPayloadAreExact() throws {
		let bytes = Data([0, 10, 255])
		XCTAssertEqual(ManagedHTTPFrame.encode(tag: 68, bytes: bytes), Data([0, 0, 0, 4, 68, 0, 10, 255]))
		XCTAssertNil(ManagedHTTPFrame.encode(tag: 68, bytes: Data(repeating: 0, count: 65_536)))
		XCTAssertEqual(try XCTUnwrap(ManagedHTTPFrame.encode(tag: 68,
			bytes: Data(repeating: 0, count: 65_535))).count, 65_540)
	}

	func testNativeErrorsNeverReturnPrivateDiagnosticPayload() throws {
		let privateData = [NSURLErrorFailingURLErrorKey: URL(string: "https://reserved.example/private?token=reserved")!,
			NSLocalizedDescriptionKey: "reserved-secret-certificate-detail"] as [String: Any]
		XCTAssertEqual(managedHTTPFailure(NSError(domain: NSURLErrorDomain,
			code: NSURLErrorServerCertificateUntrusted, userInfo: privateData)), "certificate")
		XCTAssertEqual(managedHTTPFailure(NSError(domain: NSURLErrorDomain,
			code: NSURLErrorTimedOut, userInfo: privateData)), "deadline")
		XCTAssertEqual(managedHTTPFailure(NSError(domain: "foreign", code: 1, userInfo: privateData)), "unavailable")

		// The generic -1202 cannot distinguish an already reported nested TLS cause.
		for (status, expected) in [(errSSLHostNameMismatch, "hostname_mismatch"),
			(errSSLCertExpired, "certificate_expired"), (errSSLCertNotYetValid, "certificate_not_yet_valid"),
			(errSSLUnknownRootCert, "unknown_root"), (errSSLXCertChainInvalid, "certificate_chain_invalid")] {
			let inner = NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: privateData)
			var fields = privateData
			fields[NSUnderlyingErrorKey] = inner
			let outer = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: fields)
			XCTAssertEqual(managedHTTPFailure(outer), "certificate", "Diagnosis never changes the fail-closed reason")
			let observation = managedHTTPTLSDiagnostic(outer, additionalAnchorCount: 0)
			XCTAssertEqual(Set(observation.keys), Set(["version", "trust_mode", "additional_anchor_count", "causes", "chain_termination"]))
			XCTAssertEqual(observation["trust_mode"] as? String, "native_default")
			XCTAssertEqual(observation["additional_anchor_count"] as? Int, 0)
			XCTAssertEqual(observation["chain_termination"] as? String, "complete")
			let causes = try XCTUnwrap(observation["causes"] as? [[String: Any]])
			XCTAssertEqual(causes.count, 2)
			XCTAssertEqual(causes.first?["kind"] as? String, "certificate_untrusted")
			XCTAssertEqual(causes.last?["domain"] as? String, "security")
			XCTAssertEqual(causes.last?["code"] as? Int, Int(status))
			XCTAssertEqual(causes.last?["kind"] as? String, expected)
			for cause in causes { XCTAssertEqual(Set(cause.keys), Set(["domain", "code", "kind"])) }
			let bytes = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
			let rendered = String(decoding: bytes, as: UTF8.self)
			XCTAssertLessThan(bytes.count, 4096)
			XCTAssertFalse(rendered.contains("reserved"))
			XCTAssertFalse(rendered.contains("https://"))
			XCTAssertFalse(rendered.contains(NSLocalizedDescriptionKey))
		}
		let cfNetwork = managedHTTPTLSDiagnostic(NSError(domain: kCFErrorDomainCFNetwork as String,
			code: NSURLErrorServerCertificateUntrusted, userInfo: privateData), additionalAnchorCount: 0)
		let cfCause = try XCTUnwrap((cfNetwork["causes"] as? [[String: Any]])?.first)
		XCTAssertEqual(cfCause["domain"] as? String, "cfnetwork")
		XCTAssertEqual(cfCause["code"] as? Int, NSURLErrorServerCertificateUntrusted)
		XCTAssertEqual(cfCause["kind"] as? String, "unknown")
		XCTAssertEqual(cfNetwork["chain_termination"] as? String, "complete")
		let foreign = managedHTTPTLSDiagnostic(NSError(domain: "reserved-private-domain", code: 123456,
			userInfo: privateData), additionalAnchorCount: 2)
		XCTAssertEqual(foreign["trust_mode"] as? String, "added_anchors")
		XCTAssertEqual(foreign["additional_anchor_count"] as? Int, 2)
		let unknown = try XCTUnwrap((foreign["causes"] as? [[String: Any]])?.first)
		XCTAssertEqual(unknown["domain"] as? String, "other")
		XCTAssertTrue(unknown["code"] is NSNull)
		XCTAssertEqual(unknown["kind"] as? String, "unknown")
		let invalidCode = managedHTTPTLSDiagnostic(NSError(domain: NSOSStatusErrorDomain, code: Int.max, userInfo: nil), additionalAnchorCount: 0)
		let invalidCause = try XCTUnwrap((invalidCode["causes"] as? [[String: Any]])?.first)
		XCTAssertTrue(invalidCause["code"] is NSNull)
		XCTAssertEqual(invalidCause["kind"] as? String, "unknown")
		let malformed = managedHTTPTLSDiagnostic(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
			userInfo: [NSUnderlyingErrorKey: "reserved-private-underlying"]), additionalAnchorCount: 0)
		XCTAssertEqual(malformed["chain_termination"] as? String, "unavailable")
		let cycle = managedHTTPTLSDiagnostic(ManagedHTTPCyclicDiagnosticError(domain: NSURLErrorDomain,
			code: NSURLErrorServerCertificateUntrusted, userInfo: nil), additionalAnchorCount: 0)
		XCTAssertEqual(cycle["chain_termination"] as? String, "cycle")
		XCTAssertEqual((cycle["causes"] as? [[String: Any]])?.count, 1)
		var deep = NSError(domain: NSOSStatusErrorDomain, code: Int(errSSLHostNameMismatch), userInfo: nil)
		for _ in 0..<12 {
			deep = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
				userInfo: [NSUnderlyingErrorKey: deep])
		}
		let bounded = managedHTTPTLSDiagnostic(deep, additionalAnchorCount: 0)
		XCTAssertEqual(bounded["chain_termination"] as? String, "depth")
		XCTAssertEqual((bounded["causes"] as? [[String: Any]])?.count, 8)
		for observation in [cfNetwork, foreign, invalidCode, malformed, cycle, bounded] {
			XCTAssertEqual(Set(observation.keys), Set(["version", "trust_mode", "additional_anchor_count", "causes", "chain_termination"]))
			let bytes = try JSONSerialization.data(withJSONObject: observation)
			XCTAssertLessThan(bytes.count, 4096)
			XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("reserved"))
		}
	}

	func testActualCFNetworkPACReceivesDistinctHTTPSPathsAndQueries() throws {
		let script = """
		function FindProxyForURL(url, host) {
			if (url == "https://same.example/a?case=one") return "PROXY first.example:3111; DIRECT";
			if (url == "https://same.example/b?case=two") return "PROXY second.example:3222; PROXY third.example:3333";
			return "PROXY wrong.example:3999";
		}
		"""
		let first = try XCTUnwrap(ManagedProxyLookup.evaluate(
			url: URL(string: "https://same.example/a?case=one")!, pacURL: nil, script: script,
			deadline: ProcessInfo.processInfo.systemUptime + 20))
		let second = try XCTUnwrap(ManagedProxyLookup.evaluate(
			url: URL(string: "https://same.example/b?case=two")!, pacURL: nil, script: script,
			deadline: ProcessInfo.processInfo.systemUptime + 20))
		XCTAssertEqual(first.count, 2)
		guard first.count == 2 else { return }
		XCTAssertEqual(first[0][kCFProxyHostNameKey as String] as? String, "first.example")
		XCTAssertEqual(first[1][kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
		XCTAssertEqual(second.count, 2)
		guard second.count == 2 else { return }
		XCTAssertEqual(second[0][kCFProxyHostNameKey as String] as? String, "second.example")
		XCTAssertEqual(second[1][kCFProxyHostNameKey as String] as? String, "third.example")
	}

	func testActualCFNetworkPACPreservesHTTPPathAndOrderedNativeChoices() throws {
		let script = """
		function FindProxyForURL(url, host) {
			if (url == "http://same.example/a?case=three") return "PROXY first.example:3111; PROXY second.example:3222; DIRECT";
			return "PROXY wrong.example:3999";
		}
		"""
		let result = try XCTUnwrap(ManagedProxyLookup.evaluate(
			url: URL(string: "http://same.example/a?case=three")!, pacURL: nil, script: script,
			deadline: ProcessInfo.processInfo.systemUptime + 20))
		XCTAssertEqual(result.count, 3)
		guard result.count == 3 else { return }
		XCTAssertEqual(result[0][kCFProxyHostNameKey as String] as? String, "first.example")
		XCTAssertEqual(result[1][kCFProxyHostNameKey as String] as? String, "second.example")
		XCTAssertEqual(result[2][kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
		XCTAssertNotNil(ManagedProxyLookup.dictionary(route: result[0]))
		XCTAssertNotNil(ManagedProxyLookup.dictionary(route: result[1]))
		let direct = try XCTUnwrap(ManagedProxyLookup.dictionary(route: result[2]))
		for key in [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesSOCKSEnable,
			kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
			XCTAssertEqual(direct[key as String] as? Int, 0, "DIRECT disables all inherited system selectors")
		}
	}
	func testWPADMetadataUsesDHCPOwnerOrNativeResolverWithoutSuffixConstruction() throws {
		XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: nil,
			searchDomains: ["Engineering.Corp.Example.", "corp.example", "corp.example", "com", "invalid/domain", "-bad.example"])?.map(\.absoluteString), ["http://wpad/wpad.dat"])
		XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: Data("https://pac.corp.example/profile.pac".utf8),
			searchDomains: ["corp.example"])?.map(\.absoluteString), ["https://pac.corp.example/profile.pac"])
		for invalid in ["https://name:reserved@pac.corp.example/a", "file:///reserved", "https://pac.corp.example/a#fragment", "http://pac.corp.example/\n"] {
			XCTAssertNil(ManagedProxyLookup.discoveryURLs(dhcpOption: Data(invalid.utf8), searchDomains: ["corp.example"]))
		}
	}

	func testWPADNativeDNSAdmissionIncludesSingleLabelCompanyDomains() {
		for domain in ["corp", "CORP.", "engineering.corp.example", "com"] {
			XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: nil,
				searchDomains: [domain])?.map(\.absoluteString), ["http://wpad/wpad.dat"],
				"Configured domains admit the native resolver without guessing suffix ownership")
		}
		for domains in [[], [""], ["."], ["invalid/domain"], ["-bad.example"], ["bad..example"],
			[String(repeating: "x", count: 64)], ["corp\n"], ["corp example"]] {
			XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: nil,
				searchDomains: domains)?.map(\.absoluteString), [], "Absent/invalid DNS metadata refuses before lookup")
		}
	}

	func testWPADUnresolvedNativeStateNeverFallsBackToInitialDirectOrFixedProxy() throws {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1,
			kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "fixed.example",
			kCFNetworkProxiesHTTPSPort as String: 3111]
		for metadata in [ManagedWPADMetadata(dhcpOption: nil, searchDomains: []),
			ManagedWPADMetadata(dhcpOption: Data("https://reserved:credential@pac.example/a".utf8), searchDomains: ["corp"])] {
			var metadataReads = 0
			let selected = ManagedProxyLookup.routes(url: URL(string: "https://origin.example/private?case=one")!,
				budget: 20, maximumSelections: 16, settingsProvider: { settings as CFDictionary },
				discoveryMetadataProvider: { metadataReads += 1; return metadata })
			XCTAssertEqual(metadataReads, 1, "Unresolved autodiscovery joins the native metadata provider exactly once")
			XCTAssertNil(selected, "Invalid/absent discovery cannot silently select DIRECT or a fixed proxy")
		}
	}

	func testResolvedNativePACOwnsDiscoveryWithoutReadingForeignMetadata() throws {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111; DIRECT'; }"]
		var metadataReads = 0
		let selected = try XCTUnwrap(ManagedProxyLookup.routes(url: URL(string: "https://origin.example/private?case=two")!,
			budget: 20, maximumSelections: 16, settingsProvider: { settings as CFDictionary },
			discoveryMetadataProvider: { metadataReads += 1; return ManagedWPADMetadata(dhcpOption: nil, searchDomains: []) }))
		XCTAssertEqual(metadataReads, 0, "An already-resolved native PAC candidate owns this request")
		XCTAssertEqual(selected.count, 2)
		XCTAssertEqual(selected[0][kCFProxyHostNameKey as String] as? String, "selected.example")
		XCTAssertEqual(selected[1][kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)

		// Only an explicit DIRECT in the PAC result may admit a direct route.
		var withoutDirect = settings
		withoutDirect[kCFNetworkProxiesProxyAutoConfigJavaScript as String] =
			"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111'; }"
		let proxyOnly = try XCTUnwrap(ManagedProxyLookup.routes(url: URL(string: "https://origin.example/private?case=three")!,
			budget: 20, maximumSelections: 16, settingsProvider: { withoutDirect as CFDictionary },
			discoveryMetadataProvider: { metadataReads += 1; return ManagedWPADMetadata(dhcpOption: nil, searchDomains: []) }))
		XCTAssertEqual(metadataReads, 0)
		XCTAssertEqual(proxyOnly.count, 1)
		guard proxyOnly.count == 1 else { return }
		XCTAssertEqual(proxyOnly[0][kCFProxyHostNameKey as String] as? String, "selected.example")
		XCTAssertFalse(proxyOnly.contains { $0[kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String })

		// Preserve repeated native PAC choices; removing duplicates is not ownership.
		var repeatedChoices = settings
		repeatedChoices[kCFNetworkProxiesProxyAutoConfigJavaScript as String] =
			"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111; PROXY selected.example:3111; DIRECT'; }"
		let repeated = try XCTUnwrap(ManagedProxyLookup.routes(url: URL(string: "https://origin.example/private?case=four")!,
			budget: 20, maximumSelections: 16, settingsProvider: { repeatedChoices as CFDictionary },
			discoveryMetadataProvider: { metadataReads += 1; return ManagedWPADMetadata(dhcpOption: nil, searchDomains: []) }))
		XCTAssertEqual(metadataReads, 0)
		XCTAssertEqual(repeated.count, 3)
		guard repeated.count == 3 else { return }
		XCTAssertEqual(repeated[0][kCFProxyHostNameKey as String] as? String, "selected.example")
		XCTAssertEqual(repeated[1][kCFProxyHostNameKey as String] as? String, "selected.example")
		XCTAssertEqual(repeated[2][kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
	}


	func testActualCFNetworkHTTPPACArgumentShapeObservation() throws {
		try observePACArgumentShape(scheme: "http")
	}

	func testActualCFNetworkHTTPSPACArgumentShapeObservation() throws {
		try observePACArgumentShape(scheme: "https")
	}

	// Fixed authored values only. The returned proxy is never dispatched.
	// This observation cannot replace the original full-URL assertions above.
	private func observePACArgumentShape(scheme: String) throws {
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		XCTAssertTrue(scheme == "http" || scheme == "https")
		guard scheme == "http" || scheme == "https" else { return }
		let origin = "\(scheme)://same.example:4455"
		let full = origin + "/a?case=shape"
		let url = try XCTUnwrap(URL(string: full))
		let forms = try JSONSerialization.data(withJSONObject: [full, origin + "/", origin])
		let literals = try XCTUnwrap(String(data: forms, encoding: .utf8))
		let script = """
		function FindProxyForURL(url, host) {
			var forms = \(literals);
			var u = 7;
			if (typeof url === "undefined") u = 5;
			else if (typeof url !== "string") u = 6;
			else if (url === forms[0]) u = 0;
			else if (url === forms[1]) u = 1;
			else if (url === forms[2]) u = 2;
			else if (url === "same.example") u = 3;
			else if (url === "/a?case=shape") u = 4;
			var h = 5;
			if (typeof host === "undefined") h = 3;
			else if (typeof host !== "string") h = 4;
			else if (host === "same.example") h = 0;
			else if (host === forms[0]) h = 1;
			else if (host === "same.example:4455") h = 2;
			return "PROXY pac-shape.invalid:" + (20000 + 10 * u + h);
		}
		"""
		let routes = try XCTUnwrap(ManagedProxyLookup.evaluateNative(url: url,
			pacURL: nil, script: script, deadline: deadline))
		XCTAssertEqual(routes.count, 1)
		guard routes.count == 1 else { return }
		let route = routes[0]
		let nativeKind = route[kCFProxyTypeKey as String] as? String
		let proxyType: String? = nativeKind == kCFProxyTypeHTTP as String ? "http"
			: nativeKind == kCFProxyTypeHTTPS as String ? "https" : nil
		XCTAssertNotNil(proxyType)
		guard let proxyType else { return }
		XCTAssertTrue(route[kCFProxyHostNameKey as String] as? String == "pac-shape.invalid")
		guard route[kCFProxyHostNameKey as String] as? String == "pac-shape.invalid" else { return }
		let number = try XCTUnwrap(route[kCFProxyPortNumberKey as String] as? NSNumber)
		let integral = CFGetTypeID(number) != CFBooleanGetTypeID()
			&& number.doubleValue == Double(number.intValue)
		XCTAssertTrue(integral)
		guard integral else { return }
		let code = number.intValue
		let inRange = (20000...20075).contains(code)
		XCTAssertTrue(inRange)
		guard inRange else { return }
		let urlShape = (code - 20000) / 10
		let hostShape = (code - 20000) % 10
		let recognized = (0...7).contains(urlShape) && (0...5).contains(hostShape)
		XCTAssertTrue(recognized)
		guard recognized else { return }
		print("PAC_ARGUMENT_SHAPE purpose=\(scheme) type=\(proxyType) port=\(code)")
	}
}

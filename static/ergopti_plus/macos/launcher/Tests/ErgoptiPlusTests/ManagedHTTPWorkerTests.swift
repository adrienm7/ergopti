// Tests/ErgoptiPlusTests/ManagedHTTPWorkerTests.swift
// Literal request/protocol vectors and genuine native CFNetwork PAC execution.

import CFNetwork
import Foundation
import XCTest
@testable import ErgoptiPlus

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

	func testNativeErrorsNeverReturnPrivateDiagnosticPayload() {
		let privateData = [NSURLErrorFailingURLErrorKey: URL(string: "https://reserved.example/private?token=reserved")!,
			NSLocalizedDescriptionKey: "reserved-secret-certificate-detail"] as [String: Any]
		XCTAssertEqual(managedHTTPFailure(NSError(domain: NSURLErrorDomain,
			code: NSURLErrorServerCertificateUntrusted, userInfo: privateData)), "certificate")
		XCTAssertEqual(managedHTTPFailure(NSError(domain: NSURLErrorDomain,
			code: NSURLErrorTimedOut, userInfo: privateData)), "deadline")
		XCTAssertEqual(managedHTTPFailure(NSError(domain: "foreign", code: 1, userInfo: privateData)), "unavailable")
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
		XCTAssertEqual(first[0][kCFProxyHostNameKey as String] as? String, "first.example")
		XCTAssertEqual(first[1][kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
		XCTAssertEqual(second.count, 2)
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
	func testWPADMetadataUsesDHCPOwnerOrConfiguredDNSWithoutSuffixDevolution() throws {
		XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: nil,
			searchDomains: ["Engineering.Corp.Example.", "corp.example", "corp.example", "com", "invalid/domain", "-bad.example"])
			?.map(\.absoluteString), ["http://wpad.engineering.corp.example/wpad.dat", "http://wpad.corp.example/wpad.dat"])
		XCTAssertEqual(ManagedProxyLookup.discoveryURLs(dhcpOption: Data("https://pac.corp.example/profile.pac".utf8),
			searchDomains: ["corp.example"])?.map(\.absoluteString), ["https://pac.corp.example/profile.pac"])
		for invalid in ["https://name:reserved@pac.corp.example/a", "file:///reserved", "https://pac.corp.example/a#fragment", "http://pac.corp.example/\n"] {
			XCTAssertNil(ManagedProxyLookup.discoveryURLs(dhcpOption: Data(invalid.utf8), searchDomains: ["corp.example"]))
		}
	}

}

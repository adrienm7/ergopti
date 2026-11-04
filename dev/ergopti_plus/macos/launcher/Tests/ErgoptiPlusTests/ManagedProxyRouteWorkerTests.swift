// Tests/ErgoptiPlusTests/ManagedProxyRouteWorkerTests.swift
// The proxy-route role turns a system lookup into one exportable line or a stage code.

import Foundation
import CFNetwork
import XCTest
@testable import ErgoptiPlus

final class ManagedProxyRouteWorkerTests: XCTestCase {
	private let registry = "https://registry.example/"

	private func route(_ kind: CFString, host: String? = nil, port: Int? = nil) -> [String: Any] {
		var value: [String: Any] = [kCFProxyTypeKey as String: kind as String]
		if let host { value[kCFProxyHostNameKey as String] = host }
		if let port { value[kCFProxyPortNumberKey as String] = NSNumber(value: port) }
		return value
	}

	func testHandlesOnlyItsFlag() {
		XCTAssertTrue(ManagedProxyRouteWorker.handles(arguments: ["ErgoptiPlus", "--managed-proxy-route", registry, "8"]))
		XCTAssertFalse(ManagedProxyRouteWorker.handles(arguments: ["ErgoptiPlus", "--managed-http-worker"]))
	}

	func testDirectRouteIsExportedAsDirect() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeNone)), "direct")
	}

	func testHttpAndHttpsProxiesBecomeAnHttpProxyUrl() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "proxy.corp.example", port: 3128)),
			"http://proxy.corp.example:3128")
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTPS, host: "proxy.corp.example", port: 8080)),
			"http://proxy.corp.example:8080")
	}

	func testSocksProxyBecomesSocks5AndIPv6IsBracketed() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeSOCKS, host: "10.0.0.2", port: 1080)),
			"socks5://10.0.0.2:1080")
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "fd00::1", port: 3128)),
			"http://[fd00::1]:3128")
	}

	func testHostThatCouldSmuggleAnotherUrlIsRefused() {
		for host in ["a@b.example", "a/b.example", "a b.example", "a.example?x", "", "h\u{0}"] {
			XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: host, port: 3128)), host)
		}
	}

	func testPortOutsideTheRangeOrMissingIsRefused() {
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example", port: 0)))
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example", port: 70000)))
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example")))
	}

	func testUnknownRouteKindIsRefused() {
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeFTP, host: "p.example", port: 21)))
	}

	func testOriginMustBeAnHttpsUrlWithoutCredentials() {
		XCTAssertNotNil(ManagedProxyRouteWorker.origin(registry))
		XCTAssertNil(ManagedProxyRouteWorker.origin("http://registry.example/"))
		XCTAssertNil(ManagedProxyRouteWorker.origin("https://user:pw@registry.example/"))
		XCTAssertNil(ManagedProxyRouteWorker.origin("https://registry.example/ x"))
	}

	func testArgumentsOutsideTheContractAreAUsageError() {
		let settings: () -> CFDictionary? = { nil }
		for arguments in [["x", "--managed-proxy-route"], ["x", "--managed-proxy-route", registry],
			["x", "--managed-proxy-route", registry, "0"], ["x", "--managed-proxy-route", registry, "121"],
			["x", "--managed-proxy-route", registry, "nan"], ["x", "--managed-proxy-route", "http://a.example/", "8"]] {
			XCTAssertEqual(ManagedProxyRouteWorker.run(arguments: arguments, settingsProvider: settings),
				ManagedProxyRouteWorker.usageExit, arguments.joined(separator: " "))
		}
	}

	func testUnreadableSettingsExitWithTheLookupStage() {
		XCTAssertEqual(ManagedProxyRouteWorker.run(arguments: ["x", "--managed-proxy-route", registry, "8"],
			settingsProvider: { nil }), ManagedProxyRouteWorker.unusableExit)
		let failed = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 8,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { nil })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(failed).stage, "native_proxy_lookup")
	}

	func testAStaticPacScriptSelectsTheFirstRoute() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111; DIRECT'; }"]
		let result = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 20,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { settings as CFDictionary })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(result).route, "http://selected.example:3111")
	}

	func testAPacThatSaysDirectIsExportedAsDirect() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'DIRECT'; }"]
		let result = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 20,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { settings as CFDictionary })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(result).route, "direct")
	}

	func testNoStageCodeCarriesAnAddress() {
		for stage in ManagedHTTPFailureStage.allCases {
			XCTAssertTrue(stage.rawValue.hasPrefix("native_"))
			XCTAssertFalse(stage.rawValue.contains("://"))
		}
	}
}

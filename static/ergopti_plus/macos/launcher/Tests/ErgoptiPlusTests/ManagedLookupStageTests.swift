// Tests/ErgoptiPlusTests/ManagedLookupStageTests.swift
// A lookup that names no route says which step gave up, with a closed stage code only.

import Foundation
import CFNetwork
import XCTest
@testable import ErgoptiPlus

final class ManagedLookupStageTests: XCTestCase {
	private let origin = URL(string: "https://origin.example/private?case=stage")!

	private func stage(of result: Result<[[String: Any]], ManagedLookupFailure>) -> ManagedHTTPFailureStage? {
		if case .failure(let failure) = result { return failure.stage }
		return nil
	}

	func testInvalidBudgetNamesTheBudgetStage() {
		let result = ManagedProxyLookup.resolve(url: origin, budget: 0, maximumSelections: 16, settingsProvider: { nil })
		XCTAssertEqual(stage(of: result), .proxyBudget)
	}

	func testUnavailableSystemSettingsNameTheSettingsStage() {
		let result = ManagedProxyLookup.resolve(url: origin, budget: 20, maximumSelections: 16, settingsProvider: { nil })
		XCTAssertEqual(stage(of: result), .proxyLookup)
	}

	func testUnresolvedAutodiscoveryNamesTheDiscoveryStage() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1]
		let result = ManagedProxyLookup.resolve(url: origin, budget: 20, maximumSelections: 16,
			settingsProvider: { settings as CFDictionary },
			discoveryMetadataProvider: { ManagedWPADMetadata(dhcpOption: nil, searchDomains: []) })
		XCTAssertEqual(stage(of: result), .wpadDiscovery)
	}

	func testMoreRoutesThanTheBoundNameTheRoutesStage() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111; DIRECT'; }"]
		let result = ManagedProxyLookup.resolve(url: origin, budget: 20, maximumSelections: 1,
			settingsProvider: { settings as CFDictionary })
		XCTAssertEqual(stage(of: result), .proxyRoutes)
	}

	func testEveryLookupStageIsAnUnavailableRefusalWithoutAnAddress() {
		let stages: [ManagedHTTPFailureStage] = [.proxyLookup, .proxyBudget, .proxyCandidates, .pacDownload,
			.pacEvaluation, .proxyRoutes, .wpadDiscovery]
		for stage in stages {
			XCTAssertTrue(stage.permits(reason: "unavailable"))
			XCTAssertFalse(stage.permits(reason: "certificate"))
			XCTAssertTrue(stage.rawValue.hasPrefix("native_"))
			XCTAssertFalse(stage.rawValue.contains("://"))
		}
	}

	func testRefusalWithoutFallbackCarriesTheFailingStep() throws {
		let body: [String: Any] = ["version": 1, "url": "https://127.0.0.1:1/unreachable", "method": "GET",
			"headers": [["Accept-Encoding", "identity"]], "timeout": 30, "idle_timeout": 10, "direct": false]
		let parsed = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: body)))
		var wire = Data()
		_ = ManagedHTTPWorker.execute(parsed, maximumSelections: 1, settingsProvider: { nil }, environment: [:],
			directFallback: false, output: { wire.append($0); return true })
		let text = String(decoding: wire, as: UTF8.self)
		XCTAssertTrue(text.contains("native_proxy_lookup"))
		XCTAssertFalse(text.contains("127.0.0.1"))
	}
}

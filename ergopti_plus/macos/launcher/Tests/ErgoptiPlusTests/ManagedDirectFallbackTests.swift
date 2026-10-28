// Tests/ErgoptiPlusTests/ManagedDirectFallbackTests.swift
// A proxy lookup that names no route goes direct instead of refusing the download.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class ManagedDirectFallbackTests: XCTestCase {
	/// An unusable PAC lookup goes direct instead of refusing the whole download (issue #101).
	func testUnusableProxyLookupFallsBackToDirectRoute() throws {
		let body: [String: Any] = ["version": 1, "url": "https://127.0.0.1:1/unreachable", "method": "GET",
			"headers": [["Accept-Encoding", "identity"]], "timeout": 30, "idle_timeout": 10, "direct": false]
		let parsed = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: body)))
		var wire = Data()
		_ = ManagedHTTPWorker.execute(parsed, maximumSelections: 1, settingsProvider: { nil }, environment: [:],
			output: { wire.append($0); return true })
		XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("native_proxy_lookup"),
			"a lookup that names no route must reach the direct dispatch, not refuse at the lookup")
	}
}

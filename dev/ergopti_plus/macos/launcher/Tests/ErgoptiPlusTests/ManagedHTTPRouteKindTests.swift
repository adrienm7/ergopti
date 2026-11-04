// Tests/ErgoptiPlusTests/ManagedHTTPRouteKindTests.swift
// The worker names the kind of the route it dispatched on (ledger L42).

import CFNetwork
import Foundation
import XCTest
@testable import ErgoptiPlus

final class ManagedHTTPRouteKindTests: XCTestCase {
	func testNamesEverySelectedRouteKindByAClosedToken() {
		XCTAssertEqual(managedHTTPRouteKind([kCFProxyTypeKey as String: kCFProxyTypeNone as String]), "direct")
		XCTAssertEqual(managedHTTPRouteKind([kCFProxyTypeKey as String: kCFProxyTypeHTTP as String]), "http")
		XCTAssertEqual(managedHTTPRouteKind([kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String]), "https")
		XCTAssertEqual(managedHTTPRouteKind([kCFProxyTypeKey as String: kCFProxyTypeSOCKS as String]), "socks")
	}

	func testNeverEchoesAnUnknownKindOrTheRelay() {
		let route: [String: Any] = [kCFProxyTypeKey as String: "relay.example.invalid",
			kCFProxyHostNameKey as String: "relay.example.invalid"]
		XCTAssertEqual(managedHTTPRouteKind(route), "other")
		XCTAssertEqual(managedHTTPRouteKind([:]), "other")
	}
}

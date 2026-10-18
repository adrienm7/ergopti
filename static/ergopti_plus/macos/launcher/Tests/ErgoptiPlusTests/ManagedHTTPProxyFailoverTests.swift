// Tests/ErgoptiPlusTests/ManagedHTTPProxyFailoverTests.swift
// Native proxy connection failures admit the next PAC choice; proxy replies do not.

import CFNetwork
import Foundation
import XCTest
@testable import ErgoptiPlus

final class ManagedHTTPProxyFailoverTests: XCTestCase {
	private func cfNetwork(_ code: CFNetworkErrors) -> NSError {
		// The exact shape macOS 15 delivered for a refused proxy: no URL wrapper.
		return NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(code.rawValue),
			userInfo: ["_kCFStreamErrorDomainKey": 4, "_kCFStreamErrorCodeKey": -2096])
	}

	func testBareProxyConnectionFailureIsAConnectFailure() {
		// Before the repair this mapped to "unavailable" and the ordered PAC
		// fallback never reached its second relay.
		for code in [CFNetworkErrors.cfErrorHTTPSProxyConnectionFailure, .cfErrorHTTPProxyConnectionFailure] {
			let refused = cfNetwork(code)
			XCTAssertTrue(managedHTTPProxyConnectionFailed(refused))
			XCTAssertEqual(managedHTTPFailure(refused), "connect")
		}
	}

	func testProxyRepliesAndOtherCFNetworkFailuresNeverAdmitFailover() {
		for code in [CFNetworkErrors.cfStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod,
			.cfErrorHTTPBadProxyCredentials, .cfErrorHTTPConnectionLost] {
			let error = cfNetwork(code)
			XCTAssertFalse(managedHTTPProxyConnectionFailed(error))
			XCTAssertEqual(managedHTTPFailure(error), "unavailable")
		}
		let foreign = NSError(domain: NSPOSIXErrorDomain,
			code: Int(CFNetworkErrors.cfErrorHTTPSProxyConnectionFailure.rawValue))
		XCTAssertFalse(managedHTTPProxyConnectionFailed(foreign))
		XCTAssertEqual(managedHTTPFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)), "connect")
	}
}

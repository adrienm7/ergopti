// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HomebrewAutomationConsentTests.swift
//
// Explicit opt-in controls stay included when real native Brew qualification is deferred.

import Foundation
import XCTest

enum HomebrewAutomationConsent {
	private enum ConsentError: Error {
		case refused(Int32, String)
	}

	/// Keep normal OS permission requests explicit for each native fixture invocation.
	static func arguments(_ environment: [String: String]) throws -> [String] {
		func enabled(_ name: String) throws -> Bool {
			guard let value = environment[name] else { return false }
			guard value == "0" || value == "1" else {
				throw ConsentError.refused(-1, "Malformed owned Automation consent opt-in")
			}
			return value == "1"
		}
		let request = try enabled("ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT")
		let approve = try enabled("ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI")
		guard !approve || request else {
			throw ConsentError.refused(-1, "Owned consent UI requires an explicit permission request")
		}
		return (request ? ["--allow-automation-consent"] : [])
			+ (approve ? ["--allow-owned-consent-ui"] : [])
	}
}

final class HomebrewAutomationConsentTests: XCTestCase {
	/// Keep normal OS permission requests explicit for each native fixture invocation.
	private static func consentArguments(_ environment: [String: String]) throws -> [String] {
		return try HomebrewAutomationConsent.arguments(environment)
	}

	func testAutomationConsentArgumentsRequireBothExplicitOptIns() throws {
		XCTAssertEqual(try Self.consentArguments([:]), [])
		XCTAssertEqual(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "0"]), [])
		XCTAssertEqual(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1"]),
			["--allow-automation-consent"])
		XCTAssertEqual(try Self.consentArguments([
			"ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1", "ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": "1"
		]), ["--allow-automation-consent", "--allow-owned-consent-ui"])
		XCTAssertThrowsError(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": "1"]))
		for invalid in ["true", "1\n", "", "2"] {
			XCTAssertThrowsError(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": invalid]))
			XCTAssertThrowsError(try Self.consentArguments([
				"ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1", "ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": invalid
			]))
		}
	}
}

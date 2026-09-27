// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/UpdateConsentPolicyTests.swift

import XCTest
@testable import ErgoptiPlus

@MainActor
final class UpdateConsentPolicyTests: XCTestCase {
	private final class SettingsStub: AutomaticUpdateSettings {
		let allowsAutomaticUpdates: Bool
		let automaticallyDownloadsUpdates: Bool

		init(allows: Bool, downloads: Bool) {
			allowsAutomaticUpdates = allows
			automaticallyDownloadsUpdates = downloads
		}
	}

	func testStartsOnlyWhenEveryDownloadWaitsForConsent() {
		XCTAssertNil(UpdateConsentPolicy.refusal(for: SettingsStub(allows: false, downloads: false)))
	}

	func testRefusesWhenTheBundleAllowsAutomaticUpdates() {
		XCTAssertNotNil(UpdateConsentPolicy.refusal(for: SettingsStub(allows: true, downloads: false)),
			"SUAllowsAutomaticUpdates lets Sparkle's alert enable silent downloads")
	}

	func testRefusesWhenAutomaticDownloadsAreOn() {
		XCTAssertNotNil(UpdateConsentPolicy.refusal(for: SettingsStub(allows: false, downloads: true)),
			"automatic downloads fetch and stage an update before any consent")
	}
}

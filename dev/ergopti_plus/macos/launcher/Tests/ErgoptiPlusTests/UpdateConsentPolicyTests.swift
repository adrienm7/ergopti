// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/UpdateConsentPolicyTests.swift

import XCTest
@testable import ErgoptiPlus

@MainActor
final class UpdateConsentPolicyTests: XCTestCase {
	private final class SettingsStub: AutomaticUpdateSettings {
		let allowsAutomaticUpdates: Bool
		let automaticallyDownloadsUpdates: Bool
		let automaticallyChecksForUpdates: Bool

		init(allows: Bool, downloads: Bool, checks: Bool = false) {
			allowsAutomaticUpdates = allows
			automaticallyDownloadsUpdates = downloads
			automaticallyChecksForUpdates = checks
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

	func testRefusesASecondAutomaticCheckOwner() {
		XCTAssertNotNil(UpdateConsentPolicy.refusal(for: SettingsStub(allows: false, downloads: false, checks: true)),
			"a stored Sparkle default must not re-enable a scheduler that ignores Lua's pause and interval")
	}
}

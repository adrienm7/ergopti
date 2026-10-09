// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/UpdateChannelFeedTests.swift

import Foundation
import XCTest
@testable import ErgoptiPlus

final class UpdateChannelFeedTests: XCTestCase {
	private let bundleFeed = "https://raw.githubusercontent.com/owner/repo/sparkle-appcasts/appcast-main.xml"
	private var suiteName = ""
	private var defaults: UserDefaults!

	override func setUpWithError() throws {
		suiteName = "UpdateChannelFeedTests." + UUID().uuidString
		defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
	}

	override func tearDown() {
		defaults.removePersistentDomain(forName: suiteName)
		super.tearDown()
	}

	private func feed() -> UpdateChannelFeed {
		return UpdateChannelFeed(
			defaults: defaults,
			bundleFeedURL: bundleFeed,
			feeds: ["main": "appcast-main.xml", "dev": "appcast-dev.xml"]
		)
	}

	func testWithoutSelectionTheBundleFeedIsKept() {
		XCTAssertNil(feed().selectedFeedURLString())
	}

	func testSelectedChannelReadsItsAppcastBesideTheBundleFeed() {
		let subject = feed()
		subject.selectChannel("dev")
		XCTAssertEqual(
			subject.selectedFeedURLString(),
			"https://raw.githubusercontent.com/owner/repo/sparkle-appcasts/appcast-dev.xml"
		)
	}

	func testSelectionSurvivesANewFeedObject() {
		feed().selectChannel("dev")
		XCTAssertEqual(
			feed().selectedFeedURLString(),
			"https://raw.githubusercontent.com/owner/repo/sparkle-appcasts/appcast-dev.xml"
		)
	}

	func testUnknownChannelIsIgnored() {
		let subject = feed()
		subject.selectChannel("main")
		subject.selectChannel("beta")
		XCTAssertEqual(
			subject.selectedFeedURLString(),
			"https://raw.githubusercontent.com/owner/repo/sparkle-appcasts/appcast-main.xml"
		)
	}

	func testGeneratedFeedsCoverTheRegistryChannels() {
		XCTAssertEqual(kUpdateChannelFeeds["main"], "appcast-main.xml")
		XCTAssertEqual(kUpdateChannelFeeds["dev"], "appcast-dev.xml")
	}
}

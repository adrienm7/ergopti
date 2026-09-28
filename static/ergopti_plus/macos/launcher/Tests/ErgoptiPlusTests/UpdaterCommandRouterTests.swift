// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/UpdaterCommandRouterTests.swift

import Foundation
import XCTest
@testable import ErgoptiPlus

/// Ordered record of what the router asked for, shared by both spies.
private final class Journal {
	private(set) var events: [String] = []

	func record(_ event: String) {
		events.append(event)
	}
}

/// Non-isolated like the protocol it conforms to.
private final class ChannelSelectorSpy: UpdateChannelSelecting {
	private let journal: Journal

	init(_ journal: Journal) {
		self.journal = journal
	}

	func selectChannel(_ channel: String) {
		journal.record("select:" + channel)
	}
}

@MainActor
final class UpdaterCommandRouterTests: XCTestCase {
	private final class UpdateCheckerSpy: UpdateChecking {
		private let journal: Journal

		init(_ journal: Journal) {
			self.journal = journal
		}

		func checkForUpdates() {
			XCTAssertTrue(Thread.isMainThread)
			journal.record("check")
		}
	}

	/// The router holds its checker and selector weakly, as it holds the
	/// launcher's controller and feed. A spy discarded with `_` is released at
	/// once and the router then only queues, so the test keeps both alive here.
	private var retainedSpies: [AnyObject] = []

	private func boundRouter(_ journal: Journal) -> UpdaterCommandRouter {
		let checker = UpdateCheckerSpy(journal)
		let selector = ChannelSelectorSpy(journal)
		retainedSpies = [checker, selector]
		let router = UpdaterCommandRouter(knownChannels: ["main", "dev"])
		router.bind(checker, channelSelector: selector)
		return router
	}

	func testExactCommandChecksOnce() throws {
		let journal = Journal()
		let router = boundRouter(journal)

		XCTAssertTrue(router.route(try XCTUnwrap(URL(string: "ergoptiplus://updater/check"))))
		XCTAssertEqual(journal.events, ["check"])
	}

	func testChannelCheckSelectsTheChannelBeforeChecking() throws {
		let journal = Journal()
		let router = boundRouter(journal)

		XCTAssertTrue(router.route(try XCTUnwrap(URL(string: "ergoptiplus://updater/check/dev"))))
		XCTAssertEqual(journal.events, ["select:dev", "check"])
	}

	func testChannelCommandSelectsWithoutChecking() throws {
		let journal = Journal()
		let router = boundRouter(journal)

		XCTAssertTrue(router.route(try XCTUnwrap(URL(string: "ergoptiplus://updater/channel/main"))))
		XCTAssertEqual(journal.events, ["select:main"])
	}

	func testRejectsEveryNonExactCommandComponent() throws {
		let journal = Journal()
		let router = boundRouter(journal)
		let rejected = [
			"https://updater/check",
			"ergoptiplus://other/check",
			"ergoptiplus://updater/other",
			"ergoptiplus://updater/check?again=true",
			"ergoptiplus://updater/check#fragment",
			"ergoptiplus://user@updater/check",
			"ergoptiplus://updater:42/check",
			"ergoptiplus://updater/check/beta",
			"ergoptiplus://updater/check/Dev",
			"ergoptiplus://updater/check/",
			"ergoptiplus://updater/check/dev/",
			"ergoptiplus://updater/channel/main/",
			"ergoptiplus://updater/%63heck",
			"ergoptiplus://updater/check%2Fdev",
			"ergoptiplus://updater/check/dev/again",
			"ergoptiplus://updater/channel",
			"ergoptiplus://updater/channel/stable",
			"ergoptiplus://updater/install/dev",
		]

		for rawURL in rejected {
			XCTAssertFalse(router.route(try XCTUnwrap(URL(string: rawURL))), rawURL)
		}
		XCTAssertEqual(journal.events, [])
	}

	func testCoalescesCommandsReceivedBeforeControllerBinding() throws {
		let journal = Journal()
		let checker = UpdateCheckerSpy(journal)
		let selector = ChannelSelectorSpy(journal)
		let router = UpdaterCommandRouter(knownChannels: ["main", "dev"])
		let command = try XCTUnwrap(URL(string: "ergoptiplus://updater/check/dev"))

		XCTAssertTrue(router.route(command))
		XCTAssertTrue(router.route(command))
		XCTAssertEqual(journal.events, [])
		router.bind(checker, channelSelector: selector)
		XCTAssertEqual(journal.events, ["select:dev", "check"])
	}

	func testDefaultChannelsAreTheGeneratedRegistry() throws {
		let journal = Journal()
		let checker = UpdateCheckerSpy(journal)
		let selector = ChannelSelectorSpy(journal)
		retainedSpies = [checker, selector]
		let router = UpdaterCommandRouter()
		router.bind(checker, channelSelector: selector)

		for channel in kUpdateChannelFeeds.keys.sorted() {
			XCTAssertTrue(router.route(try XCTUnwrap(URL(string: "ergoptiplus://updater/channel/" + channel))))
		}
		XCTAssertEqual(journal.events, kUpdateChannelFeeds.keys.sorted().map { "select:" + $0 })
	}
}

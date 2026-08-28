// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/UpdaterCommandRouterTests.swift

import Foundation
import XCTest
@testable import ErgoptiPlus

@MainActor
final class UpdaterCommandRouterTests: XCTestCase {
	private final class UpdateCheckerSpy: UpdateChecking {
		private(set) var calls = 0

		func checkForUpdates(_ sender: Any?) {
			XCTAssertTrue(Thread.isMainThread)
			calls += 1
		}
	}

	func testExactCommandChecksOnce() throws {
		let checker = UpdateCheckerSpy()
		let router = UpdaterCommandRouter()
		router.bind(checker)

		XCTAssertTrue(router.route(try XCTUnwrap(URL(string: "ergoptiplus://updater/check"))))
		XCTAssertEqual(checker.calls, 1)
	}

	func testRejectsEveryNonExactCommandComponent() throws {
		let checker = UpdateCheckerSpy()
		let router = UpdaterCommandRouter()
		router.bind(checker)
		let rejected = [
			"https://updater/check",
			"ergoptiplus://other/check",
			"ergoptiplus://updater/other",
			"ergoptiplus://updater/check?again=true",
			"ergoptiplus://updater/check#fragment",
			"ergoptiplus://user@updater/check",
			"ergoptiplus://updater:42/check",
		]

		for rawURL in rejected {
			XCTAssertFalse(router.route(try XCTUnwrap(URL(string: rawURL))), rawURL)
		}
		XCTAssertEqual(checker.calls, 0)
	}

	func testCoalescesCommandsReceivedBeforeControllerBinding() throws {
		let checker = UpdateCheckerSpy()
		let router = UpdaterCommandRouter()
		let command = try XCTUnwrap(URL(string: "ergoptiplus://updater/check"))

		XCTAssertTrue(router.route(command))
		XCTAssertTrue(router.route(command))
		XCTAssertEqual(checker.calls, 0)
		router.bind(checker)
		XCTAssertEqual(checker.calls, 1)
	}
}

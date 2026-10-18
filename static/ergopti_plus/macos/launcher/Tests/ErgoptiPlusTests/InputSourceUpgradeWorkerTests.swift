// Tests/ErgoptiPlusTests/InputSourceUpgradeWorkerTests.swift
//
// Model exact lookup and mutation order without changing native keyboard state.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class InputSourceUpgradeWorkerTests: XCTestCase {
	private final class State {
		var available: Set<String> = ["old1", "old2", "new1", "new2"]
		var events: [String] = []
		var refusal: String?
		var lookupFailure: String?

		func effect(_ event: String) -> Int32 {
			events.append(event)
			return refusal == event ? -50 : 0
		}

		var backend: InputSourceUpgradeBackend<String> {
			InputSourceUpgradeBackend(find: { identifier in
				self.events.append("find:" + identifier)
				if self.lookupFailure == identifier { throw InputSourceSelectionError.unavailableInventory }
				return self.available.contains(identifier) ? identifier : nil
			}, disable: { self.effect("disable:" + $0) },
				enable: { self.effect("enable:" + $0) }, select: { self.effect("select:" + $0) })
		}
	}

	private let replacements = [InputSourceReplacement(oldID: "old1", newID: "new1"),
		InputSourceReplacement(oldID: "old2", newID: "new2")]
	private let expectedEvents = ["find:new1", "find:new2", "find:old1", "find:old2",
		"disable:old1", "enable:new1", "disable:old2", "enable:new2", "select:new2"]

	func testEveryReferenceIsRetainedBeforeMutationAndLastTargetIsSelected() throws {
		let state = State()
		XCTAssertEqual(try upgradeNativeInputSources(replacements, backend: state.backend),
			.counts(disabled: 2, enabled: 2))
		XCTAssertEqual(state.events, expectedEvents)
	}

	func testLaterMissingTargetCannotDisableAnEarlierWorkingSource() throws {
		let state = State()
		state.available.remove("new2")
		XCTAssertEqual(try upgradeNativeInputSources(replacements, backend: state.backend), .missing)
		XCTAssertEqual(state.events, ["find:new1", "find:new2"],
			"Every target must be proven before the first disable or enable")
	}

	func testLaterLookupFailureCannotPublishOrMutateAPartialUpgrade() {
		let state = State()
		state.lookupFailure = "old2"
		XCTAssertThrowsError(try upgradeNativeInputSources(replacements, backend: state.backend))
		XCTAssertEqual(state.events, Array(expectedEvents.prefix(4)))
	}

	func testEveryNativeRefusalStopsWithoutInventingRollbackOrSuccess() throws {
		for (event, operation) in [
			("disable:old1", "TISDisableInputSource"), ("enable:new1", "TISEnableInputSource"),
			("disable:old2", "TISDisableInputSource"), ("enable:new2", "TISEnableInputSource"),
			("select:new2", "TISSelectInputSource")
		] {
			let state = State()
			state.refusal = event
			XCTAssertEqual(try upgradeNativeInputSources(replacements, backend: state.backend),
				.refused(operation: operation, status: -50))
			let terminal = try XCTUnwrap(expectedEvents.firstIndex(of: event))
			XCTAssertEqual(state.events, Array(expectedEvents.prefix(terminal + 1)))
		}
	}

	func testAbsentLegacySourceDoesNotPreventEnablingEveryReplacement() throws {
		let state = State()
		state.available.remove("old1")
		XCTAssertEqual(try upgradeNativeInputSources(replacements, backend: state.backend),
			.counts(disabled: 1, enabled: 2))
		XCTAssertEqual(state.events, expectedEvents.filter { $0 != "disable:old1" })
	}

	func testInvalidArgvCannotReachLookupOrPublishAResult() {
		let prefix = ["ErgoptiPlus", kInputSourceUpgradeFlag]
		for arguments in [
			["ErgoptiPlus"], ["ErgoptiPlus", "--foreign", "old", "new"],
			prefix, prefix + ["old"], prefix + ["old", "new", "extra"],
			prefix + ["", "new"], prefix + ["old", ""],
			prefix + ["bad\0old", "new"], prefix + ["old", "bad\0new"],
			prefix + [String(repeating: "x", count: kMaximumKeyboardSourceIDBytes + 1), "new"],
			prefix + ["old", String(repeating: "x", count: kMaximumKeyboardSourceIDBytes + 1)]
		] {
			XCTAssertEqual(InputSourceUpgradeWorker.run(arguments: arguments, upgrade: { _ in
				XCTFail("Invalid argv must not reach lookup or native effects")
				return .missing
			}, writeOutput: { _ in XCTFail("Invalid argv must not publish a result"); return true }), 64)
		}
		let state = State()
		XCTAssertThrowsError(try upgradeNativeInputSources([], backend: state.backend))
		XCTAssertTrue(state.events.isEmpty)
	}

	func testWorkerPreservesExactCountsMissingAndRefusalStatuses() {
		let arguments = ["ErgoptiPlus", kInputSourceUpgradeFlag, "old1", "new1", "old2", "new2"]
		for (result, text) in [
			(InputSourceUpgradeResult.counts(disabled: 1, enabled: 2), "1/2\n"),
			(.missing, "MISS\n"), (.refused(operation: "TISEnableInputSource", status: -50), "TISEnableInputSource:-50\n")
		] {
			var output: Data?
			XCTAssertEqual(InputSourceUpgradeWorker.run(arguments: arguments, upgrade: { parsed in
				XCTAssertEqual(parsed, self.replacements)
				return result
			}, writeOutput: { output = $0; return true }), 0)
			XCTAssertEqual(output, Data(text.utf8))
		}
	}

	func testWorkerCannotAcknowledgeNativeLookupOrOutputFailure() {
		let arguments = ["ErgoptiPlus", kInputSourceUpgradeFlag, "old1", "new1"]
		XCTAssertEqual(InputSourceUpgradeWorker.run(arguments: arguments, upgrade: { _ in
			throw InputSourceSelectionError.unavailableInventory
		}, writeOutput: { _ in XCTFail("Lookup failure must not emit a result"); return true }), 70)
		XCTAssertEqual(InputSourceUpgradeWorker.run(arguments: arguments,
			upgrade: { _ in .counts(disabled: 1, enabled: 1) }, writeOutput: { _ in false }), 74)
	}
}

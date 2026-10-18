// Tests/ErgoptiPlusTests/InputSourceSelectionWorkerTests.swift
//
// Native refusal and argv controls for the isolated signed selection worker.
// Actual current-source and missing-source execution has its own native fixture.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class InputSourceSelectionWorkerTests: XCTestCase {
	func testInvalidArgumentsNeverReachTheNativeSelector() {
		for arguments in [
			["ErgoptiPlus"], ["ErgoptiPlus", "--foreign", "source"],
			["ErgoptiPlus", kInputSourceSelectionFlag],
			["ErgoptiPlus", kInputSourceSelectionFlag, "source", "extra"],
			["ErgoptiPlus", kInputSourceSelectionFlag, ""],
			["ErgoptiPlus", kInputSourceSelectionFlag, "bad\0source"],
			["ErgoptiPlus", kInputSourceSelectionFlag,
				String(repeating: "x", count: kMaximumKeyboardSourceIDBytes + 1)]
		] {
			XCTAssertEqual(InputSourceSelectionWorker.run(arguments: arguments, select: { _ in
				XCTFail("Invalid argv must not reach native mutation")
				return .status(0)
			}, writeOutput: { _ in
				XCTFail("Invalid argv must not publish a result")
				return true
			}), 64)
		}
	}

	func testNativeStatusesAndMissingSourceRemainDistinct() {
		let identifier = "org.ergopti.é.keyboard"
		let arguments = ["ErgoptiPlus", kInputSourceSelectionFlag, identifier]
		for (result, expected) in [
			(InputSourceSelectionResult.status(0), "0\n"),
			(.status(-50), "-50\n"), (.status(Int32.min), "-2147483648\n"),
			(.missing, "MISS\n")
		] {
			var received: Data?
			var selections = 0
			XCTAssertEqual(InputSourceSelectionWorker.run(arguments: arguments, select: { requested in
				XCTAssertEqual(requested, identifier)
				selections += 1
				return result
			}, writeOutput: { received = $0; return true }), 0)
			XCTAssertEqual(selections, 1)
			XCTAssertEqual(received, Data(expected.utf8))
		}
	}

	func testNativeLookupFailureCannotPublishAcceptance() {
		let arguments = ["ErgoptiPlus", kInputSourceSelectionFlag, "source.id"]
		XCTAssertEqual(InputSourceSelectionWorker.run(arguments: arguments, select: { _ in
			throw InputSourceSelectionError.unavailableInventory
		}, writeOutput: { _ in
			XCTFail("A native lookup failure must not publish success or MISS")
			return true
		}), 70)
	}

	func testOutputFailureCannotAcknowledgeTheNativeResult() {
		XCTAssertEqual(InputSourceSelectionWorker.run(
			arguments: ["ErgoptiPlus", kInputSourceSelectionFlag, "source.id"],
			select: { _ in .status(0) }, writeOutput: { _ in false }), 74)
	}
}

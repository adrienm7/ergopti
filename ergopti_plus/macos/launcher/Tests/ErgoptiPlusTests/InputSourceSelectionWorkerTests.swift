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

	func testNamedRoleKeepsItsArgumentsAndRejectsInvalidRequestsBeforeLookup() {
		let arguments = ["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French", "French"]
		var received: Data?
		XCTAssertEqual(InputSourceSelectionWorker.run(arguments: arguments, select: { _ in
			XCTFail("A named request must not use the ID-only backend")
			return .status(0)
		}, selectByName: { name, candidate in
			XCTAssertEqual(name, "French")
			XCTAssertEqual(candidate, "French")
			return .status(-50)
		}, writeOutput: { received = $0; return true }), 0)
		XCTAssertEqual(received, Data("-50\n".utf8))
		for invalid in [
			["ErgoptiPlus", kInputSourceSelectionByNameFlag],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French"],
			arguments + ["extra"],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "", "French"],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French", ""],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "bad\0name", "id"],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French", "bad\0id"],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag,
				String(repeating: "é", count: kMaximumKeyboardSourceIDBytes), "id"],
			["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French",
				String(repeating: "x", count: kMaximumKeyboardSourceIDBytes + 1)]
		] {
			XCTAssertEqual(InputSourceSelectionWorker.run(arguments: invalid, selectByName: { _, _ in
				XCTFail("Invalid argv must not reach native lookup")
				return .status(0)
			}, writeOutput: { _ in XCTFail("Invalid argv must not publish a result"); return true }), 64)
		}
	}

	func testLocalizedNameSelectsTheIdentityFromOneInventoryRegardlessOfOrder() throws {
		let french = (id: "com.apple.keylayout.French", name: "French")
		let abc = (id: "com.apple.keylayout.ABC", name: "ABC")
		for inventory in [[abc, french], [french, abc]] {
			var selected: [String] = []
			let result = try selectKeyboardInputSource("French", localisedName: "French",
				inventory: inventory, sourceID: { $0.id }, sourceName: { $0.name }, select: {
					selected.append($0.id)
					return 0
				})
			XCTAssertEqual(result, .status(0))
			XCTAssertEqual(selected, [french.id])
		}
	}

	func testDuplicateLocalizedNamesNeverMutateUnlessAnExactIDProvesIdentity() throws {
		let inventory = [(id: "com.apple.keylayout.French", name: "French"),
			(id: "org.other.keyboard.French", name: "French")]
		var selected: [String] = []
		func run(_ identifier: String, name: String) throws -> InputSourceSelectionResult {
			try selectKeyboardInputSource(identifier, localisedName: name,
				inventory: inventory, sourceID: { $0.id }, sourceName: { $0.name }, select: {
					selected.append($0.id)
					return -50
				})
		}
		XCTAssertThrowsError(try run("French", name: "French"))
		XCTAssertTrue(selected.isEmpty, "Ambiguous names must never select the first source")
		XCTAssertEqual(try run("missing.id", name: "Absent"), .missing)
		XCTAssertTrue(selected.isEmpty)
		XCTAssertEqual(try run(inventory[1].id, name: "French"), .status(-50))
		XCTAssertEqual(selected, [inventory[1].id])
		var wrote = false
		XCTAssertEqual(InputSourceSelectionWorker.run(
			arguments: ["ErgoptiPlus", kInputSourceSelectionByNameFlag, "French", "French"],
			selectByName: { name, identifier in try run(identifier, name: name) },
			writeOutput: { _ in wrote = true; return true }), 70)
		XCTAssertFalse(wrote)
		XCTAssertEqual(selected, [inventory[1].id], "Ambiguity must not add another mutation")
	}
}

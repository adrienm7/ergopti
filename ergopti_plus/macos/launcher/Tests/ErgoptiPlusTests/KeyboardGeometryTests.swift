// Tests/ErgoptiPlusTests/KeyboardGeometryTests.swift

// ==============================================================================
// MODULE: Native Keyboard Geometry Tests
// DESCRIPTION:
// Keeps event keyboard-model identifiers separate from Carbon layout forms,
// verifies complete compressed coverage and rejects inherited environment facts.
// Native Carbon observations run only in the macOS Swift test target.
// ==============================================================================

import Carbon
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import ErgoptiPlus

final class KeyboardGeometryTests: XCTestCase {
	private func oracle(_ identifier: Int16) -> UInt32 {
		switch identifier {
		case 1, 40, 43: return 0x414E5349 // ANSI
		case 2, 41: return 0x49534F20 // ISO
		case 3, 42, 32767: return 0x4A495320 // JIS
		default: return 0xFFFFFFFF
		}
	}

	func testLayoutFormsAreNotKeyboardModelNumbers() {
		XCTAssertEqual(KeyboardGeometryForm.classify(0x414E5349), .ansi)
		XCTAssertEqual(KeyboardGeometryForm.classify(0x49534F20), .iso)
		XCTAssertEqual(KeyboardGeometryForm.classify(0x4A495320), .jis)
		for value in [UInt32(0), 10, 40, 41, 42, 50, 0xFFFFFFFF] {
			XCTAssertEqual(KeyboardGeometryForm.classify(value), .unknown)
		}
	}

	func testEveryNonnegativeInt16IdentifierIsReadExactlyOnce() throws {
		var observed: [Int16] = []
		let map = try KeyboardGeometryMap.capture { identifier in
			observed.append(identifier)
			return self.oracle(identifier)
		}
		XCTAssertEqual(observed, (0...32767).map { Int16($0) })
		XCTAssertEqual(map.ranges, [
			KeyboardGeometryRange(first: 0, last: 0, form: .unknown),
			KeyboardGeometryRange(first: 1, last: 1, form: .ansi),
			KeyboardGeometryRange(first: 2, last: 2, form: .iso),
			KeyboardGeometryRange(first: 3, last: 3, form: .jis),
			KeyboardGeometryRange(first: 4, last: 39, form: .unknown),
			KeyboardGeometryRange(first: 40, last: 40, form: .ansi),
			KeyboardGeometryRange(first: 41, last: 41, form: .iso),
			KeyboardGeometryRange(first: 42, last: 42, form: .jis),
			KeyboardGeometryRange(first: 43, last: 43, form: .ansi),
			KeyboardGeometryRange(first: 44, last: 32766, form: .unknown),
			KeyboardGeometryRange(first: 32767, last: 32767, form: .jis),
		])
	}

	func testUnknownDomainCompressesWithoutBorrowingAnANSIDefault() throws {
		let map = try KeyboardGeometryMap.capture { _ in 0xFFFFFFFF }
		XCTAssertEqual(map.ranges, [KeyboardGeometryRange(first: 0, last: 32767, form: .unknown)])
		XCTAssertEqual(map.environmentValue,
			"{\"maximum\":32767,\"ranges\":[{\"first\":0,\"form\":\"unknown\",\"last\":32767}],\"version\":1}")
	}

	func testCompletePartitionRejectsMissingOverlappingAndNoncanonicalRanges() {
		let invalid: [[KeyboardGeometryRange]] = [
			[],
			[KeyboardGeometryRange(first: 1, last: 32767, form: .unknown)],
			[KeyboardGeometryRange(first: 0, last: 32766, form: .unknown)],
			[KeyboardGeometryRange(first: 0, last: 32768, form: .unknown)],
			[KeyboardGeometryRange(first: 0, last: -1, form: .unknown)],
			[KeyboardGeometryRange(first: 0, last: 10, form: .ansi),
				KeyboardGeometryRange(first: 10, last: 32767, form: .iso)],
			[KeyboardGeometryRange(first: 0, last: 10, form: .ansi),
				KeyboardGeometryRange(first: 12, last: 32767, form: .iso)],
			[KeyboardGeometryRange(first: 0, last: 10, form: .ansi),
				KeyboardGeometryRange(first: 11, last: 32767, form: .ansi)],
		]
		for ranges in invalid {
			XCTAssertThrowsError(try KeyboardGeometryMap(ranges: ranges)) { error in
				guard let geometryError = error as? KeyboardGeometryError,
					case .invalidPartition = geometryError else {
					return XCTFail("The partition must fail at its actual domain admission.")
				}
			}
		}
	}

	func testEnvironmentEnvelopeHasOnlyTheVersionedCompleteGrammar() throws {
		let map = try KeyboardGeometryMap.capture(layoutTypeForKeyboard: oracle)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(
			with: Data(map.environmentValue.utf8)) as? [String: Any])
		XCTAssertEqual(Set(object.keys), ["version", "maximum", "ranges"])
		XCTAssertEqual(object["version"] as? Int, 1)
		XCTAssertEqual(object["maximum"] as? Int, 32767)
		let ranges = try XCTUnwrap(object["ranges"] as? [[String: Any]])
		XCTAssertEqual(ranges.count, 11)
		for range in ranges {
			XCTAssertEqual(Set(range.keys), ["first", "last", "form"])
			XCTAssertNotNil(range["first"] as? Int)
			XCTAssertNotNil(range["last"] as? Int)
			XCTAssertTrue(["ansi", "iso", "jis", "unknown"].contains(range["form"] as? String ?? ""))
		}
	}

	func testInheritedGeometryCannotBecomeChildAuthority() throws {
		let parent = [kKeyboardGeometryEnvironment: "stale-untrusted", "UNRELATED": "preserved"]
		let absent = launcherChildEnvironment(base: parent, launcherPid: 42, launcherBundleId: nil)
		XCTAssertNil(absent[kKeyboardGeometryEnvironment])
		let map = try KeyboardGeometryMap.capture(layoutTypeForKeyboard: oracle)
		let child = launcherChildEnvironment(base: parent, launcherPid: 42,
			launcherBundleId: nil, keyboardGeometry: map)
		XCTAssertEqual(child[kKeyboardGeometryEnvironment], map.environmentValue)
		XCTAssertEqual(child["UNRELATED"], "preserved")
		XCTAssertEqual(parent[kKeyboardGeometryEnvironment], "stale-untrusted")
	}

	func testActualNativeCarbonCanonicalAndOlderModels() throws {
		let started = DispatchTime.now().uptimeNanoseconds
		let map = try KeyboardGeometryMap.capture()
		let finished = DispatchTime.now().uptimeNanoseconds
		XCTAssertGreaterThanOrEqual(finished, started)
		let argumentLimit = sysconf(_SC_ARG_MAX)
		let environmentBytes = map.environmentValue.utf8.count
		XCTAssertGreaterThan(argumentLimit, 0)
		XCTAssertLessThan(environmentBytes + kKeyboardGeometryEnvironment.utf8.count + 2, Int(argumentLimit))
		XCTAssertGreaterThan(map.ranges.count, 0)
		XCTAssertLessThanOrEqual(map.ranges.count, 32768)
		let elapsed = finished >= started ? finished - started : 0
		print("KEYBOARD_GEOMETRY_OBSERVATION ranges=\(map.ranges.count) env_bytes=\(environmentBytes) elapsed_ns=\(elapsed) arg_max=\(argumentLimit) physical_qualified=false")
		func published(_ identifier: Int) -> KeyboardGeometryForm? {
			map.ranges.first { $0.first <= identifier && identifier <= $0.last }?.form
		}
		XCTAssertEqual(published(40), .ansi)
		XCTAssertEqual(published(41), .iso)
		XCTAssertEqual(published(42), .jis)
		// These model IDs are not the virtual keycode pair 10/50. Older/model
		// identifiers are checked against the real API, never a guessed table.
		for identifier in [Int16(0), 1, 2, 3, 10, 11, 12, 16, 43, 50, 32767] {
			let expected: KeyboardGeometryForm
			switch KBGetLayoutType(identifier) {
			case UInt32(kKeyboardANSI): expected = .ansi
			case UInt32(kKeyboardISO): expected = .iso
			case UInt32(kKeyboardJIS): expected = .jis
			default: expected = .unknown
			}
			XCTAssertEqual(published(Int(identifier)), expected)
		}
	}
}

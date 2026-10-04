// Tests/ErgoptiPlusTests/KeyboardSourceTestDiagnostics.swift

// ==============================================================================
// MODULE: Bounded Native Keyboard Source Test Evidence
// DESCRIPTION:
// Records read-only Carbon properties around the tests' existing mutations.
// Evidence never selects a source, waits, retries, or changes an XCTest verdict.
// ==============================================================================

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

struct KeyboardSourceTestIdentity: Codable, Equatable {
	let state: String
	let value: String?

	static func bounded(_ value: String?) -> Self {
		guard let value else { return Self(state: "missing", value: nil) }
		guard value.utf8.count <= 1_024 else { return Self(state: "oversize", value: nil) }
		return Self(state: "present", value: value)
	}
}

struct KeyboardSourceTestBoolean: Codable, Equatable {
	let state: String
	let value: Bool?
}

struct KeyboardSourceTestState: Codable {
	let id: KeyboardSourceTestIdentity
	let enabled: KeyboardSourceTestBoolean
	let selected: KeyboardSourceTestBoolean
	let selectCapable: KeyboardSourceTestBoolean

	static func read(_ source: TISInputSource?) -> Self {
		guard let source else {
			let unknown = KeyboardSourceTestBoolean(state: "sourceUnavailable", value: nil)
			return Self(id: .init(state: "sourceUnavailable", value: nil),
				enabled: unknown, selected: unknown, selectCapable: unknown)
		}
		func boolean(_ property: CFString) -> KeyboardSourceTestBoolean {
			guard let pointer = TISGetInputSourceProperty(source, property) else {
				return .init(state: "missing", value: nil)
			}
			guard CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()) == CFBooleanGetTypeID()
			else { return .init(state: "invalidType", value: nil) }
			return .init(state: "present",
				value: CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()))
		}
		var identifier = KeyboardSourceTestIdentity.bounded(nil)
		if let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
			if CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()) == CFStringGetTypeID() {
				identifier = .bounded(Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String)
			} else {
				identifier = .init(state: "invalidType", value: nil)
			}
		}
		return Self(id: identifier,
			enabled: boolean(kTISPropertyInputSourceIsEnabled),
			selected: boolean(kTISPropertyInputSourceIsSelected),
			selectCapable: boolean(kTISPropertyInputSourceIsSelectCapable))
	}
}

final class KeyboardSourceTestDiagnostics {
	struct Event: Codable {
		let phase: String
		let uptime: TimeInterval
		let status: OSStatus?
		let original: KeyboardSourceTestState?
		let target: KeyboardSourceTestState?
		let current: KeyboardSourceTestState?
		let snapshotID: KeyboardSourceTestIdentity?
		let keyboardType: UInt32?
		let unicodeDataBytes: Int?
	}
	struct Receipt: Codable {
		let version: Int
		let test: KeyboardSourceTestIdentity
		let pid: Int32
		let events: [Event]
		let omittedEvents: Int
	}

	private let test: KeyboardSourceTestIdentity
	private(set) var events: [Event] = []
	private(set) var omittedEvents = 0

	init(_ test: String) { self.test = .bounded(test) }

	func append(_ event: Event) {
		guard events.count < 64 else { omittedEvents += 1; return }
		events.append(event)
	}

	func record(_ phase: String, original: TISInputSource? = nil, target: TISInputSource? = nil,
		status: OSStatus? = nil, snapshot: KeyboardSourceSnapshot? = nil) {
		let uptime = ProcessInfo.processInfo.systemUptime
		let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
		append(Event(phase: phase, uptime: uptime, status: status,
			original: .read(original), target: .read(target), current: .read(current),
			snapshotID: snapshot.map { .bounded($0.sourceID) }, keyboardType: snapshot?.keyboardType,
			unicodeDataBytes: snapshot?.data.map { CFDataGetLength($0) }))
	}

	func nativeCall(_ phase: String, original: TISInputSource, target: TISInputSource? = nil,
		_ call: () -> OSStatus) -> OSStatus {
		record(phase + ".before", original: original, target: target)
		let status = call()
		record(phase + ".after", original: original, target: target, status: status)
		return status
	}

	func probe(_ invocation: KeyboardSourceProbeInvocation,
		readCurrentID: (() throws -> String)? = nil) throws -> KeyboardSourceProbeReceipt {
		record("probe.before")
		defer { record("probe.after") }
		do {
			return try probeSelectedKeyboardSource(invocation, readSnapshot: {
				let snapshot = try captureSelectedKeyboardSource()
				self.record("probe.snapshot", snapshot: snapshot)
				return snapshot
			}, readCurrentID: {
				let identifier: String
				if let readCurrentID {
					identifier = try readCurrentID()
				} else {
					identifier = try selectedKeyboardSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
				}
				self.append(Event(phase: "probe.terminalID", uptime: ProcessInfo.processInfo.systemUptime,
					status: nil, original: nil, target: nil, current: nil, snapshotID: .bounded(identifier),
					keyboardType: nil, unicodeDataBytes: nil))
				return identifier
			})
		} catch {
			let phase: String
			if let known = error as? KeyboardSourceProbeError {
				switch known {
				case .invalidArguments: phase = "probe.refused.invalidArguments"
				case .sourceChanged: phase = "probe.refused.sourceChanged"
				case .unavailableLayout: phase = "probe.refused.unavailableLayout"
				case .translationFailed: phase = "probe.refused.translationFailed"
				case .invalidUnicode: phase = "probe.refused.invalidUnicode"
				}
			} else { phase = "probe.refused.unclassified" }
			record(phase)
			throw error
		}
	}

	func receipt() -> Receipt {
		Receipt(version: 1, test: test, pid: ProcessInfo.processInfo.processIdentifier,
			events: events, omittedEvents: omittedEvents)
	}

	func emit() {
		do {
			let data = try JSONEncoder().encode(receipt())
			print("TIS_TEST_EVIDENCE " + String(decoding: data, as: UTF8.self))
		} catch {
			print("TIS_TEST_EVIDENCE {\"version\":1,\"diagnosticEncodingRefused\":true}")
		}
	}
}

final class KeyboardSourceTestDiagnosticsTests: XCTestCase {
	func testIdentityIsByteBoundedAndMissingIsExplicit() {
		XCTAssertEqual(KeyboardSourceTestIdentity.bounded(nil).state, "missing")
		XCTAssertEqual(KeyboardSourceTestIdentity.bounded(String(repeating: "é", count: 512)).state, "present")
		let oversized = KeyboardSourceTestIdentity.bounded(String(repeating: "é", count: 513))
		XCTAssertEqual(oversized.state, "oversize")
		XCTAssertNil(oversized.value)
	}

	func testUnavailableSourcePropertiesAreExplicit() {
		let state = KeyboardSourceTestState.read(nil)
		XCTAssertEqual(state.id.state, "sourceUnavailable")
		XCTAssertEqual(state.enabled.state, "sourceUnavailable")
		XCTAssertNil(state.enabled.value)
		XCTAssertEqual(state.selected.state, "sourceUnavailable")
		XCTAssertEqual(state.selectCapable.state, "sourceUnavailable")
	}

	func testReceiptRetainsNativeStatusAndEscapesIdentity() throws {
		let recorder = KeyboardSourceTestDiagnostics("controlled.\"identity\n")
		recorder.append(.init(phase: "restore.after", uptime: 123, status: -50,
			original: nil, target: nil, current: nil, snapshotID: nil, keyboardType: nil, unicodeDataBytes: nil))
		let data = try JSONEncoder().encode(recorder.receipt())
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let events = try XCTUnwrap(object["events"] as? [[String: Any]])
		XCTAssertEqual(events[0]["status"] as? Int, -50)
		let test = try XCTUnwrap(object["test"] as? [String: Any])
		XCTAssertEqual(test["value"] as? String, "controlled.\"identity\n")
		XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
	}

	func testEventOverflowIsCountedWithoutChangingPriorReceipt() {
		let recorder = KeyboardSourceTestDiagnostics("controlled.bounded")
		let event = KeyboardSourceTestDiagnostics.Event(phase: "controlled", uptime: 1, status: 0,
			original: nil, target: nil, current: nil, snapshotID: nil, keyboardType: nil, unicodeDataBytes: nil)
		for _ in 0..<67 { recorder.append(event) }
		XCTAssertEqual(recorder.receipt().events.count, 64)
		XCTAssertEqual(recorder.receipt().omittedEvents, 3)
		XCTAssertEqual(recorder.receipt().events.first?.status, 0)
	}
}

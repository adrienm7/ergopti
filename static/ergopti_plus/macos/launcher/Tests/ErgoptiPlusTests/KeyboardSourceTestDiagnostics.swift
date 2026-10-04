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
	struct PhaseWitness: Codable {
		let version: Int
		let sequence: Int
		let phase: String
	}

	// Closed vocabulary: witnesses contain no identities or native property data.
	static let observationPhases = [
		"original.capture", "target.inventory", "body.before", "body.after",
		"translation.snapshot", "event.before", "event.after", "probe.before", "probe.after",
		"probe.snapshot", "probe.refused.invalidArguments", "probe.refused.sourceChanged",
		"probe.refused.unavailableLayout", "probe.refused.translationFailed",
		"probe.refused.invalidUnicode", "probe.refused.unclassified",
	] + ["enable", "disable", "select", "restore.inner", "restore.outer"].flatMap {
		[$0 + ".before", $0 + ".after"]
	}
	static let knownWitnessPhases = Set(observationPhases.flatMap {
		[$0 + ".observe.entered", $0 + ".observe.completed"]
	} + ["enable", "disable", "select", "restore.inner", "restore.outer", "probe",
		"original.capture", "target.list", "target.enabledProperty"].flatMap {
		[$0 + ".call.entered", $0 + ".call.returned"]
	} + ["probe.call.refused", "probe.terminalID.returned", "unclassified", "overflow"])

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
	private let writeWitness: (Data) -> Void
	private var witnessCount = 0
	private(set) var events: [Event] = []
	private(set) var omittedEvents = 0

	init(_ test: String, writeWitness: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) }) {
		self.test = .bounded(test)
		self.writeWitness = writeWitness
	}

	func witness(_ phase: String) {
		guard witnessCount <= 128 else { return }
		let known = Self.knownWitnessPhases.contains(phase) ? phase : "unclassified"
		let published = witnessCount == 128 ? "overflow" : known
		witnessCount += 1
		let record = PhaseWitness(version: 1, sequence: witnessCount, phase: published)
		Self.writeFramedRecord(prefix: "TIS_TEST_PHASE ", encode: { try JSONEncoder().encode(record) },
			write: writeWitness)
	}

	// Publication precedes collection, which may block inside a native read.
	// The injected collector permits causal ordering controls without Carbon.
	func observe(_ phase: String, collect: () -> Event) {
		witness(phase + ".observe.entered")
		append(collect())
		witness(phase + ".observe.completed")
	}

	func append(_ event: Event) {
		guard events.count < 64 else { omittedEvents += 1; return }
		events.append(event)
	}

	func record(_ phase: String, original: TISInputSource? = nil, target: TISInputSource? = nil,
		status: OSStatus? = nil, snapshot: KeyboardSourceSnapshot? = nil) {
		observe(phase) {
			let uptime = ProcessInfo.processInfo.systemUptime
			let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
			return Event(phase: phase, uptime: uptime, status: status,
				original: .read(original), target: .read(target), current: .read(current),
				snapshotID: snapshot.map { .bounded($0.sourceID) }, keyboardType: snapshot?.keyboardType,
				unicodeDataBytes: snapshot?.data.map { CFDataGetLength($0) })
		}
	}

	func nativeCall(_ phase: String, original: TISInputSource, target: TISInputSource? = nil,
		_ call: () -> OSStatus) -> OSStatus {
		record(phase + ".before", original: original, target: target)
		witness(phase + ".call.entered")
		let status = call()
		witness(phase + ".call.returned")
		record(phase + ".after", original: original, target: target, status: status)
		return status
	}

	func probe(_ invocation: KeyboardSourceProbeInvocation,
		readCurrentID: (() throws -> String)? = nil) throws -> KeyboardSourceProbeReceipt {
		record("probe.before")
		witness("probe.call.entered")
		defer { record("probe.after") }
		do {
			let receipt = try probeSelectedKeyboardSource(invocation, readSnapshot: {
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
				self.witness("probe.terminalID.returned")
				return identifier
			})
			witness("probe.call.returned")
			return receipt
		} catch {
			witness("probe.call.refused")
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

	// Assemble the terminator with the body before handing the complete record to
	// the output owner. Swift print may publish its body and newline separately,
	// allowing an XCTest completion receipt to appear between those writes.
	// A single FileHandle call does not promise global atomicity across producers.
	static func writeRecord(encode: () throws -> Data,
		write: (Data) -> Void = { FileHandle.standardOutput.write($0) }) {
		writeFramedRecord(prefix: "TIS_TEST_EVIDENCE ", encode: encode, write: write)
	}

	private static func writeFramedRecord(prefix: String, encode: () throws -> Data, write: (Data) -> Void) {
		let payload: Data
		do { payload = try encode() }
		catch { payload = Data("{\"version\":1,\"diagnosticEncodingRefused\":true}".utf8) }
		var record = Data(prefix.utf8)
		record.append(payload)
		record.append(0x0A)
		write(record)
	}

	func emit() {
		Self.writeRecord(encode: { try JSONEncoder().encode(receipt()) })
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

// Pure framing controls use the same emitter as the native tests. They do not
// call Carbon, change a source, or relax the strict XCTest receipt reader.
extension KeyboardSourceTestDiagnosticsTests {
	func testInitialNativeCallWitnessesPreserveExactBoundaries() throws {
		var writes: [Data] = []
		let recorder = KeyboardSourceTestDiagnostics("controlled", writeWitness: { writes.append($0) })
		let expected = [
			"original.capture.call.entered", "original.capture.call.returned",
			"target.list.call.entered", "target.list.call.returned",
			"target.enabledProperty.call.entered", "target.enabledProperty.call.returned",
		]
		for phase in expected { recorder.witness(phase) }
		let prefix = Data("TIS_TEST_PHASE ".utf8)
		let observed = try writes.map { data in
			try JSONDecoder().decode(KeyboardSourceTestDiagnostics.PhaseWitness.self,
				from: Data(data.dropFirst(prefix.count).dropLast())).phase
		}
		XCTAssertEqual(observed, expected)
	}

	func testPhaseWitnessIsPublishedBeforeObservationCollection() throws {
		var writes: [Data] = []
		let recorder = KeyboardSourceTestDiagnostics("private.identity", writeWitness: { writes.append($0) })
		let event = KeyboardSourceTestDiagnostics.Event(phase: "select.before", uptime: 1, status: nil,
			original: nil, target: nil, current: nil, snapshotID: .bounded("private.source"),
			keyboardType: nil, unicodeDataBytes: nil)
		recorder.observe("select.before") {
			XCTAssertEqual(writes.count, 1, "The native collector must not run before the entered witness is written")
			XCTAssertTrue(recorder.events.isEmpty)
			return event
		}
		XCTAssertEqual(recorder.events.count, 1)
		XCTAssertEqual(writes.count, 2)
		let prefix = Data("TIS_TEST_PHASE ".utf8)
		let phases = try writes.map { data -> KeyboardSourceTestDiagnostics.PhaseWitness in
			XCTAssertTrue(data.starts(with: prefix))
			XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
			XCTAssertEqual(data.last, 0x0A)
			XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
			return try JSONDecoder().decode(KeyboardSourceTestDiagnostics.PhaseWitness.self,
				from: Data(data.dropFirst(prefix.count).dropLast()))
		}
		XCTAssertEqual(phases.map(\.phase), ["select.before.observe.entered", "select.before.observe.completed"])
		XCTAssertEqual(phases.map(\.sequence), [1, 2])
	}

	func testPhaseVocabularyOverflowAndPrivacyAreBounded() throws {
		var writes: [Data] = []
		let recorder = KeyboardSourceTestDiagnostics("private.identity", writeWitness: { writes.append($0) })
		recorder.witness("/Users/private/TOKEN%\n::error::inert")
		for _ in 0..<132 { recorder.witness("select.call.entered") }
		XCTAssertEqual(writes.count, 129, "One final overflow witness bounds all subsequent writes")
		let prefix = Data("TIS_TEST_PHASE ".utf8)
		let phases = try writes.map { data -> KeyboardSourceTestDiagnostics.PhaseWitness in
			XCTAssertLessThanOrEqual(data.count - prefix.count - 1, 256)
			XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
			XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("TOKEN"))
			let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
				Data(data.dropFirst(prefix.count).dropLast())) as? [String: Any])
			XCTAssertEqual(Set(object.keys), Set(["version", "sequence", "phase"]))
			return try JSONDecoder().decode(KeyboardSourceTestDiagnostics.PhaseWitness.self,
				from: Data(data.dropFirst(prefix.count).dropLast()))
		}
		XCTAssertEqual(phases.first?.phase, "unclassified")
		XCTAssertEqual(phases.last?.phase, "overflow")
		XCTAssertEqual(phases.last?.sequence, 129)
		XCTAssertTrue(recorder.events.isEmpty, "Immediate witnesses do not rewrite full receipt events")
	}

	func testEvidenceWritesOneCompleteUTF8RecordBeforeFollowingReceipt() throws {
		let recorder = KeyboardSourceTestDiagnostics("controlled.é\nidentity")
		recorder.append(.init(phase: "restore.after", uptime: 123, status: -50,
			original: nil, target: nil, current: nil, snapshotID: nil, keyboardType: nil, unicodeDataBytes: nil))
		var writes: [Data] = []
		KeyboardSourceTestDiagnostics.writeRecord(encode: { try JSONEncoder().encode(recorder.receipt()) },
			write: { writes.append($0) })
		XCTAssertEqual(writes.count, 1)
		let record = try XCTUnwrap(writes.first)
		let prefix = Data("TIS_TEST_EVIDENCE ".utf8)
		XCTAssertTrue(record.starts(with: prefix))
		XCTAssertEqual(record.last, 0x0A)
		XCTAssertEqual(record.filter { $0 == 0x0A }.count, 1)
		let payload = Data(record.dropFirst(prefix.count).dropLast())
		let decoded = try JSONDecoder().decode(KeyboardSourceTestDiagnostics.Receipt.self, from: payload)
		XCTAssertEqual(decoded.test.value, "controlled.é\nidentity")
		XCTAssertEqual(decoded.events.first?.status, -50)
		let completion = "Test Case '-[Controlled framing]' passed (0.001 seconds).\n"
		var transcript = record
		transcript.append(Data(completion.utf8))
		let lines = String(decoding: transcript, as: UTF8.self).split(separator: "\n")
		XCTAssertEqual(lines.count, 2)
		XCTAssertEqual(String(lines[1]) + "\n", completion)
	}

	func testEncodingRefusalStillWritesOneCompleteClosedRecord() {
		enum ControlledRefusal: Error { case refused }
		var writes: [Data] = []
		KeyboardSourceTestDiagnostics.writeRecord(encode: { throw ControlledRefusal.refused },
			write: { writes.append($0) })
		XCTAssertEqual(writes.count, 1)
		XCTAssertEqual(writes.first,
			Data("TIS_TEST_EVIDENCE {\"version\":1,\"diagnosticEncodingRefused\":true}\n".utf8))
	}

	func testBoundedLargeReceiptKeepsTerminatorInTheSingleWrite() throws {
		let recorder = KeyboardSourceTestDiagnostics(String(repeating: "é", count: 512))
		let event = KeyboardSourceTestDiagnostics.Event(phase: "controlled", uptime: 1, status: -50,
			original: nil, target: nil, current: nil,
			snapshotID: .bounded(String(repeating: "é", count: 512)), keyboardType: nil, unicodeDataBytes: nil)
		for _ in 0..<67 { recorder.append(event) }
		var writes: [Data] = []
		KeyboardSourceTestDiagnostics.writeRecord(encode: { try JSONEncoder().encode(recorder.receipt()) },
			write: { writes.append($0) })
		XCTAssertEqual(writes.count, 1)
		let record = try XCTUnwrap(writes.first)
		XCTAssertGreaterThan(record.count, 4_096)
		XCTAssertEqual(record.last, 0x0A)
		XCTAssertEqual(record.filter { $0 == 0x0A }.count, 1)
		let decoded = try JSONDecoder().decode(KeyboardSourceTestDiagnostics.Receipt.self,
			from: Data(record.dropFirst(Data("TIS_TEST_EVIDENCE ".utf8).count).dropLast()))
		XCTAssertEqual(decoded.events.count, 64)
		XCTAssertEqual(decoded.omittedEvents, 3)
	}
}

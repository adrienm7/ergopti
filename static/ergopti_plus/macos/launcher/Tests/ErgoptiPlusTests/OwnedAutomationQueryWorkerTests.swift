// Tests/ErgoptiPlusTests/OwnedAutomationQueryWorkerTests.swift
// Native capture/EOF retirement tests. Fixed debug roles do not qualify Shortcuts API consent.

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

private final class AutomationQueryTestSession {
	let process = Process()
	let input = Pipe(), output = Pipe(), errors = Pipe()
	var stdout = Data(), stderr = Data()
	var decoder = OwnedProgramLineDecoder(maximumBytes: 90000)
	var markers: [String] = []
	private var inputClosed = false
	private var waitOrdinal = 0

	init(executable: URL, operation: String, role: String = "--automation-query-worker") throws {
		process.executableURL = executable
		process.arguments = [role, operation, "19"]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		for descriptor in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
			let flags = fcntl(descriptor, F_GETFL)
			guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
		}
	}

	func poll() throws {
		for (handle, role) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
			var bytes = [UInt8](repeating: 0, count: 4096)
			let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
			if count > 0 {
				let data = Data(bytes.prefix(count))
				if role {
					stdout.append(data)
					guard stdout.count <= 90000, decoder.append(data) else { throw NSError(domain: "query-limit", code: 1) }
					while let line = decoder.pop() {
						guard let value = String(data: line, encoding: .utf8) else { throw NSError(domain: "query-encoding", code: 1) }
						markers.append(value)
					}
				} else { stderr.append(data) }
			} else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
		}
	}

	/// Report fixed receipt facts only; payload and stderr bytes remain private.
	private func timeoutFacts(ordinal: Int) -> String {
		func status(_ prefix: String) -> String {
			var observed: Int32?
			for marker in markers where marker.hasPrefix(prefix) {
				let raw = String(marker.dropFirst(prefix.count))
				guard let value = Int32(raw), String(value) == raw else { return "invalid" }
				if let previous = observed, previous != value { return "mixed" }
				observed = value
			}
			return observed.map { String($0) } ?? "none"
		}
		let running = process.isRunning
		let terminal: String
		if running { terminal = "pending" }
		else {
			switch process.terminationReason {
			case .exit: terminal = "exit:\(process.terminationStatus)"
			case .uncaughtSignal: terminal = "signal:\(process.terminationStatus)"
			@unknown default: terminal = "unknown"
			}
		}
		return "wait=\(ordinal) held=\(markers.filter { $0 == "Q1 HELD" }.count)"
			+ " data=\(markers.filter { $0.hasPrefix("Q1 DATA ") }.count)"
			+ " refused=\(status("Q1 REFUSED ")) pending=\(status("Q1 PENDING ")) retired=\(status("Q1 RETIRED "))"
			+ " markers=\(markers.count) stdoutBytes=\(stdout.count) stderrBytes=\(stderr.count)"
			+ " bufferedBytes=\(decoder.buffered.count) running=\(running ? 1 : 0) terminal=\(terminal)"
			+ " setup=\(Self.setupFacts(markers))"
	}

	/// Accept only fixed syscall phases, boolean relationships and canonical codes.
	static func setupFacts(_ markers: [String]) -> String {
		let setup = markers.filter { $0.hasPrefix("Q1 SETUP ") }
		if setup.isEmpty { return "none" }
		guard setup.count <= 4 else { return "invalid" }
		var phases: [String] = [], records: [String] = []
		for marker in setup {
			let fields = marker.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
			guard fields.count == 14, fields[0] == "Q1", fields[1] == "SETUP",
				["getsid", "setsid", "getfl", "setfl"].contains(fields[2]) else { return "invalid" }
			let raw = Array(fields.dropFirst(3))
			let numbers = raw.compactMap { Int32($0) }
			guard numbers.count == 11, zip(raw, numbers).allSatisfy({ pair in pair.0 == String(pair.1) }),
				[0, 1, 2, 3, 7, 8, 9, 10].allSatisfy({ numbers[$0] == 0 || numbers[$0] == 1 }),
				numbers[5] >= 0, numbers[6] >= 0 else { return "invalid" }
			if fields[2] == "getsid" || fields[2] == "setsid" {
				guard [-1, 0, 1].contains(numbers[4]) else { return "invalid" }
			} else if fields[2] == "getfl" {
				guard numbers[4] >= -1 else { return "invalid" }
			} else if numbers[4] != -1 && numbers[4] != 0 { return "invalid" }
			phases.append(fields[2])
			records.append("\(fields[2]):before=\(numbers[0]),\(numbers[1]),\(numbers[2]),\(numbers[3])"
				+ ":returnCode=\(numbers[4]),errnoBefore=\(numbers[5]),errnoAfter=\(numbers[6])"
				+ ":after=\(numbers[7]),\(numbers[8]),\(numbers[9]),\(numbers[10])")
		}
		guard [["getsid"], ["getsid", "setsid"], ["getsid", "getfl"], ["getsid", "getfl", "setfl"],
			["getsid", "setsid", "getfl"], ["getsid", "setsid", "getfl", "setfl"]].contains(phases) else { return "invalid" }
		return records.joined(separator: ";")
	}

	func wait(_ predicate: () -> Bool) throws {
		waitOrdinal += 1
		let ordinal = waitOrdinal
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		repeat {
			try poll()
			if predicate() { return }
			usleep(1000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		throw NSError(domain: "query-native-timeout", code: 1,
			userInfo: [NSLocalizedDescriptionKey: timeoutFacts(ordinal: ordinal)])
	}

	func activate() throws { try input.fileHandleForWriting.write(contentsOf: Data("ACTIVATE\n".utf8)) }
	func cancel() throws {
		if !inputClosed { try input.fileHandleForWriting.close(); inputClosed = true }
	}
	func finish() throws {
		try wait { !process.isRunning }
		process.waitUntilExit()
		try poll()
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, 0)
		XCTAssertTrue(stderr.isEmpty)
		XCTAssertTrue(decoder.buffered.isEmpty)
	}
	func cleanup() {
		do { try cancel(); try finish() }
		catch { XCTFail("Owned query cleanup remains unacknowledged; native source evidence must be retained.") }
	}
}

final class OwnedAutomationQueryWorkerTests: XCTestCase {
	private func executable() throws -> URL {
		let products = Bundle(for: OwnedAutomationQueryWorkerTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
			XCTFail("The actual native launcher executable is required.")
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
		}
		return executable
	}

	func testActualBoundedCapturePublishesOnlyAfterRetirement() throws {
		let session = try AutomationQueryTestSession(executable: executable(), operation: "fixture")
		defer { session.cleanup() }
		try session.wait { session.markers.contains("Q1 HELD") }
		XCTAssertEqual(session.markers, ["Q1 HELD"])
		try session.activate()
		try session.wait { session.markers.contains("Q1 RETIRED 0") }
		try session.finish()
		XCTAssertEqual(session.markers.count, 3)
		XCTAssertTrue(session.markers[1].hasPrefix("Q1 DATA "))
		let raw = try XCTUnwrap(Data(base64Encoded: String(session.markers[1].dropFirst(8))))
		let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
		let rows = try XCTUnwrap(packet["rows"] as? [[String: Any]])
		XCTAssertEqual(rows.first?["id"] as? String, "11111111-1111-1111-1111-111111111111")
		let name = try XCTUnwrap(rows.first?["name"] as? String)
		XCTAssertEqual(Data(name.utf8), Data([0xe6, 0x97, 0xa5, 0xe6, 0x9c, 0xac, 0x20, 0x65, 0xcc, 0x81, 0x0a]))
		XCTAssertEqual(packet["nonce"] as? Int, 19)
	}

	func testActualOverflowCancelsWithoutPublishingPrivateData() throws {
		let session = try AutomationQueryTestSession(executable: executable(), operation: "fixture-overflow")
		defer { session.cleanup() }
		try session.wait { session.markers.contains("Q1 HELD") }; try session.activate()
		try session.wait { session.markers.contains(where: { $0.hasPrefix("Q1 RETIRED ") }) }
		try session.finish()
		XCTAssertFalse(session.markers.contains(where: { $0.hasPrefix("Q1 DATA ") }))
	}

	func testActualPrivateStderrNeverReachesHammerspoon() throws {
		let session = try AutomationQueryTestSession(executable: executable(), operation: "fixture-stderr")
		defer { session.cleanup() }
		try session.wait { session.markers.contains("Q1 HELD") }; try session.activate()
		try session.wait { session.markers.contains(where: { $0.hasPrefix("Q1 RETIRED ") }) }
		try session.finish()
		XCTAssertFalse(String(data: session.stdout, encoding: .utf8)!.contains("PRIVATE_NATIVE_QUERY_ERROR"))
		XCTAssertFalse(session.markers.contains(where: { $0.hasPrefix("Q1 DATA ") }))
	}

	func testActualEOFRetiresActivatedQueryBeforeHelperCompletion() throws {
		let session = try AutomationQueryTestSession(executable: executable(), operation: "fixture-wait")
		defer { session.cleanup() }
		try session.wait { session.markers.contains("Q1 HELD") }; try session.activate(); try session.cancel()
		try session.wait { session.markers.contains(where: { $0.hasPrefix("Q1 RETIRED ") }) }
		try session.finish()
		XCTAssertFalse(session.markers.contains(where: { $0.hasPrefix("Q1 DATA ") }))
	}

	func testSetupFactsKeepOnlyTypedGroupRelationships() {
		let markers = [
			"Q1 SETUP getsid 1 0 0 1 0 0 0 1 0 0 1",
			"Q1 SETUP setsid 1 0 0 1 -1 0 1 1 0 0 1", "Q1 REFUSED 1",
		]
		XCTAssertEqual(AutomationQueryTestSession.setupFacts(markers),
			"getsid:before=1,0,0,1:returnCode=0,errnoBefore=0,errnoAfter=0:after=1,0,0,1;"
				+ "setsid:before=1,0,0,1:returnCode=-1,errnoBefore=0,errnoAfter=1:after=1,0,0,1")
		XCTAssertEqual(AutomationQueryTestSession.setupFacts(["Q1 REFUSED 1"]), "none")
	}

	func testSetupFactsRejectRawIdentifiersAndNoncanonicalCodes() {
		let valid = "Q1 SETUP getsid 1 0 0 1 0 0 0 1 0 0 1"
		for invalid in [
			valid.replacingOccurrences(of: "getsid 1", with: "getsid 50001"),
			"Q1 SETUP getsid 1 0 0 1 50001 0 0 1 0 0 1",
			"Q1 SETUP getsid 1 0 0 1 0 0 -1 1 0 0 1",
			"Q1 SETUP getsid 1 0 0 1 0 +0 0 1 0 0 1",
			"Q1 SETUP getsid 1 0 0 1 0 00 0 1 0 0 1",
			"Q1 SETUP getsid 1 0 0 1 0 2147483648 0 1 0 0 1",
			"Q1 SETUP unexpected 1 0 0 1 0 0 0 1 0 0 1",
			"Q1 SETUP getsid 1 0 0 1 0 0 0 1 0 0 PRIVATE",
		] {
			XCTAssertEqual(AutomationQueryTestSession.setupFacts([invalid]), "invalid")
		}
	}

	func testSetupFactsRejectChangedPhaseOrderAndUnboundedRecords() {
		let sid = "Q1 SETUP getsid 1 0 0 1 0 0 0 1 0 0 1"
		let flags = "Q1 SETUP getfl 1 0 0 1 -1 0 9 1 0 0 1"
		for invalid in [[flags], [sid, sid], [sid, flags, sid], Array(repeating: sid, count: 5)] {
			XCTAssertEqual(AutomationQueryTestSession.setupFacts(invalid), "invalid")
		}
	}

	/// Retains the actual Foundation group-leader failure as a causal comparator.
	/// Only the native-spawned bridge, not this direct guardian, can make progress.
	func testActualDirectFoundationGuardianRetainsSessionRefusal() throws {
		let session = try AutomationQueryTestSession(executable: executable(), operation: "fixture",
			role: "--automation-query-guardian")
		defer { session.cleanup() }
		try session.wait { session.markers.contains("Q1 REFUSED \(EPERM)") }
		try session.finish()
		XCTAssertEqual(session.markers.count, 3)
		XCTAssertFalse(session.markers.contains("Q1 HELD"))
		XCTAssertNotEqual(AutomationQueryTestSession.setupFacts(session.markers), "invalid")
		let phases = session.markers.prefix(2).map { $0.split(separator: " ").map(String.init) }
		guard phases.count == 2, phases.allSatisfy({ $0.count == 14 }) else {
			XCTFail("The exact Foundation group-leader refusal receipt is required."); return
		}
		XCTAssertEqual(phases.map { $0[2] }, ["getsid", "setsid"])
		for fields in phases {
			XCTAssertEqual(Array(fields[3...6]), ["1", "0", "0", "1"])
			XCTAssertEqual(Array(fields[10...13]), ["1", "0", "0", "1"])
		}
		XCTAssertEqual(phases[0][7], "0")
		XCTAssertEqual(phases[1][7], "-1")
		XCTAssertEqual(phases[1][9], String(EPERM))
	}

	private func bridgeArguments(_ operation: String = "discover", nonce: String = "19") -> [String] {
		let base = ["/fixed/signed/launcher", "--automation-query-worker", operation, nonce]
		return operation == "revalidate" ? base + ["11111111-1111-1111-1111-111111111111"] : base
	}

	private func bridgeData(operation: String = "discover", nonce: Any = 19, version: Any = 1) throws -> String {
		let packet: [String: Any] = ["version": version, "nonce": nonce, "operation": operation,
			"status": "observed", "rows": [], "truncated": false]
		return "Q1 DATA " + (try JSONSerialization.data(withJSONObject: packet)).base64EncodedString()
	}

	func testBridgePayloadRequiresBothExactRetirementsAndBusinessAdmission() throws {
		var transcript = OwnedAutomationQueryWorker.BridgeTranscript()
		let args = bridgeArguments(), data = try bridgeData()
		XCTAssertTrue(transcript.accept("Q1 HELD", arguments: args))
		XCTAssertTrue(transcript.accept(data, arguments: args))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true))
		XCTAssertTrue(transcript.accept("Q1 RETIRED 0", arguments: args))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: nil, cancelled: false, beforeDeadline: true))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 9, cancelled: false, beforeDeadline: true))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: true, beforeDeadline: true))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: false))
		XCTAssertEqual(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true), data)
		XCTAssertFalse(transcript.accept("Q1 RETIRED 0", arguments: args))
	}

	func testBridgeRejectsForeignNonceRoleAndBooleanAuthority() throws {
		for line in [try bridgeData(nonce: 20), try bridgeData(nonce: true), try bridgeData(version: true),
			try bridgeData(operation: "revalidate")] {
			var transcript = OwnedAutomationQueryWorker.BridgeTranscript()
			XCTAssertTrue(transcript.accept("Q1 HELD", arguments: bridgeArguments()))
			XCTAssertFalse(transcript.accept(line, arguments: bridgeArguments()))
		}
		var revalidate = OwnedAutomationQueryWorker.BridgeTranscript()
		XCTAssertTrue(revalidate.accept("Q1 HELD", arguments: bridgeArguments("revalidate")))
		XCTAssertTrue(revalidate.accept(try bridgeData(operation: "revalidate"), arguments: bridgeArguments("revalidate")))
	}

	func testBridgeRejectsDuplicateOutOfOrderAndNoncanonicalReceipts() throws {
		let data = try bridgeData(), args = bridgeArguments()
		for invalid in ["Q1 REFUSED 0", "Q1 REFUSED +1", "Q1 RETIRED 256", "Q1 PENDING 00",
			"Q1 DATA A===", "Q1 DATA ", "Q1 UNKNOWN 0", "Q1 RETIRED -1"] {
			XCTAssertFalse(OwnedAutomationQueryWorker.validBridgeReceipt(invalid))
		}
		for lines in [[data], ["Q1 HELD", "Q1 HELD"],
			["Q1 HELD", "Q1 REFUSED 1"], ["Q1 HELD", data, data], ["Q1 HELD", data, "Q1 RETIRED 1"],
			["Q1 HELD", "Q1 PENDING 0", data], ["Q1 PENDING 0", "Q1 HELD"], ["Q1 REFUSED 1", "Q1 HELD"]] {
			var transcript = OwnedAutomationQueryWorker.BridgeTranscript()
			XCTAssertFalse(lines.allSatisfy { transcript.accept($0, arguments: args) })
		}
		var cancellation = OwnedAutomationQueryWorker.BridgeTranscript()
		XCTAssertTrue(cancellation.accept("Q1 HELD", arguments: args))
		XCTAssertTrue(cancellation.accept("Q1 PENDING 0", arguments: args))
		XCTAssertTrue(cancellation.accept("Q1 RETIRED 137", arguments: args))
		XCTAssertNil(cancellation.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true))
	}

	func testBridgePreservesNegativeRetirementWithoutGrantingData() throws {
		let args = bridgeArguments(), data = try bridgeData()
		for lines in [["Q1 RETIRED 137"], ["Q1 PENDING 5", "Q1 RETIRED 137"], ["Q1 REFUSED 1"]] {
			var transcript = OwnedAutomationQueryWorker.BridgeTranscript()
			XCTAssertTrue(lines.allSatisfy { transcript.accept($0, arguments: args) })
			XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true))
			XCTAssertFalse(transcript.accept(data, arguments: args))
		}
		let setup = "Q1 SETUP getsid 1 0 0 1 0 0 0 1 0 0 1"
		var service = OwnedAutomationQueryWorker.BridgeTranscript()
		XCTAssertFalse(service.accept(setup, arguments: args))
		var fixture = OwnedAutomationQueryWorker.BridgeTranscript()
		XCTAssertTrue(fixture.accept(setup, arguments: bridgeArguments("fixture")))
		XCTAssertTrue(fixture.accept("Q1 REFUSED 1", arguments: bridgeArguments("fixture")))
		XCTAssertNil(fixture.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true))
	}

	func testSameImageDigestRefusesMissingChangedAndUnsupportedObservations() {
		let original = Data(repeating: 1, count: 20), changed = Data(repeating: 2, count: 20)
		XCTAssertTrue(OwnedAutomationQueryWorker.sameImageDigest(original, original))
		for observation in [nil, Data(), changed, Data(repeating: 1, count: 32)] as [Data?] {
			XCTAssertFalse(OwnedAutomationQueryWorker.sameImageDigest(original, observation))
		}
		XCTAssertFalse(OwnedAutomationQueryWorker.sameImageDigest(nil, original))
	}

	func testActualHeldSourceGenerationRejectsReplacementAndRestoration() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		defer { try? FileManager.default.removeItem(at: directory) }
		let current = directory.appendingPathComponent("owned-source"), retained = directory.appendingPathComponent("retained-source")
		try Data("original owned source fixture".utf8).write(to: current)
		let descriptor = current.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
		XCTAssertGreaterThanOrEqual(descriptor, 0)
		guard descriptor >= 0 else { return }
		defer { Darwin.close(descriptor) }
		let original = try XCTUnwrap(OwnedAutomationQueryWorker.SourceGeneration.descriptor(descriptor))
		XCTAssertEqual(OwnedAutomationQueryWorker.SourceGeneration.path(current.path), original)
		usleep(1000)
		try FileManager.default.moveItem(at: current, to: retained)
		try Data("replacement owned source fixture".utf8).write(to: current)
		XCTAssertNotEqual(OwnedAutomationQueryWorker.SourceGeneration.path(current.path), original)
		try FileManager.default.removeItem(at: current)
		try FileManager.default.moveItem(at: retained, to: current)
		XCTAssertNotEqual(OwnedAutomationQueryWorker.SourceGeneration.descriptor(descriptor), original)
		XCTAssertNotEqual(OwnedAutomationQueryWorker.SourceGeneration.path(current.path), original)
	}

	func testPermissionObservationIsFixedAndSeparateFromBusinessRoles() throws {
		let args = ["owned", "--automation-query-worker", "permission-observation", "19"]
		XCTAssertTrue(OwnedAutomationQueryWorker.validRequest(arguments: args))
		XCTAssertFalse(OwnedAutomationQueryWorker.validRequest(arguments: args + ["arbitrary-target"]))
		let statuses: [Int32] = [0, -600, -1743, -1744, Int32.min, Int32.max]
		for status in statuses {
			let packet = try XCTUnwrap(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 19, addressStatus: 0, permissionStatus: status))
			let bytes = try JSONSerialization.data(withJSONObject: packet)
			XCTAssertTrue(OwnedAutomationQueryWorker.bridgePacketMatches(bytes, arguments: args))
			XCTAssertFalse(OwnedAutomationQueryWorker.bridgePacketMatches(bytes, arguments: bridgeArguments()))
			XCTAssertNil(packet["status"])
			XCTAssertNil(packet["rows"])
		}
		XCTAssertNil(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 19, addressStatus: 0, permissionStatus: nil))
		XCTAssertNil(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 19, addressStatus: -50, permissionStatus: 0))
		XCTAssertNil(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 0, addressStatus: 0, permissionStatus: 0))
	}

	func testPermissionObservationRejectsPromptAndOpenDiagnosticGrammar() throws {
		let args = ["owned", "--automation-query-worker", "permission-observation", "19"]
		let original = try XCTUnwrap(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 19, addressStatus: 0, permissionStatus: 0))
		let changes: [(String, Any)] = [("ask_user", true), ("ask_user", 0), ("osstatus", true),
			("osstatus", 0.5), ("osstatus", Int64(Int32.max) + 1), ("observation", "granted"),
			("observation", "address-refused"), ("target", "arbitrary"), ("event_class", "****"),
			("event_id", "****"), ("nonce", 20), ("status", "observed"), ("rows", [] as [String])]
		for (key, value) in changes {
			var packet = original; packet[key] = value
			XCTAssertFalse(OwnedAutomationQueryWorker.bridgePacketMatches(try JSONSerialization.data(withJSONObject: packet), arguments: args), key)
		}
		var missing = original; missing.removeValue(forKey: "osstatus")
		XCTAssertFalse(OwnedAutomationQueryWorker.bridgePacketMatches(try JSONSerialization.data(withJSONObject: missing), arguments: args))
	}

	func testPermissionObservationStillRequiresExactNativeRetirement() throws {
		let args = ["owned", "--automation-query-worker", "permission-observation", "19"]
		let packet = try XCTUnwrap(OwnedAutomationQueryWorker.permissionObservationPacket(nonce: 19, addressStatus: 0, permissionStatus: -1744))
		let bytes = try JSONSerialization.data(withJSONObject: packet)
		var transcript = OwnedAutomationQueryWorker.BridgeTranscript()
		XCTAssertTrue(transcript.accept("Q1 HELD", arguments: args))
		XCTAssertTrue(transcript.accept("Q1 DATA " + bytes.base64EncodedString(), arguments: args))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true))
		XCTAssertTrue(transcript.accept("Q1 RETIRED 0", arguments: args))
		XCTAssertEqual(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: true), "Q1 DATA " + bytes.base64EncodedString())
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: true, beforeDeadline: true))
		XCTAssertNil(transcript.publishablePayload(guardianStatus: 0, cancelled: false, beforeDeadline: false))
	}
}

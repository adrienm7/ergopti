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

	init(executable: URL, operation: String) throws {
		process.executableURL = executable
		process.arguments = ["--automation-query-worker", operation, "19"]
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
}

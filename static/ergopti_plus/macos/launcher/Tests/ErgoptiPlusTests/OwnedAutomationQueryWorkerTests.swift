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

	func wait(_ predicate: () -> Bool) throws {
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		repeat {
			try poll()
			if predicate() { return }
			usleep(1000)
		} while ProcessInfo.processInfo.systemUptime < deadline
		throw NSError(domain: "query-native-timeout", code: 1)
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
}

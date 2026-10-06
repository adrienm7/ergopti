// Tests/ErgoptiPlusTests/OwnedProgramWorkerTests.swift
// Real signed-role/native-child regressions, executed by the macOS launcher lane.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

private final class OwnedProgramTestSession {
	let directory: URL
	let executable: URL
	let source: URL
	let process = Process()
	private let input = Pipe()
	private let output = Pipe()
	private let error = Pipe()
	private var decoder = OwnedProgramLineDecoder(maximumBytes: 128)
	private(set) var markers: [String] = []
	private(set) var stdout = Data()
	private(set) var stderr = Data()
	private var inputClosed = false

	init(executable: URL, payload: URL? = nil, arguments: [String], symlinkSource: Bool = false, sendInitialRequest: Bool = true, prepareFixture: ((URL) throws -> Void)? = nil) throws {
		self.executable = executable
		directory = FileManager.default.temporaryDirectory.appendingPathComponent("ergopti-owned-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		try prepareFixture?(directory)
		source = directory.appendingPathComponent("config.toml")
		// The source SHA preimage deliberately includes a BOM and decomposed text.
		let content = Data([0xef, 0xbb, 0xbf]) + Data("name = \"e\u{301}\"\n".utf8)
		try content.write(to: source)
		let sourcePath: URL
		if symlinkSource {
			sourcePath = directory.appendingPathComponent("config-link.toml")
			try FileManager.default.createSymbolicLink(at: sourcePath, withDestinationURL: source)
		} else { sourcePath = source }
		let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
		let descriptor: [String: Any] = [
			"version": 1, "executable": (payload ?? executable).path,
			"arguments": arguments.map { $0.replacingOccurrences(of: "@FIXTURE_DIR@", with: directory.path) },
			"source_path": sourcePath.path, "source_sha256": hash,
		]
		process.executableURL = executable
		process.arguments = ["--owned-program-worker"]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = error
		try process.run()
		guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		for handle in [output.fileHandleForReading, error.fileHandleForReading] {
			let flags = fcntl(handle.fileDescriptor, F_GETFL)
			guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
		}
		let request = try JSONSerialization.data(withJSONObject: descriptor) + Data([10])
		if sendInitialRequest { try input.fileHandleForWriting.write(contentsOf: request) }
	}

	func send(_ command: String) throws {
		guard !inputClosed else { throw NSError(domain: "OwnedProgramTest", code: 1) }
		try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
	}

	func sendIncompleteRequest() throws {
		try input.fileHandleForWriting.write(contentsOf: Data("{\"version\":1".utf8))
	}

	func closeInput() throws {
		guard !inputClosed else { return }
		try input.fileHandleForWriting.close()
		inputClosed = true
	}

	private func drain(_ handle: FileHandle) throws -> Data {
		var bytes = [UInt8](repeating: 0, count: 4096)
		let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
		if count >= 0 { return Data(bytes.prefix(count)) }
		if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return Data() }
		throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
	}

	func poll() throws {
		let bytes = try drain(output.fileHandleForReading)
		stdout.append(bytes)
		stderr.append(try drain(error.fileHandleForReading))
		guard stdout.count <= 128, stderr.isEmpty, decoder.append(bytes) else {
			throw NSError(domain: "OwnedProgramPrivateOutput", code: 1)
		}
		while let line = decoder.pop() {
			guard let text = String(data: line, encoding: .utf8), OwnedProgramWorker.validReceipt(text) else {
				throw NSError(domain: "OwnedProgramInvalidReceipt", code: 1)
			}
			markers.append(text)
		}
	}

	func wait(timeout: TimeInterval = 5, until predicate: () -> Bool) throws {
		let deadline = Date().addingTimeInterval(timeout)
		repeat {
			try poll()
			if predicate() { return }
			usleep(1_000)
		} while Date() < deadline
		throw NSError(domain: "OwnedProgramNativeTimeout", code: 1)
	}

	func finish() throws {
		try wait { !process.isRunning }
		process.waitUntilExit()
		try poll()
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, 0)
		XCTAssertTrue(decoder.buffered.isEmpty)
		XCTAssertTrue(stderr.isEmpty)
	}

	func cleanup() {
		// This independent fixture-only stop covers assertion failures without
		// weakening the production CANCEL/retirement assertions in the test body.
		do {
			// A broken FIFO source fence must fail its main assertion, then release
			// its blocked reader so fixture teardown can still obtain native proof.
			var sourceInfo = stat()
			if lstat(source.path, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFIFO {
				let fifo = Darwin.open(source.path, O_RDWR | O_NONBLOCK)
				if fifo >= 0 { Darwin.close(fifo) }
			}
			try Data().write(to: directory.appendingPathComponent("fixture.stop"))
			if process.isRunning && !inputClosed { try send("CANCEL") }
			try closeInput()
			try finish()
			guard markers.contains(where: { $0.hasPrefix("V1 RETIRED ") || $0.hasPrefix("V1 REFUSED ") }) else {
				XCTFail("native ownership was not proven retired; evidence retained at \(directory.path)")
				return
			}
			try FileManager.default.removeItem(at: directory)
		} catch {
			XCTFail("native cleanup remains unverified; evidence retained at \(directory.path)")
		}
	}
}

final class OwnedProgramWorkerTests: XCTestCase {
	private func launcherExecutable() throws -> URL {
		let products = Bundle(for: OwnedProgramWorkerTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
			XCTFail("the real native ErgoptiPlus SwiftPM executable is required")
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
		}
		return executable
	}

	func testLiteralRawUnicodeArgumentsRemainHeldUntilActivation() throws {
		let arguments = ["", "é", "e\u{301}", "日本語🙂", "literal\nnewline", "100%", "'\"$();"]
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/argv.json",
		] + arguments)
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		let result = session.directory.appendingPathComponent("argv.json")
		XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 0") }
		try session.finish()
		let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String])
		XCTAssertEqual(actual.map { Data($0.utf8) }, arguments.map { Data($0.utf8) })
		// Independent bytes prevent canonical-equivalence String equality masking
		// normalization of the two distinct accent representations.
		XCTAssertEqual(Data(actual[1].utf8), Data([0xc3, 0xa9]))
		XCTAssertEqual(Data(actual[2].utf8), Data([0x65, 0xcc, 0x81]))
		XCTAssertEqual(session.markers, ["V1 HELD", "V1 ACTIVE", "V1 RETIRED 0"])
	}

	func testSourceChangeBeforeActivationCannotProduceSideEffect() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/must-not-exist.json",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try Data("changed = true\n".utf8).write(to: session.source, options: .atomic)
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 137") }
		try session.finish()
		XCTAssertFalse(session.markers.contains("V1 ACTIVE"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("must-not-exist.json").path))
	}

	func testIndependentPOSIXScriptWithUnicodePathPreservesLiteralArgumentsAndPrivateStreams() throws {
		let scriptName = "fixture script é 日本語.sh"
		let values = [
			"", "Été 日本語🙂", "e\u{301}", "quote '\";",
			"$(touch '@FIXTURE_DIR@/interpolation-must-not-exist')",
			"`touch '@FIXTURE_DIR@/backtick-must-not-exist'`", "100%:%s", "line one\nline two",
		]
		// This independent POSIX script records actual positional bytes, rather
		// than calling a Swift fixture or reconstructing expected argv in native code.
		let script = #"""
		#!/bin/sh
		marker=$1
		shift
		printf '%s\000' "$@" > "$marker" || exit 74
		printf '%s\n' 'PRIVATE_POSIX_STDOUT_SENTINEL'
		printf '%s\n' 'PRIVATE_POSIX_STDERR_SENTINEL' >&2
		exit 37
		"""# + "\n"
		let session = try OwnedProgramTestSession(
			executable: launcherExecutable(), payload: URL(fileURLWithPath: "/bin/sh"),
			arguments: ["@FIXTURE_DIR@/" + scriptName, "@FIXTURE_DIR@/script-argv.bin"] + values,
			prepareFixture: { directory in
				let path = directory.appendingPathComponent(scriptName)
				try Data(script.utf8).write(to: path)
				try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
			}
		)
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		let recorded = session.directory.appendingPathComponent("script-argv.bin")
		XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path))
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 37") }
		try session.finish()
		var expected = Data()
		for value in values {
			expected.append(Data(value.replacingOccurrences(of: "@FIXTURE_DIR@", with: session.directory.path).utf8))
			expected.append(0)
		}
		XCTAssertEqual(try Data(contentsOf: recorded), expected)
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("interpolation-must-not-exist").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("backtick-must-not-exist").path))
		XCTAssertEqual(session.markers, ["V1 HELD", "V1 ACTIVE", "V1 RETIRED 37"])
		XCTAssertNil(session.stdout.range(of: Data("PRIVATE_POSIX".utf8)))
		XCTAssertTrue(session.stderr.isEmpty)
	}

	func testCancelledHeldPayloadNeverActivates() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/must-not-exist.json",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.send("CANCEL")
		try session.wait { session.markers.contains("V1 RETIRED 137") }
		try session.finish()
		XCTAssertFalse(session.markers.contains("V1 ACTIVE"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("must-not-exist.json").path))
	}

	func testSymlinkTargetChangedToFIFOCannotBlockCancellationOrExecutePayload() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/must-not-exist.json",
		], symlinkSource: true)
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try FileManager.default.removeItem(at: session.source)
		XCTAssertEqual(mkfifo(session.source.path, 0o600), 0)
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 137") }
		try session.finish()
		XCTAssertFalse(session.markers.contains("V1 ACTIVE"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("must-not-exist.json").path))
	}

	func testLeaderExitCannotSettleTermResistantOutputtingDescendant() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "parent-exit-live-child", "@FIXTURE_DIR@",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.send("ACTIVATE")
		let leaderFile = session.directory.appendingPathComponent("leader.json")
		try session.wait { FileManager.default.fileExists(atPath: leaderFile.path) }
		let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: leaderFile)) as? [String: NSNumber])
		let leader = try XCTUnwrap(metadata["pid"]).int32Value
		let child = try XCTUnwrap(metadata["child"]).int32Value
		try session.wait { ergopti_owned_program_observe(leader).nonlive }
		let before = ergopti_owned_program_observe(child)
		XCTAssertEqual(before.error_code, 0)
		XCTAssertEqual(before.process_group_id, leader)
		XCTAssertFalse(before.nonlive)
		XCTAssertFalse(session.markers.contains(where: { $0.hasPrefix("V1 RETIRED ") }))
		XCTAssertTrue(session.process.isRunning)
		try session.send("CANCEL")
		try session.wait { session.markers.contains("V1 RETIRED 0") }
		try session.finish()
		let after = ergopti_owned_program_observe(child)
		let sameIdentity = after.error_code == 0 && after.start_seconds == before.start_seconds
			&& after.start_microseconds == before.start_microseconds
		XCTAssertTrue(after.error_code == ESRCH || !sameIdentity || after.nonlive)
		XCTAssertLessThanOrEqual(session.stdout.count, 128)
		XCTAssertTrue(session.stderr.isEmpty)
	}

	func testLargePrivateStreamsNeverReachControlPipesAndNonzeroStatusIsExact() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "flood-exit", "@FIXTURE_DIR@/emitted-bytes.txt",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 37") }
		try session.finish()
		XCTAssertEqual(try String(contentsOf: session.directory.appendingPathComponent("emitted-bytes.txt"), encoding: .utf8), "67108864")
		XCTAssertEqual(session.markers, ["V1 HELD", "V1 ACTIVE", "V1 RETIRED 37"])
		XCTAssertNil(session.stdout.range(of: Data("PRIVATE_OWNED_PROGRAM".utf8)))
		XCTAssertTrue(session.stderr.isEmpty)
	}

	func testEOFWhileExitedLeaderHasLiveDescendantStillProvesGroupRetirement() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "parent-exit-live-child", "@FIXTURE_DIR@",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.send("ACTIVATE")
		let leaderFile = session.directory.appendingPathComponent("leader.json")
		try session.wait { FileManager.default.fileExists(atPath: leaderFile.path) }
		let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: leaderFile)) as? [String: NSNumber])
		let leader = try XCTUnwrap(metadata["pid"]).int32Value
		let child = try XCTUnwrap(metadata["child"]).int32Value
		try session.wait { ergopti_owned_program_observe(leader).nonlive }
		let before = ergopti_owned_program_observe(child)
		XCTAssertEqual(before.error_code, 0)
		XCTAssertFalse(before.nonlive)
		XCTAssertFalse(session.markers.contains(where: { $0.hasPrefix("V1 RETIRED ") }))
		try session.closeInput()
		try session.wait { session.markers.contains("V1 RETIRED 0") }
		try session.finish()
		let after = ergopti_owned_program_observe(child)
		let sameIdentity = after.error_code == 0 && after.start_seconds == before.start_seconds
			&& after.start_microseconds == before.start_microseconds
		XCTAssertTrue(after.error_code == ESRCH || !sameIdentity || after.nonlive)
	}

	func testEOFBeforeActivationCancelsPhysicalHeldChild() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/must-not-exist.json",
		])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.closeInput()
		try session.wait { session.markers.contains("V1 RETIRED 137") }
		try session.finish()
		XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("must-not-exist.json").path))
	}

	func testEOFBeforeAnyRequestReturnsProvenConstructorRefusal() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [], sendInitialRequest: false)
		defer { session.cleanup() }
		try session.closeInput()
		try session.wait { session.markers.contains("V1 REFUSED \(ECANCELED)") }
		try session.finish()
		XCTAssertEqual(session.markers, ["V1 REFUSED \(ECANCELED)"])
	}

	func testIncompleteRequestThenEOFReturnsProvenConstructorRefusal() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [], sendInitialRequest: false)
		defer { session.cleanup() }
		try session.sendIncompleteRequest()
		try session.closeInput()
		try session.wait { session.markers.contains("V1 REFUSED \(ECANCELED)") }
		try session.finish()
		XCTAssertEqual(session.markers, ["V1 REFUSED \(ECANCELED)"])
	}

	func testMissingExecutableReturnsClosedConstructorRefusal() throws {
		let missing = URL(fileURLWithPath: "/nonexistent-ergopti-owned-\(UUID().uuidString)")
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), payload: missing, arguments: [])
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 REFUSED \(ENOENT)") }
		try session.finish()
		XCTAssertEqual(session.markers, ["V1 REFUSED \(ENOENT)"])
	}

	func testExistingSymlinkedCanonicalSourceStillAdmitsRawPreimage() throws {
		let session = try OwnedProgramTestSession(executable: launcherExecutable(), arguments: [
			ownedProgramFixtureFlag, "argv", "@FIXTURE_DIR@/argv.json", "symlink source",
		], symlinkSource: true)
		defer { session.cleanup() }
		try session.wait { session.markers.contains("V1 HELD") }
		try session.send("ACTIVATE")
		try session.wait { session.markers.contains("V1 RETIRED 0") }
		try session.finish()
		XCTAssertEqual(session.markers, ["V1 HELD", "V1 ACTIVE", "V1 RETIRED 0"])
		XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("argv.json").path))
	}

	func testMalformedRequestsAndReceiptsFailClosedWithoutQuotingSecrets() {
		XCTAssertNil(OwnedProgramRequest.parse(Data("{\"version\":true}".utf8)))
		XCTAssertFalse(OwnedProgramWorker.validReceipt("V1 RETIRED PRIVATE_SECRET"))
		XCTAssertFalse(OwnedProgramWorker.validReceipt("V1 RETIRED -1"))
		XCTAssertFalse(OwnedProgramWorker.validReceipt("V1 RETIRED 256"))
		XCTAssertFalse(OwnedProgramWorker.validReceipt("V1 PENDING -1"))
		XCTAssertFalse(OwnedProgramWorker.validReceipt("V1 RETIRED 037"))
		var decoder = OwnedProgramLineDecoder(maximumBytes: 8)
		XCTAssertTrue(decoder.append(Data("ACTIVATE".utf8)))
		XCTAssertFalse(decoder.append(Data([10])))
		XCTAssertEqual(decoder.buffered, Data("ACTIVATE".utf8))
	}
}

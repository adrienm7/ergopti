// Tests/ErgoptiPlusTests/OwnedSuspendedImageTests.swift
// Genuine SDK image/owner controls; no bearer is released before IMAGE_READY.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

private final class SuspendedImageNativeSession {
	let directory: URL
	let alias: URL
	let session: URL
	let process = Process()
	let input = Pipe()
	let output = Pipe()
	let error = Pipe()
	var sessionWriter: FileHandle
	var outgoingDescriptor: Int32 = -1
	var markers: [String] = []
	var decoder = OwnedProgramLineDecoder(maximumBytes: 1024)
	var inputClosed = false
	var outputEOF = false
	var errorEOF = false
	var outputClosed = false
	var errorClosed = false
	var receivingCloseFailed = false
	let loggedFixture: Bool

	init(launcher: URL, inodeDelta: UInt64 = 0, prefillSession: Bool = false, listenerEvent: Bool = false, loggedFixture: Bool = false) throws {
		self.loggedFixture = loggedFixture
		let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
		directory = temporary.appendingPathComponent("ergopti-image-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		let runtime = directory.appendingPathComponent("Library/Application Support/Ergopti/ollama-native-http")
		try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
		alias = runtime.appendingPathComponent(".ergopti-image-0123456789abcdef0123456789abcdef")
		try FileManager.default.copyItem(at: URL(fileURLWithPath: loggedFixture ? "/bin/sh" : "/usr/bin/true"), to: alias)
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: alias.path)
		let sessions = directory.appendingPathComponent("Library/Application Support/Ergopti/ollama-native-sessions")
		try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		session = sessions.appendingPathComponent("daemon-0123456789abcdef0123456789abcdef.json")
		let descriptor = Darwin.open(session.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
		sessionWriter = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		if prefillSession { try sessionWriter.write(contentsOf: Data("UNRELEASED_FIXTURE_KEY".utf8)); try sessionWriter.synchronize() }
		var image = stat()
		guard lstat(alias.path, &image) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
		// The test bundle's actual compiled SwiftPM product supplies the source
		// context. Caller-selected bytes cannot bypass this original copy fence.
		let worker = directory.appendingPathComponent("OwnedOutgoingHTTP.app/Contents/MacOS/ErgoptiPlus")
		try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
		let compiledBytes = try Data(contentsOf: launcher)
		try FileManager.default.copyItem(at: launcher, to: worker)
		guard try Data(contentsOf: worker) == compiledBytes else { throw NSError(domain: "OutgoingSourceCopy", code: 1) }
		for arguments in [["--force", "-s", "-", worker.path], ["--verify", "--strict", worker.path]] {
			let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
			signer.arguments = arguments
			signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
			try signer.run(); signer.waitUntilExit()
			guard signer.terminationReason == .exit, signer.terminationStatus == 0 else {
				throw NSError(domain: "OutgoingNativeCodesign", code: 1)
			}
		}
		outgoingDescriptor = Darwin.open(worker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		var outgoing = stat()
		guard outgoingDescriptor >= 0, fstat(outgoingDescriptor, &outgoing) == 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		let outgoingSHA = SHA256.hash(data: try Data(contentsOf: worker)).map { String(format: "%02x", $0) }.joined()
		var request: [String: Any] = [
			"version": 1, "executable": alias.path, "arguments": ["serve"],
			"device": String(UInt64(UInt32(bitPattern: image.st_dev))), "inode": String(UInt64(image.st_ino) + inodeDelta),
			"session_path": session.path, "remaining_ms": 10_000, "home": directory.path,
			"models_path": "", "network_policy": directory.appendingPathComponent("policy.json").path,
			"host": "127.0.0.1:11434", "proxy_url": "",
			"outgoing_worker": worker.path, "outgoing_device": String(UInt64(UInt32(bitPattern: outgoing.st_dev))),
			"outgoing_inode": String(UInt64(outgoing.st_ino)), "outgoing_sha256": outgoingSHA,
		]
		if listenerEvent { request["listener_event"] = true }
		if loggedFixture {
			let logs = directory.appendingPathComponent("logs")
			try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			request["log_directory"] = logs.path
			let script = "printf 'stdout '\nprintf 'stderr ' >&2\nprintf 'split\\nstdout tail'\nprintf 'split\\nstderr tail' >&2\n"
			try Data(script.utf8).write(to: directory.appendingPathComponent("serve"), options: .withoutOverwriting)
			process.currentDirectoryURL = directory
		}
		process.executableURL = launcher
		process.arguments = [OwnedSuspendedImageGuardian.flag]
		process.standardInput = input; process.standardOutput = output; process.standardError = error
		try process.run()
		var initialized = false
		defer { if loggedFixture && !initialized { cleanup() } }
		guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		for handle in [output.fileHandleForReading, error.fileHandleForReading] {
			let flags = fcntl(handle.fileDescriptor, F_GETFL)
			guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
		}
		try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
		initialized = true
	}

	func poll() throws {
		for handle in [output.fileHandleForReading, error.fileHandleForReading] {
			if handle === output.fileHandleForReading ? outputClosed : errorClosed { continue }
			var bytes = [UInt8](repeating: 0, count: 1024)
			let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
			if count > 0 {
				guard handle === output.fileHandleForReading, decoder.append(Data(bytes.prefix(count))) else {
					throw NSError(domain: "SuspendedImagePrivateOutput", code: 1)
				}
				while let line = decoder.pop() {
					guard let text = String(data: line, encoding: .utf8) else { throw NSError(domain: "SuspendedImageReceipt", code: 1) }
					markers.append(text)
				}
			} else if count == 0 {
				if handle === output.fileHandleForReading { outputEOF = true } else { errorEOF = true }
			} else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
			}
		}
	}
	func wait(until predicate: () -> Bool) throws {
		let deadline = Date().addingTimeInterval(15)
		repeat { try poll(); if predicate() { return }; usleep(1_000) } while Date() < deadline
		throw NSError(domain: "SuspendedImageNativeTimeout", code: 1)
	}
	func send(_ command: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
	func closeInput() throws {
		guard !inputClosed else { return }
		try input.fileHandleForWriting.close(); inputClosed = true
	}
	func finish() throws {
		try wait { !process.isRunning && (!loggedFixture || (outputEOF && errorEOF)) }; process.waitUntilExit(); try poll()
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, 0)
		XCTAssertTrue(decoder.buffered.isEmpty)
	}
	func closeLoggedReceiving() throws {
		guard loggedFixture, !process.isRunning, !receivingCloseFailed, outputEOF, errorEOF,
			markers.last == "V1 RETIRED 0 1 1 0 0 0 0", markers.contains("V1 LOGS_CLOSED 0") else {
			throw NSError(domain: "SuspendedImageLogClosure", code: 1)
		}
		if !outputClosed {
			outputClosed = true
			do { try output.fileHandleForReading.close() }
			catch { receivingCloseFailed = true; throw error }
		}
		if !errorClosed {
			errorClosed = true
			do { try error.fileHandleForReading.close() }
			catch { receivingCloseFailed = true; throw error }
		}
	}
	func cleanup() {
		do {
			if process.isRunning && !inputClosed { try send("CANCEL") }
			try closeInput(); try finish()
			guard markers.contains(where: { $0.hasPrefix("V1 RETIRED ") || $0.hasPrefix("V1 REFUSED ") }) else {
				XCTFail("native retirement remains unproven; retained \(directory.path)"); return
			}
			if loggedFixture { try closeLoggedReceiving() }
			try sessionWriter.close()
			guard Darwin.close(outgoingDescriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			outgoingDescriptor = -1
			try FileManager.default.removeItem(at: directory)
		} catch { XCTFail("native cleanup remains unproven; retained \(directory.path)") }
	}
}

final class OwnedSuspendedImageTests: XCTestCase {
	private func launcher() throws -> URL {
		let products = Bundle(for: OwnedSuspendedImageTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		return try XCTUnwrap(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
	}
	func testCanonicalIntegerIdentityAndPublicOnlyEnvironmentCannotBeRoundedOrExtended() throws {
		let home = "/private/tmp/ergopti-image-request-test"
		let request: [String: Any] = [
			"version": 1, "executable": home + "/Library/Application Support/Ergopti/ollama-native-http/.ergopti-image-0123456789abcdef0123456789abcdef",
			"arguments": ["serve"], "device": "1", "inode": "18446744073709551615",
			"session_path": home + "/Library/Application Support/Ergopti/ollama-native-sessions/daemon-0123456789abcdef0123456789abcdef.json",
			"remaining_ms": 1000, "home": home, "models_path": "", "network_policy": home + "/policy.json",
			"host": "127.0.0.1:11434", "proxy_url": "",
		]
		func parse(_ fields: [String: Any]) throws -> OwnedSuspendedImageRequest? {
			OwnedSuspendedImageRequest.parse(try JSONSerialization.data(withJSONObject: fields), launcher: "/usr/bin/true")
		}
		XCTAssertEqual(try XCTUnwrap(parse(request)).inode, UInt64.max)
		let rejected: [(String, Any)] = [
			("device", NSNumber(value: 1)), ("device", "4294967296"), ("inode", "01"),
			("inode", "18446744073709551616"), ("inode", "-1"), ("version", true),
			("remaining_ms", NSNumber(value: 1.5)), ("proxy_url", "http://secret:secret@127.0.0.1:8080"),
			("host", "127.0.0.1:011434"), ("arguments", ["serve", "--secret"]),
			("environment", ["PRIVATE_KEY": "not-admitted"]), ("session_path", home + "/foreign.json"),
		]
		for (field, value) in rejected { var altered = request; altered[field] = value; XCTAssertNil(try parse(altered), field) }
	}
	func testHeldMappedIdentityPrecedesEverySessionByteAndActivation() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher()); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		let fields = try XCTUnwrap(fixture.markers.first).split(separator: " ")
		XCTAssertEqual(fields.count, 8)
		let child = try XCTUnwrap(Int32(fields[2]))
		let observed = ergopti_owned_program_observe(child)
		XCTAssertEqual(observed.error_code, 0); XCTAssertEqual(observed.process_group_id, child)
		XCTAssertEqual(observed.start_seconds, try XCTUnwrap(UInt64(fields[4]))); XCTAssertEqual(observed.start_microseconds, try XCTUnwrap(UInt64(fields[5])))
		XCTAssertFalse(observed.nonlive)
		XCTAssertEqual(try Data(contentsOf: fixture.session).count, 0)
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE"))
		try fixture.sessionWriter.write(contentsOf: Data("POST_IMAGE_PROOF_FIXTURE_KEY".utf8)); try fixture.sessionWriter.synchronize()
		try fixture.send("ACTIVATE"); try fixture.finish()
		XCTAssertTrue(fixture.markers.contains("V1 ACTIVE")); XCTAssertEqual(fixture.markers.last, "V1 RETIRED 0 1 1 0 0 0 0")
	}
	func testWrongCatalogueInodeNeverPublishesImageReadyOrActivation() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher(), inodeDelta: 1); defer { fixture.cleanup() }
		try fixture.finish()
		XCTAssertFalse(fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }))
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE")); XCTAssertEqual(fixture.markers.last, "V1 RETIRED 137 1 1 0 0 0 0")
		XCTAssertEqual(try Data(contentsOf: fixture.session).count, 0)
	}
	func testCallerEOFPhysicallyRetiresMappedHeldLeader() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher()); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		try fixture.closeInput(); try fixture.finish()
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE")); XCTAssertEqual(fixture.markers.last, "V1 RETIRED 137 1 1 0 0 0 0")
	}
	func testReplacedNamedImageBeforeActivationCannotResumeTheHeldLeader() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher()); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		try FileManager.default.moveItem(at: fixture.alias, to: fixture.directory.appendingPathComponent("old-image"))
		try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: fixture.alias)
		try fixture.sessionWriter.write(contentsOf: Data("POST_IMAGE_PROOF_FIXTURE_KEY".utf8)); try fixture.sessionWriter.synchronize()
		try fixture.send("ACTIVATE"); try fixture.finish()
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE")); XCTAssertEqual(fixture.markers.last, "V1 RETIRED 137 1 1 0 0 0 0")
	}
	func testNonemptySessionIsRefusedBeforeAnyImageOwnerIsPrepared() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher(), prefillSession: true); defer { fixture.cleanup() }
		try fixture.finish()
		XCTAssertEqual(fixture.markers, ["V1 REFUSED \(ESTALE)"])
	}

	func testOptionalListenerEventMissingConnectionNeverClaimsBoundOrReady() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher(), listenerEvent: true); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		try fixture.sessionWriter.write(contentsOf: Data("POST_IMAGE_PROOF_FIXTURE_KEY".utf8)); try fixture.sessionWriter.synchronize()
		try fixture.send("ACTIVATE"); try fixture.finish()
		XCTAssertTrue(fixture.markers.contains("V1 ACTIVE"))
		XCTAssertFalse(fixture.markers.contains(where: { $0.hasPrefix("V1 LISTENER_BOUND ") || $0.hasPrefix("V1 READY") }))
		XCTAssertEqual(fixture.markers.last, "V1 RETIRED 0 1 1 0 0 0 0")
	}
	func testOptionalListenerEventCancelledBeforeActivationClosesAllOriginalOwners() throws {
		let fixture = try SuspendedImageNativeSession(launcher: launcher(), listenerEvent: true); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		try fixture.send("CANCEL"); try fixture.finish()
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE"))
		XCTAssertFalse(fixture.markers.contains(where: { $0.hasPrefix("V1 LISTENER_BOUND ") }))
		XCTAssertEqual(fixture.markers.last, "V1 RETIRED 137 1 1 0 0 0 0")
	}
 private func receiveNativeListenerEvent(_ mode: String) throws {
  let process = Process(); let output = Pipe(); let error = Pipe()
  process.executableURL = try launcher()
  process.arguments = [OwnedListenerEventFixture.flag, mode]
  process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output; process.standardError = error
  try process.run(); process.waitUntilExit()
  XCTAssertEqual(process.terminationReason, .exit)
  XCTAssertEqual(process.terminationStatus, 0, mode)
  XCTAssertEqual(try output.fileHandleForReading.readToEnd(), Data("ERGOPTI_LISTENER_EVENT_CONTROL pass=1\n".utf8))
  XCTAssertEqual(error.fileHandleForReading.readDataToEndOfFile(), Data())
  try output.fileHandleForReading.close(); try error.fileHandleForReading.close()
 }
 func testActualUnixOriginalMappedPeerFrameAndEOFAdmitted() throws { try receiveNativeListenerEvent("positive") }
 func testActualUnixForkedDescendantCannotImpersonateOriginalMappedPeer() throws { try receiveNativeListenerEvent("descendant") }
 func testActualUnixMissingWriterEOFNeverGrantsListenerEvent() throws { try receiveNativeListenerEvent("missing-eof") }
 func testActualUnixCancellationBeforeAcquisitionRetiresExactNativeOwner() throws { try receiveNativeListenerEvent("cancel-acquisition") }
 func testActualUnixForeignReplacementSurvivesConditionalNamespaceCleanup() throws { try receiveNativeListenerEvent("namespace-replacement") }
 func testActualUnixCloseEBADFRemainsRetainedAfterEveryAttempt() throws { try receiveNativeListenerEvent("uncertain-close") }

}

/// Genuine pipe/file controls plus one real guardian/mapped-shell composition.
/// These controls do not qualify an actual packaged Ollama daemon.
final class SuspendedImageLogCaptureTests: XCTestCase {
	private func directory() throws -> URL {
		let value = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("ergopti-native-daily-log-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		return value
	}
	private func cleanup(_ directory: URL, capture: SuspendedImageLogCapture) {
		addTeardownBlock {
			capture.closeWriters()
			// Unknown close debt retains this fixture's inputs. Never erase them
			// merely because the SDK test method returned or an assertion failed.
			if capture.settleAfterRetirement() { try FileManager.default.removeItem(at: directory) }
		}
	}
	private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) throws -> Date {
		var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
		return try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
			hour: hour, minute: minute, second: second)))
	}
	private func write(_ data: Data, to descriptor: Int32) {
		XCTAssertEqual(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, data.count) }, data.count)
	}
	func testNativeSplitRecordsAndFinalTailsUseWriteTimeDay() throws {
		let root = try directory()
		var now = try date(10, 23, 59, 58)
		let capture = SuspendedImageLogCapture(directory: root.path, sink: LoggerRecordSink(now: { now }))
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		let descriptors = capture.readDescriptors + [capture.outputDescriptor, capture.errorDescriptor]
		write(Data("before\nsplit".utf8), to: capture.outputDescriptor); capture.drain()
		now = try date(11, 0, 0, 1)
		write(Data(" continuation\n".utf8), to: capture.outputDescriptor)
		write(Data("stderr tail".utf8), to: capture.errorDescriptor); capture.drain()
		XCTAssertFalse(capture.settleAfterRetirement(), "parent writers are still live")
		capture.closeWriters()
		XCTAssertTrue(capture.settleAfterRetirement())
		XCTAssertTrue(capture.settleAfterRetirement(), "tail publication is exactly once")
		XCTAssertEqual(capture.writeError, 0)
		XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ErgoptiPlus_2026-10-10.log"), encoding: .utf8),
			"23:59:58 [OLLAMA-SERVER] before\n")
		XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ErgoptiPlus_2026-10-11.log"), encoding: .utf8),
			"00:00:01 [OLLAMA-SERVER] split continuation\n00:00:01 [OLLAMA-SERVER] stderr tail\n")
		for descriptor in descriptors { errno = 0; XCTAssertEqual(fcntl(descriptor, F_GETFD), -1); XCTAssertEqual(errno, EBADF) }
	}
	func testInheritedWriterBlocksEOFAndFinalTailSettlement() throws {
		let root = try directory()
		let capture = SuspendedImageLogCapture(directory: root.path)
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		let inherited = Darwin.dup(capture.outputDescriptor)
		var inheritedToClose = inherited
		defer {
			if inheritedToClose >= 0 {
				let descriptor = inheritedToClose
				inheritedToClose = -1
				XCTAssertEqual(Darwin.close(descriptor), 0)
			}
		}
		XCTAssertGreaterThan(inherited, 2)
		write(Data("last tail".utf8), to: inherited)
		capture.closeWriters()
		XCTAssertFalse(capture.settleAfterRetirement())
		XCTAssertFalse(capture.settled)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
		inheritedToClose = -1
		XCTAssertEqual(Darwin.close(inherited), 0)
		XCTAssertTrue(capture.settleAfterRetirement())
		XCTAssertEqual(capture.writeError, 0)
	}
	func testPipeCloseUncertaintyRemainsStickyWithoutNumericRetry() throws {
		let root = try directory(); let sink = LoggerRecordSink()
		var closes = 0
		let capture = SuspendedImageLogCapture(directory: root.path, sink: sink, closeOperation: { descriptor in
			closes += 1; let status = Darwin.close(descriptor)
			if closes == 1 { errno = EINTR; return -1 }; return status
		})
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		capture.closeWriters(); XCTAssertEqual(capture.closeError, EINTR)
		XCTAssertFalse(capture.settleAfterRetirement())
		let count = closes
		XCTAssertFalse(capture.settleAfterRetirement()); capture.closeWriters()
		XCTAssertEqual(closes, count, "the original numeric descriptors are not closed twice")
		XCTAssertTrue(sink.settleOwnedResources(), "only the fixture closes its known sink after refusal")
	}
	func testSinkCloseUncertaintyBlocksSuccessfulRetirement() throws {
		let root = try directory(); var closes = 0
		let sink = LoggerRecordSink(closeOperation: { descriptor in
			closes += 1; let status = Darwin.close(descriptor)
			if closes == 1 { errno = EINTR; return -1 }; return status
		})
		let capture = SuspendedImageLogCapture(directory: root.path, sink: sink)
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		write(Data("record\n".utf8), to: capture.outputDescriptor); capture.closeWriters()
		XCTAssertFalse(capture.settleAfterRetirement())
		XCTAssertEqual(sink.ownedCloseError, EINTR)
		let count = closes
		XCTAssertFalse(capture.settleAfterRetirement()); XCTAssertEqual(closes, count)
		XCTAssertFalse(capture.settled)
	}
	func testInvalidUTF8RefusesLogSuccessButClosesRealPipes() throws {
		let root = try directory(); let capture = SuspendedImageLogCapture(directory: root.path)
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		write(Data([0xff, 10]), to: capture.errorDescriptor); capture.closeWriters()
		XCTAssertTrue(capture.settleAfterRetirement(), "actual closure and successful writes are different facts")
		XCTAssertEqual(capture.writeError, EILSEQ)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
	}
	func testReplacedConfiguredDirectoryRefusesBothOldAndForeignSink() throws {
		let root = try directory(); let capture = SuspendedImageLogCapture(directory: root.path)
		cleanup(root, capture: capture)
		XCTAssertEqual(capture.setupError, 0)
		let original = root.appendingPathExtension("original")
		try FileManager.default.moveItem(at: root, to: original)
		addTeardownBlock { if capture.settled { try FileManager.default.removeItem(at: original) } }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		write(Data("refused\n".utf8), to: capture.outputDescriptor); capture.closeWriters()
		XCTAssertTrue(capture.settleAfterRetirement())
		XCTAssertEqual(capture.writeError, EIO)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: original.path), [])
	}
	func testActualGuardianMappedShellBothStreamsAndFinalTailsPersistBeforeRetirement() throws {
		let products = Bundle(for: OwnedSuspendedImageTests.self).bundleURL.deletingLastPathComponent()
		let launchers = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		let launcher = try XCTUnwrap(launchers.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
		let began = Date()
		let fixture = try SuspendedImageNativeSession(launcher: launcher, loggedFixture: true)
		defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains(where: { $0.hasPrefix("V1 IMAGE_READY ") }) }
		XCTAssertEqual(fixture.markers.count, 1)
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE"))
		XCTAssertEqual(try Data(contentsOf: fixture.session), Data())
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("logs").path), [])
		let ready = try XCTUnwrap(fixture.markers.first).split(separator: " ")
		XCTAssertEqual(ready.count, 8)
		let child = try XCTUnwrap(Int32(ready[2]))
		let observed = ergopti_owned_program_observe(child)
		XCTAssertEqual(observed.error_code, 0)
		XCTAssertEqual(observed.process_group_id, child)
		XCTAssertEqual(observed.start_seconds, try XCTUnwrap(UInt64(ready[4])))
		XCTAssertEqual(observed.start_microseconds, try XCTUnwrap(UInt64(ready[5])))
		XCTAssertFalse(observed.nonlive)
		try fixture.sessionWriter.write(contentsOf: Data("POST_IMAGE_PROOF_FIXTURE_KEY".utf8))
		try fixture.sessionWriter.synchronize()
		try fixture.send("ACTIVATE")
		try fixture.finish()
		let ended = Date()
		XCTAssertEqual(Array(fixture.markers.dropFirst()), ["V1 ACTIVE", "V1 LOGS_CLOSED 0", "V1 OUTGOING_CLOSED 0", "V1 RETIRED 0 1 1 0 0 0 0"])
		XCTAssertFalse(fixture.process.isRunning)
		XCTAssertTrue(fixture.outputEOF)
		XCTAssertTrue(fixture.errorEOF)
		try fixture.closeLoggedReceiving()
		try fixture.closeInput()
		XCTAssertTrue(fixture.outputClosed)
		XCTAssertTrue(fixture.errorClosed)
		XCTAssertFalse(fixture.receivingCloseFailed)
		let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
		formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
		let allowedDays = Set([formatter.string(from: began), formatter.string(from: ended)])
		let logs = fixture.directory.appendingPathComponent("logs")
		let names = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
		XCTAssertFalse(names.isEmpty)
		var records: [String] = []
		for name in names {
			XCTAssertTrue(allowedDays.contains(where: { name == "ErgoptiPlus_\($0).log" }))
			let bytes = try Data(contentsOf: logs.appendingPathComponent(name))
			XCTAssertEqual(bytes.last, 10)
			let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
			for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
				XCTAssertNotNil(String(line).range(of: "^[0-9]{2}:[0-9]{2}:[0-9]{2} \\[OLLAMA-SERVER\\] (stdout split|stdout tail|stderr split|stderr tail)$", options: .regularExpression))
				records.append(String(line.dropFirst("00:00:00 [OLLAMA-SERVER] ".count)))
			}
		}
		XCTAssertEqual(records.sorted(), ["stderr split", "stderr tail", "stdout split", "stdout tail"])
		XCTAssertEqual(records.filter { $0.hasPrefix("stdout") }, ["stdout split", "stdout tail"])
		XCTAssertEqual(records.filter { $0.hasPrefix("stderr") }, ["stderr split", "stderr tail"])
	}

}

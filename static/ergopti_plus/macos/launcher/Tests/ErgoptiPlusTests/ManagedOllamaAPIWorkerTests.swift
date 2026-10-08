// Tests/ErgoptiPlusTests/ManagedOllamaAPIWorkerTests.swift
// Real SDK accepted-socket provenance precedes every literal API byte.

import CryptoKit
import Darwin
import Foundation
import Sparkle
import XCTest
@testable import ErgoptiPlus

private final class ManagedOllamaTestSession {
	enum Failure: Error { case prerequisite, deadline, process, framing }
	let root: URL
	let runtime: URL
	let original: URL
	let peer = Process()
	private let peerDiagnostics = Pipe()
	let profile: [String: Any]
	let device: String
	let inode: String
	private var closed = false
	init(mode: String = "length", connections: Int = 2, foreign: Bool = false, retainedMachO: Bool = false) throws {
		let manager = FileManager.default
		root = manager.temporaryDirectory.appendingPathComponent("ergopti-native-listener-" + UUID().uuidString).resolvingSymlinksInPath()
		runtime = root.appendingPathComponent("Library/Application Support/Ergopti/ollama-native-http/ollama")
		let products = Bundle(for: ManagedOllamaAPIWorkerTests.self).bundleURL.deletingLastPathComponent()
		let candidates = [products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
		guard let launcher = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) else { throw Failure.prerequisite }
		original = launcher
		try manager.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		try manager.copyItem(at: original, to: runtime)
		let frameworks = runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
		try manager.createDirectory(at: frameworks, withIntermediateDirectories: false)
		try manager.copyItem(at: Bundle(for: SPUUpdater.self).bundleURL, to: frameworks.appendingPathComponent("Sparkle.framework"))
		var native = stat()
		guard lstat(runtime.path, &native) == 0 else { throw Failure.prerequisite }
		device = String(UInt32(bitPattern: native.st_dev)); inode = String(UInt64(native.st_ino))
		peer.executableURL = foreign ? original : runtime
		peer.arguments = [retainedMachO ? ManagedOllamaListenerFixture.retainedFlag : ManagedOllamaListenerFixture.flag, root.path, mode, String(connections)]
		var environment = ProcessInfo.processInfo.environment; environment["HOME"] = root.path; peer.environment = environment
		peer.standardInput = FileHandle.nullDevice; peer.standardOutput = FileHandle.nullDevice; peer.standardError = peerDiagnostics
		try peer.run(); try peerDiagnostics.fileHandleForWriting.close()
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		var value: [String: Any]?
		while ProcessInfo.processInfo.systemUptime < deadline {
			if let bytes = try? Data(contentsOf: root.appendingPathComponent("profile.json")),
				let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { value = fields; break }
			guard peer.isRunning else {
				peer.waitUntilExit()
				let bytes = peerDiagnostics.fileHandleForReading.readDataToEndOfFile()
				try peerDiagnostics.fileHandleForReading.close()
				let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
				print("ERGOPTI_PEER_EXIT status=\(peer.terminationStatus) reason=\(peer.terminationReason.rawValue) dyld_library_missing=\(text.contains("Library not loaded:") ? 1 : 0) code_signature_failure=\(text.contains("code signature") ? 1 : 0)")
				for line in text.split(separator: "\n").prefix(16) {
					if line.hasPrefix("ERGOPTI_RETAINED_IMAGE_") && line.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) { print(line) }
				}
				throw Failure.process
			}
			usleep(10_000)
		}
		guard let value else { peer.terminate(); peer.waitUntilExit(); throw Failure.deadline }
		profile = value
	}
	deinit {
		if !closed && peer.isRunning { peer.terminate(); peer.waitUntilExit() }
		if !closed { try? FileManager.default.removeItem(at: root) }
	}
	func common() -> [String: Any] {
		return ["version": 1, "executable": runtime.path, "device": device, "inode": inode,
			"port": profile["port"]!, "timeout_ms": 5_000]
	}
	func request(identity: [String: Any], post: Bool = false) -> [String: Any] {
		var fields = common()
		for key in ["pid", "start_seconds", "start_microseconds"] { fields[key] = identity[key] }
		fields["method"] = post ? "POST" : "GET"
		fields["path"] = post ? "/api/pull" : "/api/ergopti-native-http-admission"
		let body = post ? "{\"name\":\"independent-literal\"}" : ""
		fields["body"] = body
		fields["idle_ms"] = 5_000
		let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
		fields["headers"] = [["X-Ergopti-Native-Session", String(repeating: "a", count: 64)],
			["X-Ergopti-Native-Challenge", String(repeating: "b", count: 64)],
			["X-Ergopti-Native-Body-SHA256", digest]]
		if post { fields["headers"] = (fields["headers"] as! [[String]]) + [["X-Ergopti-Native-Operation", String(repeating: "c", count: 32)]] }
		return fields
	}
	func worker(_ fields: [String: Any], probe: Bool) throws -> (Int32, [(UInt8, Data)]) {
		let process = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
		process.executableURL = original
		if probe { process.arguments = [ManagedOllamaAPIWorker.probeFlag, "5000"] } else {
			let absolute = fields["timeout_ms"] is NSNull ? "none" : String((fields["timeout_ms"] as! NSNumber).intValue)
			process.arguments = [ManagedOllamaAPIWorker.requestFlag, String((fields["idle_ms"] as! NSNumber).intValue), absolute]
		}
		var environment = ProcessInfo.processInfo.environment; environment["HOME"] = root.path
		environment["ERGOPTI_MANAGED_LISTENER_DIAGNOSTICS"] = "1"
		if let knownPeer = profile["pid"] as? NSNumber, knownPeer.int64Value > 0, knownPeer.int64Value <= Int64(Int32.max) {
			environment["ERGOPTI_MANAGED_LISTENER_DIAGNOSTIC_PID"] = String(knownPeer.int64Value)
		}
		process.environment = environment
		process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
		try process.run(); try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
		try diagnostics.fileHandleForWriting.close()
		var payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]); payload.append(10)
		try input.fileHandleForWriting.write(contentsOf: payload); try input.fileHandleForWriting.close()
		guard ManagedPTYWorker.nonblocking(output.fileHandleForReading.fileDescriptor) else { throw Failure.process }
		var bytes = Data(), eof = false
		let deadline = ProcessInfo.processInfo.systemUptime + 8
		while ProcessInfo.processInfo.systemUptime < deadline && (!eof || process.isRunning) {
			var buffer = [UInt8](repeating: 0, count: 8192)
			let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
			if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
			else if count == 0 { eof = true }
			else if ![EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { process.terminate(); process.waitUntilExit(); throw Failure.process }
			usleep(1_000)
		}
		guard eof && !process.isRunning else { process.terminate(); process.waitUntilExit(); throw Failure.deadline }
		process.waitUntilExit(); try output.fileHandleForReading.close()
		let diagnosticBytes = diagnostics.fileHandleForReading.readDataToEndOfFile()
		try diagnostics.fileHandleForReading.close()
		for line in String(decoding: diagnosticBytes.prefix(4096), as: UTF8.self).split(separator: "\n").prefix(16) {
			if line.hasPrefix("ERGOPTI_LISTENER_DIAGNOSTIC "), line.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
				print(line)
			} else if line.range(of: #"^ERGOPTI_KNOWN_PEER_(LEXICAL|PHYSICAL)_DIAGNOSTIC listed=[01] pathreceived=[01] pathmatches=[01] uidmatches=[01] devicematches=[01] inodematches=[01] list_errno=[0-9]{1,5} path_errno=[0-9]{1,5} stat_errno=[0-9]{1,5} canonical_errno=[0-9]{1,5}$"#, options: .regularExpression) != nil {
				print(line)
			}
		}
		var frames: [(UInt8, Data)] = [], offset = 0
		while offset < bytes.count {
			guard bytes.count - offset >= 5 else { throw Failure.framing }
			let length = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
			guard length > 0 && length <= 65_536, Int(length) <= bytes.count - offset - 4 else { throw Failure.framing }
			frames.append((bytes[offset + 4], Data(bytes[(offset + 5)..<(offset + 4 + Int(length))])))
			offset += 4 + Int(length)
		}
		return (process.terminationStatus, frames)
	}
	func finish() throws {
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		while peer.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
		guard !peer.isRunning else { peer.terminate(); peer.waitUntilExit(); throw Failure.deadline }
		peer.waitUntilExit(); guard peer.terminationStatus == 0 else { throw Failure.process }
		try peerDiagnostics.fileHandleForReading.close()
		closed = true; try FileManager.default.removeItem(at: root)
	}
	func captured(_ index: Int) throws -> Data {
		let deadline = ProcessInfo.processInfo.systemUptime + 3
		while ProcessInfo.processInfo.systemUptime < deadline {
			if FileManager.default.fileExists(atPath: root.appendingPathComponent("closed-\(index)").path) {
				return try Data(contentsOf: root.appendingPathComponent("request-\(index).bin"))
			}
			usleep(10_000)
		}
		throw Failure.deadline
	}
}

final class ManagedOllamaAPIWorkerTests: XCTestCase {
	private func terminal(_ frames: [(UInt8, Data)]) throws -> [String: Any] {
		XCTAssertEqual(frames.filter { $0.0 == 67 }.count, 1)
		let last = try XCTUnwrap(frames.last); XCTAssertEqual(last.0, 67)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: last.1) as? [String: Any])
	}
	private func probe(_ session: ManagedOllamaTestSession) throws -> [String: Any] {
		let (status, frames) = try session.worker(session.common(), probe: true)
		XCTAssertEqual(status, 0); XCTAssertEqual(frames.map { $0.0 }, [67])
		let receipt = try terminal(frames); XCTAssertEqual(receipt["success"] as? Bool, true)
		let identity = try XCTUnwrap(receipt["listener"] as? [String: Any])
		XCTAssertEqual(Set(identity.keys), ["pid", "uid", "start_seconds", "start_microseconds", "device", "inode"])
		XCTAssertEqual((identity["pid"] as? NSNumber)?.int32Value, session.peer.processIdentifier)
		XCTAssertEqual((identity["uid"] as? NSNumber)?.uint32Value, geteuid())
		XCTAssertEqual(identity["device"] as? String, session.device); XCTAssertEqual(identity["inode"] as? String, session.inode)
		XCTAssertEqual(try session.captured(0), Data(), "Discovery must send no HTTP bytes before discovering the SDK owner")
		return identity
	}
	func testRealAcceptedOwnerBeforeGETAndPhysicalClientEOF() throws {
		let session = try ManagedOllamaTestSession(), identity = try probe(session)
		let (status, frames) = try session.worker(session.request(identity: identity), probe: false)
		XCTAssertEqual(status, 0); XCTAssertEqual(frames.first?.0, 72)
		XCTAssertEqual(frames.filter { $0.0 == 68 }.reduce(Data()) { $0 + $1.1 }, Data("oneTWO".utf8))
		XCTAssertEqual(try terminal(frames)["success"] as? Bool, true)
		let captured = String(decoding: try session.captured(1), as: UTF8.self)
		XCTAssertTrue(captured.hasPrefix("GET /api/ergopti-native-http-admission HTTP/1.1\r\n"))
		XCTAssertTrue(captured.contains("X-Ergopti-Native-Session: " + String(repeating: "a", count: 64)))
		try session.finish()
	}
	func testLiteralChunkedPOSTKeepsExactAcceptedOwner() throws {
		let session = try ManagedOllamaTestSession(mode: "chunked"), identity = try probe(session)
		let (status, frames) = try session.worker(session.request(identity: identity, post: true), probe: false)
		XCTAssertEqual(status, 0)
		XCTAssertEqual(frames.filter { $0.0 == 68 }.reduce(Data()) { $0 + $1.1 }, Data("oneTWO".utf8))
		let receipt = try terminal(frames), returned = try XCTUnwrap(receipt["listener"] as? [String: Any])
		XCTAssertEqual(NSDictionary(dictionary: returned), NSDictionary(dictionary: identity))
		let captured = String(decoding: try session.captured(1), as: UTF8.self)
		XCTAssertTrue(captured.hasPrefix("POST /api/pull HTTP/1.1\r\n")); XCTAssertTrue(captured.hasSuffix("{\"name\":\"independent-literal\"}"))
		try session.finish()
	}
	func testWrongSDKStartRefusesBeforeAnySecretOrBody() throws {
		let session = try ManagedOllamaTestSession(), identity = try probe(session)
		var request = session.request(identity: identity); request["start_seconds"] = "1"
		let (status, frames) = try session.worker(request, probe: false)
		XCTAssertEqual(status, 74); XCTAssertEqual(frames.map { $0.0 }, [67])
		let receipt = try terminal(frames); XCTAssertEqual(receipt["reason"] as? String, "admission"); XCTAssertTrue(receipt["listener"] is NSNull)
		XCTAssertEqual(try session.captured(1), Data()); try session.finish()
	}
	func testWrongCatalogueInodeRefusesDiscoveryBeforeAnyHTTP() throws {
		let session = try ManagedOllamaTestSession(connections: 1)
		var request = session.common(); request["inode"] = "1"
		let (status, frames) = try session.worker(request, probe: true)
		XCTAssertNotEqual(status, 0); XCTAssertEqual(try terminal(frames)["success"] as? Bool, false)
		XCTAssertEqual(try session.captured(0), Data()); try session.finish()
	}
	func testForeignExecutableOnRightPortCannotAdmitSecret() throws {
		let session = try ManagedOllamaTestSession(connections: 1, foreign: true)
		let (status, frames) = try session.worker(session.common(), probe: true)
		XCTAssertNotEqual(status, 0); XCTAssertEqual(try terminal(frames)["success"] as? Bool, false)
		XCTAssertEqual(try session.captured(0), Data()); try session.finish()
	}
	func testRedirectIsRefusedWithoutSecondConnection() throws {
		let session = try ManagedOllamaTestSession(mode: "redirect"), identity = try probe(session)
		let (status, frames) = try session.worker(session.request(identity: identity), probe: false)
		XCTAssertEqual(status, 74); XCTAssertEqual(frames.map { $0.0 }, [67])
		XCTAssertEqual(try terminal(frames)["reason"] as? String, "protocol")
		_ = try session.captured(1); try session.finish()
	}
	func testTruncatedResponseCannotPublishSuccessfulTerminal() throws {
		let session = try ManagedOllamaTestSession(mode: "truncated"), identity = try probe(session)
		let (status, frames) = try session.worker(session.request(identity: identity), probe: false)
		XCTAssertEqual(status, 74); XCTAssertEqual(frames.first?.0, 72)
		XCTAssertEqual(try terminal(frames)["success"] as? Bool, false)
		_ = try session.captured(1); try session.finish()
	}
	func testStrictRequestKindsAndPinnedExecutablePath() throws {
		let home = "/private/ergopti-literal-home", executable = home + "/Library/Application Support/Ergopti/ollama-native-http/ollama"
		let valid: [String: Any] = ["version": 1, "executable": executable, "device": "1", "inode": "2", "port": 11434, "timeout_ms": 5000]
		func parsed(_ fields: [String: Any]) throws -> ManagedOllamaRequest? {
			return ManagedOllamaRequest.parse(try JSONSerialization.data(withJSONObject: fields), discovery: true, home: home)
		}
		XCTAssertNotNil(try parsed(valid))
		for (key, value) in [("version", true as Any), ("device", 1 as Any), ("inode", "02" as Any), ("port", true as Any), ("timeout_ms", true as Any), ("executable", "/tmp/foreign" as Any)] {
			var changed = valid; changed[key] = value; XCTAssertNil(try parsed(changed), key)
		}
	}

	func testProgressingPullWithoutAbsoluteDeadlineOutlivesInitialIdleBudget() throws {
		let session = try ManagedOllamaTestSession(mode: "progress"), identity = try probe(session)
		var request = session.request(identity: identity, post: true)
		request["timeout_ms"] = NSNull(); request["idle_ms"] = 1000
		let started = ProcessInfo.processInfo.systemUptime
		let (status, frames) = try session.worker(request, probe: false)
		XCTAssertEqual(status, 0); XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - started, 1.6)
		XCTAssertEqual(frames.filter { $0.0 == 68 }.reduce(Data()) { $0 + $1.1 }, Data("aBcD".utf8))
		XCTAssertEqual(try terminal(frames)["success"] as? Bool, true)
		_ = try session.captured(1); try session.finish()
	}
	func testProgressCannotRefreshOriginalAbsoluteDeadline() throws {
		let session = try ManagedOllamaTestSession(mode: "progress"), identity = try probe(session)
		var request = session.request(identity: identity, post: true)
		request["timeout_ms"] = 750; request["idle_ms"] = 1000
		let (status, frames) = try session.worker(request, probe: false)
		XCTAssertEqual(status, 124); XCTAssertEqual(try terminal(frames)["reason"] as? String, "deadline")
		XCTAssertEqual(try terminal(frames)["success"] as? Bool, false)
		_ = try session.captured(1); try session.finish()
	}
	func testActualStalledInputExpiresIdleWithNoAbsoluteDeadline() throws {
		let session = try ManagedOllamaTestSession(mode: "stall"), identity = try probe(session)
		var request = session.request(identity: identity, post: true)
		request["timeout_ms"] = NSNull(); request["idle_ms"] = 1000
		let (status, frames) = try session.worker(request, probe: false)
		XCTAssertEqual(status, 124); XCTAssertEqual(try terminal(frames)["reason"] as? String, "deadline")
		XCTAssertEqual(frames.filter { $0.0 == 68 }.reduce(Data()) { $0 + $1.1 }, Data("a".utf8))
		_ = try session.captured(1); try session.finish()
	}

	func testRetainedReadOnlyMachOReallyLoadsAndOwnsAcceptedTCP() throws {
		let session = try ManagedOllamaTestSession(retainedMachO: true)
		let (probeStatus, probeFrames) = try session.worker(session.common(), probe: true)
		XCTAssertEqual(probeStatus, 0); XCTAssertEqual(probeFrames.map { $0.0 }, [67])
		let identity = try XCTUnwrap(try terminal(probeFrames)["listener"] as? [String: Any])
		XCTAssertEqual((identity["pid"] as? NSNumber)?.intValue, (session.profile["pid"] as? NSNumber)?.intValue)
		XCTAssertNotEqual((identity["pid"] as? NSNumber)?.int32Value, session.peer.processIdentifier)
		XCTAssertEqual(identity["device"] as? String, session.device); XCTAssertEqual(identity["inode"] as? String, session.inode)
		XCTAssertEqual(try session.captured(0), Data())
		let (status, frames) = try session.worker(session.request(identity: identity), probe: false)
		XCTAssertEqual(status, 0); XCTAssertEqual(try terminal(frames)["success"] as? Bool, true)
		XCTAssertEqual(frames.filter { $0.0 == 68 }.reduce(Data()) { $0 + $1.1 }, Data("oneTWO".utf8))
		_ = try session.captured(1)
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		while session.peer.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
		XCTAssertFalse(session.peer.isRunning); session.peer.waitUntilExit()
		let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.root.appendingPathComponent("retained-image.json"))) as? [String: Any])
		XCTAssertEqual(receipt["read_only"] as? Bool, true); XCTAssertEqual(receipt["reaped"] as? Bool, true)
		XCTAssertEqual(receipt["descriptor_closed"] as? Bool, true); XCTAssertEqual(receipt["exit_status"] as? Int, 0)
		XCTAssertEqual(receipt["inode"] as? String, session.inode)
		try session.finish()
	}
}

// Tests/ErgoptiPlusTests/ManagedHTTPWireTests.swift
// Actual TLS and CONNECT recipients through the production NSURLSession executor.

import CFNetwork
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

enum ManagedWireFixtureError: Error {
	case refused
	case deadline
}

final class ManagedWireFixture {
	let process = Process()
	let input = Pipe()
	let output = Pipe()
	var profile: [String: Any] = [:]
	var closed = false

	init() throws {
		guard let python = ProcessInfo.processInfo.environment["ERGOPTI_NATIVE_HTTP_PYTHON"], !python.isEmpty else {
			throw ManagedWireFixtureError.refused
		}
		var repository = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { repository.deleteLastPathComponent() }
		process.executableURL = URL(fileURLWithPath: python)
		process.arguments = [repository.appendingPathComponent("static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py").path]
		process.standardInput = input
		process.standardOutput = output
		// Fixture restoration facts must survive without entering the JSON reply pipe.
		process.standardError = FileHandle.standardError
		try process.run()
		do { profile = try read(timeout: 45) }
		catch {
			try? close()
			throw error
		}
	}

	private func read(timeout: TimeInterval) throws -> [String: Any] {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		var bytes = Data()
		while bytes.count < 65_536 {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { throw ManagedWireFixtureError.deadline }
			var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
			let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
			if status < 0 && errno == EINTR { continue }
			guard status >= 0 else { throw ManagedWireFixtureError.refused }
			if status == 0 { continue }
			var byte: UInt8 = 0
			guard Darwin.read(descriptor.fd, &byte, 1) == 1 else { throw ManagedWireFixtureError.refused }
			if byte == 10 {
				guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
					fields["version"] as? Int == 1 else { throw ManagedWireFixtureError.refused }
				return fields
			}
			bytes.append(byte)
		}
		throw ManagedWireFixtureError.refused
	}

	func command(_ fields: [String: Any]) throws -> [String: Any] {
		var data = try JSONSerialization.data(withJSONObject: fields)
		data.append(10)
		try input.fileHandleForWriting.write(contentsOf: data)
		return try read(timeout: 20)
	}

	func close() throws {
		if closed { return }
		try input.fileHandleForWriting.close()
		let terminal = try read(timeout: 45)
		guard terminal["closed"] as? Bool == true else { throw ManagedWireFixtureError.refused }
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
		guard !process.isRunning else { throw ManagedWireFixtureError.deadline }
		process.waitUntilExit()
		try output.fileHandleForReading.close()
		guard process.terminationStatus == 0 else { throw ManagedWireFixtureError.refused }
		closed = true
	}
}

final class ManagedWireFrames: @unchecked Sendable {
	private let lock = NSLock()
	private var bytes = Data()

	func append(_ data: Data) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard data.count <= 1_048_576 - bytes.count else { return false }
		bytes.append(data)
		return true
	}

	func frames() throws -> [(UInt8, Data)] {
		lock.lock()
		defer { lock.unlock() }
		var cursor = 0
		var result: [(UInt8, Data)] = []
		while cursor < bytes.count {
			guard bytes.count - cursor >= 5 else { throw ManagedWireFixtureError.refused }
			let count = bytes[cursor..<cursor + 4].reduce(0) { ($0 << 8) | Int($1) }
			guard count > 0, count <= 65_536, count <= bytes.count - cursor - 4 else { throw ManagedWireFixtureError.refused }
			let tag = bytes[cursor + 4]
			result.append((tag, bytes.subdata(in: cursor + 5..<cursor + 4 + count)))
			cursor += count + 4
		}
		return result
	}
}

final class ManagedHTTPWireTests: XCTestCase {
	/// Actual system trust, PAC script/URL and proxy recipients are mandatory
	/// receiving checks. Missing native prerequisites fail rather than skip.
	func testRealNativeTLSFullURLPACOrderedFallbackAndOwnedClosure() throws {
		let fixture = try ManagedWireFixture()
		defer {
			do { try fixture.close() }
			catch { XCTFail("Owned native wire fixture did not restore trust and private keychain") }
		}
		let host = try XCTUnwrap(fixture.profile["host"] as? String)
		let port = try XCTUnwrap(fixture.profile["origin_port"] as? Int)
		let script = try XCTUnwrap(fixture.profile["pac"] as? String)
		let pacURL = try XCTUnwrap(fixture.profile["pac_url"] as? String)

		func execute(_ path: String, useURL: Bool = false) throws -> (Int32, [(UInt8, Data)]) {
			let fields: [String: Any] = ["version": 1, "url": "https://\(host):\(port)\(path)",
				"method": "GET", "headers": [["Accept-Encoding", "identity"]],
				"timeout": 20, "idle_timeout": 10, "direct": false]
			let request = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: fields)))
			var settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1]
			if useURL { settings[kCFNetworkProxiesProxyAutoConfigURLString as String] = pacURL }
			else { settings[kCFNetworkProxiesProxyAutoConfigJavaScript as String] = script }
			let collector = ManagedWireFrames()
			let status = ManagedHTTPWorker.execute(request, maximumSelections: 128,
				settingsProvider: { settings as CFDictionary }, output: collector.append)
			return (status, try collector.frames())
		}

		func terminal(_ result: (Int32, [(UInt8, Data)])) throws -> [String: Any] {
			XCTAssertEqual(result.1.filter { $0.0 == 67 }.count, 1, "One terminal follows physical native session invalidation")
			let last = try XCTUnwrap(result.1.last)
			XCTAssertEqual(last.0, 67)
			return try XCTUnwrap(JSONSerialization.jsonObject(with: last.1) as? [String: Any])
		}

		let untrusted = try execute("/certificate?case=seven")
		XCTAssertNotEqual(untrusted.0, 0)
		XCTAssertEqual(try terminal(untrusted)["reason"] as? String, "certificate")
		XCTAssertFalse(untrusted.1.contains { $0.0 == 72 || $0.0 == 68 }, "Untrusted origin TLS delivers no HTTP headers or body")
		let trust = try fixture.command(["command": "trust", "enabled": true])
		XCTAssertEqual(trust["trusted"] as? Bool, true)

		for (path, useURL) in [("/alpha?case=one", false), ("/beta?case=two", true), ("/fallback?case=three", false)] {
			let result = try execute(path, useURL: useURL)
			XCTAssertEqual(result.0, 0, "Real native path/query route must succeed")
			XCTAssertEqual(try terminal(result)["success"] as? Bool, true)
			let heads = result.1.filter { $0.0 == 72 }
			XCTAssertEqual(heads.count, 1)
			if let head = heads.first {
				XCTAssertEqual((try JSONSerialization.jsonObject(with: head.1) as? [String: Any])?["status"] as? Int, 200)
			}
			let body = result.1.filter { $0.0 == 68 }.reduce(into: Data()) { $0.append($1.1) }
			XCTAssertEqual(body, Data([111, 119, 110, 101, 100, 0, 110, 97, 116, 105, 118, 101, 255, 119, 105, 114, 101]))
			let snapshot = try fixture.command(["command": "stats"])
			XCTAssertEqual(snapshot["active"] as? Int, 0, "Native success follows origin/proxy socket closure")
		}
		let auth = try execute("/auth?case=four")
		XCTAssertNotEqual(auth.0, 0)
		XCTAssertEqual(try terminal(auth)["success"] as? Bool, false)
		XCTAssertFalse(auth.1.contains { $0.0 == 68 }, "Proxy authentication refusal delivers no body")
		let final = try fixture.command(["command": "stats"])
		XCTAssertEqual(final["active"] as? Int, 0)
		let records = try XCTUnwrap(final["records"] as? [[String: Any]])
		let origins = records.filter { $0["event"] as? String == "origin" }
		XCTAssertEqual(origins.count, 3)
		XCTAssertEqual(origins.map { $0["path"] as? String }, ["/alpha?case=one", "/beta?case=two", "/fallback?case=three"])
		XCTAssertEqual(origins.map { $0["route"] as? String }, ["first", "second", "first"])
		XCTAssertEqual(records.filter { $0["event"] as? String == "connect" && $0["route"] as? String == "second" }.count, 1,
			"A 407 never advances to the second PAC choice")
		try fixture.close()
	}
}

// Tests/ErgoptiPlusTests/ManagedPACSourceTests.swift
// Native source ownership against real request-owned HTTP/TLS PAC peers.

import CFNetwork
import Darwin
import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

private final class ManagedPACSourceFixture {
	private static var retainedDebt: [ManagedPACSourceFixture] = []
	private let process = Process()
	private let input = Pipe()
	private let output = Pipe()
	private var closed = false
	private var startAttempted = false
	private var startAcknowledged = false
	private var startupFailure: Error?
	private var cleanupFailure: Error?
	private(set) var profile: [String: Any] = [:]

	init() throws {
		guard let python = ProcessInfo.processInfo.environment["ERGOPTI_NATIVE_HTTP_PYTHON"], !python.isEmpty else {
			throw ManagedWireFixtureError.refused
		}
		var repository = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { repository.deleteLastPathComponent() }
		process.executableURL = URL(fileURLWithPath: python)
		process.arguments = [repository.appendingPathComponent("static/ergopti_plus/macos/tests/support/native_pac_source_fixture.py").path]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		// Retain the exact Process/Pipe capabilities before native acquisition.
		// A thrown run is not proof that no native child was acquired.
		retainDebt()
		do {
			startAttempted = true
			try process.run()
			startAcknowledged = true
			profile = try Self.read(output, deadline: deadline)
		} catch {
			if !startAcknowledged {
				startupFailure = error
				throw error
			}
			try? close()
			throw error
		}
	}

	private func retainDebt() {
		if !Self.retainedDebt.contains(where: { $0 === self }) { Self.retainedDebt.append(self) }
	}

	private static func read(_ pipe: Pipe, deadline: TimeInterval) throws -> [String: Any] {
		var bytes = Data()
		while bytes.count < 65_536 {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { throw ManagedWireFixtureError.deadline }
			var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
			let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
			if ready < 0 && errno == EINTR { continue }
			guard ready >= 0 else { throw ManagedWireFixtureError.refused }
			if ready == 0 { continue }
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

	func url(_ path: String, tls: Bool = false, hostname: String = "127.0.0.1") throws -> URL {
		let port = try XCTUnwrap(profile[tls ? "https_port" : "http_port"] as? Int)
		return try XCTUnwrap(URL(string: "\(tls ? "https" : "http")://\(hostname):\(port)/source/\(path)"))
	}

	func certificates() throws -> [SecCertificate] {
		let file = try XCTUnwrap(profile["ca_file"] as? String)
		return try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_FILE": file])
	}

	func close() throws {
		if let startupFailure { throw startupFailure }
		if let cleanupFailure { throw cleanupFailure }
		guard !startAttempted || startAcknowledged else { throw ManagedWireFixtureError.refused }
		if closed { return }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		do {
			try input.fileHandleForWriting.close()
			let receipt = try Self.read(output, deadline: deadline)
			guard receipt["closed"] as? Bool == true else { throw ManagedWireFixtureError.refused }
			while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
			guard !process.isRunning else { throw ManagedWireFixtureError.deadline }
			process.waitUntilExit()
			guard process.terminationStatus == 0 else { throw ManagedWireFixtureError.refused }
			try output.fileHandleForReading.close()
			closed = true
			Self.retainedDebt.removeAll(where: { $0 === self })
		} catch {
			cleanupFailure = error
			retainDebt()
			throw error
		}
	}
}

final class ManagedPACSourceTests: XCTestCase {
	func testStrictUTF8AndBOMAdmission() throws {
		let script = "function FindProxyForURL(u,h){return 'DIRECT';}"
		XCTAssertEqual(try ManagedPACSource.decode(Data(script.utf8)), script)
		XCTAssertEqual(try ManagedPACSource.decode(Data([239, 187, 191]) + Data(script.utf8)), script)
		XCTAssertEqual(try ManagedPACSource.decode(Data([255, 254, 65, 0])), "A")
		XCTAssertEqual(try ManagedPACSource.decode(Data([254, 255, 0, 65])), "A")
		XCTAssertEqual(try ManagedPACSource.decode(Data([255, 254, 61, 216, 0, 222])), "😀")
	}

	func testStrictUTF16RejectsMalformedSurrogatesAndNUL() throws {
		let invalid: [[UInt8]] = [[], [239, 187, 191], [192, 128], [255, 254, 65],
			[255, 254, 0, 216], [255, 254, 0, 220], [255, 254, 0, 216, 65, 0],
			[254, 255, 216, 0, 0], [65, 0], [255, 254, 0, 0]]
		for bytes in invalid {
			XCTAssertThrowsError(try ManagedPACSource.decode(Data(bytes)))
		}
		XCTAssertThrowsError(try ManagedPACSource.decode(Data(repeating: 65, count: 1_048_577)))
	}

	func testAuthorityScopeIncludesCanonicalSchemeHostEffectivePort() throws {
		let initial = try ManagedPACSource.Authority(XCTUnwrap(URL(string: "https://PAC.example/a")))
		XCTAssertEqual(initial, try ManagedPACSource.Authority(XCTUnwrap(URL(string: "https://pac.example:443/b"))))
		for text in ["https://pac.example:444/a", "https://foreign.example/a", "http://pac.example/a"] {
			XCTAssertNotEqual(initial, try ManagedPACSource.Authority(XCTUnwrap(URL(string: text))))
		}
		for text in ["ftp://pac.example/a", "https://user:password@pac.example/a", "https://pac.example/a#fragment"] {
			XCTAssertThrowsError(try ManagedPACSource.Authority(XCTUnwrap(URL(string: text))))
		}
	}

	func testBindingEscapesRequestDataAndRefusesInvalidSource() throws {
		let url = try XCTUnwrap(URL(string: "https://same.example:4455/a?case=%22%5C%0A"))
		let original = "function FindProxyForURL(url,host){return 'DIRECT';}// trailing comment"
		let bound = try ManagedPACSource.bind(original, url: url)
		XCTAssertTrue(bound.hasPrefix(original + "\n;"))
		XCTAssertTrue(bound.contains("original.call(this,args[0],args[1])"))
		XCTAssertTrue(bound.contains("same.example"))
		XCTAssertThrowsError(try ManagedPACSource.bind("", url: url))
		XCTAssertThrowsError(try ManagedPACSource.bind("FindProxyForURL\0", url: url))
		XCTAssertThrowsError(try ManagedPACSource.bind(String(repeating: " ", count: 1_048_576), url: url))
	}

	func testRealPACSourceDecodersRetireEverySession() throws {
		let fixture = try ManagedPACSourceFixture()
		defer { do { try fixture.close() } catch { XCTFail("Owned PAC source fixture retirement refused") } }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		let expected = try XCTUnwrap(fixture.profile["script"] as? String)
		for path in ["utf8", "utf8-bom", "utf16-le", "utf16-be"] {
			XCTAssertEqual(ManagedPACSource.load(try fixture.url(path), deadline: deadline, certificates: []), expected)
			XCTAssertFalse(ManagedPACSource.hasDebt)
		}
	}

	func testRealPACSourceStatusSizeAndEncodingRefusalsRetire() throws {
		let fixture = try ManagedPACSourceFixture()
		defer { do { try fixture.close() } catch { XCTFail("Owned PAC source fixture retirement refused") } }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		for path in ["unavailable", "oversized", "empty", "nul", "invalid-utf8", "invalid-utf16", "truncated"] {
			XCTAssertNil(ManagedPACSource.load(try fixture.url(path), deadline: deadline, certificates: []))
			XCTAssertFalse(ManagedPACSource.hasDebt)
		}
	}

	func testRealPACSourceRedirectsHaveFreshCredentialFreeOwners() throws {
		let fixture = try ManagedPACSourceFixture()
		defer { do { try fixture.close() } catch { XCTFail("Owned PAC source fixture retirement refused") } }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		let expected = try XCTUnwrap(fixture.profile["script"] as? String)
		for path in ["redirect", "foreign"] {
			XCTAssertEqual(ManagedPACSource.load(try fixture.url(path), deadline: deadline, certificates: []), expected)
			XCTAssertFalse(ManagedPACSource.hasDebt)
		}
		for path in ["foreign-auth", "loop"] {
			XCTAssertNil(ManagedPACSource.load(try fixture.url(path), deadline: deadline, certificates: []))
			XCTAssertFalse(ManagedPACSource.hasDebt)
		}
	}

	func testRealPACSourceTrustAnchorsPreserveHostnameAndDowngradeRefusal() throws {
		let fixture = try ManagedPACSourceFixture()
		defer { do { try fixture.close() } catch { XCTFail("Owned PAC source fixture retirement refused") } }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		let certificates = try fixture.certificates()
		XCTAssertNil(ManagedPACSource.load(try fixture.url("utf8", tls: true), deadline: deadline, certificates: []))
		XCTAssertFalse(ManagedPACSource.hasDebt)
		XCTAssertEqual(ManagedPACSource.load(try fixture.url("utf8", tls: true), deadline: deadline, certificates: certificates),
			try XCTUnwrap(fixture.profile["script"] as? String))
		XCTAssertFalse(ManagedPACSource.hasDebt)
		XCTAssertNil(ManagedPACSource.load(try fixture.url("utf8", tls: true, hostname: "localhost"), deadline: deadline, certificates: certificates))
		XCTAssertFalse(ManagedPACSource.hasDebt)
		XCTAssertNil(ManagedPACSource.load(try fixture.url("downgrade", tls: true), deadline: deadline, certificates: certificates))
		XCTAssertFalse(ManagedPACSource.hasDebt)
	}

	func testRealPACSourceDeadlineRefusesAndRetiresBeforeReplacement() throws {
		let fixture = try ManagedPACSourceFixture()
		defer { do { try fixture.close() } catch { XCTFail("Owned PAC source fixture retirement refused") } }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		XCTAssertNil(ManagedPACSource.load(try fixture.url("utf8"), deadline: 0, certificates: []))
		XCTAssertFalse(ManagedPACSource.hasDebt)
		XCTAssertNil(ManagedPACSource.load(try fixture.url("held"), deadline: ProcessInfo.processInfo.systemUptime + 0.05, certificates: []))
		while ManagedPACSource.hasDebt && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
		XCTAssertFalse(ManagedPACSource.hasDebt)
		XCTAssertEqual(ManagedPACSource.load(try fixture.url("utf8"), deadline: deadline, certificates: []),
			try XCTUnwrap(fixture.profile["script"] as? String))
		XCTAssertFalse(ManagedPACSource.hasDebt)
	}

	func testOriginalLookupBudgetIncludesSettingsPreparation() throws {
		let url = try XCTUnwrap(URL(string: "https://same.example/a?case=original"))
		var reads = 0
		XCTAssertNil(ManagedProxyLookup.routes(url: url, budget: 0.01, maximumSelections: 128,
			settingsProvider: {
				reads += 1
				Thread.sleep(forTimeInterval: 0.02)
				return [kCFNetworkProxiesHTTPEnable as String: 0] as CFDictionary
			}))
		XCTAssertEqual(reads, 1)
		XCTAssertFalse(ManagedPACSource.hasDebt)
	}
}

// Tests/ErgoptiPlusTests/ManagedNetworkBootstrapTests.swift
// Additional real SDK controls; the original 35 native subjects stay unchanged.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

private final class NetworkBootstrapNativeGuardian {
	let root: URL
	let session: URL
	let bootstrap: URL
	let process = Process()
	let input = Pipe(), output = Pipe(), diagnostics = Pipe()
	var sessionWriter: FileHandle?
	var bootstrapWriter: FileHandle?
	var outgoingDescriptor: Int32 = -1
	var inputClosed = false
	var reaped = false
	var stdoutEOF = false, stderrEOF = false
	var markers: [String] = []
	var decoder = OwnedProgramLineDecoder(maximumBytes: 1024)

	init(launcher: URL) throws {
		let manager = FileManager.default
		root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ergopti-network-bootstrap-" + UUID().uuidString)
		let sessions = root.appendingPathComponent("Library/Application Support/Ergopti/ollama-native-sessions")
		session = sessions.appendingPathComponent("daemon-0123456789abcdef0123456789abcdef.json")
		bootstrap = sessions.appendingPathComponent("network-0123456789abcdef0123456789abcdef.json")
		do {
			try manager.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
			let runtime = root.appendingPathComponent("Library/Application Support/Ergopti/ollama-native-http")
			try manager.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
			let alias = runtime.appendingPathComponent(".ergopti-image-0123456789abcdef0123456789abcdef")
			try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: alias)
			try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: alias.path)
			for selected in [session, bootstrap] {
				let fd = Darwin.open(selected.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
				guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
				let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
				if selected == session { sessionWriter = file } else { bootstrapWriter = file }
			}
			let worker = root.appendingPathComponent("OwnedOutgoingHTTP.app/Contents/MacOS/ErgoptiPlus")
			try manager.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
			let original = try Data(contentsOf: launcher)
			try manager.copyItem(at: launcher, to: worker)
			guard try Data(contentsOf: worker) == original else { throw NSError(domain: "BootstrapSourceCopy", code: 1) }
			for arguments in [["--force", "-s", "-", worker.path], ["--verify", "--strict", worker.path]] {
				let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); signer.arguments = arguments
				signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
				try signer.run(); signer.waitUntilExit()
				guard signer.terminationReason == .exit, signer.terminationStatus == 0 else { throw NSError(domain: "BootstrapNativeSignature", code: 1) }
			}
			outgoingDescriptor = Darwin.open(worker.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
			var outgoing = stat(), image = stat(), network = stat()
			guard outgoingDescriptor >= 0, fstat(outgoingDescriptor, &outgoing) == 0, lstat(alias.path, &image) == 0,
				fstat(try XCTUnwrap(bootstrapWriter).fileDescriptor, &network) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			let request: [String: Any] = [
				"version": 1, "executable": alias.path, "arguments": ["serve"],
				"device": String(UInt32(bitPattern: image.st_dev)), "inode": String(UInt64(image.st_ino)),
				"session_path": session.path, "remaining_ms": 10_000, "home": root.path,
				"models_path": "../unchanged-models", "network_policy": root.appendingPathComponent("policy.json").path,
				"host": "127.0.0.1:11434", "proxy_url": "", "store_mode": "environment",
				"store_cwd": manager.currentDirectoryPath, "bootstrap_path": bootstrap.path,
				"bootstrap_device": String(UInt32(bitPattern: network.st_dev)), "bootstrap_inode": String(UInt64(network.st_ino)),
				"outgoing_worker": worker.path, "outgoing_device": String(UInt32(bitPattern: outgoing.st_dev)),
				"outgoing_inode": String(UInt64(outgoing.st_ino)),
				"outgoing_sha256": SHA256.hash(data: try Data(contentsOf: worker)).map { String(format: "%02x", $0) }.joined(),
			]
			process.executableURL = launcher; process.arguments = [OwnedSuspendedImageGuardian.flag]
			process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
			try process.run()
			try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try diagnostics.fileHandleForWriting.close()
			guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			for file in [output.fileHandleForReading, diagnostics.fileHandleForReading] {
				let flags = fcntl(file.fileDescriptor, F_GETFL)
				guard flags >= 0, fcntl(file.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			}
			try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
		} catch {
			if process.isRunning { try? input.fileHandleForWriting.close(); inputClosed = true; process.waitUntilExit(); reaped = true }
			try? sessionWriter?.close(); try? bootstrapWriter?.close()
			if outgoingDescriptor >= 0 { Darwin.close(outgoingDescriptor); outgoingDescriptor = -1 }
			throw error
		}
	}

	func poll() throws {
		for (isOutput, file) in [(true, output.fileHandleForReading), (false, diagnostics.fileHandleForReading)] {
			var bytes = [UInt8](repeating: 0, count: 2048)
			let count = Darwin.read(file.fileDescriptor, &bytes, bytes.count)
			if count == 0 { if isOutput { stdoutEOF = true } else { stderrEOF = true } }
			else if count > 0 {
				guard isOutput, decoder.append(Data(bytes.prefix(count))) else { throw NSError(domain: "BootstrapPrivateOutput", code: 1) }
				while let line = decoder.pop() {
					guard let text = String(data: line, encoding: .utf8) else { throw NSError(domain: "BootstrapReceipt", code: 1) }
					markers.append(text)
				}
			} else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
		}
	}
	func wait(_ predicate: () -> Bool) throws {
		let deadline = ProcessInfo.processInfo.systemUptime + 15
		repeat { try poll(); if predicate() { return }; usleep(1000) } while ProcessInfo.processInfo.systemUptime < deadline
		throw NSError(domain: "BootstrapNativeDeadline", code: 1)
	}
	func send(_ line: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
	func finish() throws {
		try wait { !process.isRunning && stdoutEOF && stderrEOF }
		process.waitUntilExit(); reaped = true
		XCTAssertEqual(process.terminationReason, .exit); XCTAssertEqual(process.terminationStatus, 0)
		XCTAssertTrue(decoder.buffered.isEmpty)
	}
	func cleanup() {
		do {
			if process.isRunning && !inputClosed { try send("CANCEL") }
			if !inputClosed { try input.fileHandleForWriting.close(); inputClosed = true }
			if !reaped { try finish() }
			guard reaped, stdoutEOF, stderrEOF, markers.contains("V1 BOOTSTRAP_CLOSED 0"),
				markers.contains("V1 OUTGOING_CLOSED 0"), markers.last?.hasPrefix("V1 RETIRED ") == true else { throw NSError(domain: "BootstrapNativeRetirement", code: 1) }
			try output.fileHandleForReading.close(); try diagnostics.fileHandleForReading.close()
			try sessionWriter?.close(); sessionWriter = nil; try bootstrapWriter?.close(); bootstrapWriter = nil
			let fd = outgoingDescriptor; outgoingDescriptor = -1
			guard fd >= 0, Darwin.close(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			try FileManager.default.removeItem(at: root)
		} catch { XCTFail("Bootstrap physical cleanup remains unproven; owned files retained.") }
	}
}

private final class BootstrapNativeTLSFixture {
	let root: URL
	let certificate: URL
	let process = Process()
	let output = Pipe(), diagnostics = Pipe()
	var endpoint: URL?

	init(startServer: Bool) throws {
		let manager = FileManager.default
		root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ergopti-bootstrap-tls-" + UUID().uuidString)
		try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		certificate = root.appendingPathComponent("ca.pem")
		let key = root.appendingPathComponent("private-key.pem"), config = root.appendingPathComponent("openssl.cnf")
		try Data("[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=extensions\n[dn]\nCN=Independent loopback\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n".utf8).write(to: config)
		let openssl = Process(); openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
		openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path, "-out", certificate.path, "-keyout", key.path]
		openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
		try openssl.run(); openssl.waitUntilExit()
		guard openssl.terminationReason == .exit, openssl.terminationStatus == 0 else { throw NSError(domain: "BootstrapNativeCertificateFixture", code: 1) }
		if !startServer { return }
		// CI provides the pinned Python interpreter. This independent real TLS
		// peer binds port zero and never changes account trust or proxy settings.
		let source = """
		import http.server, socketserver, ssl, sys
		class Handler(http.server.BaseHTTPRequestHandler):
		    def do_GET(self):
		        body=b'independent-native-tls-body'
		        self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
		    def log_message(self,*args): pass
		class NumericLoopbackServer(http.server.HTTPServer):
		    def server_bind(self):
		        # The peer never needs DNS: retain only its actual numeric bind.
		        socketserver.TCPServer.server_bind(self)
		        self.server_name, self.server_port = self.server_address[:2]
		server=NumericLoopbackServer(('127.0.0.1',0),Handler)
		context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(sys.argv[1],sys.argv[2])
		server.socket=context.wrap_socket(server.socket,server_side=True)
		print(server.server_address[1],flush=True)
		server.serve_forever()
		"""
		let locator = Process(), located = Pipe()
		locator.executableURL = URL(fileURLWithPath: "/usr/bin/env"); locator.arguments = ["python3", "-c", "import sys; print(sys.executable)"]
		locator.standardOutput = located; locator.standardError = FileHandle.nullDevice
		try locator.run(); try located.fileHandleForWriting.close(); locator.waitUntilExit()
		let python = String(decoding: located.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		try located.fileHandleForReading.close()
		guard locator.terminationReason == .exit, locator.terminationStatus == 0, python.hasPrefix("/") else { throw NSError(domain: "BootstrapNativePythonPrerequisite", code: 1) }
		process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-c", source, certificate.path, key.path]
		process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = diagnostics
		try process.run(); try output.fileHandleForWriting.close(); try diagnostics.fileHandleForWriting.close()
		let flags = fcntl(output.fileHandleForReading.fileDescriptor, F_GETFL)
		guard flags >= 0, fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
		var line = Data(); var terminated = false
		let deadline = ProcessInfo.processInfo.systemUptime + 5
		while line.count <= 16 && ProcessInfo.processInfo.systemUptime < deadline {
			var byte: UInt8 = 0
			let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &byte, 1)
			if count == 1 { if byte == 10 { terminated = true; break }; line.append(byte) }
			else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { break }
			else { usleep(1000) }
		}
		guard terminated else { process.terminate(); process.waitUntilExit(); throw NSError(domain: "BootstrapNativeTLSPeer", code: 1) }
		guard let port = UInt16(String(decoding: line, as: UTF8.self)), port > 0 else { throw NSError(domain: "BootstrapNativeTLSPort", code: 1) }
		endpoint = URL(string: "https://127.0.0.1:\(port)/independent")
	}
	func cleanup() {
		if process.isRunning { process.terminate(); process.waitUntilExit() }
		do {
			try output.fileHandleForReading.close(); try diagnostics.fileHandleForReading.close()
			try FileManager.default.removeItem(at: root)
		} catch { XCTFail("Native TLS peer cleanup remains unproven.") }
	}
}

final class ManagedNetworkBootstrapTests: XCTestCase {
	private func launcher() throws -> URL {
		let products = Bundle(for: ManagedNetworkBootstrapTests.self).bundleURL.deletingLastPathComponent()
		return try XCTUnwrap([products.appendingPathComponent("ErgoptiPlus"), products.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")].first { FileManager.default.isExecutableFile(atPath: $0.path) })
	}
	private func publicFields() -> [String: Any] {
		let home = "/private/tmp/ergopti-network-bootstrap-request"
		let sessions = home + "/Library/Application Support/Ergopti/ollama-native-sessions/"
		return ["version": 1, "executable": home + "/Library/Application Support/Ergopti/ollama-native-http/.ergopti-image-0123456789abcdef0123456789abcdef",
			"arguments": ["serve"], "device": "1", "inode": "2", "session_path": sessions + "daemon-0123456789abcdef0123456789abcdef.json",
			"remaining_ms": 1000, "home": home, "models_path": "../unchanged models", "network_policy": home + "/policy.json", "host": "127.0.0.1:11434", "proxy_url": "",
			"bootstrap_path": sessions + "network-0123456789abcdef0123456789abcdef.json", "bootstrap_device": "1", "bootstrap_inode": "9007199254740993",
			"store_mode": "environment", "store_cwd": FileManager.default.currentDirectoryPath]
	}
	private func parse(_ fields: [String: Any]) throws -> OwnedSuspendedImageRequest? {
		OwnedSuspendedImageRequest.parse(try JSONSerialization.data(withJSONObject: fields), launcher: "/usr/bin/true")
	}
	func testProductionStoreAndBootstrapContextLexicalFences() throws {
		for raw in ["../unchanged models", "/Volumes/External Models/original", "relative-models"] {
			var fields = publicFields(); fields["models_path"] = raw
			let selected = try XCTUnwrap(parse(fields))
			XCTAssertEqual(selected.environment["OLLAMA_MODELS"], raw)
			XCTAssertEqual(selected.bootstrap?.inode, 9_007_199_254_740_993)
			XCTAssertNil(selected.environment["https_proxy"]); XCTAssertNil(selected.environment["SSL_CERT_FILE"])
		}
		var defaults = publicFields(); defaults["models_path"] = ""; defaults["store_mode"] = "default"
		XCTAssertNil(try XCTUnwrap(parse(defaults)).environment["OLLAMA_MODELS"])
	}
	func testBootstrapContextCannotPartiallyOverrideLegacyRequest() throws {
		for key in ["bootstrap_path", "bootstrap_device", "bootstrap_inode", "store_mode", "store_cwd"] {
			var fields = publicFields(); fields.removeValue(forKey: key); XCTAssertNil(try parse(fields), key)
		}
		for (key, value) in [("bootstrap_device", "01"), ("bootstrap_inode", "18446744073709551616"), ("store_mode", "default"), ("store_cwd", "/foreign/work"), ("bootstrap_path", "/foreign/network.json"), ("models_path", "contains\0tail"), ("proxy_url", "http://127.0.0.1:8080")] {
			var fields = publicFields(); fields[key] = value; XCTAssertNil(try parse(fields), key)
		}
		var legacy = publicFields()
		for key in ["bootstrap_path", "bootstrap_device", "bootstrap_inode", "store_mode", "store_cwd"] { legacy.removeValue(forKey: key) }
		XCTAssertNil(try parse(legacy), "legacy cannot acquire the new raw external store admission")
	}
	func testNativeBootstrapEmptyBeforeImageProofAndOriginalCloseReceipt() throws {
		let fixture = try NetworkBootstrapNativeGuardian(launcher: launcher()); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains { $0.hasPrefix("V1 IMAGE_READY ") } }
		XCTAssertEqual(try Data(contentsOf: fixture.session).count, 0); XCTAssertEqual(try Data(contentsOf: fixture.bootstrap).count, 0)
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE"))
		let fields = try XCTUnwrap(fixture.markers.first).split(separator: " "); XCTAssertEqual(fields.count, 8)
		let child = try XCTUnwrap(Int32(fields[2])); let actual = ergopti_owned_program_observe(child)
		XCTAssertEqual(actual.error_code, 0); XCTAssertFalse(actual.nonlive); XCTAssertEqual(actual.process_group_id, child)
		XCTAssertEqual(actual.start_seconds, try XCTUnwrap(UInt64(fields[4]))); XCTAssertEqual(actual.start_microseconds, try XCTUnwrap(UInt64(fields[5])))
		try XCTUnwrap(fixture.sessionWriter).write(contentsOf: Data("POST_IMAGE_SESSION_FIXTURE".utf8)); try XCTUnwrap(fixture.sessionWriter).synchronize()
		try XCTUnwrap(fixture.bootstrapWriter).write(contentsOf: Data("POST_IMAGE_BOOTSTRAP_FIXTURE".utf8)); try XCTUnwrap(fixture.bootstrapWriter).synchronize()
		try fixture.send("ACTIVATE"); try fixture.finish()
		XCTAssertTrue(fixture.markers.contains("V1 ACTIVE")); XCTAssertTrue(fixture.markers.contains("V1 BOOTSTRAP_CLOSED 0"))
		XCTAssertEqual(fixture.markers.last, "V1 RETIRED 0 1 1 0 0 0 0"); XCTAssertTrue(fixture.reaped && fixture.stdoutEOF && fixture.stderrEOF)
	}
	func testNativeBootstrapReplacementRefusesActivationAndRetires() throws {
		let fixture = try NetworkBootstrapNativeGuardian(launcher: launcher()); defer { fixture.cleanup() }
		try fixture.wait { fixture.markers.contains { $0.hasPrefix("V1 IMAGE_READY ") } }
		try FileManager.default.moveItem(at: fixture.bootstrap, to: fixture.root.appendingPathComponent("held-bootstrap"))
		try Data("FOREIGN_BOOTSTRAP".utf8).write(to: fixture.bootstrap); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.bootstrap.path)
		try XCTUnwrap(fixture.sessionWriter).write(contentsOf: Data("POST_IMAGE_SESSION_FIXTURE".utf8)); try XCTUnwrap(fixture.sessionWriter).synchronize()
		try fixture.send("ACTIVATE"); try fixture.finish()
		XCTAssertFalse(fixture.markers.contains("V1 ACTIVE")); XCTAssertTrue(fixture.markers.contains("V1 BOOTSTRAP_CLOSED 0"))
		XCTAssertEqual(fixture.markers.last, "V1 RETIRED 137 1 1 0 0 0 0")
	}
	func testNativeCustomAnchorsPreserveHostnameAndDefaultRefusal() throws {
		let fixture = try BootstrapNativeTLSFixture(startServer: true); defer { fixture.cleanup() }
		let endpoint = try XCTUnwrap(fixture.endpoint)
		let request = ManagedHTTPRequest(url: endpoint, method: "GET", headers: [("Accept-Encoding", "identity")], timeout: 5, idleTimeout: 5, direct: true)
		var refused: [Data] = []
		XCTAssertEqual(ManagedHTTPWorker.execute(request, maximumSelections: 1, environment: [:], output: { refused.append($0); return true }), 74)
		XCTAssertTrue(String(decoding: try XCTUnwrap(refused.last).dropFirst(5), as: UTF8.self).contains("certificate"))
		var admitted: [Data] = []
		XCTAssertEqual(ManagedHTTPWorker.execute(request, maximumSelections: 1, environment: ["SSL_CERT_FILE": fixture.certificate.path], output: { admitted.append($0); return true }), 0)
		let body = admitted.filter { $0.count > 5 && $0[4] == 68 }.reduce(Data()) { $0 + $1.dropFirst(5) }
		XCTAssertEqual(String(decoding: body, as: UTF8.self), "independent-native-tls-body")
		let certificates = try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_FILE": fixture.certificate.path])
		// Bounded closed observations distinguish native trust from transport;
		// never emit certificate subjects, URLs, frame bodies, or native errors.
		let terminal = admitted.last.flatMap { frame -> [String: Any]? in
			guard frame.count >= 5, frame[4] == 67 else { return nil }
			return (try? JSONSerialization.jsonObject(with: frame.dropFirst(5))) as? [String: Any]
		}
		let knownReasons = ["complete", "protocol", "deadline", "cancelled", "offline", "certificate", "connect", "unavailable", "proxy", "content_encoding"]
		let reason = terminal?["reason"] as? String
		let terminalReason = reason.flatMap { knownReasons.contains($0) ? $0 : nil } ?? "unknown"
		var positiveTrust: SecTrust?
		let positiveCreated = SecTrustCreateWithCertificates(certificates as CFArray,
			SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &positiveTrust)
		let positiveTrusted = positiveCreated == errSecSuccess
			&& positiveTrust.map { ManagedCertificateAuthorities.evaluate($0, adding: certificates) } == true
		print("BOOTSTRAP_TLS_OBSERVATION terminal=\(terminalReason) custom_anchor_peer=\(positiveTrusted ? 1 : 0)")
		var trust: SecTrust?
		XCTAssertEqual(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, "foreign.invalid" as CFString), &trust), errSecSuccess)
		XCTAssertFalse(ManagedCertificateAuthorities.evaluate(try XCTUnwrap(trust), adding: certificates))
	}
	func testNativeCertificateDataRefusalsAndDirectory() throws {
		let fixture = try BootstrapNativeTLSFixture(startServer: false); defer { fixture.cleanup() }
		XCTAssertTrue(try ManagedCertificateAuthorities.load(environment: [:]).isEmpty)
		let directory = fixture.root.appendingPathComponent("custom-roots")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		try FileManager.default.copyItem(at: fixture.certificate, to: directory.appendingPathComponent("root.pem"))
		try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("hash.0"), withDestinationURL: directory.appendingPathComponent("root.pem"))
		XCTAssertEqual(try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_DIR": directory.path]).count, 2)
		XCTAssertThrowsError(try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_DIR": directory.path + ":"]))
		for text in ["", "unrelated", "-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----", "-----BEGIN CERTIFICATE-----\n%%\n-----END CERTIFICATE-----"] {
			try Data(text.utf8).write(to: fixture.certificate)
			XCTAssertThrowsError(try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_FILE": fixture.certificate.path]))
		}
		XCTAssertThrowsError(try ManagedCertificateAuthorities.load(environment: ["SSL_CERT_FILE": fixture.root.appendingPathComponent("missing.pem").path]))
	}
}

// Tests/ErgoptiPlusTests/ManagedBootstrapDownloadTests.swift
// Literal protocol observations and actual retained descriptor publication.

import CFNetwork
import Foundation
import XCTest
@testable import ErgoptiPlus

final class ManagedBootstrapDownloadTests: XCTestCase {
	private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	private var input: [String: Any] {
		return ["version": 1, "url": "https://release.example/exact/archive?q=pin", "sha256": digest,
			"output": "/private/tmp/owned/archive.tar", "timeout_ms": 30_000, "size": 3]
	}
	private var policyFields: [String: Any] {
		return ["schema_version": 1, "max_selections": 128, "redirects": ["max_hops": 50],
			"selected_proxy_bypass": "environment", "environment_bypass_precedence": ["no_proxy", "NO_PROXY"],
			"loopback": ["dns_hosts": ["localhost"], "dns_suffixes": [".localhost"],
				"ipv4_cidrs": ["127.0.0.0/8"], "ipv6_addresses": ["::1"]]]
	}

	private func frame(_ tag: UInt8, _ fields: [String: Any]) throws -> Data {
		return try XCTUnwrap(ManagedHTTPFrame.encode(tag: tag,
			bytes: JSONSerialization.data(withJSONObject: fields)))
	}

	func testPrivateAdmissionKeepsExactPublicPinAndRefusesOtherJSONKinds() throws {
		let parsed = try XCTUnwrap(ManagedBootstrapRequest.parse(JSONSerialization.data(withJSONObject: input)))
		XCTAssertEqual(parsed.url.absoluteString, "https://release.example/exact/archive?q=pin")
		XCTAssertEqual(parsed.sha256, digest)
		XCTAssertEqual(parsed.timeoutMilliseconds, 30_000)
		XCTAssertEqual(parsed.size, 3)
		let invalidRequests: [(String, Any)] = [
			("version", true as Any), ("timeout_ms", true), ("timeout_ms", 30_000.5),
			("size", true), ("size", "3"), ("size", 0), ("size", 3.5),
			("url", "http://release.example/archive"), ("url", "https://user:secret@release.example/archive"),
			("url", "https://release.example/archive#fragment"), ("output", "relative/archive"),
			("sha256", String(repeating: "x", count: 64))
		]
		for (key, value) in invalidRequests {
			var invalid = input
			invalid[key] = value
			XCTAssertNil(ManagedBootstrapRequest.parse(try JSONSerialization.data(withJSONObject: invalid)), "Refuse invalid \(key)")
		}
		var optional = input
		optional.removeValue(forKey: "size")
		XCTAssertNil(try XCTUnwrap(ManagedBootstrapRequest.parse(JSONSerialization.data(withJSONObject: optional))).size)
		var override = input
		override["proxy"] = "reserved"
		XCTAssertNil(ManagedBootstrapRequest.parse(try JSONSerialization.data(withJSONObject: override)))
	}

	func testCanonicalPolicyRequiresIntegerRoutingLimits() throws {
		let bytes = try JSONSerialization.data(withJSONObject: policyFields)
		let parsed = try XCTUnwrap(ManagedBootstrapPolicy.parse(bytes))
		XCTAssertEqual(parsed.maximumSelections, 128)
		XCTAssertEqual(parsed.maximumRedirects, 50)
		let invalidPolicies: [(String, Any)] = [("schema_version", true), ("max_selections", 0),
			("redirects", ["max_hops": true]), ("environment_bypass_precedence", ["no_proxy", "no_proxy"])]
		for (key, value) in invalidPolicies {
			var invalid = policyFields
			invalid[key] = value
			XCTAssertNil(ManagedBootstrapPolicy.parse(try JSONSerialization.data(withJSONObject: invalid)))
		}
	}

	func testCanonicalBypassPreservesLoopbackCIDRIPv6DomainPortAndInventoryOrder() throws {
		let policy = try XCTUnwrap(ManagedBootstrapPolicy.parse(JSONSerialization.data(withJSONObject: policyFields)))
		for url in ["https://127.250.7.9/a", "https://[0:0:0:0:0:0:0:1]/a", "https://localhost/a", "https://one.localhost/a"] {
			XCTAssertTrue(policy.direct(try XCTUnwrap(URL(string: url)), environment: [:]))
		}
		let target = try XCTUnwrap(URL(string: "https://nested.example.test:8443/a?retained=yes"))
		for bypass in ["example.test", ".example.test", "*.example.test", "example.test:8443", "*"] {
			XCTAssertTrue(policy.direct(target, environment: ["no_proxy": bypass]))
		}
		for bypass in ["foreign.test", "example.test:443", "user:reserved@example.test", "ample.test"] {
			XCTAssertFalse(policy.direct(target, environment: ["no_proxy": bypass]))
		}
		XCTAssertFalse(policy.direct(target, environment: ["no_proxy": "foreign.test", "NO_PROXY": "*"]),
			"The first nonempty canonical bypass entry owns the decision")
		XCTAssertTrue(policy.direct(target, environment: ["no_proxy": "", "NO_PROXY": "*"]))
		XCTAssertTrue(policy.direct(try XCTUnwrap(URL(string: "https://10.33.4.5/a")), environment: ["no_proxy": "10.0.0.0/8"]))
		XCTAssertFalse(policy.direct(try XCTUnwrap(URL(string: "https://11.33.4.5/a")), environment: ["no_proxy": "10.0.0.0/8"]))
		XCTAssertTrue(policy.direct(try XCTUnwrap(URL(string: "https://[2001:db8::1]/a")), environment: ["no_proxy": "2001:db8::/32"]))
		XCTAssertTrue(policy.direct(try XCTUnwrap(URL(string: "https://[2001:db8::1]:8443/a")), environment: ["no_proxy": "[2001:db8::1]:8443"]))
		XCTAssertFalse(policy.direct(try XCTUnwrap(URL(string: "https://[2001:db9::1]/a")), environment: ["no_proxy": "2001:db8::/32"]))
	}

	func testCollectorRequiresRealTerminalEvidenceBeforeDigestAcceptance() throws {
		var written = Data()
		let collector = ManagedBootstrapCollector(maximumBytes: 3, remaining: { 10 },
			writeBody: { written.append($0); return true })
		XCTAssertTrue(collector.consume(try frame(72, ["version": 1, "status": 200, "headers": []])))
		XCTAssertTrue(collector.consume(try XCTUnwrap(ManagedHTTPFrame.encode(tag: 68, bytes: Data("abc".utf8)))))
		XCTAssertFalse(collector.verified(digest: digest, size: 3), "Body EOF alone cannot become native session retirement")
		XCTAssertTrue(collector.consume(try frame(67, ["version": 1, "success": true, "reason": "complete"])))
		XCTAssertTrue(collector.verified(digest: digest, size: 3))
		XCTAssertEqual(written, Data("abc".utf8))
		XCTAssertFalse(collector.consume(try frame(67, ["version": 1, "success": true, "reason": "complete"])))
	}

	func testRedirectHeaderCancelsBeforeAnyBodyAndStillRequiresClosure() throws {
		var writes = 0
		let collector = ManagedBootstrapCollector(maximumBytes: 3, remaining: { 10 },
			writeBody: { _ in writes += 1; return true })
		XCTAssertFalse(collector.consume(try frame(72, ["version": 1, "status": 302,
			"headers": [["Location", "/next/archive?pin=retained"]]])))
		XCTAssertTrue(collector.redirectCancelled)
		XCTAssertFalse(collector.terminal)
		XCTAssertTrue(collector.consume(try frame(67, ["version": 1, "success": false, "reason": "protocol"])))
		XCTAssertTrue(collector.terminal)
		XCTAssertFalse(collector.successfulTerminal)
		XCTAssertEqual(collector.location, "/next/archive?pin=retained")
		XCTAssertEqual(collector.bytes, 0)
		XCTAssertEqual(writes, 0)
		XCTAssertFalse(collector.verified(digest: digest, size: 3))
	}

	func testCollectorRejectsOversizeTruncatedAndUnacknowledgedNativeInput() throws {
		let oversize = ManagedBootstrapCollector(maximumBytes: 2, remaining: { 10 }, writeBody: { _ in XCTFail("Oversize bytes must not reach disk"); return true })
		XCTAssertTrue(oversize.consume(try frame(72, ["version": 1, "status": 200, "headers": []])))
		XCTAssertFalse(oversize.consume(try XCTUnwrap(ManagedHTTPFrame.encode(tag: 68, bytes: Data("abc".utf8)))))
		XCTAssertEqual(oversize.failure, "verify")
		let malformed = ManagedBootstrapCollector(maximumBytes: nil, remaining: { 10 }, writeBody: { _ in false })
		XCTAssertFalse(malformed.consume(Data([0, 0, 0, 9, 72, 1])))
		XCTAssertEqual(malformed.failure, "protocol")
		let expired = ManagedBootstrapCollector(maximumBytes: nil, remaining: { 0 }, writeBody: { _ in XCTFail("Expired bytes must not reach disk"); return true })
		XCTAssertFalse(expired.consume(try frame(72, ["version": 1, "status": 200, "headers": []])))
		XCTAssertEqual(expired.failure, "deadline")
	}

	func testActualDescriptorPublicationRequiresPersistedDigestAndExclusiveDestination() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let output = directory.appendingPathComponent("archive.bin")
		let spool = try XCTUnwrap(ManagedBootstrapSpool(output: output.path))
		XCTAssertTrue(spool.write(Data("abc".utf8), remaining: { 10 }))
		XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Partial bytes are not published")
		XCTAssertFalse(spool.verify(digest: String(repeating: "0", count: 64), bytes: 3, remaining: { 10 }))
		XCTAssertTrue(spool.verify(digest: digest, bytes: 3, remaining: { 10 }))
		XCTAssertTrue(spool.publish(bytes: 3, remaining: { 10 }))
		XCTAssertTrue(spool.close(success: true))
		XCTAssertEqual(try Data(contentsOf: output), Data("abc".utf8))
		let refused = try XCTUnwrap(ManagedBootstrapSpool(output: output.path))
		XCTAssertTrue(refused.write(Data("replacement".utf8), remaining: { 10 }))
		XCTAssertFalse(refused.publish(bytes: 11, remaining: { 10 }))
		XCTAssertTrue(refused.close(success: false))
		XCTAssertEqual(try Data(contentsOf: output), Data("abc".utf8), "Exclusive publication preserves every preexisting byte")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["archive.bin"])
	}

	func testActualCleanupPreservesAReplacementOfItsOwnedCaptureName() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let spool = try XCTUnwrap(ManagedBootstrapSpool(output: directory.appendingPathComponent("archive.bin").path))
		XCTAssertTrue(spool.write(Data("abc".utf8), remaining: { 10 }))
		let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		XCTAssertEqual(names.count, 1, "A real exclusive capture must exist before testing replacement")
		let capture = directory.appendingPathComponent(try XCTUnwrap(names.first))
		try FileManager.default.moveItem(at: capture, to: directory.appendingPathComponent("displaced-owned.bin"))
		let foreign = Data("independent replacement bytes".utf8)
		try foreign.write(to: capture, options: .withoutOverwriting)
		XCTAssertFalse(spool.verify(digest: digest, bytes: 3, remaining: { 10 }))
		XCTAssertFalse(spool.close(success: false), "A changed capture pathname reports cleanup debt")
		XCTAssertEqual(try Data(contentsOf: capture), foreign, "Cleanup never removes the replacement inode")
	}

	func testActualRetainedDirectoryRefusesPublicationAfterNamespaceReplacement() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: root) }
		let original = root.appendingPathComponent("current")
		try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		let spool = try XCTUnwrap(ManagedBootstrapSpool(output: original.appendingPathComponent("archive.bin").path))
		XCTAssertTrue(spool.write(Data("abc".utf8), remaining: { 10 }))
		XCTAssertTrue(spool.verify(digest: digest, bytes: 3, remaining: { 10 }))
		try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved"))
		try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		let foreign = Data("unrelated destination".utf8)
		let replacement = original.appendingPathComponent("archive.bin")
		try foreign.write(to: replacement, options: .withoutOverwriting)
		XCTAssertFalse(spool.publish(bytes: 3, remaining: { 10 }))
		XCTAssertTrue(spool.close(success: false), "The retained original directory still permits exact owned capture cleanup")
		XCTAssertEqual(try Data(contentsOf: replacement), foreign)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("moved").path), [])
	}

	func testActualNativeBootstrapTLSFullURLPACAndArtifactPublication() throws {
		let fixture = try ManagedWireFixture()
		defer {
			do { try fixture.close() }
			catch { XCTFail("Actual bootstrap fixture did not restore trust, hosts, keychain and native processes") }
		}
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		let host = try XCTUnwrap(fixture.profile["host"] as? String)
		let port = try XCTUnwrap(fixture.profile["origin_port"] as? Int)
		let script = try XCTUnwrap(fixture.profile["pac"] as? String)
		let pacURL = try XCTUnwrap(fixture.profile["pac_url"] as? String)
		let expected = Data([111, 119, 110, 101, 100, 0, 110, 97, 116, 105, 118, 101, 255, 119, 105, 114, 101])
		let expectedDigest = "87f8e549e9de9c2685521b6594c1c889492f1ebf7e5aeece5449e797f208391e"
		let policy = try XCTUnwrap(ManagedBootstrapPolicy.parse(JSONSerialization.data(withJSONObject: policyFields)))

		func download(_ path: String, name: String, useURL: Bool = false) throws -> String {
			let fields: [String: Any] = ["version": 1, "url": "https://\(host):\(port)\(path)",
				"sha256": expectedDigest, "output": directory.appendingPathComponent(name).path,
				"timeout_ms": 20_000, "size": 17]
			let request = try XCTUnwrap(ManagedBootstrapRequest.parse(JSONSerialization.data(withJSONObject: fields)))
			var settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1]
			if useURL { settings[kCFNetworkProxiesProxyAutoConfigURLString as String] = pacURL }
			else { settings[kCFNetworkProxiesProxyAutoConfigJavaScript as String] = script }
			return ManagedBootstrapDownload.execute(request, policy: policy, environment: [:], settingsProvider: { settings as CFDictionary })
		}

		XCTAssertEqual(try download("/alpha?case=one", name: "untrusted.bin"), "certificate")
		XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("untrusted.bin").path))
		XCTAssertEqual(try fixture.command(["command": "trust", "enabled": true])["trusted"] as? Bool, true)
		for (path, name, useURL) in [("/alpha?case=one", "first.bin", false),
			("/beta?case=two", "second.bin", true), ("/fallback?case=three", "fallback.bin", false)] {
			XCTAssertEqual(try download(path, name: name, useURL: useURL), "complete")
			XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), expected)
			XCTAssertEqual(try fixture.command(["command": "stats"])["active"] as? Int, 0,
				"Artifact publication follows physical native session/socket closure")
		}
		XCTAssertEqual(try download("/alpha?case=one", name: "first.bin"), "file_publish")
		XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("first.bin")), expected,
			"Actual native transfer never overwrites a preexisting destination")
		XCTAssertEqual(try download("/redirect?case=five", name: "redirect.bin"), "complete")
		XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("redirect.bin")), expected,
			"The final redirected URL receives its own native PAC route and pinned bytes")
		XCTAssertEqual(try download("/downgrade?case=six", name: "downgrade.bin"), "http")
		XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("downgrade.bin").path),
			"An HTTPS redirect cannot contact an HTTP successor or publish partial bytes")
		let stats = try fixture.command(["command": "stats"])
		XCTAssertEqual(stats["active"] as? Int, 0)
		let records = try XCTUnwrap(stats["records"] as? [[String: Any]])
		let origins = records.filter { $0["event"] as? String == "origin" }
		XCTAssertEqual(origins.map { $0["path"] as? String },
			["/alpha?case=one", "/beta?case=two", "/fallback?case=three", "/alpha?case=one",
				"/redirect?case=five", "/beta?case=two", "/downgrade?case=six"])
		XCTAssertEqual(origins.map { $0["route"] as? String }, ["first", "second", "first", "first", "first", "second", "first"])
		let closed = records.filter { $0["event"] as? String == "redirect_closed" }
		XCTAssertEqual(closed.count, 2)
		XCTAssertTrue(closed.allSatisfy { $0["eof"] as? Bool == true },
			"Both held redirect bodies are physically cancelled at headers")
		let cancelledIndex = try XCTUnwrap(records.firstIndex { $0["event"] as? String == "redirect_closed"
			&& $0["path"] as? String == "/redirect?case=five" })
		let successorIndex = try XCTUnwrap(records.indices.first { $0 > cancelledIndex
			&& records[$0]["event"] as? String == "origin" && records[$0]["path"] as? String == "/beta?case=two" })
		XCTAssertLessThan(cancelledIndex, successorIndex,
			"The first redirect's physical socket retirement precedes the successor origin")
		XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
			Set(["first.bin", "second.bin", "fallback.bin", "redirect.bin"]))
		try fixture.close()
	}
}

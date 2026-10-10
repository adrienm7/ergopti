// Tests/ErgoptiPlusTests/ManagedHTTPWPADWireTests.swift
// Injected native DHCP metadata joins actual CFNetwork PAC fetch and NSURLSession.

import CFNetwork
import Foundation
import XCTest
@testable import ErgoptiPlus

final class ManagedHTTPWPADWireTests: XCTestCase {
	/// Provider injection qualifies the receiving boundary, while acquiring
	/// actual customer DHCP/DNS settings remains a separate device check.
	func testDHCPMetadataOwnsRealPACURLRoutesAndRefusesInvalidDiscoveryBeforeNetwork() throws {
		let fixture = try ManagedWireFixture()
		defer {
			do { try fixture.close() }
			catch { XCTFail("WPAD receiving fixture did not restore owned trust and private keychain") }
		}
		let host = try XCTUnwrap(fixture.profile["host"] as? String)
		let port = try XCTUnwrap(fixture.profile["origin_port"] as? Int)
		let ports = try XCTUnwrap(fixture.profile["ports"] as? [String: Int])
		let refused = try XCTUnwrap(ports["refused"])
		let pacURL = try XCTUnwrap(fixture.profile["pac_url"] as? String)
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1,
			kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
			kCFNetworkProxiesHTTPSPort as String: refused]

		func execute(_ path: String, metadata: ManagedWPADMetadata, expired: Bool = false) throws -> (Int32, [(UInt8, Data)], Int) {
			let fields: [String: Any] = ["version": 1, "url": "https://\(host):\(port)\(path)",
				"method": "GET", "headers": [["Accept-Encoding", "identity"]],
				"timeout": 20, "idle_timeout": 10, "direct": false]
			let request = try XCTUnwrap(ManagedHTTPRequest.parse(JSONSerialization.data(withJSONObject: fields)))
			let collector = ManagedWireFrames()
			var reads = 0
			let status = ManagedHTTPWorker.execute(request, maximumSelections: 128,
				started: ProcessInfo.processInfo.systemUptime - (expired ? 21 : 0),
				settingsProvider: { settings as CFDictionary },
				discoveryMetadataProvider: { reads += 1; return metadata }, output: collector.append)
			return (status, try collector.frames(), reads)
		}

		func terminal(_ frames: [(UInt8, Data)]) throws -> [String: Any] {
			XCTAssertEqual(frames.filter { $0.0 == 67 }.count, 1)
			let last = try XCTUnwrap(frames.last)
			XCTAssertEqual(last.0, 67)
			return try XCTUnwrap(JSONSerialization.jsonObject(with: last.1) as? [String: Any])
		}

		for metadata in [ManagedWPADMetadata(dhcpOption: nil, searchDomains: []),
			ManagedWPADMetadata(dhcpOption: Data("https://reserved:credential@pac.example/a".utf8), searchDomains: ["corp"])] {
			let result = try execute("/alpha?case=one", metadata: metadata)
			XCTAssertEqual(result.0, 78)
			XCTAssertEqual(result.2, 1)
			XCTAssertEqual(try terminal(result.1)["reason"] as? String, "unavailable")
			XCTAssertFalse(result.1.contains { $0.0 == 72 || $0.0 == 68 })
		}
		let metadata = ManagedWPADMetadata(dhcpOption: Data(pacURL.utf8), searchDomains: ["corp"])
		let expired = try execute("/alpha?case=one", metadata: metadata, expired: true)
		XCTAssertEqual(expired.0, 75)
		XCTAssertEqual(expired.2, 0, "Expired original budget refuses before even reading discovery metadata")
		XCTAssertEqual(try terminal(expired.1)["reason"] as? String, "deadline")
		let before = try fixture.command(["command": "stats"])
		XCTAssertEqual((before["records"] as? [[String: Any]])?.count, 0,
			"Invalid discovery never falls back to DIRECT or the configured fixed relay")
		XCTAssertEqual(before["active"] as? Int, 0)

		XCTAssertEqual(try fixture.command(["command": "trust", "enabled": true])["trusted"] as? Bool, true)
		for path in ["/alpha?case=one", "/beta?case=two"] {
			let result = try execute(path, metadata: metadata)
			if result.0 != 0 {
				// Inspect the original completed request only; never echo unknown frame data.
				var label = "unknown"
				if result.1.filter({ $0.0 == 67 }).count == 1,
					let last = result.1.last, last.0 == 67, last.1.count <= 65_536,
					let fields = (try? JSONSerialization.jsonObject(with: last.1)) as? [String: Any],
					let version = fields["version"] as? NSNumber,
					CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
					let reason = fields["reason"] as? String,
					["complete", "deadline", "cancelled", "offline", "certificate", "connect", "proxy", "unavailable"].contains(reason) {
					label = reason
				}
				print("# native_http_wpad_failure reason=\(label)")
			}
			XCTAssertEqual(result.0, 0)
			XCTAssertEqual(result.2, 1)
			XCTAssertEqual(try terminal(result.1)["success"] as? Bool, true)
			XCTAssertEqual(result.1.filter { $0.0 == 72 }.count, 1)
			let body = result.1.filter { $0.0 == 68 }.reduce(into: Data()) { $0.append($1.1) }
			XCTAssertEqual(body, Data([111, 119, 110, 101, 100, 0, 110, 97, 116, 105, 118, 101, 255, 119, 105, 114, 101]))
			XCTAssertEqual(try fixture.command(["command": "stats"])["active"] as? Int, 0)
		}
		let final = try fixture.command(["command": "stats"])
		let records = try XCTUnwrap(final["records"] as? [[String: Any]])
		let origins = records.filter { $0["event"] as? String == "origin" }
		XCTAssertEqual(origins.map { $0["path"] as? String }, ["/alpha?case=one", "/beta?case=two"])
		XCTAssertEqual(origins.map { $0["route"] as? String }, ["first", "second"])
		XCTAssertEqual(records.filter { $0["event"] as? String == "connect" }.count, 2)
		try fixture.close()
	}
}

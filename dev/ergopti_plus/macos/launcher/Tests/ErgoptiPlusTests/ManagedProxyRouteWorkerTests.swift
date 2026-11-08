// Tests/ErgoptiPlusTests/ManagedProxyRouteWorkerTests.swift
// The proxy-route role turns a system lookup into one exportable line or a stage code.

import Foundation
import CFNetwork
import Darwin
import XCTest
@testable import ErgoptiPlus

final class ManagedProxyRouteWorkerTests: XCTestCase {
	private let registry = "https://registry.example/"

	private func route(_ kind: CFString, host: String? = nil, port: Int? = nil) -> [String: Any] {
		var value: [String: Any] = [kCFProxyTypeKey as String: kind as String]
		if let host { value[kCFProxyHostNameKey as String] = host }
		if let port { value[kCFProxyPortNumberKey as String] = NSNumber(value: port) }
		return value
	}

	func testHandlesOnlyItsFlag() {
		XCTAssertTrue(ManagedProxyRouteWorker.handles(arguments: ["ErgoptiPlus", "--managed-proxy-route", registry, "8"]))
		XCTAssertFalse(ManagedProxyRouteWorker.handles(arguments: ["ErgoptiPlus", "--managed-http-worker"]))
	}

	func testDirectRouteIsExportedAsDirect() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeNone)), "direct")
	}

	func testHttpAndHttpsProxiesBecomeAnHttpProxyUrl() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "proxy.corp.example", port: 3128)),
			"http://proxy.corp.example:3128")
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTPS, host: "proxy.corp.example", port: 8080)),
			"http://proxy.corp.example:8080")
	}

	func testSocksProxyBecomesSocks5AndIPv6IsBracketed() {
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeSOCKS, host: "10.0.0.2", port: 1080)),
			"socks5://10.0.0.2:1080")
		XCTAssertEqual(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "fd00::1", port: 3128)),
			"http://[fd00::1]:3128")
	}

	func testHostThatCouldSmuggleAnotherUrlIsRefused() {
		for host in ["a@b.example", "a/b.example", "a b.example", "a.example?x", "", "h\u{0}"] {
			XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: host, port: 3128)), host)
		}
	}

	func testPortOutsideTheRangeOrMissingIsRefused() {
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example", port: 0)))
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example", port: 70000)))
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeHTTP, host: "p.example")))
	}

	func testUnknownRouteKindIsRefused() {
		XCTAssertNil(ManagedProxyRouteWorker.text(for: route(kCFProxyTypeFTP, host: "p.example", port: 21)))
	}

	func testOriginMustBeAnHttpsUrlWithoutCredentials() {
		XCTAssertNotNil(ManagedProxyRouteWorker.origin(registry))
		XCTAssertNil(ManagedProxyRouteWorker.origin("http://registry.example/"))
		XCTAssertNil(ManagedProxyRouteWorker.origin("https://user:pw@registry.example/"))
		XCTAssertNil(ManagedProxyRouteWorker.origin("https://registry.example/ x"))
	}

	func testArgumentsOutsideTheContractAreAUsageError() {
		let settings: () -> CFDictionary? = { nil }
		for arguments in [["x", "--managed-proxy-route"], ["x", "--managed-proxy-route", registry],
			["x", "--managed-proxy-route", registry, "0"], ["x", "--managed-proxy-route", registry, "121"],
			["x", "--managed-proxy-route", registry, "nan"], ["x", "--managed-proxy-route", "http://a.example/", "8"]] {
			XCTAssertEqual(ManagedProxyRouteWorker.run(arguments: arguments, settingsProvider: settings),
				ManagedProxyRouteWorker.usageExit, arguments.joined(separator: " "))
		}
	}

	func testUnreadableSettingsExitWithTheLookupStage() {
		XCTAssertEqual(ManagedProxyRouteWorker.run(arguments: ["x", "--managed-proxy-route", registry, "8"],
			settingsProvider: { nil }), ManagedProxyRouteWorker.unusableExit)
		let failed = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 8,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { nil })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(failed, deadline: .infinity).stage, "native_proxy_lookup")
	}

	func testAStaticPacScriptSelectsTheFirstReachableRoute() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'PROXY selected.example:3111; DIRECT'; }"]
		let result = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 20,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { settings as CFDictionary })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(result, deadline: .infinity, probe: { _, _, _ in true }).route,
			"http://selected.example:3111")
	}

	func testAPacThatSaysDirectIsExportedAsDirect() {
		let settings: [String: Any] = [kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
			kCFNetworkProxiesProxyAutoConfigJavaScript as String:
				"function FindProxyForURL(url, host) { return 'DIRECT'; }"]
		let result = ManagedProxyLookup.resolve(url: URL(string: registry)!, budget: 20,
			maximumSelections: ManagedProxyRouteWorker.maximumSelections, settingsProvider: { settings as CFDictionary })
		XCTAssertEqual(ManagedProxyRouteWorker.outcome(result, deadline: .infinity).route, "direct")
	}

	func testPacListWalkSkipsUnreachableRelayBeforeDirect() {
		let choices = [route(kCFProxyTypeHTTP, host: "dead.example", port: 3128), route(kCFProxyTypeNone)]
		var probed: [String] = []
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 10,
			probe: { host, port, budget in
				probed.append(host)
				XCTAssertEqual(port, 3128)
				XCTAssertEqual(budget, LauncherTimings.managedProxyProbeTimeout.seconds)
				return false
			}, now: { 0 })
		XCTAssertEqual(answer.route, "direct")
		XCTAssertNil(answer.stage)
		XCTAssertEqual(probed, ["dead.example"])
	}

	func testPacListWalkKeepsReachableRelayAndStopsBeforeDirect() {
		let choices = [route(kCFProxyTypeHTTP, host: "dead.example", port: 3128),
			route(kCFProxyTypeSOCKS, host: "live.example", port: 1080), route(kCFProxyTypeNone)]
		var probed: [String] = []
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 10,
			probe: { host, _, _ in probed.append(host); return host == "live.example" }, now: { 0 })
		XCTAssertEqual(answer.route, "socks5://live.example:1080")
		XCTAssertEqual(probed, ["dead.example", "live.example"])
	}

	func testPacListWalkKeepsLastRelayUnprobed() {
		let choices = [route(kCFProxyTypeHTTP, host: "dead.example", port: 3128),
			route(kCFProxyTypeHTTP, host: "last.example", port: 8080)]
		var probed: [String] = []
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 10,
			probe: { host, _, _ in probed.append(host); return false }, now: { 0 })
		XCTAssertEqual(answer.route, "http://last.example:8080")
		XCTAssertEqual(probed, ["dead.example"])
	}

	func testPacListWalkDirectNeverProbesLaterRelays() {
		let choices = [route(kCFProxyTypeNone), route(kCFProxyTypeHTTP, host: "unused.example", port: 3128)]
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 10,
			probe: { _, _, _ in XCTFail("DIRECT must not probe a relay"); return false }, now: { 0 })
		XCTAssertEqual(answer.route, "direct")
	}

	func testPacListWalkRefusesMalformedLaterRouteBeforeProbing() {
		let choices = [route(kCFProxyTypeHTTP, host: "live.example", port: 3128),
			route(kCFProxyTypeHTTP, host: "invalid.example", port: 70000)]
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 10,
			probe: { _, _, _ in XCTFail("The whole list must be validated first"); return true }, now: { 0 })
		XCTAssertNil(answer.route)
		XCTAssertEqual(answer.stage, "native_proxy_dictionary")
	}

	func testPacListWalkBudgetExpiryNeverInventsDirect() {
		let choices = [route(kCFProxyTypeHTTP, host: "slow.example", port: 3128), route(kCFProxyTypeNone)]
		var clock = 0.0
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 0.25,
			probe: { _, _, budget in
				XCTAssertEqual(budget, 0.25)
				clock = 0.25
				return false
			}, now: { clock })
		XCTAssertNil(answer.route)
		XCTAssertEqual(answer.stage, "native_dispatch_deadline")
	}

	func testPacListWalkBudgetExpiryRejectsLateSuccess() {
		let choices = [route(kCFProxyTypeHTTP, host: "slow.example", port: 3128), route(kCFProxyTypeNone)]
		var clock = 0.0
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 0.25,
			probe: { _, _, _ in clock = 0.3; return true }, now: { clock })
		XCTAssertNil(answer.route)
		XCTAssertEqual(answer.stage, "native_dispatch_deadline")
	}

	func testPacListWalkExhaustedLookupBudgetNeverStartsProbe() {
		let choices = [route(kCFProxyTypeHTTP, host: "unused.example", port: 3128), route(kCFProxyTypeNone)]
		let answer = ManagedProxyRouteWorker.outcome(.success(choices), deadline: 1,
			probe: { _, _, _ in XCTFail("The lookup spent the budget"); return false }, now: { 1 })
		XCTAssertNil(answer.route)
		XCTAssertEqual(answer.stage, "native_dispatch_deadline")
	}

	func testNativeTcpProbeRejectsInvalidBudgetAndPort() {
		XCTAssertFalse(ManagedProxyRouteWorker.tcpReachable(host: "127.0.0.1", port: 0, budget: 1))
		XCTAssertFalse(ManagedProxyRouteWorker.tcpReachable(host: "127.0.0.1", port: 80, budget: 0))
	}

	func testNativeTcpProbeReachesListenerAndRetiresConnection() {
		let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
		XCTAssertGreaterThanOrEqual(listener, 0)
		guard listener >= 0 else { return }
		defer { close(listener) }
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		let bound = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		XCTAssertEqual(bound, 0)
		guard bound == 0 else { return }
		XCTAssertEqual(listen(listener, 1), 0)
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let named = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
		}
		XCTAssertEqual(named, 0)
		guard named == 0 else { return }
		XCTAssertTrue(ManagedProxyRouteWorker.tcpReachable(host: "127.0.0.1",
			port: Int(UInt16(bigEndian: address.sin_port)), budget: LauncherTimings.managedProxyProbeTimeout.seconds))
		// A bounded accept keeps a broken probe from hanging the native suite.
		XCTAssertNotEqual(fcntl(listener, F_SETFL, O_NONBLOCK), -1)
		let peer = accept(listener, nil, nil)
		XCTAssertGreaterThanOrEqual(peer, 0)
		guard peer >= 0 else { return }
		defer { close(peer) }
		XCTAssertNotEqual(fcntl(peer, F_SETFL, 0), -1)
		let microseconds = LauncherTimings.managedProxyProbeTimeout.microseconds
		var timeout = timeval(tv_sec: Int(microseconds / 1_000_000), tv_usec: Int32(microseconds % 1_000_000))
		let timed = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		XCTAssertEqual(timed, 0)
		guard timed == 0 else { return }
		var byte: UInt8 = 0
		XCTAssertEqual(recv(peer, &byte, 1, 0), 0, "The probe must close without sending an application byte")
	}

	func testNoStageCodeCarriesAnAddress() {
		for stage in ManagedHTTPFailureStage.allCases {
			XCTAssertTrue(stage.rawValue.hasPrefix("native_"))
			XCTAssertFalse(stage.rawValue.contains("://"))
		}
	}
}

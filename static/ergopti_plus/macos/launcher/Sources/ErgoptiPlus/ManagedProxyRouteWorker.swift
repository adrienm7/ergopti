// Sources/ErgoptiPlus/ManagedProxyRouteWorker.swift
// Headless role that names the system route (PAC and WPAD included) for one HTTPS origin.

import CFNetwork
import Foundation
import Network

/// An Ollama daemon Ergopti starts cannot evaluate a PAC: it reads only
/// HTTPS_PROXY. This role resolves the origin through the same native lookup
/// the managed downloader uses and prints the first reachable route, so the
/// shell that starts the daemon can hand it that one variable. A relay with
/// another PAC entry after it is probed within the shared deadline; the last
/// entry is kept unprobed, as on Linux and Windows.
///
/// Protocol: `--managed-proxy-route <https-url> <budget-seconds>`.
/// stdout, exit 0: one line, `ROUTE direct` or `ROUTE <scheme>://<host>:<port>`.
/// stderr, exit 78: one line, `STAGE <native_*>`, the closed failure-stage code
/// of the shared inventory, never an address. Exit 64: malformed arguments.
enum ManagedProxyRouteWorker {
	static let flag = "--managed-proxy-route"
	/// Pinned to `max_selections` of proxy_policy.json by test-managed-proxy-route-contract.cjs.
	static let maximumSelections = 128
	/// Longest lookup the caller may ask for, in seconds.
	static let maximumBudgetSeconds = 120.0
	static let unusableExit: Int32 = 78
	static let usageExit: Int32 = 64

	static func handles(arguments: [String]) -> Bool { arguments.dropFirst().first == flag }

	/// Characters a proxy host may carry into an environment URL. Anything
	/// else could smuggle a path, credentials or a second URL into HTTPS_PROXY.
	private static func isSafeHost(_ host: String) -> Bool {
		return !host.isEmpty && host.utf8.count <= 253 && host.unicodeScalars.allSatisfy { scalar in
			switch scalar {
			case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_", ":": return true
			default: return false
			}
		}
	}

	/// Turns one native route into the text the shell exports.
	/// - Returns: `direct`, a proxy URL, or nil when the route cannot be exported.
	static func text(for route: [String: Any]) -> String? {
		guard let kind = route[kCFProxyTypeKey as String] as? String else { return nil }
		if kind == kCFProxyTypeNone as String { return "direct" }
		let scheme: String
		if kind == kCFProxyTypeHTTP as String || kind == kCFProxyTypeHTTPS as String { scheme = "http" }
		else if kind == kCFProxyTypeSOCKS as String { scheme = "socks5" }
		else { return nil }
		guard let host = route[kCFProxyHostNameKey as String] as? String, isSafeHost(host),
			let port = route[kCFProxyPortNumberKey as String] as? NSNumber,
			CFGetTypeID(port) != CFBooleanGetTypeID(), port.doubleValue == Double(port.intValue),
			(1...65535).contains(port.intValue) else { return nil }
		let authority = host.contains(":") ? "[" + host + "]" : host
		return scheme + "://" + authority + ":" + String(port.intValue)
	}

	/// A TCP connection probe, including asynchronous DNS, bounded by the caller.
	/// Network.framework owns address iteration. Cancellation is requested before
	/// returning; the headless role bounds any remaining asynchronous retirement.
	static func tcpReachable(host: String, port: Int, budget: TimeInterval) -> Bool {
		guard budget.isFinite, budget > 0, let number = UInt16(exactly: port),
			number > 0, let endpoint = NWEndpoint.Port(rawValue: number) else { return false }
		let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
		let queue = DispatchQueue(label: "com.ergopti.managed-route-probe")
		let completed = DispatchSemaphore(value: 0)
		let lock = NSLock()
		var reachable = false
		connection.stateUpdateHandler = { state in
			switch state {
			case .ready:
				lock.lock(); reachable = true; lock.unlock()
				completed.signal()
			case .failed, .waiting, .cancelled: completed.signal()
			default: break
			}
		}
		connection.start(queue: queue)
		let settled = completed.wait(timeout: .now() + budget) == .success
		connection.cancel()
		lock.lock()
		defer { lock.unlock() }
		return settled && reachable
	}

	/// Walks the ordered PAC selections, keeping the last relay unprobed.
	/// - Returns: (stdout, stderr), exactly one of them non-nil. A spent probe
	///   deadline is a dispatch refusal, never evidence of an unavailable PAC.
	static func outcome(_ result: Result<[[String: Any]], ManagedLookupFailure>, deadline: TimeInterval,
		probe: (String, Int, TimeInterval) -> Bool = tcpReachable,
		now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> (route: String?, stage: String?) {
		switch result {
		case .failure(let failure): return (nil, failure.stage.rawValue)
		case .success(let routes):
			guard !routes.isEmpty else { return (nil, ManagedHTTPFailureStage.routeEmpty.rawValue) }
			let texts = routes.compactMap { text(for: $0) }
			guard texts.count == routes.count else { return (nil, ManagedHTTPFailureStage.proxyDictionary.rawValue) }
			for (index, route) in routes.enumerated() {
				let remaining = deadline - now()
				guard remaining > 0 else { return (nil, ManagedHTTPFailureStage.dispatchDeadline.rawValue) }
				let selected = texts[index]
				if selected == "direct" || index == routes.count - 1 { return (selected, nil) }
				guard let host = route[kCFProxyHostNameKey as String] as? String,
					let port = route[kCFProxyPortNumberKey as String] as? NSNumber else {
					return (nil, ManagedHTTPFailureStage.proxyDictionary.rawValue)
				}
				let reachable = probe(host, port.intValue, min(LauncherTimings.managedProxyProbeTimeout.seconds, remaining))
				guard now() < deadline else { return (nil, ManagedHTTPFailureStage.dispatchDeadline.rawValue) }
				if reachable { return (selected, nil) }
			}
			return (nil, ManagedHTTPFailureStage.routeEmpty.rawValue)
		}
	}

	/// Parses and validates the origin: HTTPS, a host, no credentials.
	static func origin(_ text: String) -> URL? {
		guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
			url.user == nil, url.password == nil, url.fragment == nil,
			!text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { return nil }
		return url
	}

	static func run(arguments: [String],
		settingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() }) -> Int32 {
		guard arguments.count == 4, let url = origin(arguments[2]), let budget = Double(arguments[3]),
			budget.isFinite, budget > 0, budget <= maximumBudgetSeconds else { return usageExit }
		let deadline = ProcessInfo.processInfo.systemUptime + budget
		let result = ManagedProxyLookup.resolve(url: url, budget: budget, maximumSelections: maximumSelections,
			settingsProvider: settingsProvider)
		let decided = outcome(result, deadline: deadline)
		if let route = decided.route {
			print("ROUTE " + route)
			return 0
		}
		FileHandle.standardError.write(Data(("STAGE " + (decided.stage ?? "native_route_empty") + "\n").utf8))
		return unusableExit
	}
}

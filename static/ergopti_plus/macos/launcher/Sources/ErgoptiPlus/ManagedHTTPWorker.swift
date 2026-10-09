// Sources/ErgoptiPlus/ManagedHTTPWorker.swift
// Native request-level transport for owned download clients. Private request
// bytes travel over stdin; stdout is a bounded binary protocol, never a log.

import CFNetwork
import CoreFoundation
import CPOSIXCompatibility
import Darwin
import Foundation
import Security
import SystemConfiguration

/// One exact, replayable HTTP request. Redirects belong to the caller, so every
/// redirected URL crosses the same native request boundary again.
struct ManagedHTTPRequest {
	let url: URL
	let method: String
	let headers: [(String, String)]
	let timeout: TimeInterval?
	let idleTimeout: TimeInterval
	let direct: Bool

	static func parse(_ bytes: Data) -> ManagedHTTPRequest? {
		guard bytes.count <= 65_536,
			let object = try? JSONSerialization.jsonObject(with: bytes),
			let fields = object as? [String: Any],
			Set(fields.keys) == Set(["version", "url", "method", "headers", "timeout", "idle_timeout", "direct"]),
			let version = fields["version"] as? NSNumber,
			CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
			let text = fields["url"] as? String, !text.utf8.contains(0),
			let url = URL(string: text), let scheme = url.scheme, ["https", "http"].contains(scheme),
			let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
			url.fragment == nil,
			let method = fields["method"] as? String, ["GET", "HEAD"].contains(method),
			let pairs = fields["headers"] as? [[String]], pairs.count <= 128,
			let idle = fields["idle_timeout"] as? NSNumber,
			CFGetTypeID(idle) != CFBooleanGetTypeID(), idle.doubleValue.isFinite, idle.doubleValue > 0,
			let directNumber = fields["direct"] as? NSNumber,
			CFGetTypeID(directNumber) == CFBooleanGetTypeID()
		else { return nil }
		let timeout: TimeInterval?
		if fields["timeout"] is NSNull { timeout = nil }
		else if let value = fields["timeout"] as? NSNumber,
			CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue > 0 {
			timeout = value.doubleValue
		} else { return nil }
		let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
		var names = Set<String>()
		var headers: [(String, String)] = []
		for pair in pairs {
			guard pair.count == 2, !pair[0].isEmpty,
				pair[0].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
					|| (97...122).contains($0) || punctuation.contains($0) }),
				!pair[1].unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
				names.insert(pair[0].lowercased()).inserted
			else { return nil }
			headers.append((pair[0], pair[1]))
		}
		return ManagedHTTPRequest(url: url, method: method, headers: headers,
			timeout: timeout, idleTimeout: idle.doubleValue, direct: directNumber.boolValue)
	}
}

/// The payload byte tags distinguish headers, body and terminal evidence. A
/// truncated pipe never becomes successful EOF, even after response headers.
enum ManagedHTTPFrame {
	static let maximumPayload = 65_536

	static func encode(tag: UInt8, bytes: Data) -> Data? {
		guard bytes.count < maximumPayload else { return nil }
		let count = UInt32(bytes.count + 1)
		var result = Data([
			UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
			UInt8((count >> 8) & 255), UInt8(count & 255), tag
		])
		result.append(bytes)
		return result
	}
}

private final class ManagedPACResult {
	var received = false
	var proxies: CFArray?
	var failed = false
}

private func managedPACCallback(_ context: UnsafeMutableRawPointer, _ proxies: CFArray, _ error: CFError?) {
	#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
	managedHTTPFixtureStage("pac_callback")
	#endif
	let result = Unmanaged<ManagedPACResult>.fromOpaque(context).takeUnretainedValue()
	result.proxies = error == nil ? proxies : nil
	result.failed = error != nil
	result.received = true
}

/// Native discovery metadata stays separate from test-owned PAC settings.
struct ManagedWPADMetadata {
	let dhcpOption: Data?
	let searchDomains: [String]
}

/// Resolves the exact URL explicitly, before origin TLS. An authority-only
/// CONNECT observation is never used as the PAC input.
enum ManagedProxyLookup {
	static func routes(url: URL, budget: TimeInterval, maximumSelections: Int,
		settingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() },
		discoveryMetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {
		guard let settings = settingsProvider() else { return nil }
		let dictionary = (settings as AnyObject) as? [String: Any]
		let discoveryEnabled = (dictionary?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? NSNumber)?.boolValue == true
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("proxy_copy")
		#endif
		let initial: AnyObject = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("proxy_copied")
		#endif
		guard let candidates = initial as? [[String: Any]], !candidates.isEmpty || discoveryEnabled,
			candidates.count <= maximumSelections else { return nil }
		// A native PAC callback owns the complete choice list. Initial fallback
		// entries cannot add DIRECT or fixed proxies that the script omitted.
		let hasNativePAC = candidates.contains(where: {
			let kind = $0[kCFProxyTypeKey as String] as? String
			return kind == kCFProxyTypeAutoConfigurationURL as String
				|| kind == kCFProxyTypeAutoConfigurationJavaScript as String
		})
		var routes: [[String: Any]] = []
		let deadline = ProcessInfo.processInfo.systemUptime + budget
		for candidate in candidates {
			guard let kind = candidate[kCFProxyTypeKey as String] as? String else { return nil }
			if kind == kCFProxyTypeAutoConfigurationURL as String {
				guard let pacURL = candidate[kCFProxyAutoConfigurationURLKey as String] as? URL,
					let expanded = evaluate(url: url, pacURL: pacURL, script: nil, deadline: deadline),
					!expanded.isEmpty else { return nil }
				routes.append(contentsOf: expanded)
			} else if kind == kCFProxyTypeAutoConfigurationJavaScript as String {
				guard let script = candidate[kCFProxyAutoConfigurationJavaScriptKey as String] as? String,
					let expanded = evaluate(url: url, pacURL: nil, script: script, deadline: deadline),
					!expanded.isEmpty else { return nil }
				routes.append(contentsOf: expanded)
			} else if !hasNativePAC { routes.append(candidate) }
			guard routes.count <= maximumSelections else { return nil }
		}
		// CFNetwork can expose discovery as a flag without a PAC candidate.
		// Join that native state to public DHCP/DNS discovery metadata; never
		// relabel the initial DIRECT entry as proof that WPAD has completed.
		if discoveryEnabled,
			!hasNativePAC {
			guard let discovered = discover(url: url, deadline: deadline,
				maximumSelections: maximumSelections, metadataProvider: discoveryMetadataProvider) else { return nil }
			routes = discovered
		}
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("routes_done")
		managedHTTPFixtureRoutes(routes)
		#endif
		return routes.isEmpty ? nil : routes
	}

	/// Public SystemConfiguration metadata for the current primary service.
	/// The actual resolver owns search order and scoped DNS behavior. Configured
	/// metadata admits discovery, rather than constructing or devolving suffixes.
	static func discoveryURLs(dhcpOption: Data?, searchDomains: [String]) -> [URL]? {
		if let dhcpOption {
			guard !dhcpOption.isEmpty,
				let text = String(data: dhcpOption, encoding: .utf8),
				!text.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }),
				let endpoint = URL(string: text), let scheme = endpoint.scheme,
				["http", "https"].contains(scheme), let host = endpoint.host, !host.isEmpty,
				endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil
			else { return nil }
			// A supplied DHCP URL owns discovery. Invalid/unreachable DHCP PAC
			// is a refusal, rather than an unannounced switch to DNS discovery.
			return [endpoint]
		}
		let configured = searchDomains.contains { domain in
			let normalized = domain.lowercased().hasSuffix(".") ? String(domain.lowercased().dropLast()) : domain.lowercased()
			let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
			return normalized.utf8.count <= 253 && !labels.isEmpty
				&& labels.allSatisfy { label in
					!label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
						&& label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
				}
		}
		guard configured else { return [] }
		// CFNetwork performs this lookup through native DNS. Single-label company
		// domains remain valid; no application public-suffix approximation is used.
		guard let endpoint = URL(string: "http://wpad/wpad.dat") else { return nil }
		return [endpoint]
	}

	static func discoveryMetadata() -> ManagedWPADMetadata {
		var option: Data?
		if let info = SCDynamicStoreCopyDHCPInfo(nil, nil), let native = DHCPInfoGetOptionData(info, 252) {
			option = native as Data
		}
		let nativeDNS = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any]
		var domains = nativeDNS?[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
		if let domain = nativeDNS?[kSCPropNetDNSDomainName as String] as? String { domains.append(domain) }
		return ManagedWPADMetadata(dhcpOption: option, searchDomains: domains)
	}

	static func discover(url: URL, deadline: TimeInterval, maximumSelections: Int,
		metadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() }) -> [[String: Any]]? {
		let metadata = metadataProvider()
		guard let endpoints = discoveryURLs(dhcpOption: metadata.dhcpOption, searchDomains: metadata.searchDomains),
			!endpoints.isEmpty, endpoints.count <= maximumSelections else { return nil }
		for endpoint in endpoints {
			guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
			if let result = evaluate(url: url, pacURL: endpoint, script: nil, deadline: deadline),
				!result.isEmpty, result.count <= maximumSelections { return result }
		}
		return nil
	}

	static func evaluate(url: URL, pacURL: URL?, script: String?, deadline: TimeInterval) -> [[String: Any]]? {
		let result = ManagedPACResult()
		var context = CFStreamClientContext(version: 0,
			info: Unmanaged.passUnretained(result).toOpaque(), retain: nil, release: nil, copyDescription: nil)
		let source: CFRunLoopSource?
		if let pacURL {
			#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
			managedHTTPFixtureStage("pac_url")
			#endif
			source = CFNetworkExecuteProxyAutoConfigurationURL(pacURL as CFURL, url as CFURL,
				managedPACCallback, &context)
		} else if let script {
			#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
			managedHTTPFixtureStage("pac_script")
			#endif
			source = CFNetworkExecuteProxyAutoConfigurationScript(script as CFString, url as CFURL,
				managedPACCallback, &context)
		} else { return nil }
		guard let source else { return nil }
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("pac_source")
		#endif
		let loop = CFRunLoopGetCurrent()
		CFRunLoopAddSource(loop, source, CFRunLoopMode.defaultMode)
		defer {
			CFRunLoopRemoveSource(loop, source, CFRunLoopMode.defaultMode)
			CFRunLoopSourceInvalidate(source)
		}
		while !result.received {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { return nil }
			#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
			managedHTTPFixtureStage("pac_wait")
			#endif
			CFRunLoopRunInMode(CFRunLoopMode.defaultMode, remaining, true)
		}
		guard !result.failed, let proxies = result.proxies else { return nil }
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("pac_done")
		#endif
		let object: AnyObject = proxies
		return object as? [[String: Any]]
	}

	static func dictionary(route: [String: Any]) -> [AnyHashable: Any]? {
		guard let kind = route[kCFProxyTypeKey as String] as? String else { return nil }
		// The selected native route is final for this exact URL. Disable every
		// other system selector so NSURLSession cannot repeat PAC with an
		// authority-only HTTPS URL or inherit a foreign bypass list.
		var selected: [AnyHashable: Any] = [kCFNetworkProxiesHTTPEnable as String: 0,
			kCFNetworkProxiesHTTPSEnable as String: 0, kCFNetworkProxiesSOCKSEnable as String: 0,
			kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
			kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
			kCFNetworkProxiesExceptionsList as String: [String](),
			kCFNetworkProxiesExcludeSimpleHostnames as String: 0]
		if kind == kCFProxyTypeNone as String { return selected }
		guard let host = route[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
			!host.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }),
			let port = route[kCFProxyPortNumberKey as String] as? NSNumber,
			CFGetTypeID(port) != CFBooleanGetTypeID(), port.doubleValue == Double(port.intValue),
			(1...65535).contains(port.intValue) else { return nil }
		if kind == kCFProxyTypeHTTP as String || kind == kCFProxyTypeHTTPS as String {
			selected[kCFNetworkProxiesHTTPEnable as String] = 1
			selected[kCFNetworkProxiesHTTPProxy as String] = host
			selected[kCFNetworkProxiesHTTPPort as String] = port
			selected[kCFNetworkProxiesHTTPSEnable as String] = 1
			selected[kCFNetworkProxiesHTTPSProxy as String] = host
			selected[kCFNetworkProxiesHTTPSPort as String] = port
			return selected
		}
		if kind == kCFProxyTypeSOCKS as String {
			selected[kCFNetworkProxiesSOCKSEnable as String] = 1
			selected[kCFNetworkProxiesSOCKSProxy as String] = host
			selected[kCFNetworkProxiesSOCKSPort as String] = port
			return selected
		}
		return nil
	}
}

/// Native error codes only. URLs, certificate subjects and authentication
/// challenges are deliberately absent from the receiving protocol.
func managedHTTPFailure(_ error: NSError) -> String {
	guard error.domain == NSURLErrorDomain else { return "unavailable" }
	switch error.code {
	case NSURLErrorTimedOut: return "deadline"
	case NSURLErrorCancelled: return "cancelled"
	case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "offline"
	case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "offline"
	case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
		NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
		NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
		NSURLErrorClientCertificateRequired: return "certificate"
	case NSURLErrorUserAuthenticationRequired: return "unavailable"
	case NSURLErrorCannotConnectToHost: return "connect"
	default: return "unavailable"
	}
}

private final class ManagedHTTPSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let completion = DispatchSemaphore(value: 0)
	private var session: URLSession?
	private var receivedHeaders = false
	private var failure: String?
	private var proxyObserved = false
	private var nativeResponseObserved = false
	private var deliveredBytes = false
	private var refusedTCPConnect = false
	private var proxyAuthenticationObserved = false
	private let certificates: [SecCertificate]
	private let output: (Data) -> Bool
	private(set) var exitStatus: Int32 = 74
	var permitsProxyFailover: Bool {
		return failure == "connect" && proxyObserved && refusedTCPConnect
			&& !receivedHeaders && !nativeResponseObserved && !deliveredBytes
	}

	init(output: @escaping (Data) -> Bool, certificates: [SecCertificate]) {
		self.output = output
		self.certificates = certificates
	}

	private func write(tag: UInt8, bytes: Data) -> Bool {
		guard let frame = ManagedHTTPFrame.encode(tag: tag, bytes: bytes) else { return false }
		return output(frame)
	}

	private func json(tag: UInt8, object: [String: Any]) -> Bool {
		guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
		return write(tag: tag, bytes: data)
	}

	func execute(_ request: ManagedHTTPRequest, proxy: [AnyHashable: Any]) -> Int32 {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpCookieStorage = nil
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = request.idleTimeout
		if let timeout = request.timeout { configuration.timeoutIntervalForResource = timeout }
		configuration.connectionProxyDictionary = proxy
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		let owned = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
		session = owned
		var native = URLRequest(url: request.url)
		native.httpMethod = request.method
		for (name, value) in request.headers { native.setValue(value, forHTTPHeaderField: name) }
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("session_resume")
		#endif
		owned.dataTask(with: native).resume()
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("session_wait")
		#endif
		completion.wait()
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("session_done")
		#endif
		session = nil
		return exitStatus
	}

	func publishTerminal() -> Int32 {
		let success = failure == nil && exitStatus == 0
		let sent = json(tag: 67, object: ["version": 1, "success": success, "reason": failure ?? "complete"])
		return success && sent ? 0 : 74
	}

	func urlSession(_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void) {
		// HTTPX receives the original redirect and handles credential stripping,
		// hop limits and the next complete request URL before native dispatch.
		completionHandler(nil)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		guard !receivedHeaders, let response = response as? HTTPURLResponse,
			(100...599).contains(response.statusCode) else {
			failure = "protocol"; completionHandler(.cancel); return
		}
		// NSURLSession decodes content coding itself. Owned archive/model fetches
		// explicitly request identity; refuse a server violating that premise
		// rather than present already-decoded bytes as HTTPX raw encoded data.
		let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
		guard encoding == nil || encoding == "identity" else {
			failure = "content_encoding"; completionHandler(.cancel); return
		}
		let headers = response.allHeaderFields.map { [String(describing: $0.key), String(describing: $0.value)] }
		guard json(tag: 72, object: ["version": 1, "status": response.statusCode, "headers": headers]) else {
			failure = "protocol"; completionHandler(.cancel); return
		}
		receivedHeaders = true
		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		guard receivedHeaders, failure == nil else { dataTask.cancel(); return }
		if !data.isEmpty { deliveredBytes = true }
		var offset = 0
		while offset < data.count {
			let count = min(ManagedHTTPFrame.maximumPayload - 1, data.count - offset)
			guard write(tag: 68, bytes: data.subdata(in: offset..<(offset + count))) else {
				failure = "protocol"; dataTask.cancel(); return
			}
			offset += count
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if failure == nil, let error { failure = managedHTTPFailure(error as NSError) }
		if let error = error as NSError?, error.domain == NSURLErrorDomain,
			error.code == NSURLErrorUserAuthenticationRequired, proxyAuthenticationObserved { failure = "proxy" }
		if let error {
			var native = error as NSError
			var seen = Set<ObjectIdentifier>()
			while seen.insert(ObjectIdentifier(native)).inserted {
				if native.domain == NSPOSIXErrorDomain && native.code == Int(ECONNREFUSED) {
					refusedTCPConnect = true; break
				}
				guard let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
				native = underlying
			}
		}
		if !receivedHeaders && failure == nil { failure = "protocol" }
		session.finishTasksAndInvalidate()
	}

	func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
		if failure == nil, let error { failure = managedHTTPFailure(error as NSError) }
		#if ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS
		managedHTTPFixtureStage("session_invalid")
		#endif
		exitStatus = failure == nil ? 0 : 74
		completion.signal()
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
		for transaction in metrics.transactionMetrics {
			if transaction.isProxyConnection { proxyObserved = true }
			if transaction.response != nil || transaction.countOfResponseBodyBytesReceived != 0 {
				nativeResponseObserved = true
			}
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		answer(challenge, completionHandler: completionHandler)
	}

	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		answer(challenge, completionHandler: completionHandler)
	}

	private func answer(_ challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.protectionSpace.isProxy() { proxyAuthenticationObserved = true }
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, !certificates.isEmpty {
			guard let trust = challenge.protectionSpace.serverTrust,
				ManagedCertificateAuthorities.evaluate(trust, adding: certificates) else {
				failure = "certificate"; completionHandler(.cancelAuthenticationChallenge, nil); return
			}
			completionHandler(.useCredential, URLCredential(trust: trust)); return
		}
		completionHandler(.performDefaultHandling, nil)
	}
}

/// One headless request per physical process, before any application startup.
enum ManagedHTTPWorker {
	static let flag = "--managed-http-worker"

	static func handles(arguments: [String]) -> Bool { arguments.dropFirst().first == flag }

	private static func refuse(reason: String, status: Int32, output: (Data) -> Bool) -> Int32 {
		guard let json = try? JSONSerialization.data(withJSONObject: ["version": 1, "success": false, "reason": reason]),
			let frame = ManagedHTTPFrame.encode(tag: 67, bytes: json) else { return 74 }
		return output(frame) ? status : 74
	}

	private static func stdout(_ frame: Data) -> Bool {
		var offset = 0
		while offset < frame.count {
			let count = frame.withUnsafeBytes { bytes in
				Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
			}
			if count < 0 && errno == EINTR { continue }
			// Disconnection is cancellation. Physical process exit also retires
			// native sockets even if a delegate was blocked on pipe backpressure.
			guard count > 0 else { Darwin._exit(74) }
			offset += count
		}
		return true
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 4, let idle = Double(arguments[2]),
			idle.isFinite, idle > 0 else { return 64 }
		let budget: TimeInterval?
		if arguments[3] == "none" { budget = nil }
		else if let seconds = Double(arguments[3]), seconds.isFinite, seconds > 0 { budget = seconds }
		else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		// This watchdog also bounds malformed stdin and a consumer which stops
		// reading. It never renews on progress or redirects.
		let watchdog = DispatchSource.makeTimerSource(queue: .global())
		let parent = getppid()
		let started = ProcessInfo.processInfo.systemUptime
		watchdog.schedule(deadline: .now(), repeating: .milliseconds(20))
		watchdog.setEventHandler {
			if getppid() != parent { Darwin._exit(74) }
			if let budget, ProcessInfo.processInfo.systemUptime - started >= budget { Darwin._exit(75) }
		}
		watchdog.resume()
		defer { watchdog.cancel() }
		var input = Data()
		var bytes = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
			if count < 0 && errno == EINTR { continue }
			guard count >= 0 else { return 74 }
			if count == 0 { break }
			guard count <= 65_536 - input.count else { return 64 }
			input.append(contentsOf: bytes.prefix(count))
		}
		guard let request = ManagedHTTPRequest.parse(input), request.idleTimeout <= idle,
			request.timeout == budget else { return 64 }
		let policyURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/static/ergopti_plus/_shared/modules/network/proxy_policy.json")
		guard let bytes = try? Data(contentsOf: policyURL),
			let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			let maximum = object["max_selections"] as? NSNumber,
			CFGetTypeID(maximum) != CFBooleanGetTypeID(), maximum.doubleValue == Double(maximum.intValue), maximum.intValue > 0
		else { return refuse(reason: "unavailable", status: 78, output: stdout) }
		return execute(request, maximumSelections: maximum.intValue, started: started, output: stdout)
	}

	/// Native framework executor shared by the signed CLI and wire acceptance.
	/// Tests supply literal CF settings and a private output pipe here, never an
	/// alternate NSURLSession implementation or a release command-line override.
	static func execute(_ request: ManagedHTTPRequest, maximumSelections: Int,
		started: TimeInterval = ProcessInfo.processInfo.systemUptime,
		settingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() },
		discoveryMetadataProvider: () -> ManagedWPADMetadata = { ManagedProxyLookup.discoveryMetadata() },
		environment: [String: String] = ProcessInfo.processInfo.environment,
		output: @escaping (Data) -> Bool) -> Int32 {
		let certificates: [SecCertificate]
		do { certificates = try ManagedCertificateAuthorities.load(environment: environment) }
		catch { return refuse(reason: "certificate", status: 74, output: output) }
		guard maximumSelections > 0 else { return refuse(reason: "unavailable", status: 78, output: output) }
		let routes: [[String: Any]]
		if request.direct { routes = [[kCFProxyTypeKey as String: kCFProxyTypeNone as String]] }
		else {
			let lookupRemaining = request.timeout.map { $0 - (ProcessInfo.processInfo.systemUptime - started) }
			if let lookupRemaining, lookupRemaining <= 0 { return refuse(reason: "deadline", status: 75, output: output) }
			guard let selected = ManagedProxyLookup.routes(url: request.url,
				budget: min(lookupRemaining ?? request.idleTimeout, request.idleTimeout),
				maximumSelections: maximumSelections, settingsProvider: settingsProvider,
				discoveryMetadataProvider: discoveryMetadataProvider)
			else { return refuse(reason: "unavailable", status: 78, output: output) }
			routes = selected
		}
		for (index, route) in routes.enumerated() {
			guard let proxy = ManagedProxyLookup.dictionary(route: route) else { return refuse(reason: "proxy", status: 78, output: output) }
			let remaining = request.timeout.map { $0 - (ProcessInfo.processInfo.systemUptime - started) }
			if let remaining, remaining <= 0 { return refuse(reason: "deadline", status: 75, output: output) }
			let scoped = ManagedHTTPRequest(url: request.url, method: request.method,
				headers: request.headers, timeout: remaining, idleTimeout: request.idleTimeout, direct: request.direct)
			let owned = ManagedHTTPSession(output: output, certificates: certificates)
			let status = owned.execute(scoped, proxy: proxy)
			if status == 0 || !owned.permitsProxyFailover || index == routes.count - 1 {
				return owned.publishTerminal()
			}
		}
		return refuse(reason: "unavailable", status: 78, output: output)
	}
}

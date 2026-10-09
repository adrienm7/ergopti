// Sources/ErgoptiPlus/ManagedPACSource.swift
// Request-owned direct PAC retrieval and exact full-URL script binding.

import CFNetwork
import Foundation
import Security

/// Shared source rules apply before a PAC enters the public CFNetwork runtime.
enum ManagedPACSource {
	enum Refusal: Error { case policy, location, decoding, size, status, redirect, authentication, deadline }
	fileprivate enum Hop { case source(Data), redirect(URL) }

	struct Authority: Equatable {
		let scheme: String
		let host: String
		let port: Int

		init(_ url: URL) throws {
			guard let scheme = url.scheme?.lowercased(),
				ManagedNetworkBootstrapPolicy.pacSourceSchemes.contains(scheme),
				let host = url.host?.lowercased(), !host.isEmpty,
				url.user == nil, url.password == nil, url.fragment == nil,
				!url.absoluteString.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 })
			else { throw Refusal.location }
			let port = url.port ?? (scheme == "https" ? 443 : 80)
			guard (1...65535).contains(port) else { throw Refusal.location }
			self.scheme = scheme
			self.host = host
			self.port = port
		}
	}

	/// Foundation UTF-16 conversion may repair malformed input. Admit every
	/// surrogate pair explicitly so a PAC never executes replacement text.
	static func decode(_ bytes: Data) throws -> String {
		let maximum = ManagedNetworkBootstrapPolicy.maximumPACSourceBytes
		guard !bytes.isEmpty, bytes.count <= maximum else { throw Refusal.size }
		let values = [UInt8](bytes)
		let script: String
		if values.starts(with: [255, 254]) || values.starts(with: [254, 255]) {
			guard (values.count - 2) % 2 == 0 else { throw Refusal.decoding }
			let little = values[0] == 255
			var scalars = String.UnicodeScalarView()
			var at = 2
			func unit(_ index: Int) -> UInt32 {
				little ? UInt32(values[index]) | (UInt32(values[index + 1]) << 8)
					: (UInt32(values[index]) << 8) | UInt32(values[index + 1])
			}
			while at < values.count {
				let first = unit(at)
				at += 2
				let value: UInt32
				if (0xD800...0xDBFF).contains(first) {
					guard at < values.count else { throw Refusal.decoding }
					let second = unit(at)
					guard (0xDC00...0xDFFF).contains(second) else { throw Refusal.decoding }
					at += 2
					value = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
				} else {
					guard !(0xDC00...0xDFFF).contains(first) else { throw Refusal.decoding }
					value = first
				}
				guard let scalar = UnicodeScalar(value) else { throw Refusal.decoding }
				scalars.append(scalar)
			}
			script = String(scalars)
		} else {
			let data = values.starts(with: [239, 187, 191]) ? bytes.dropFirst(3) : bytes[...]
			guard let decoded = String(data: Data(data), encoding: .utf8) else { throw Refusal.decoding }
			script = decoded
		}
		guard !script.isEmpty, !script.utf8.contains(0), script.utf8.count <= maximum else { throw Refusal.size }
		return script
	}

	/// Preserve native PAC helpers and the public callback. Only the existing
	/// function's arguments are bound; an invalid/non-writable function refuses.
	static func bind(_ script: String, url: URL) throws -> String {
		_ = try Authority(url)
		guard !script.isEmpty, !script.utf8.contains(0),
			script.utf8.count <= ManagedNetworkBootstrapPolicy.maximumPACSourceBytes,
			let host = url.host else { throw Refusal.size }
		let bytes = try JSONSerialization.data(withJSONObject: [url.absoluteString, host])
		guard var arguments = String(data: bytes, encoding: .utf8) else { throw Refusal.decoding }
		arguments = arguments.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
			.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
		let bound = script + "\n;(function(global){'use strict';var descriptor=Object.getOwnPropertyDescriptor(global,'FindProxyForURL');" +
			"if(!descriptor||descriptor.get||descriptor.set||descriptor.writable!==true||typeof descriptor.value!=='function'){throw new Error('PAC function refused');}" +
			"var original=descriptor.value;" +
			"var args=" + arguments + ";var bound=function(){FindProxyForURL=original;" +
			"try{return original.call(this,args[0],args[1]);}finally{FindProxyForURL=bound;}};FindProxyForURL=bound;if(FindProxyForURL!==bound){throw new Error('PAC binding refused');}})(this);\n"
		guard bound.utf8.count <= ManagedNetworkBootstrapPolicy.maximumPACSourceBytes else { throw Refusal.size }
		return bound
	}

	private static let gate = NSLock()
	private static var retained: [ObjectIdentifier: ManagedPACSourceOwner] = [:]

	static var hasDebt: Bool {
		gate.lock()
		defer { gate.unlock() }
		return !retained.isEmpty
	}

	fileprivate static func retain(_ owner: ManagedPACSourceOwner) -> Bool {
		gate.lock()
		defer { gate.unlock() }
		guard retained.isEmpty else { return false }
		retained[ObjectIdentifier(owner)] = owner
		return true
	}

	fileprivate static func retire(_ owner: ManagedPACSourceOwner) {
		gate.lock()
		defer { gate.unlock() }
		retained.removeValue(forKey: ObjectIdentifier(owner))
	}

	/// No successful script is published until the exact session invalidates.
	/// A timed-out owner remains retained and blocks another source acquisition.
	static func load(_ url: URL, deadline: TimeInterval, certificates: [SecCertificate]) -> String? {
		guard deadline.isFinite, ProcessInfo.processInfo.systemUptime < deadline,
			ManagedNetworkBootstrapPolicy.pacSourceRoute == "direct",
			ManagedNetworkBootstrapPolicy.pacSourceCredentials == "native-default",
			ManagedNetworkBootstrapPolicy.pacSourceCredentialScope == "initial_authority",
			ManagedNetworkBootstrapPolicy.pacSourceStrictDecoding,
			let authority = try? Authority(url) else { return nil }
		var current = url
		for hop in 0...ManagedNetworkBootstrapPolicy.maximumPACRedirects {
			guard !hasDebt, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
			let owner = ManagedPACSourceOwner(initial: authority, deadline: deadline, certificates: certificates)
			guard retain(owner), let result = owner.execute(current) else { return nil }
			switch result {
			case .source(let bytes): return try? decode(bytes)
			case .redirect(let next):
				guard hop < ManagedNetworkBootstrapPolicy.maximumPACRedirects else { return nil }
				current = next
			}
		}
		return nil
	}
}

/// Delegate callbacks use one serial queue. Invalidation is the physical
/// publication fence; the outer private worker contains any unsettled debt.
private final class ManagedPACSourceOwner: NSObject, URLSessionDataDelegate {
	private let initial: ManagedPACSource.Authority
	private let deadline: TimeInterval
	private let certificates: [SecCertificate]
	private let settled = DispatchSemaphore(value: 0)
	private let state = NSLock()
	private var failure: ManagedPACSource.Refusal?
	private var invalidated = false
	private var acceptedResponse = false
	private var body = Data()
	private var nextURL: URL?
	private var redirectCancellation = false
	private var current: URL?
	private var session: URLSession?
	private var task: URLSessionDataTask?

	init(initial: ManagedPACSource.Authority, deadline: TimeInterval, certificates: [SecCertificate]) {
		self.initial = initial
		self.deadline = deadline
		self.certificates = certificates
	}

	private func refuse(_ reason: ManagedPACSource.Refusal) {
		state.lock()
		if failure == nil { failure = reason }
		state.unlock()
	}

	private func active() -> Bool {
		state.lock()
		defer { state.unlock() }
		return failure == nil && !invalidated && ProcessInfo.processInfo.systemUptime < deadline
	}

	private func request(_ url: URL) -> URLRequest {
		// Reconstruct every hop, excluding forwarded authorization, cookies and
		// the origin download's headers. The native account owns authentication.
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: deadline - ProcessInfo.processInfo.systemUptime)
		request.httpMethod = "GET"
		return request
	}

	func execute(_ url: URL) -> ManagedPACSource.Hop? {
		let remaining = deadline - ProcessInfo.processInfo.systemUptime
		guard remaining > 0 else { ManagedPACSource.retire(self); return nil }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.connectionProxyDictionary = ManagedProxyLookup.dictionary(route: [kCFProxyTypeKey as String: kCFProxyTypeNone as String])
		configuration.urlCache = nil
		configuration.urlCredentialStorage = nil
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.timeoutIntervalForRequest = remaining
		configuration.timeoutIntervalForResource = remaining
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		queue.name = "ErgoptiPlus.PACSource"
		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
		self.session = session
		current = url
		guard active() else {
			refuse(.deadline)
			session.invalidateAndCancel()
			return nil
		}
		let task = session.dataTask(with: request(url))
		self.task = task
		guard active() else {
			refuse(.deadline)
			session.invalidateAndCancel()
			return nil
		}
		task.resume()
		let wait = deadline - ProcessInfo.processInfo.systemUptime
		guard wait > 0, settled.wait(timeout: .now() + wait) == .success else {
			refuse(.deadline)
			task.cancel()
			session.invalidateAndCancel()
			return nil
		}
		state.lock()
		let admitted = invalidated && failure == nil
		state.unlock()
		guard admitted, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
		if let nextURL { return .redirect(nextURL) }
		guard acceptedResponse else { return nil }
		return .source(body)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		if active(), nextURL != nil {
			redirectCancellation = true
			completionHandler(.cancel)
			return
		}
		guard active(), let response = response as? HTTPURLResponse,
			response.statusCode == ManagedNetworkBootstrapPolicy.pacSourceStatus,
			response.expectedContentLength <= ManagedNetworkBootstrapPolicy.maximumPACSourceBytes,
			let current, response.url == current else {
			refuse(.status)
			completionHandler(.cancel)
			return
		}
		acceptedResponse = true
		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		guard active(), acceptedResponse,
			data.count <= ManagedNetworkBootstrapPolicy.maximumPACSourceBytes - body.count else {
			refuse(.size)
			dataTask.cancel()
			return
		}
		body.append(data)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
		guard active(), [301, 302, 303, 307, 308].contains(response.statusCode),
			let current, response.url == current, let next = newRequest.url,
			let from = try? ManagedPACSource.Authority(current), let to = try? ManagedPACSource.Authority(next),
			!ManagedNetworkBootstrapPolicy.pacSourceForbidsDowngrade || from.scheme != "https" || to.scheme == "https" else {
			refuse(.redirect)
			completionHandler(nil)
			return
		}
		nextURL = next
		// Refuse native task-level redirect reuse. The load controller starts a
		// fresh credential-free session only after this session invalidates.
		completionHandler(nil)
	}

	private func answer(_ challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		guard active(), !challenge.protectionSpace.isProxy() else {
			refuse(.authentication)
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
			if certificates.isEmpty { completionHandler(.performDefaultHandling, nil); return }
			guard let trust = challenge.protectionSpace.serverTrust,
				ManagedCertificateAuthorities.evaluate(trust, adding: certificates) else {
				refuse(.authentication)
				completionHandler(.cancelAuthenticationChallenge, nil)
				return
			}
			completionHandler(.useCredential, URLCredential(trust: trust))
			return
		}
		guard let current, let authority = try? ManagedPACSource.Authority(current), authority == initial,
			challenge.protectionSpace.host.lowercased() == initial.host,
			challenge.protectionSpace.port == initial.port,
			challenge.protectionSpace.protocol?.lowercased() == initial.scheme,
			challenge.previousFailureCount == 0 else {
			refuse(.authentication)
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}
		completionHandler(.performDefaultHandling, nil)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		answer(challenge, completionHandler: completionHandler)
	}

	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
		completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		answer(challenge, completionHandler: completionHandler)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error = error as NSError?,
			!(redirectCancellation && nextURL != nil && error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
			refuse(.status)
		}
		session.finishTasksAndInvalidate()
	}

	func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
		if error != nil { refuse(.status) }
		state.lock()
		invalidated = true
		state.unlock()
		self.task = nil
		self.session = nil
		ManagedPACSource.retire(self)
		settled.signal()
	}
}

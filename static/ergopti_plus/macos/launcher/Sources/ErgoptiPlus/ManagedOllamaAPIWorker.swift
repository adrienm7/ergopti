// Sources/ErgoptiPlus/ManagedOllamaAPIWorker.swift
// Local API secrets cross only a retained TCP connection proven by the SDK.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation

struct ManagedOllamaRequest {
	let executable: String
	let device: UInt64
	let inode: UInt64
	let port: UInt16
	let milliseconds: Int?
	let idleMilliseconds: Int
	let expected: ergopti_listener_identity?
	let method: String?
	let path: String?
	let headers: [(String, String)]
	let body: Data

	static func integer(_ value: Any?) -> UInt64? {
		guard let text = value as? String, !text.isEmpty,
			text == "0" || (!text.hasPrefix("0") && text.utf8.allSatisfy({ (48...57).contains($0) })),
			let result = UInt64(text) else { return nil }
		return result
	}
	static func parse(_ data: Data, discovery: Bool, home: String) -> ManagedOllamaRequest? {
		let common: Set<String> = ["version", "executable", "device", "inode", "port", "timeout_ms"]
		let request: Set<String> = ["pid", "start_seconds", "start_microseconds", "method", "path", "headers", "body", "idle_ms"]
		guard data.count <= 131_072, home.hasPrefix("/"), !home.utf8.contains(0),
			let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			Set(fields.keys) == (discovery ? common : common.union(request)),
			ManagedBootstrapRequest.integer(fields["version"]) == 1,
			let executable = fields["executable"] as? String,
			executable == URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Ergopti/ollama-native-http/ollama").standardizedFileURL.path,
			let device = integer(fields["device"]), device <= UInt64(UInt32.max),
			let inode = integer(fields["inode"]), inode > 0,
			let port = ManagedBootstrapRequest.integer(fields["port"]), port > 1023, port <= 65535
		else { return nil }
		let budget: Int?
		if fields["timeout_ms"] is NSNull {
			guard !discovery else { return nil }; budget = nil
		} else {
			guard let value = ManagedBootstrapRequest.integer(fields["timeout_ms"]), value > 0, value <= Int64(Int32.max) else { return nil }
			budget = Int(value)
		}
		let idle: Int
		if discovery { idle = budget! } else {
			guard let value = ManagedBootstrapRequest.integer(fields["idle_ms"]), value > 0, value <= Int64(Int32.max) else { return nil }
			idle = Int(value)
		}
		if discovery {
			return ManagedOllamaRequest(executable: executable, device: device, inode: inode, port: UInt16(port),
				milliseconds: budget, idleMilliseconds: idle, expected: nil, method: nil, path: nil, headers: [], body: Data())
		}
		guard let pid = ManagedBootstrapRequest.integer(fields["pid"]), pid > 0, pid <= Int64(Int32.max),
			let seconds = integer(fields["start_seconds"]), seconds > 0,
			let microseconds = integer(fields["start_microseconds"]), microseconds < 1_000_000,
			let method = fields["method"] as? String, let path = fields["path"] as? String,
			(method == "GET" && path == "/api/ergopti-native-http-admission") || (method == "POST" && path == "/api/pull"),
			let pairs = fields["headers"] as? [[String]], (3...4).contains(pairs.count),
			method != "POST" || pairs.count == 4,
			let text = fields["body"] as? String, text.utf8.count <= 65_536,
			method != "GET" || text.isEmpty else { return nil }
		let admitted: Set<String> = ["x-ergopti-native-session", "x-ergopti-native-challenge", "x-ergopti-native-operation", "x-ergopti-native-body-sha256"]
		var names = Set<String>()
		var headers: [(String, String)] = []
		for pair in pairs {
			guard pair.count == 2, admitted.contains(pair[0].lowercased()),
				names.insert(pair[0].lowercased()).inserted, !pair[1].isEmpty, pair[1].utf8.count <= 4096,
				pair[1].utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return nil }
			let length = pair[0].lowercased() == "x-ergopti-native-operation" ? 32 : 64
			guard pair[1].utf8.count == length, pair[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
			headers.append((pair[0], pair[1]))
		}
		guard Set(["x-ergopti-native-session", "x-ergopti-native-challenge", "x-ergopti-native-body-sha256"]).isSubset(of: names) else { return nil }
		let body = Data(text.utf8)
		let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
		guard headers.first(where: { $0.0.lowercased() == "x-ergopti-native-body-sha256" })?.1 == digest else { return nil }
		let expected = ergopti_listener_identity(pid: Int32(pid), uid: geteuid(), start_seconds: seconds,
			start_microseconds: microseconds, device: device, inode: inode)
		return ManagedOllamaRequest(executable: executable, device: device, inode: inode, port: UInt16(port),
			milliseconds: budget, idleMilliseconds: idle, expected: expected, method: method, path: path, headers: headers, body: body)
	}
}

private enum ManagedOllamaFailure: Error { case admission, protocolError, timeout, cancelled, io, output }
private final class ManagedOllamaCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func set() { lock.lock(); value = true; lock.unlock() }
	var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class ManagedOllamaConnection {
	let descriptor: Int32
	let deadline: TimeInterval?
	let idleMilliseconds: Int
	var lastProgress: TimeInterval
	let parent: pid_t
	let cancellation: ManagedOllamaCancellation
	var buffered = Data()
	var closed = false
	init(_ descriptor: Int32, deadline: TimeInterval?, idleMilliseconds: Int, lastProgress: TimeInterval, parent: pid_t, cancellation: ManagedOllamaCancellation) {
		self.descriptor = descriptor; self.deadline = deadline; self.idleMilliseconds = idleMilliseconds
		self.lastProgress = lastProgress; self.parent = parent; self.cancellation = cancellation
	}
	func remaining() throws -> UInt32 {
		guard !cancellation.cancelled && getppid() == parent else { throw ManagedOllamaFailure.cancelled }
		let now = ProcessInfo.processInfo.systemUptime
		let idleRemaining = Double(idleMilliseconds) - (now - lastProgress) * 1000
		let milliseconds = min(idleRemaining, deadline.map { ($0 - now) * 1000 } ?? Double.infinity)
		guard milliseconds > 0 else { throw ManagedOllamaFailure.timeout }
		return UInt32(min(Double(UInt32.max), max(1, milliseconds)))
	}
	func ready(_ fd: Int32, _ events: Int16) throws {
		while true {
			let budget = try remaining()
			var event = pollfd(fd: fd, events: events, revents: 0)
			let result = Darwin.poll(&event, 1, Int32(min(20, budget)))
			if result < 0 && errno == EINTR { continue }
			guard result >= 0 else { throw ManagedOllamaFailure.io }
			if result > 0 { return }
		}
	}
	func send(_ data: Data, fd: Int32? = nil) throws {
		let target = fd ?? descriptor
		var offset = 0
		while offset < data.count {
			try ready(target, Int16(POLLOUT))
			let count = data.withUnsafeBytes { Darwin.write(target, $0.baseAddress!.advanced(by: offset), data.count - offset) }
			if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
			guard count > 0 else { throw fd == nil ? ManagedOllamaFailure.io : ManagedOllamaFailure.output }
			offset += count
		}
	}
	func receive() throws -> Data? {
		while true {
			try ready(descriptor, Int16(POLLIN))
			var bytes = [UInt8](repeating: 0, count: 16_384)
			let count = Darwin.read(descriptor, &bytes, bytes.count)
			if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
			guard count >= 0 else { throw ManagedOllamaFailure.io }
			if count > 0 { lastProgress = ProcessInfo.processInfo.systemUptime }
			return count == 0 ? nil : Data(bytes.prefix(count))
		}
	}
	func exact(_ count: Int) throws -> Data {
		while buffered.count < count {
			guard let next = try receive() else { throw ManagedOllamaFailure.protocolError }
			buffered.append(next)
		}
		let result = buffered.prefix(count)
		buffered.removeFirst(count)
		return Data(result)
	}
	func line(limit: Int) throws -> Data {
		while true {
			if let end = buffered.range(of: Data([13, 10])) {
				guard end.lowerBound <= limit else { throw ManagedOllamaFailure.protocolError }
				let value = Data(buffered[..<end.lowerBound]); buffered.removeSubrange(..<end.upperBound)
				return value
			}
			guard buffered.count <= limit, let next = try receive() else { throw ManagedOllamaFailure.protocolError }
			buffered.append(next)
		}
	}
	func frame(_ tag: UInt8, bytes: Data) throws {
		guard let frame = ManagedHTTPFrame.encode(tag: tag, bytes: bytes) else { throw ManagedOllamaFailure.protocolError }
		try send(frame, fd: STDOUT_FILENO)
	}
	func json(_ tag: UInt8, _ fields: [String: Any]) throws {
		try frame(tag, bytes: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
	}
	func terminal(_ fields: [String: Any]) throws {
		// Once physical TCP closure is proved, publish only an immediate bounded
		// pipe write. A deadline does not purchase a fresh blocking-output budget.
		let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
		guard closed, let frame = ManagedHTTPFrame.encode(tag: 67, bytes: bytes), frame.count <= 512 else {
			throw ManagedOllamaFailure.output
		}
		let written = frame.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!, frame.count) }
		guard written == frame.count else { throw ManagedOllamaFailure.output }
	}
	func close() -> Bool {
		guard !closed else { return false }
		closed = true
		let shutdownResult = Darwin.shutdown(descriptor, SHUT_RDWR)
		let shutdownError = errno
		let closeResult = Darwin.close(descriptor)
		return (shutdownResult == 0 || shutdownError == ENOTCONN) && closeResult == 0
	}
}

enum ManagedOllamaAPIWorker {
	static let probeFlag = "--managed-ollama-listener-probe"
	static let requestFlag = "--managed-ollama-api-worker"
	static func handles(arguments: [String]) -> Bool { arguments.count > 1 && [probeFlag, requestFlag].contains(arguments[1]) }
	static func identityFields(_ value: ergopti_listener_identity) -> [String: Any] {
		return ["pid": value.pid, "uid": value.uid, "start_seconds": String(value.start_seconds),
			"start_microseconds": String(value.start_microseconds), "device": String(value.device), "inode": String(value.inode)]
	}
	private static func input(milliseconds: Int?, idleMilliseconds: Int, started: TimeInterval, parent: pid_t,
		cancelled: ManagedOllamaCancellation) -> (Data, TimeInterval)? {
		var bytes = Data(), lastProgress = started
		while bytes.count <= 131_072 {
			let now = ProcessInfo.processInfo.systemUptime
			guard !cancelled.cancelled, getppid() == parent, now - lastProgress < Double(idleMilliseconds) / 1000,
				milliseconds.map({ now - started < Double($0) / 1000 }) ?? true else { return nil }
			var event = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
			let ready = Darwin.poll(&event, 1, 20)
			if ready < 0 && errno == EINTR { continue }
			guard ready >= 0 else { return nil }
			if ready == 0 { continue }
			var byte: UInt8 = 0
			let count = Darwin.read(STDIN_FILENO, &byte, 1)
			if count < 0 && errno == EINTR { continue }
			guard count == 1 else { return nil }
			lastProgress = ProcessInfo.processInfo.systemUptime
			if byte == 10 { return (bytes, lastProgress) }; bytes.append(byte)
		}
		return nil
	}
	static func run(arguments: [String]) -> Int32 {
		let started = ProcessInfo.processInfo.systemUptime
		let parent = getppid()
		let discovery = arguments.count > 1 && arguments[1] == probeFlag
		guard arguments.count == (discovery ? 3 : 4), let idle = Int(arguments[2]), idle > 0, idle <= Int(Int32.max),
			let home = ProcessInfo.processInfo.environment["HOME"] else { return 64 }
		let budget: Int?
		if discovery { budget = idle } else if arguments[3] == "none" { budget = nil } else {
			guard let value = Int(arguments[3]), value > 0, value <= Int(Int32.max) else { return 64 }; budget = value
		}
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		let cancellation = ManagedOllamaCancellation()
		var signals: [DispatchSourceSignal] = []
		for number in [SIGTERM, SIGINT, SIGHUP] {
			_ = Darwin.signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
			source.setEventHandler { cancellation.set() }; source.resume(); signals.append(source)
		}
		defer { signals.forEach { $0.cancel() } }
		guard let received = input(milliseconds: budget, idleMilliseconds: idle, started: started, parent: parent, cancelled: cancellation),
			let request = ManagedOllamaRequest.parse(received.0, discovery: discovery, home: home),
			request.milliseconds == budget, request.idleMilliseconds == idle else { return 64 }
		let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
		guard socket >= 0 else { return 74 }
		let connection = ManagedOllamaConnection(socket, deadline: budget.map { started + Double($0) / 1000 },
			idleMilliseconds: idle, lastProgress: received.1, parent: parent, cancellation: cancellation)
		defer { if !connection.closed { _ = connection.close() } }
		var listener: ergopti_listener_identity?
		var failure = "connect"
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		let diagnosticsEnabled = ProcessInfo.processInfo.environment["ERGOPTI_MANAGED_LISTENER_DIAGNOSTICS"] == "1"
		var lastDiagnostic: String?
		var diagnosticCount = 0
		#endif
		do {
			guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0, ManagedPTYWorker.nonblocking(socket),
				ManagedPTYWorker.nonblocking(STDOUT_FILENO) else { throw ManagedOllamaFailure.io }
			var address = sockaddr_in()
			address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
			address.sin_port = request.port.bigEndian; address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
			let error = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			} }
			if error != 0 {
				guard errno == EINPROGRESS else { throw ManagedOllamaFailure.io }
				try connection.ready(socket, Int16(POLLOUT))
				var socketError: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
				guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
					socketError == 0 else { throw ManagedOllamaFailure.io }
			}
			while listener == nil {
				var observed = ergopti_listener_identity()
				let remaining = try connection.remaining()
				let expected = request.expected
				let result = request.executable.withCString { path -> Int32 in
					if var exact = expected { return ergopti_listener_validate(socket, path, &exact, remaining, &observed) }
					#if ERGOPTI_GUARDIAN_TEST_SUPPORT
					if diagnosticsEnabled {
						var diagnostic = ergopti_listener_diagnostic()
						let result = ergopti_listener_discover_diagnostic(socket, path, request.device, request.inode,
							remaining, &observed, &diagnostic)
						let line = "ERGOPTI_LISTENER_DIAGNOSTIC paths=\(diagnostic.path_matches) stage=\(diagnostic.candidate_stage) errno=\(diagnostic.candidate_errno) result=\(result)"
						if line != lastDiagnostic && diagnosticCount < 8 {
							_ = fputs(line + "\n", stderr); lastDiagnostic = line; diagnosticCount += 1
						}
						return result
					}
					#endif
					return ergopti_listener_discover(socket, path, request.device, request.inode, remaining, &observed)
				}
				if result == 0 { listener = observed; break }
				guard result == ENOENT else { throw result == ETIMEDOUT ? ManagedOllamaFailure.timeout : ManagedOllamaFailure.admission }
				var wait = pollfd(fd: -1, events: 0, revents: 0); _ = Darwin.poll(&wait, 1, 20)
			}
			_ = try connection.remaining()
			if request.method != nil { try perform(request, connection: connection) }
			guard connection.close(), let listener else { return 74 }
			try connection.terminal(["version": 1, "success": true, "reason": "complete", "listener": identityFields(listener)])
			return 0
		} catch let error as ManagedOllamaFailure {
			switch error {
			case .admission: failure = "admission"
			case .protocolError: failure = "protocol"
			case .timeout: failure = "deadline"
			case .cancelled: failure = "cancelled"
			case .output: failure = "unavailable"
			case .io: failure = "connect"
			}
		} catch { failure = "protocol" }
		guard connection.closed || connection.close() else { return 74 }
		var terminal: [String: Any] = ["version": 1, "success": false, "reason": failure, "listener": NSNull()]
		if let listener { terminal["listener"] = identityFields(listener) }
		// A failed output/deadline may refuse the private terminal as well. EOF
		// without this final frame remains an explicit failure in the receiver.
		try? connection.terminal(terminal)
		return failure == "deadline" ? 124 : (failure == "cancelled" ? 130 : 74)
	}
	private static func perform(_ request: ManagedOllamaRequest, connection: ManagedOllamaConnection) throws {
		guard let method = request.method, let path = request.path else { throw ManagedOllamaFailure.protocolError }
		var header = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(request.port)\r\nConnection: close\r\nAccept-Encoding: identity\r\nContent-Type: application/json\r\nContent-Length: \(request.body.count)\r\n"
		for (name, value) in request.headers { header += name + ": " + value + "\r\n" }
		header += "\r\n"
		try connection.send(Data(header.utf8)); try connection.send(request.body)
		let statusLine = String(decoding: try connection.line(limit: ManagedHTTPFrame.maximumPayload - 1), as: UTF8.self)
		let pieces = statusLine.split(separator: " ", maxSplits: 2)
		guard pieces.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(pieces[0])),
			let status = Int(pieces[1]), (200...599).contains(status) else { throw ManagedOllamaFailure.protocolError }
		var headers: [[String]] = []
		var size = statusLine.utf8.count
		var contentLength: Int64?
		var chunked = false
		while true {
			let bytes = try connection.line(limit: ManagedHTTPFrame.maximumPayload - 1)
			if bytes.isEmpty { break }
			size += bytes.count + 2
			guard size < ManagedHTTPFrame.maximumPayload, headers.count < 128,
				bytes.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) }), let separator = bytes.firstIndex(of: 58), separator > 0 else { throw ManagedOllamaFailure.protocolError }
			let name = String(decoding: bytes[..<separator], as: UTF8.self)
			let value = String(decoding: bytes[(separator + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
			guard name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw ManagedOllamaFailure.protocolError }
			if name.lowercased() == "content-length" {
				guard contentLength == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(value) else { throw ManagedOllamaFailure.protocolError }
				contentLength = length
			}
			if name.lowercased() == "transfer-encoding" {
				guard !chunked, value.lowercased() == "chunked" else { throw ManagedOllamaFailure.protocolError }; chunked = true
			}
			if name.lowercased() == "content-encoding" && value.lowercased() != "identity" { throw ManagedOllamaFailure.protocolError }
			headers.append([name, value])
		}
		guard !chunked || contentLength == nil, !(300...399).contains(status) else { throw ManagedOllamaFailure.protocolError }
		try connection.json(72, ["version": 1, "status": status, "headers": headers])
		if chunked {
			while true {
				let line = try connection.line(limit: 128)
				guard !line.isEmpty, line.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
					let count = UInt64(String(decoding: line, as: UTF8.self), radix: 16) else { throw ManagedOllamaFailure.protocolError }
				if count == 0 {
					guard try connection.line(limit: 0).isEmpty else { throw ManagedOllamaFailure.protocolError }
					break
				}
				var remaining = count
				while remaining > 0 {
					let amount = Int(min(remaining, UInt64(ManagedHTTPFrame.maximumPayload - 1)))
					try connection.frame(68, bytes: connection.exact(amount)); remaining -= UInt64(amount)
				}
				guard try connection.exact(2) == Data([13, 10]) else { throw ManagedOllamaFailure.protocolError }
			}
		} else if var remaining = contentLength {
			while remaining > 0 {
				let amount = Int(min(remaining, Int64(ManagedHTTPFrame.maximumPayload - 1)))
				try connection.frame(68, bytes: connection.exact(amount)); remaining -= Int64(amount)
			}
		} else {
			if !connection.buffered.isEmpty { try connection.frame(68, bytes: connection.buffered); connection.buffered.removeAll() }
			while let bytes = try connection.receive() { try connection.frame(68, bytes: bytes) }
		}
		guard connection.buffered.isEmpty else { throw ManagedOllamaFailure.protocolError }
	}
}

// Sources/ErgoptiPlus/ManagedOllamaListenerFixture.swift
// Debug-only literal TCP peer; the production SDK must discover its real owner.

#if ERGOPTI_GUARDIAN_TEST_SUPPORT
import Darwin
import Foundation

private final class ManagedOllamaProbeCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func cancel() { lock.lock(); value = true; lock.unlock() }
	var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum ManagedOllamaListenerFixture {
	static let flag = "--managed-ollama-listener-fixture"
	static let retainedFlag = "--managed-ollama-retained-mach-o-fixture"
	static func handles(arguments: [String]) -> Bool { arguments.count > 1 && [flag, retainedFlag].contains(arguments[1]) }
	private static func publish(_ bytes: Data, path: String) -> Bool {
		let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { return false }
		var offset = 0
		let written = bytes.withUnsafeBytes { buffer -> Bool in
			while offset < bytes.count {
				let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
				if count < 0 && errno == EINTR { continue }
				guard count > 0 else { return false }; offset += count
			}
			return fsync(descriptor) == 0
		}
		let closed = Darwin.close(descriptor) == 0
		return written && closed
	}
	private static func retained(arguments: [String]) -> Int32 {
		// This is a native probe, not an assumption that script FD execution
		// implies Mach-O/dyld or proc_pidpath semantics on either architecture.
		let cancellation = ManagedOllamaProbeCancellation()
		var signals: [DispatchSourceSignal] = []
		for kind in [SIGTERM, SIGINT, SIGHUP] {
			_ = Darwin.signal(kind, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: kind, queue: .global())
			source.setEventHandler { cancellation.cancel() }; source.resume(); signals.append(source)
		}
		defer { signals.forEach { $0.cancel() } }
		func failure(stage: Int, error: Int32) -> Int32 {
			_ = fputs("ERGOPTI_RETAINED_IMAGE_DIAGNOSTIC stage=\(stage) errno=\(error)\n", stderr)
			return 74
		}
		let descriptor = Darwin.open(arguments[0], O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard descriptor >= 0 else { return failure(stage: 1, error: errno) }
		var retained = true
		defer { if retained { _ = Darwin.close(descriptor) } }
		var image = stat()
		guard fstat(descriptor, &image) == 0, (image.st_mode & S_IFMT) == S_IFREG,
			fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY,
			let argv = duplicateCStringVector([arguments[0], flag, arguments[2], arguments[3], arguments[4]]) else { return 74 }
		defer { for case let value? in argv { free(value) } }
		guard let envp = duplicateCStringVector(ProcessInfo.processInfo.environment.keys.sorted().map {
			$0 + "=" + ProcessInfo.processInfo.environment[$0]!
		}) else { return 74 }
		defer { for case let value? in envp { free(value) } }
		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else { return 74 }
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawn_file_actions_adddup2(&actions, descriptor, 3) == 0 else { return 74 }
		if descriptor != 3 { guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { return 74 } }
		var attributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&attributes) == 0 else { return 74 }
		defer { posix_spawnattr_destroy(&attributes) }
		var defaults = sigset_t(); sigemptyset(&defaults)
		for kind in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, kind) }
		guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
			posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)) == 0 else { return 74 }
		var child: pid_t = 0
		var argumentsVector = argv, environmentVector = envp
		let status = argumentsVector.withUnsafeMutableBufferPointer { arguments in
			environmentVector.withUnsafeMutableBufferPointer { environment in
				posix_spawn(&child, "/dev/fd/3", &actions, &attributes, arguments.baseAddress, environment.baseAddress)
			}
		}
		guard status == 0, child > 0 else { return failure(stage: 2, error: status) }
		let deadline = ProcessInfo.processInfo.systemUptime + 25
		var observation: Int32 = 0, timedOut = false
		while true {
			let waited = waitpid(child, &observation, WNOHANG)
			if waited == child { break }
			if waited < 0 && errno == EINTR { continue }
			guard waited == 0 else { return 74 }
			if !timedOut && (cancellation.cancelled || ProcessInfo.processInfo.systemUptime >= deadline) {
				// This exact child remains unreaped, hence its PID is reserved.
				timedOut = true; _ = Darwin.kill(child, SIGTERM)
			}
			usleep(10_000)
		}
		guard Darwin.close(descriptor) == 0 else { return 74 }; retained = false
		let exit = (observation & 0x7f) == 0 ? (observation >> 8) & 0xff : 128 + (observation & 0x7f)
		guard let receipt = try? JSONSerialization.data(withJSONObject: [
			"child": child, "parent": getpid(), "device": String(UInt32(bitPattern: image.st_dev)),
			"inode": String(UInt64(image.st_ino)), "read_only": true, "reaped": true,
			"descriptor_closed": true, "exit_status": exit,
		], options: [.sortedKeys]), publish(receipt, path: arguments[2] + "/retained-image.json") else { return 74 }
		if timedOut || exit != 0 {
			_ = fputs("ERGOPTI_RETAINED_IMAGE_EXIT timeout=\(timedOut ? 1 : 0) status=\(exit)\n", stderr)
		}
		return !timedOut && exit == 0 ? 0 : 74
	}
	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 5, arguments[2].hasPrefix("/"),
			["length", "chunked", "redirect", "truncated", "extra", "progress", "stall"].contains(arguments[3]),
			let count = Int(arguments[4]), (1...8).contains(count) else { return 64 }
		if arguments[1] == retainedFlag { return retained(arguments: arguments) }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		let root = arguments[2], mode = arguments[3]
		let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
		guard descriptor >= 0 else { return 74 }; defer { _ = Darwin.close(descriptor) }
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
		address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
		let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
			Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
		} }
		guard bound == 0, Darwin.listen(descriptor, 8) == 0 else { return 74 }
		var size = socklen_t(MemoryLayout<sockaddr_in>.size)
		let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
			getsockname(descriptor, $0, &size)
		} }
		guard named == 0, let profile = try? JSONSerialization.data(withJSONObject: ["port": Int(UInt16(bigEndian: address.sin_port)), "pid": getpid()], options: [.sortedKeys]),
			publish(profile, path: root + "/profile.json") else { return 74 }
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		func ready(_ fd: Int32, _ events: Int16) -> Bool {
			while ProcessInfo.processInfo.systemUptime < deadline {
				var item = pollfd(fd: fd, events: events, revents: 0)
				let result = Darwin.poll(&item, 1, 20)
				if result < 0 && errno == EINTR { continue }
				if result < 0 { return false }; if result > 0 { return true }
			}
			return false
		}
		for index in 0..<count {
			guard ready(descriptor, Int16(POLLIN)) else { return 124 }
			let peer = Darwin.accept(descriptor, nil, nil)
			guard peer >= 0 else { return 74 }
			var bytes = Data(), refused = false, complete = false
			while !complete {
				guard ready(peer, Int16(POLLIN)) else { _ = Darwin.close(peer); return 124 }
				var buffer = [UInt8](repeating: 0, count: 4096)
				let received = Darwin.read(peer, &buffer, buffer.count)
				if received < 0 && errno == EINTR { continue }
				if received == 0 { refused = true; break }
				guard received > 0, bytes.count + received < 131_072 else { _ = Darwin.close(peer); return 74 }
				bytes.append(contentsOf: buffer.prefix(received))
				if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
					let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
					let lengths = head.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
					guard lengths.count == 1, let length = Int(lengths[0].dropFirst(15).trimmingCharacters(in: .whitespaces)), length >= 0 else { _ = Darwin.close(peer); return 74 }
					complete = bytes.count >= end.upperBound + length
				}
			}
			guard publish(bytes, path: root + "/request-\(index).bin") else { _ = Darwin.close(peer); return 74 }
			if !refused {
				let response: String
				switch mode {
				case "chunked": response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\none\r\n3\r\nTWO\r\n0\r\n\r\n"
				case "redirect": response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/foreign\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
				case "truncated": response = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\noneTWO"
				case "extra": response = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nXY"
				default: response = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\noneTWO"
				}
				let payloads: [Data]
				if mode == "progress" || mode == "stall" {
					payloads = [Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)]
						+ ["a", "B", "c", "D"].map { Data(("1\r\n" + $0 + "\r\n").utf8) } + [Data("0\r\n\r\n".utf8)]
				} else { payloads = [Data(response.utf8)] }
				var physicallyClosed = false
				for (part, payload) in payloads.enumerated() {
					if part > 0 && mode == "progress" { usleep(400_000) }
					if part > 1 && mode == "stall" { usleep(1_500_000) }
					var offset = 0
					while offset < payload.count {
						guard ready(peer, Int16(POLLOUT)) else { _ = Darwin.close(peer); return 124 }
						let written = payload.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!.advanced(by: offset), payload.count - offset) }
						if written < 0 && errno == EINTR { continue }
						if written < 0 && [EPIPE, ECONNRESET].contains(errno) && ["progress", "stall"].contains(mode) { physicallyClosed = true; break }
						guard written > 0 else { _ = Darwin.close(peer); return 74 }; offset += written
					}
					if physicallyClosed { break }
				}
				_ = Darwin.shutdown(peer, SHUT_WR)
				// Observe actual client EOF after its physical close, never a timer.
				while true {
					guard ready(peer, Int16(POLLIN)) else { _ = Darwin.close(peer); return 124 }
					var byte: UInt8 = 0; let read = Darwin.read(peer, &byte, 1)
					if read < 0 && errno == EINTR { continue }
					if read == 0 { break }
					if read < 0 && errno == ECONNRESET { break }
					guard read > 0 else { _ = Darwin.close(peer); return 74 }
				}
			}
			guard Darwin.close(peer) == 0, publish(Data("closed\n".utf8), path: root + "/closed-\(index)") else { return 74 }
		}
		return 0
	}
}
#endif

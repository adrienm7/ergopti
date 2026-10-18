// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportRequestChannel.swift
import CPOSIXCompatibility
import Darwin
import Foundation
import Security

/// Report data only; none of these frames is installation, numeric ABI or input authority.
enum OwnedVHDReportWire {
	struct Frame { let operation: UInt8, result: UInt8, fields: [UInt8], nonce: Data }
	static func decode(_ data: Data, direction: UInt8, nonce: Data? = nil) -> Frame? {
		guard data.count == 64, data.prefix(8) == Data("EGRVHR01".utf8), direction <= 1, data[8] == direction,
			data[16..<32].allSatisfy({ $0 == 0 }), data[32..<64].contains(where: { $0 != 0 }) else { return nil }
		let token = data.subdata(in: 32..<64), fields = Array(data[11..<16])
		guard nonce == nil || nonce == token else { return nil }
		if direction == 0 {
			guard data[9] == 1 || data[9] == 2, data[10] == 0, fields.allSatisfy({ $0 == 0 }) else { return nil }
		} else {
			guard data[9] == 1, (1...3).contains(data[10]), fields.allSatisfy({ $0 <= 1 }),
				data[10] == 1 || fields.allSatisfy({ $0 == 0 }) else { return nil }
		}
		return Frame(operation: data[9], result: data[10], fields: fields, nonce: token)
	}
	static func encode(direction: UInt8, operation: UInt8, result: UInt8 = 0, fields: [UInt8] = [0, 0, 0, 0, 0], nonce: Data) -> Data? {
		guard fields.count == 5, nonce.count == 32 else { return nil }
		var data = Data(repeating: 0, count: 64)
		data.replaceSubrange(0..<8, with: Data("EGRVHR01".utf8)); data[8] = direction; data[9] = operation; data[10] = result
		data.replaceSubrange(11..<16, with: fields); data.replaceSubrange(32..<64, with: nonce)
		return decode(data, direction: direction, nonce: nonce) == nil ? nil : data
	}
}

/// Each original FD is held before sampling. Socket witnesses outlive the original close cut.
final class OwnedVHDReportDescriptor {
	let number: Int32
	private(set) var identity: stat?, error: Int32 = 0, closed = false
	private var socketIdentity = ergopti_vhd_report_socket_identity(), witness: OwnedVHDReportDescriptor?
	private let socket: Bool
	private var sampled = false, closeAttempted = false
	init(_ number: Int32, socket: Bool = false) { self.number = number; self.socket = socket }
	func capture() -> Bool {
		var value = stat(); let status = fstat(number, &value), saved = errno
		guard status == 0 else { error = saved; return false }; identity = value
		if socket {
			let status = ergopti_vhd_report_socket_capture(number, &socketIdentity)
			guard status == 0 else { error = status; return false }
		}
		sampled = true; return current()
	}
	func retainSocketWitness() -> Bool {
		guard socket, witness == nil, current() else { return false }
		let raw = fcntl(number, F_DUPFD_CLOEXEC, 0), saved = errno
		guard raw >= 0 else { error = saved; return false }
		let duplicate = OwnedVHDReportDescriptor(raw, socket: true); witness = duplicate
		guard duplicate.capture(), current(), duplicate.socketIdentity.cookie == socketIdentity.cookie else { error = ESTALE; return false }
		return true
	}
	func current() -> Bool {
		guard sampled, !closeAttempted, error == 0, let original = identity else { return false }
		var value = stat(); let status = fstat(number, &value), saved = errno
		guard status == 0, value.st_dev == original.st_dev, value.st_ino == original.st_ino,
			value.st_mode & mode_t(S_IFMT) == original.st_mode & mode_t(S_IFMT) else { error = status == 0 ? ESTALE : saved; return false }
		if socket {
			let status = ergopti_vhd_report_socket_matches(number, &socketIdentity)
			guard status == 0 else { error = status; return false }
		}
		return witness?.current() ?? true
	}
	func close() -> Bool {
		if closeAttempted { return closed && (witness?.close() ?? true) }
		guard current() else { return false }; closeAttempted = true
		let status = Darwin.close(number), saved = errno
		closed = status == 0; if !closed { error = saved; return false }
		return witness?.close() ?? true
	}
	static func same(_ a: stat, _ b: stat) -> Bool {
		a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode
	}
}

/// Dedicated report-only native rendezvous. B publication/Choice types never enter this file.
enum OwnedVirtualHIDDaemonReportRequestChannel {
	static let environment = "ERGOPTI_VHD_REPORT_ROUTE"
	static func validRoute(_ path: String) -> Bool {
		let prefix = "/private/tmp/.ergopti-vhd-report-", suffix = "/channel.sock"
		guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
		let token = path.dropFirst(prefix.count).dropLast(suffix.count)
		return token.count == 32 && token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
	}
	static func address(_ route: String) -> sockaddr_un? {
		guard validRoute(route) else { return nil }; var address = sockaddr_un()
		let bytes = Array(route.utf8) + [0]; guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
		address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }; return address
	}
	static func configure(_ fd: OwnedVHDReportDescriptor) -> Bool {
		guard fd.current() else { return false }; let flags = fcntl(fd.number, F_GETFL), saved = errno
		guard fd.current(), flags >= 0 else { return false }
		let status = fcntl(fd.number, F_SETFL, flags | O_NONBLOCK), changed = errno
		guard fd.current(), status == 0 else { _ = saved; _ = changed; return false }
		var one: Int32 = 1; let signal = setsockopt(fd.number, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
		return fd.current() && signal == 0
	}
	static func write(_ data: Data, fd: OwnedVHDReportDescriptor, current: () -> Bool) -> Bool {
		guard data.count == 64, let start = OwnedVirtualHIDDaemonReportClock.now() else { return false }; var offset = 0
		while offset < data.count {
			guard current(), fd.current(), OwnedVirtualHIDDaemonReportClock.remains(start) else { return false }
			let count = data.withUnsafeBytes { Darwin.write(fd.number, $0.baseAddress!.advanced(by: offset), data.count - offset) }, saved = errno
			guard fd.current(), current() else { return false }
			if count > 0 { offset += count; continue }; if count < 0 && saved == EINTR { continue }
			guard count < 0 && (saved == EAGAIN || saved == EWOULDBLOCK) else { return false }
			var item = pollfd(fd: fd.number, events: Int16(POLLOUT), revents: 0)
			guard fd.current() else { return false }; let status = Darwin.poll(&item, 1, 20), error = errno
			guard fd.current(), current(), status >= 0 || error == EINTR, item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { return false }
		}
		return current() && fd.current()
	}
	static func read(fd: OwnedVHDReportDescriptor, buffer: inout Data, start: inout UInt64?, refused: inout Bool, current: () -> Bool) -> Data? {
		guard buffer.count < 64, current(), fd.current() else { refused = true; return nil }; var bytes = [UInt8](repeating: 0, count: 64)
		if !buffer.isEmpty { guard let start, OwnedVirtualHIDDaemonReportClock.remains(start) else { refused = true; return nil } }
		let count = Darwin.read(fd.number, &bytes, 64 - buffer.count), saved = errno
		guard fd.current(), current() else { refused = true; return nil }
		if count < 0 && (saved == EINTR || saved == EAGAIN || saved == EWOULDBLOCK) { return nil }
		guard count > 0 && count <= 64 - buffer.count else { refused = true; return nil }
		if buffer.isEmpty { start = OwnedVirtualHIDDaemonReportClock.now() }
		buffer.append(contentsOf: bytes.prefix(count)); guard let began = start, OwnedVirtualHIDDaemonReportClock.remains(began), buffer.count == 64 else { return nil }
		let frame = buffer; buffer.removeAll(keepingCapacity: true); start = nil; return frame
	}

	final class Root {
		final class Request {
			fileprivate let original: Root
			fileprivate init(_ original: Root) { self.original = original }
			func current() -> Bool { original.current() && !original.withdrawn() }
			func withdrawn() -> Bool { original.withdrawn() }
			func stageCaptureCurrent() -> Bool { original.current() }
		}
		final class Retirement {
			fileprivate let original: Root
			fileprivate init(_ original: Root) { self.original = original }
			func matches(_ request: Request) -> Bool { original === request.original && original.retired() }
		}
		private static let rootsLock = NSLock(); private static var roots: [Root] = []
		private let lock = NSRecursiveLock()
		private var publisher: OwnedRuntimePublisherIdentity?, publisherAttempted = false
		private var descriptors: [OwnedVHDReportDescriptor] = [], socket: OwnedVHDReportDescriptor?, directory: OwnedVHDReportDescriptor?
		private var directoryPath = "", routePath = "", routeIdentity: stat?, born = ergopti_vhd_report_peer_identity(), peerCode: SecCode?
		private var admitted = false, refused = false, closed = false, withdrawal = false, request: Request?
		private var nonce: Data?, incoming = Data(), framingStart: UInt64?, requestWaitStart: UInt64?, terminalSent = false
		private init() {}
		static func acquire() -> Root {
			let owner = Root(); rootsLock.lock(); roots.append(owner); rootsLock.unlock()
			guard !Thread.isMainThread, getuid() == 0, geteuid() == 0, CommandLine.arguments.count == 2,
				CommandLine.arguments[1] == "--virtual-hid-daemon-report-worker" else { owner.refused = true; return owner }
			owner.publisherAttempted = true; owner.publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller()
			guard owner.publisher?.current() == true, let route = ProcessInfo.processInfo.environment[environment], validRoute(route) else { owner.refused = true; return owner }
			owner.routePath = route; owner.directoryPath = URL(fileURLWithPath: route).deletingLastPathComponent().path
			guard let directory = owner.retain(open(owner.directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)),
				let directoryIdentity = directory.identity, directoryIdentity.st_uid != 0, directoryIdentity.st_mode & 0o7777 == 0o700 else { owner.refused = true; return owner }
			owner.directory = directory; var named = stat()
			guard fstatat(directory.number, "channel.sock", &named, AT_SYMLINK_NOFOLLOW) == 0,
				named.st_uid == directoryIdentity.st_uid, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), named.st_mode & 0o7777 == 0o600 else { owner.refused = true; return owner }
			owner.routeIdentity = named
			guard let socket = owner.retain(Darwin.socket(AF_UNIX, SOCK_STREAM, 0), socket: true) else { owner.refused = true; return owner }
			owner.socket = socket
			guard socket.retainSocketWitness(), configure(socket), var address = address(route), owner.namespaceCurrent(), socket.current() else { owner.refused = true; return owner }
			let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket.number, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, saved = errno
			guard owner.namespaceCurrent(), socket.current(), status == 0 || saved == EINPROGRESS || saved == EAGAIN || saved == EWOULDBLOCK,
				let start = OwnedVirtualHIDDaemonReportClock.now() else { owner.refused = true; return owner }
			if status != 0 {
				var error: Int32 = EINPROGRESS
				while error != 0 {
					guard owner.namespaceCurrent(), socket.current(), OwnedVirtualHIDDaemonReportClock.remains(start) else { owner.refused = true; return owner }
					var item = pollfd(fd: socket.number, events: Int16(POLLOUT), revents: 0); _ = Darwin.poll(&item, 1, 20)
					var size = socklen_t(MemoryLayout<Int32>.size)
					guard socket.current(), owner.namespaceCurrent(), getsockopt(socket.number, SOL_SOCKET, SO_ERROR, &error, &size) == 0,
						socket.current(), size == socklen_t(MemoryLayout<Int32>.size), error == 0 || error == EINPROGRESS else { owner.refused = true; return owner }
				}
			}
			guard ergopti_vhd_report_channel_peer(socket.number, &owner.born) == 0, owner.born.uid == directoryIdentity.st_uid else { owner.refused = true; return owner }
			let attrs = [kSecGuestAttributePid as String: NSNumber(value: owner.born.pid)] as CFDictionary
			guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &owner.peerCode) == errSecSuccess, owner.pairCurrent() else { owner.refused = true; return owner }
			owner.requestWaitStart = OwnedVirtualHIDDaemonReportClock.now(); owner.admitted = true; return owner
		}
		private func retain(_ raw: Int32, socket: Bool = false) -> OwnedVHDReportDescriptor? {
			guard raw >= 0 else { return nil }; let held = OwnedVHDReportDescriptor(raw, socket: socket); descriptors.append(held)
			return held.capture() ? held : nil
		}
		private func namespaceCurrent() -> Bool {
			guard let directory, directory.current(), let expected = directory.identity, let leaf = routeIdentity else { return false }
			var parent = stat(), named = stat()
			return lstat(directoryPath, &parent) == 0 && OwnedVHDReportDescriptor.same(expected, parent)
				&& fstatat(directory.number, "channel.sock", &named, AT_SYMLINK_NOFOLLOW) == 0 && OwnedVHDReportDescriptor.same(leaf, named) && directory.current()
		}
		private func pairCurrent() -> Bool {
			guard !closed, !refused, publisher?.current() == true, namespaceCurrent(), let socket, socket.current(), let peerCode,
				OwnedRuntimePublisherSignature.currentLeaf(peerCode, role: .launcher) == publisher?.leaf else { return false }
			var value = ergopti_vhd_report_peer_identity()
			return ergopti_vhd_report_channel_peer(socket.number, &value) == 0 && value.pid == born.pid && value.uid == born.uid
				&& value.start_seconds == born.start_seconds && value.start_microseconds == born.start_microseconds && socket.current() && namespaceCurrent()
		}
		func current() -> Bool { lock.lock(); defer { lock.unlock() }; return admitted && pairCurrent() }
		private func withdrawn() -> Bool { lock.lock(); defer { lock.unlock() }; return withdrawal }
		func receiveRequest() -> Request? {
			lock.lock(); defer { lock.unlock() }
			if request == nil { guard let started = requestWaitStart, OwnedVirtualHIDDaemonReportClock.remains(started) else { refused = true; return nil } }
			guard current(), let socket, let data = read(fd: socket, buffer: &incoming, start: &framingStart, refused: &refused, current: { self.current() }) else { return nil }
			guard let frame = OwnedVHDReportWire.decode(data, direction: 0, nonce: nonce) else { refused = true; return nil }
			if request == nil { nonce = frame.nonce; request = Request(self) }
			if frame.operation == 2 { withdrawal = true }
			return request
		}
		func send(observation: OwnedVirtualHIDDaemonReportObserver.Observation) -> Bool {
			lock.lock(); defer { lock.unlock() }; guard !terminalSent, current(), let nonce, let socket else { return false }
			let result: UInt8, fields: [UInt8]
			switch observation {
			case .historical(let report):
				guard !withdrawal else { return false }; result = 1; let v = report.values
				fields = [v.driverActivated, v.driverConnected, v.driverVersionMismatched, v.virtualHIDKeyboardReady, v.virtualHIDPointingReady].map { $0 ? 1 : 0 }
			case .unavailable: result = 2; fields = [0, 0, 0, 0, 0]
			case .cleanupPending: result = 3; fields = [0, 0, 0, 0, 0]
			}
			guard let data = OwnedVHDReportWire.encode(direction: 1, operation: 1, result: result, fields: fields, nonce: nonce),
				write(data, fd: socket, current: { self.current() }) else { refused = true; return false }
			terminalSent = true; return true
		}
		func retire() -> Retirement? {
			lock.lock(); defer { lock.unlock() }; if closed { return Retirement(self) }; var complete = true
			for held in descriptors.reversed() { if !held.close() { complete = false } }
			if complete { if let publisher { complete = publisher.retire() } else { complete = !publisherAttempted } }
			guard complete else { refused = true; return nil }; closed = true
			Self.rootsLock.lock(); Self.roots.removeAll { $0 === self }; Self.rootsLock.unlock(); return Retirement(self)
		}
		func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
	}

}

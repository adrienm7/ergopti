// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportObserver.swift
import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import Security

/// Passive official-daemon observation by an already staged Root helper. No privileged launch is performed here.
final class OwnedVirtualHIDDaemonReportObserver {
	enum Failure { case authority, endpoint, identity, signature, transport, protocolFrame, deadline, stopped, cleanup }
	enum RemoteCleanup { case unobserved }
	/// Historical data after checked local closure. This is neither live compatibility nor a readiness capability.
	final class Historical {
		let values: OwnedVirtualHIDDaemonReportProtocol.Values
		let remoteCleanup: RemoteCleanup = .unobserved
		fileprivate init(_ values: OwnedVirtualHIDDaemonReportProtocol.Values) { self.values = values }
	}
	enum Observation { case historical(Historical), unavailable(Failure), cleanupPending(Failure) }
	private static let rootsLock = NSLock()
	private static var roots: [OwnedVirtualHIDDaemonReportObserver] = []
	private static let endpoint = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
	private let operation = NSRecursiveLock(), state = NSLock()
	private var stopped = false, attempted = false, settled = false
	private var failure: Failure?, firstErrno: Int32 = 0
	private var start: UInt64?
	private var publisher: OwnedRuntimePublisherIdentity?, publisherAttempted = false
	private var descriptors: [Descriptor] = [], anchors: [Anchor] = []
	private var socket: Descriptor?, witness: Descriptor?
	private var endpointParent: Descriptor?, endpointStamp: stat?
	private var born = ergopti_vhd_report_peer_identity(), peerAdmitted = false
	private var daemonCode: SecCode?, daemonStatic: SecStaticCode?, daemonRequirement: SecRequirement?
	private var outcome: Observation?
	private init() {}

	/// Admission uses the real executing staged installer; arguments and Root UID alone cannot authorize a report.
	static func acquire() -> OwnedVirtualHIDDaemonReportObserver {
		let owner = OwnedVirtualHIDDaemonReportObserver()
		rootsLock.lock(); roots.append(owner); rootsLock.unlock()
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0,
			CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--virtual-hid-daemon-report-worker",
			let start = OwnedVirtualHIDDaemonReportClock.now() else { owner.fail(.authority); return owner }
		owner.start = start
		owner.publisherAttempted = true
		owner.publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller()
		guard owner.publisher?.current() == true, owner.withinBudget() else { owner.fail(.authority); return owner }
		return owner
	}
	/// Negative withdrawal only. No observed Boolean or callback can redeem it.
	func stop() { state.lock(); stopped = true; state.unlock() }
	private func isStopped() -> Bool { state.lock(); defer { state.unlock() }; return stopped }
	private func fail(_ value: Failure, _ error: Int32 = 0) {
		if failure == nil { failure = value }
		if firstErrno == 0 && error != 0 { firstErrno = error }
	}
	private func withinBudget() -> Bool {
		guard let start, OwnedVirtualHIDDaemonReportClock.remains(start) else { fail(.deadline); return false }
		return true
	}
	private func authorityCurrent() -> Bool {
		guard !Thread.isMainThread, !isStopped(), getuid() == 0, geteuid() == 0,
			publisher?.current() == true, withinBudget() else {
			fail(isStopped() ? .stopped : .authority); return false
		}
		return true
	}
	/// Returns only after the delivery ACK and all original local rights have been checked closed.
	func observe() -> Observation {
		operation.lock(); defer { operation.unlock() }
		if let outcome { return outcome }
		guard !attempted else { return .cleanupPending(failure ?? .cleanup) }
		attempted = true
		var captured: OwnedVirtualHIDDaemonReportProtocol.Values?
		if failure == nil && authorityCurrent() && prepare() {
			var heartbeatCount = 0
			while nativeCurrent() {
				guard let header = readExactly(4) else { break }
				if header == Data([0, 0, 0, 1]) {
					guard let byte = readExactly(1), OwnedVirtualHIDDaemonReportProtocol.isHeartbeat(header + byte),
						heartbeatCount < 32 else { fail(.protocolFrame); break }
					heartbeatCount += 1 // Heartbeats do not satisfy or extend this observation.
					continue
				}
				guard header == Data([0, 0, 0, 19]), let body = readExactly(19),
					let request = OwnedVirtualHIDDaemonReportProtocol.decode(header + body), nativeCurrent() else {
					fail(.protocolFrame); break
				}
				guard writeExactly(OwnedVirtualHIDDaemonReportProtocol.acknowledgment(for: request)), nativeCurrent() else { break }
				captured = request.values
				break
			}
		}
		// Closure uses only retained original rights; failure/source loss cannot authorize foreign cleanup.
		let closed = retireOriginalRights()
		if closed, let captured, failure == nil, !isStopped(), withinBudget() {
			outcome = .historical(Historical(captured))
		} else if closed { outcome = .unavailable(failure ?? .transport) }
		else { outcome = .cleanupPending(failure ?? .cleanup) }
		return outcome!
	}

	private func retain(_ raw: Int32, socket: Bool = false) -> Descriptor? {
		guard raw >= 0 else { fail(.transport, errno); return nil }
		let held = Descriptor(raw, socket: socket)
		descriptors.append(held) // Before fstat/libproc/configuration can refuse an acquired descriptor.
		guard held.capture() else { fail(.identity, held.error); return nil }
		return held
	}
	private func pinParent(of path: String) -> Descriptor? {
		let pieces = path.split(separator: "/").map(String.init)
		guard path.hasPrefix("/"), !pieces.isEmpty, pieces.allSatisfy({ $0 != "." && $0 != ".." }), authorityCurrent(),
			let root = retain(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) else { return nil }
		guard protected(root.stamp, directory: true) else { fail(.endpoint); return nil }
		var parent = root
		for piece in pieces.dropLast() {
			guard baseCurrent(), parent.current() else { fail(.endpoint); return nil }
			let raw = openat(parent.number, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), saved = errno
			guard let child = retain(raw) else { fail(.endpoint, saved); return nil }
			guard protected(child.stamp, directory: true),
				(piece != "rootonly" || child.stamp!.st_mode & 0o7777 == 0o700) else { fail(.endpoint); return nil }
			anchors.append(Anchor(parent: parent, name: piece, child: child))
			guard baseCurrent() else { return nil }
			parent = child
		}
		return parent
	}
	private func protected(_ value: stat?, directory: Bool) -> Bool {
		guard let value, value.st_uid == 0, value.st_mode & 0o022 == 0 else { return false }
		return value.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG)
	}
	private func pinFixedFile(_ path: String) -> Descriptor? {
		guard let parent = pinParent(of: path), let name = path.split(separator: "/").last, baseCurrent() else { return nil }
		let raw = openat(parent.number, String(name), O_RDONLY | O_NOFOLLOW | O_CLOEXEC), saved = errno
		guard let file = retain(raw) else { fail(.identity, saved); return nil }
		guard protected(file.stamp, directory: false) else { fail(.identity); return nil }
		anchors.append(Anchor(parent: parent, name: String(name), child: file))
		return baseCurrent() ? file : nil
	}
	private func verifyFixedFile(_ path: String) -> Bool {
		guard let entry = OwnedVirtualHIDDaemonReportReference.entries[String(path.dropFirst())], !entry.directory,
			let file = pinFixedFile(path), file.stamp?.st_size == off_t(entry.bytes) else { fail(.signature); return false }
		var digest = SHA256(), offset: off_t = 0
		var bytes = [UInt8](repeating: 0, count: 64 * 1024)
		while offset < off_t(entry.bytes) {
			guard baseCurrent(), file.current() else { return false }
			let remaining = min(bytes.count, entry.bytes - Int(offset))
			let count = pread(file.number, &bytes, remaining, offset), saved = errno
			guard baseCurrent(), file.current() else { return false }
			if count < 0 && saved == EINTR { continue }
			guard count > 0 && count <= remaining else { fail(.signature, saved); return false }
			digest.update(data: Data(bytes.prefix(count))); offset += off_t(count)
		}
		guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.hash else { fail(.signature); return false }
		return baseCurrent()
	}
	private func prepare() -> Bool {
		guard let parent = pinParent(of: Self.endpoint), baseCurrent() else { return false }
		endpointParent = parent
		var named = stat()
		let endpointStatus = fstatat(parent.number, "karabiner_virtual_hid_device_service.sock", &named, AT_SYMLINK_NOFOLLOW), saved = errno
		guard endpointStatus == 0, named.st_uid == 0, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), named.st_mode & 0o022 == 0,
			baseCurrent() else { fail(.endpoint, saved); return false }
		endpointStamp = named
		guard verifyFixedFile(OwnedVirtualHIDDaemonReportReference.daemonExecutable),
			verifyFixedFile(OwnedVirtualHIDDaemonReportReference.daemon + "/Contents/Info.plist"), baseCurrent() else { return false }
		guard let held = retain(Darwin.socket(AF_UNIX, SOCK_STREAM, 0), socket: true) else { return false }
		socket = held
		guard baseCurrent(), held.current() else { return false }
		let duplicate = fcntl(held.number, F_DUPFD_CLOEXEC, 0), duplicateError = errno
		guard let witness = retain(duplicate, socket: true) else { fail(.identity, duplicateError); return false }
		self.witness = witness
		guard held.sameSocket(witness), baseCurrent() else { fail(.identity); return false }
		guard configure(held) else { return false }
		var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
		let name = Array(Self.endpoint.utf8) + [0]
		guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail(.endpoint); return false }
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		guard baseCurrent(), socketCurrent() else { return false }
		let connectStatus = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(held.number, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}, error = errno
		guard baseCurrent(), socketCurrent() else { return false }
		if connectStatus != 0 {
			guard error == EINPROGRESS || error == EAGAIN || error == EWOULDBLOCK, wait(Int16(POLLOUT), peer: false) else {
				fail(.transport, error); return false
			}
			var pending: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
			guard baseCurrent(), socketCurrent() else { return false }
			let checked = getsockopt(held.number, SOL_SOCKET, SO_ERROR, &pending, &length), saved = errno
			guard baseCurrent(), socketCurrent(), checked == 0, length == socklen_t(MemoryLayout<Int32>.size), pending == 0 else {
				fail(.transport, checked == 0 ? pending : saved); return false
			}
		}
		guard ergopti_vhd_report_channel_peer(held.number, &born) == 0, born.uid == 0,
			baseCurrent(), socketCurrent() else { fail(.identity); return false }
		let attributes = [kSecGuestAttributePid as String: NSNumber(value: born.pid)] as CFDictionary
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &daemonCode) == errSecSuccess, let daemonCode,
			SecCodeCopyStaticCode(daemonCode, [], &daemonStatic) == errSecSuccess, let daemonStatic else {
			fail(.signature); return false
		}
		let fixed = "anchor apple generic and identifier \"org.pqrs.Karabiner-VirtualHIDDevice-Daemon\" and certificate leaf[subject.OU] = \"G43BCU2T37\""
		var trusted: SecRequirement?, information: CFDictionary?
		guard SecRequirementCreateWithString(fixed as CFString, [], &trusted) == errSecSuccess, let trusted,
			SecStaticCodeCheckValidity(daemonStatic, OwnedRuntimePublisherSignature.strict, trusted) == errSecSuccess,
			SecCodeCopySigningInformation(daemonStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any], let main = fields[kSecCodeInfoMainExecutable as String] as? URL,
			main.standardizedFileURL.path == OwnedVirtualHIDDaemonReportReference.daemonExecutable,
			let cms = fields[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
			let hash = fields[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { fail(.signature); return false }
		let exact = fixed + " and cdhash H\"" + hash.map({ String(format: "%02x", $0) }).joined() + "\""
		guard SecRequirementCreateWithString(exact as CFString, [], &daemonRequirement) == errSecSuccess else { fail(.signature); return false }
		peerAdmitted = true
		return nativeCurrent()
	}

	private func configure(_ held: Descriptor) -> Bool {
		guard baseCurrent(), socketCurrent() else { return false }
		let flags = fcntl(held.number, F_GETFL), flagsError = errno
		guard baseCurrent(), socketCurrent(), flags >= 0 else { fail(.transport, flagsError); return false }
		let configured = fcntl(held.number, F_SETFL, flags | O_NONBLOCK), configureError = errno
		guard baseCurrent(), socketCurrent(), configured == 0 else { fail(.transport, configureError); return false }
		var one: Int32 = 1
		let noSignal = setsockopt(held.number, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)), signalError = errno
		guard baseCurrent(), socketCurrent(), noSignal == 0 else { fail(.transport, signalError); return false }
		return true
	}
	private func baseCurrent() -> Bool {
		guard failure == nil, authorityCurrent(), descriptors.allSatisfy({ $0.current() }), anchors.allSatisfy({ $0.current() }) else {
			fail(.identity); return false
		}
		if let parent = endpointParent, let expected = endpointStamp {
			var named = stat()
			guard parent.current(), fstatat(parent.number, "karabiner_virtual_hid_device_service.sock", &named, AT_SYMLINK_NOFOLLOW) == 0,
				Descriptor.same(expected, named), parent.current() else { fail(.endpoint); return false }
		}
		return true
	}
	private func socketCurrent() -> Bool {
		guard let socket, let witness, socket.current(), witness.current(), socket.sameSocket(witness) else {
			fail(.identity); return false
		}
		return true
	}
	private func nativeCurrent() -> Bool {
		guard baseCurrent(), socketCurrent(), peerAdmitted, let socket, let daemonCode, let daemonRequirement else { return false }
		var observed = ergopti_vhd_report_peer_identity()
		guard ergopti_vhd_report_channel_peer(socket.number, &observed) == 0,
			observed.pid == born.pid, observed.uid == born.uid, observed.start_seconds == born.start_seconds,
			observed.start_microseconds == born.start_microseconds,
			SecCodeCheckValidity(daemonCode, SecCSFlags(rawValue: kSecCSStrictValidate), daemonRequirement) == errSecSuccess,
			baseCurrent(), socketCurrent() else { fail(.identity); return false }
		return true
	}
	private func wait(_ events: Int16, peer: Bool = true) -> Bool {
		guard (peer ? nativeCurrent() : baseCurrent() && socketCurrent()), let socket else { return false }
		var item = pollfd(fd: socket.number, events: events, revents: 0)
		let status = Darwin.poll(&item, 1, 20), saved = errno
		guard (peer ? nativeCurrent() : baseCurrent() && socketCurrent()) else { return false }
		if status < 0 && saved != EINTR { fail(.transport, saved); return false }
		if item.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 { fail(.transport); return false }
		return true
	}
	private func readExactly(_ size: Int) -> Data? {
		guard size > 0 && size <= 23 else { fail(.protocolFrame); return nil }
		var received = Data(), bytes = [UInt8](repeating: 0, count: size)
		while received.count < size {
			guard nativeCurrent(), let socket else { return nil }
			let count = Darwin.read(socket.number, &bytes, size - received.count), saved = errno
			guard nativeCurrent() else { return nil }
			if count < 0 && saved == EINTR { continue }
			if count < 0 && (saved == EAGAIN || saved == EWOULDBLOCK) { guard wait(Int16(POLLIN)) else { return nil }; continue }
			guard count > 0 && count <= size - received.count else { fail(.transport, saved); return nil }
			received.append(contentsOf: bytes.prefix(count))
		}
		return received
	}
	private func writeExactly(_ bytes: Data) -> Bool {
		guard bytes.count == 13, bytes.prefix(5) == Data([0, 0, 0, 9, 5]) else { fail(.protocolFrame); return false }
		var offset = 0
		while offset < bytes.count {
			guard nativeCurrent(), let socket else { return false }
			let count = bytes.withUnsafeBytes { Darwin.write(socket.number, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }, saved = errno
			guard nativeCurrent() else { return false }
			if count < 0 && saved == EINTR { continue }
			if count < 0 && (saved == EAGAIN || saved == EWOULDBLOCK) { guard wait(Int16(POLLOUT)) else { return false }; continue }
			guard count > 0 && count <= bytes.count - offset else { fail(.transport, saved); return false }
			offset += count
		}
		return true
	}

	/// Checked local rights only; neither EOF nor successful close acknowledges the daemon's IOKit cleanup.
	func retire() -> Bool { operation.lock(); defer { operation.unlock() }; stop(); return retireOriginalRights() }
	func retired() -> Bool { operation.lock(); defer { operation.unlock() }; return settled }
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixtureChangedFileRetirement() throws -> (wasCurrent: Bool, rejectedMutation: Bool, failure: Int32, firstClose: Bool, originalClosed: Bool, repeatedClose: Bool, replacementCurrent: Bool) {
		try Descriptor.fixtureChangedFileRetirement()
	}
	#endif
	private func retireOriginalRights() -> Bool {
		if settled { return true }
		var complete = true
		// The duplicate keeps the original socket object alive through its final identity/close cut.
		if let socket {
			if socket.close() {
				if let witness, !witness.close() { complete = false; fail(.cleanup, witness.error) }
			} else { complete = false; fail(.cleanup, socket.error) }
		}
		for held in descriptors.reversed() where held !== socket && held !== witness {
			if !held.close() { complete = false; fail(.cleanup, held.error) }
		}
		if complete {
			if let publisher { complete = publisher.retire(); if complete { self.publisher = nil } }
			else { complete = !publisherAttempted }
		}
		if complete {
			daemonCode = nil; daemonStatic = nil; daemonRequirement = nil
			settled = true
			Self.rootsLock.lock(); Self.roots.removeAll { $0 === self }; Self.rootsLock.unlock()
		}
		return complete
	}

	private final class Descriptor {
		let number: Int32, socket: Bool
		private(set) var stamp: stat?, error: Int32 = 0, closeError: Int32 = 0
		private var identity = ergopti_vhd_report_socket_identity(), captured = false, closeAttempted = false, closed = false
		init(_ number: Int32, socket: Bool) { self.number = number; self.socket = socket }
		func capture() -> Bool {
			var value = stat()
			let status = fstat(number, &value), saved = errno
			guard status == 0 else { error = saved; return false }
			stamp = value
			if socket {
				let observed = ergopti_vhd_report_socket_capture(number, &identity)
				guard observed == 0 else { error = observed; return false }
			}
			captured = true
			return current()
		}
		func current() -> Bool {
			guard captured, !closeAttempted, error == 0, let stamp else { return false }
			var value = stat()
			let status = fstat(number, &value), saved = errno
			guard status == 0, socket ? value.st_dev == stamp.st_dev && value.st_ino == stamp.st_ino
				&& value.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) : Self.same(stamp, value) else {
				error = status == 0 ? ESTALE : saved; return false
			}
			if socket { let result = ergopti_vhd_report_socket_matches(number, &identity); if result != 0 { error = result; return false } }
			return true
		}
		func sameSocket(_ other: Descriptor) -> Bool {
			current() && other.current() && identity.cookie == other.identity.cookie && identity.cookie != 0
		}
		func close() -> Bool {
			if closeAttempted { return closed }
			// Content changes refuse observation, but cannot keep our same original FD open forever.
			guard captured, let stamp else { return false }
			var value = stat()
			let observed = fstat(number, &value), observedError = errno
			guard observed == 0, value.st_dev == stamp.st_dev, value.st_ino == stamp.st_ino,
				value.st_mode & mode_t(S_IFMT) == stamp.st_mode & mode_t(S_IFMT) else {
				if error == 0 { error = observed == 0 ? ESTALE : observedError }; return false
			}
			if socket {
				let result = ergopti_vhd_report_socket_matches(number, &identity)
				guard result == 0 else { if error == 0 { error = result }; return false }
			}
			closeAttempted = true
			let status = Darwin.close(number), saved = errno
			closed = status == 0
			if !closed { closeError = saved; if error == 0 { error = saved } }
			return closed
		}
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		static func fixtureChangedFileRetirement() throws -> (wasCurrent: Bool, rejectedMutation: Bool, failure: Int32, firstClose: Bool, originalClosed: Bool, repeatedClose: Bool, replacementCurrent: Bool) {
			let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
			let raw = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
			guard raw >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			let held = Descriptor(raw, socket: false); var replacement: Int32 = -1
			defer {
				if replacement >= 0 { Darwin.close(replacement) }
				// An omitted production close still leaves this fixture's unchanged original FD to release.
				if !held.closeAttempted, let stamp = held.stamp {
					var value = stat()
					if fstat(raw, &value) == 0, value.st_dev == stamp.st_dev, value.st_ino == stamp.st_ino { Darwin.close(raw) }
				}
				unlink(path)
			}
			guard held.capture() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(held.error)) }
			let wasCurrent = held.current(); var byte: UInt8 = 1
			guard Darwin.write(raw, &byte, 1) == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			let rejectedMutation = !held.current()
			let firstClose = held.close()
			errno = 0; let originalClosed = fcntl(raw, F_GETFD) == -1 && errno == EBADF
			replacement = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
			guard replacement >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
			// The kernel may choose a different number; this fixture makes no forced-reuse claim.
			let repeatedClose = held.close(), replacementCurrent = fcntl(replacement, F_GETFD) >= 0
			return (wasCurrent, rejectedMutation, held.error, firstClose, originalClosed, repeatedClose, replacementCurrent)
		}
		#endif
		static func same(_ a: stat, _ b: stat) -> Bool {
			a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
				&& a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
				&& a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
				&& a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
		}
	}
	private struct Anchor {
		let parent: Descriptor, name: String, child: Descriptor
		func current() -> Bool {
			guard parent.current(), child.current(), let expected = child.stamp else { return false }
			var value = stat()
			return fstatat(parent.number, name, &value, AT_SYMLINK_NOFOLLOW) == 0 && Descriptor.same(expected, value)
				&& parent.current() && child.current()
		}
	}
}

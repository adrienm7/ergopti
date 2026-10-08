// Sources/ErgoptiPlus/ManagedPTYWorker.swift
// Cold bootstrap keeps raw PTY progress separate from privileged retirement.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation

struct ManagedPTYRequest {
	let sourcePath: String
	let sourceSHA256: String
	let environment: [(String, String)]
	let timeoutMilliseconds: Int
	let receiptPath: String
	let nonce: String

	static func parse(_ bytes: Data) -> ManagedPTYRequest? {
		guard bytes.count <= 65_536,
			let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			Set(fields.keys) == Set(["version", "source_path", "source_sha256", "environment", "timeout_ms", "receipt_path", "nonce"]),
			ManagedBootstrapRequest.integer(fields["version"]) == 1,
			let source = fields["source_path"] as? String, source.hasPrefix("/"), !source.utf8.contains(0),
			let digest = fields["source_sha256"] as? String, digest.utf8.count == 64,
			digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
			let pairs = fields["environment"] as? [[String]], pairs.count <= 4,
			let timeout = ManagedBootstrapRequest.integer(fields["timeout_ms"]), timeout > 0, timeout <= Int64(Int32.max),
			let receipt = fields["receipt_path"] as? String, receipt.hasPrefix("/"), !receipt.utf8.contains(0),
			let nonce = fields["nonce"] as? String, !nonce.isEmpty, nonce.utf8.count <= 128,
			nonce.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
		else { return nil }
		var names = Set<String>()
		var environment: [(String, String)] = []
		for pair in pairs {
			guard pair.count == 2,
				["PROJECT_ROOT", "ERGOPTI_NATIVE_ARCH", "ERGOPTI_NATIVE_PYTHONS", "ERGOPTI_MLX_REPAIR"].contains(pair[0]),
				!pair[1].utf8.contains(0), names.insert(pair[0]).inserted else { return nil }
			environment.append((pair[0], pair[1]))
		}
		return ManagedPTYRequest(sourcePath: source, sourceSHA256: digest, environment: environment,
			timeoutMilliseconds: Int(timeout), receiptPath: receipt, nonce: nonce)
	}
}

private final class ManagedPTYSignalLatch: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	func set() { lock.lock(); value = true; lock.unlock() }
	var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Source bytes are copied into an unlinked descriptor before any child exists.
/// The child's fixed fd 3 therefore cannot follow a later pathname replacement.
enum ManagedPTYSource {
	static func snapshot(_ request: ManagedPTYRequest, interrupted: () -> Bool) -> Int32? {
		let input = Darwin.open(request.sourcePath, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
		guard input >= 0 else { return nil }
		defer { Darwin.close(input) }
		var initial = stat()
		guard fstat(input, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG, initial.st_size > 0 else { return nil }
		var template = Array((FileManager.default.temporaryDirectory.path + "/ergopti-pty-source.XXXXXX").utf8CString)
		let output = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
		guard output >= 0 else { return nil }
		defer { Darwin.close(output) }
		let preparedPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
		var prepared = stat()
		guard fstat(output, &prepared) == 0 else { return nil }
		var unlinked = false
		func unlinkOwned() -> Bool {
			var named = stat()
			guard lstat(preparedPath, &named) == 0, named.st_dev == prepared.st_dev,
				named.st_ino == prepared.st_ino else { return false }
			return Darwin.unlink(preparedPath) == 0
		}
		defer { if !unlinked { _ = unlinkOwned() } }
		guard fcntl(output, F_SETFD, FD_CLOEXEC) == 0 else { return nil }
		var hash = SHA256()
		var remaining = initial.st_size
		var bytes = [UInt8](repeating: 0, count: 4096)
		while remaining > 0 {
			guard !interrupted() else { return nil }
			let count = Darwin.read(input, &bytes, Int(min(remaining, off_t(bytes.count))))
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { return nil }
			let data = Data(bytes.prefix(count))
			guard ManagedPTYWorker.write(data, to: output) else { return nil }
			hash.update(data: data)
			remaining -= off_t(count)
		}
		var tail: UInt8 = 0
		var final = stat()
		var path = stat()
		guard Darwin.read(input, &tail, 1) == 0, !interrupted(), fstat(input, &final) == 0,
			stat(request.sourcePath, &path) == 0, initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
			initial.st_size == final.st_size, initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
			initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
			initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
			initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
			path.st_dev == final.st_dev, path.st_ino == final.st_ino,
			hash.finalize().map({ String(format: "%02x", $0) }).joined() == request.sourceSHA256,
			Darwin.fsync(output) == 0 else { return nil }
		// The child receives a read-only capability, never mkstemp's writable fd.
		// Reopening is fenced by the retained original inode before unlinking.
		let retained = Darwin.open(preparedPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		guard retained >= 0 else { return nil }
		var retainedInfo = stat()
		guard fstat(retained, &retainedInfo) == 0, retainedInfo.st_dev == prepared.st_dev,
			retainedInfo.st_ino == prepared.st_ino, retainedInfo.st_nlink == 1,
			retainedInfo.st_size == initial.st_size, !interrupted(), unlinkOwned() else {
			Darwin.close(retained); return nil
		}
		unlinked = true
		return retained
	}
}

private final class ManagedPTYReceipt {
	let descriptor: Int32
	private let path: String
	private let identity: stat

	init?(_ path: String) {
		let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { return nil }
		var identity = stat()
		var named = stat()
		guard fstat(descriptor, &identity) == 0, lstat(path, &named) == 0,
			(identity.st_mode & S_IFMT) == S_IFREG, identity.st_uid == geteuid(), identity.st_size == 0,
			identity.st_nlink == 1, identity.st_mode & 0o077 == 0,
			identity.st_dev == named.st_dev, identity.st_ino == named.st_ino else {
			Darwin.close(descriptor); return nil
		}
		self.descriptor = descriptor
		self.path = path
		self.identity = identity
	}

	func publish(_ fields: [String: Any]) -> Bool {
		var named = stat()
		guard lstat(path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG,
			named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
			let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), bytes.count <= 4096,
			lseek(descriptor, 0, SEEK_SET) == 0, ftruncate(descriptor, 0) == 0,
			ManagedPTYWorker.write(bytes, to: descriptor), Darwin.fsync(descriptor) == 0 else { return false }
		return true
	}
}

enum ManagedPTYWorker {
	static let flag = "--managed-pty-worker"
	private static let guardianFlag = "--managed-pty-guardian"
	private static let controlDescriptor: Int32 = 3
	private static let pollMilliseconds: Int32 = 20

	static func handles(arguments: [String]) -> Bool {
		return arguments.count > 1 && [flag, guardianFlag].contains(arguments[1])
	}

	static func nonblocking(_ descriptor: Int32) -> Bool {
		let flags = fcntl(descriptor, F_GETFL)
		return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
	}

	static func write(_ bytes: Data, to descriptor: Int32) -> Bool {
		var offset = 0
		while offset < bytes.count {
			let count = bytes.withUnsafeBytes { buffer in Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset) }
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { return false }
			offset += count
		}
		return true
	}

	private static func readLine(_ descriptor: Int32, milliseconds: Int, started: TimeInterval) -> Data? {
		var data = Data()
		while data.count <= 65_536 {
			guard ProcessInfo.processInfo.systemUptime - started < Double(milliseconds) / 1000 else { return nil }
			var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
			let ready = Darwin.poll(&event, 1, pollMilliseconds)
			if ready < 0 && errno == EINTR { continue }
			guard ready >= 0 else { return nil }
			if ready == 0 { continue }
			var byte: UInt8 = 0
			let count = Darwin.read(descriptor, &byte, 1)
			if count < 0 && errno == EINTR { continue }
			guard count == 1 else { return nil }
			if byte == 10 { return data }
			data.append(byte)
		}
		return nil
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 3, let milliseconds = Int(arguments[2]), milliseconds > 0,
			milliseconds <= Int(Int32.max) else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		if arguments[1] == guardianFlag { return guardian(milliseconds: milliseconds) }
		let parent = getppid()
		// Install before stdin or spawn: a pause during suspended-role admission
		// must order native cancellation instead of abandoning the reservation.
		let latch = ManagedPTYSignalLatch()
		var sources: [DispatchSourceSignal] = []
		for number in [SIGTERM, SIGINT, SIGHUP] {
			_ = Darwin.signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
			source.setEventHandler { latch.set() }
			source.resume(); sources.append(source)
		}
		defer { for source in sources { source.cancel() } }
		let started = ProcessInfo.processInfo.systemUptime
		guard let bytes = readLine(STDIN_FILENO, milliseconds: milliseconds, started: started),
			let request = ManagedPTYRequest.parse(bytes), request.timeoutMilliseconds == milliseconds,
			let receipt = ManagedPTYReceipt(request.receiptPath) else { return 64 }
		defer { Darwin.close(receipt.descriptor) }
		return bridge(executable: arguments[0], input: bytes, request: request, receipt: receipt,
			started: started, parent: parent, latch: latch)
	}

	private static func bridge(executable: String, input: Data, request: ManagedPTYRequest,
		receipt: ManagedPTYReceipt, started: TimeInterval, parent: pid_t, latch: ManagedPTYSignalLatch) -> Int32 {
		prepareLeaseChildReaping()
		guard let expected = LeaseExecutableIdentity.capture(at: executable),
			let sockets = makeReservedLeaseSocketEndpoints() else { return 74 }
		let control = sockets.outerDescriptor
		let inner = sockets.innerDescriptor
		var controlClosed = false
		defer { if !controlClosed { Darwin.close(control) } }
		var actions: posix_spawn_file_actions_t?
		var attributes: posix_spawnattr_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else { Darwin.close(inner); return 74 }
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawnattr_init(&attributes) == 0 else { Darwin.close(inner); return 74 }
		defer { posix_spawnattr_destroy(&attributes) }
		guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED)) == 0,
			posix_spawn_file_actions_adddup2(&actions, inner, controlDescriptor) == 0,
			posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO) == 0,
			posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDWR, 0) == 0,
			posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_RDWR, 0) == 0,
			let argv = duplicateCStringVector([executable, guardianFlag, String(request.timeoutMilliseconds)]),
			let envp = duplicateProcessEnvironment() else { Darwin.close(inner); return 74 }
		defer { for case let pointer? in argv { free(pointer) }; for case let pointer? in envp { free(pointer) } }
		var mutableArguments = argv
		var mutableEnvironment = envp
		var guardian: pid_t = 0
		let error = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				posix_spawn(&guardian, executable, &actions, &attributes, arguments.baseAddress, environment.baseAddress)
			}
		}
		Darwin.close(inner)
		guard error == 0 else { return 74 }
		// Keep this exact child unreaped until its privileged terminal arrives.
		// A rejected suspended role cannot have created any payload descendant.
		if LeaseExecutableIdentity.capture(at: executable) != expected {
			_ = Darwin.kill(guardian, SIGKILL)
			var status: Int32 = 0
			while waitpid(guardian, &status, 0) < 0 && errno == EINTR { }
			return 74
		}
		guard Darwin.kill(guardian, SIGCONT) == 0 else {
			_ = Darwin.kill(guardian, SIGKILL)
			var status: Int32 = 0
			while waitpid(guardian, &status, 0) < 0 && errno == EINTR { }
			return 74
		}
		var envelope = input
		// A separate scalar line carries the original global monotonic start.
		envelope.append(10); envelope.append(Data(String(started).utf8)); envelope.append(10)
		var disconnected = !write(envelope, to: control)
		_ = nonblocking(control)
		var decoder = OwnedProgramLineDecoder(maximumBytes: 128)
		var terminal: [String]?
		var cancelSent = false
		var deadline = false
		while terminal == nil && !disconnected {
			deadline = ProcessInfo.processInfo.systemUptime - started >= Double(request.timeoutMilliseconds) / 1000
			if (deadline || latch.cancelled || getppid() != parent) && !cancelSent {
				cancelSent = true
				if !write(Data("CANCEL\n".utf8), to: control) { disconnected = true; break }
			}
			var event = pollfd(fd: control, events: Int16(POLLIN), revents: 0)
			_ = Darwin.poll(&event, 1, pollMilliseconds)
			var buffer = [UInt8](repeating: 0, count: 128)
			let count = Darwin.read(control, &buffer, buffer.count)
			if count > 0 {
				if !decoder.append(Data(buffer.prefix(count))) { disconnected = true; break }
				while let line = decoder.pop() {
					let parts = String(decoding: line, as: UTF8.self).split(separator: " ").map(String.init)
					if parts.count == 4 && parts[0] == "RETIRED" { terminal = parts }
					else { disconnected = true }
				}
			} else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { disconnected = true }
		}
		if disconnected { _ = shutdown(control, SHUT_WR) }
		// Blocking wait retains the exact guardian capability after cancellation.
		// No group signal is issued after this successful guardian reap.
		var nativeStatus: Int32 = 0
		var waited: pid_t
		repeat { waited = waitpid(guardian, &nativeStatus, 0) } while waited < 0 && errno == EINTR
		guard waited == guardian, nativeStatus == 0, let terminal,
			let exit = Int32(terminal[1]), let worker = Int32(terminal[2]),
			(0...255).contains(exit), (0...255).contains(worker),
			["0", "1"].contains(terminal[3]), worker != 0 || terminal[3] == "1" else { return 74 }
		guard Darwin.close(control) == 0 else { return 74 }
		controlClosed = true
		let result: Int32 = deadline ? 124 : (latch.cancelled ? 130 : worker)
		guard receipt.publish(["version": 1, "nonce": request.nonce, "state": "retired", "group_retired": true,
			"guardian_reaped": true, "pty_eof": true, "handles_closed": true, "status_valid": true,
			"exit_status": exit, "worker_status": result, "source_admitted": terminal[3] == "1"]) else { return 74 }
		return result
	}

	private static func guardian(milliseconds: Int) -> Int32 {
		guard setsid() == getpid(), nonblocking(controlDescriptor), nonblocking(STDOUT_FILENO) else { return 74 }
		prepareLeaseChildReaping()
		let parent = getppid()
		let received = ProcessInfo.processInfo.systemUptime
		guard let bytes = readLine(controlDescriptor, milliseconds: milliseconds, started: received),
			let request = ManagedPTYRequest.parse(bytes), request.timeoutMilliseconds == milliseconds,
			let clock = readLine(controlDescriptor, milliseconds: milliseconds, started: received),
			let started = Double(String(decoding: clock, as: UTF8.self)), started.isFinite,
			started > 0, started <= ProcessInfo.processInfo.systemUptime else { return 74 }
		let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/static/ergopti_plus/macos/modules/llm/ensure-mlx-deps.sh").standardizedFileURL.path
		var cancelled = false
		var deadline = false
		var decoder = OwnedProgramLineDecoder(maximumBytes: 128)
		func consumeControl() {
			var bytes = [UInt8](repeating: 0, count: 128)
			let count = Darwin.read(controlDescriptor, &bytes, bytes.count)
			if count > 0 {
				if !decoder.append(Data(bytes.prefix(count))) { cancelled = true; return }
				while let line = decoder.pop() { if line == Data("CANCEL".utf8) { cancelled = true } else { cancelled = true } }
			} else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { cancelled = true }
			deadline = ProcessInfo.processInfo.systemUptime - started >= Double(milliseconds) / 1000
			if deadline || getppid() != parent { cancelled = true }
		}
		guard URL(fileURLWithPath: request.sourcePath).standardizedFileURL.path == expected,
			let source = ManagedPTYSource.snapshot(request, interrupted: { consumeControl(); return cancelled }) else {
			return write(Data("RETIRED 64 64 0\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		var master: Int32 = -1
		var slave: Int32 = -1
		guard openpty(&master, &slave, nil, nil, nil) == 0 else {
			guard Darwin.close(source) == 0 else { return 74 }
			return write(Data("RETIRED 74 74 1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		guard nonblocking(master) else {
			let closed = [source, master, slave].map { Darwin.close($0) == 0 }.allSatisfy { $0 }
			return closed && write(Data("RETIRED 74 74 1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		var environment = ProcessInfo.processInfo.environment
		// Noninteractive bash must not run an inherited startup file or exported
		// shell function before the admitted, retained bootstrap source.
		for name in environment.keys.filter({ $0 == "BASH_ENV" || $0 == "ENV" || $0.hasPrefix("BASH_FUNC_") }) {
			environment.removeValue(forKey: name)
		}
		for (name, value) in request.environment { environment[name] = value }
		environment["ERGOPTI_BOOTSTRAP_SCRIPT_DIR"] = URL(fileURLWithPath: expected).deletingLastPathComponent().path
		guard let argv = duplicateCStringVector(["/bin/bash", "/dev/fd/3"]),
			let envp = duplicateCStringVector(environment.keys.sorted().map { $0 + "=" + environment[$0]! }) else {
			let closed = [source, master, slave].map { Darwin.close($0) == 0 }.allSatisfy { $0 }
			return closed && write(Data("RETIRED 74 74 1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		defer { for case let pointer? in argv { free(pointer) }; for case let pointer? in envp { free(pointer) } }
		var mutableArguments = argv
		var mutableEnvironment = envp
		var owner: OpaquePointer?
		let error = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				ergopti_owned_program_prepare_with_tty_source("/bin/bash", arguments.baseAddress, environment.baseAddress, slave, source, &owner)
			}
		}
		let sourceClosed = Darwin.close(source) == 0
		let slaveClosed = Darwin.close(slave) == 0
		let borrowedClosed = sourceClosed && slaveClosed
		guard let prepared = owner else {
			let masterClosed = Darwin.close(master) == 0
			return borrowedClosed && masterClosed && write(Data("RETIRED 74 74 1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		if error != 0 || !borrowedClosed { cancelled = true }
		consumeControl()
		if !cancelled {
			let activation = ergopti_owned_program_activate(prepared)
			if !activation.active || activation.cancelled { cancelled = true }
		}
		var retired: ergopti_owned_program_receipt?
		var eof = false
		var output = Data()
		var delivered = true
		while retired == nil || !eof || !output.isEmpty {
			consumeControl()
			if cancelled {
				_ = ergopti_owned_program_cancel(prepared)
				// Cancelled progress cannot publish to a successor UI epoch. Drain
				// the real PTY while discarding its bounded undelivered tail.
				delivered = false; output.removeAll()
			}
			let observation = ergopti_owned_program_poll(prepared)
			if observation.retired { retired = observation }
			if !eof && output.count < 65_536 {
				var bytes = [UInt8](repeating: 0, count: min(4096, 65_536 - output.count))
				let count = Darwin.read(master, &bytes, bytes.count)
				if count > 0 { if delivered { output.append(contentsOf: bytes.prefix(count)) } }
				// Darwin PTYs report EIO when the final slave closes. This may
				// precede leader exit; the native owner still gates retirement.
				else if count == 0 || (count < 0 && errno == EIO) { eof = true }
				else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { cancelled = true }
			}
			if !output.isEmpty {
				let count = output.withUnsafeBytes { buffer in Darwin.write(STDOUT_FILENO, buffer.baseAddress!, output.count) }
				if count > 0 { output.removeSubrange(..<count) }
				else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
					delivered = false; output.removeAll(); cancelled = true
				}
			}
			var events = [pollfd(fd: controlDescriptor, events: Int16(POLLIN), revents: 0),
				pollfd(fd: eof ? -1 : master, events: Int16(POLLIN), revents: 0),
				pollfd(fd: output.isEmpty ? -1 : STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)]
			_ = Darwin.poll(&events, nfds_t(events.count), pollMilliseconds)
		}
		guard let retired, retired.status_valid, retired.error_code == 0,
			ergopti_owned_program_destroy(&owner), Darwin.close(master) == 0, borrowedClosed else { return 74 }
		let status: Int32 = deadline ? 124 : (cancelled ? 130 : retired.exit_status)
		return write(Data("RETIRED \(retired.exit_status) \(status) 1\n".utf8), to: controlDescriptor) ? 0 : 74
	}
}

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
			let pairs = fields["environment"] as? [[String]], pairs.count <= 6,
			let timeout = ManagedBootstrapRequest.integer(fields["timeout_ms"]), timeout > 0, timeout <= Int64(Int32.max),
			let receipt = fields["receipt_path"] as? String, receipt.hasPrefix("/"), !receipt.utf8.contains(0),
			let nonce = fields["nonce"] as? String, !nonce.isEmpty, nonce.utf8.count <= 128,
			nonce.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
		else { return nil }
		let official = URL(fileURLWithPath: source).lastPathComponent == "ensure-ollama-deps.sh"
		let admittedNames: Set<String> = official ? ["PROJECT_ROOT", "ERGOPTI_NATIVE_ARCH", "ERGOPTI_NATIVE_PYTHONS",
			"ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN", "ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR", "ERGOPTI_BOOTSTRAP_PYTHON"]
			: ["PROJECT_ROOT", "ERGOPTI_NATIVE_ARCH", "ERGOPTI_NATIVE_PYTHONS", "ERGOPTI_MLX_REPAIR"]
		var names = Set<String>()
		var environment: [(String, String)] = []
		for pair in pairs {
			guard pair.count == 2,
				admittedNames.contains(pair[0]),
				!pair[1].utf8.contains(0), names.insert(pair[0]).inserted else { return nil }
			environment.append((pair[0], pair[1]))
		}
		if official {
			let values = Dictionary(uniqueKeysWithValues: environment)
			guard names == admittedNames, values["ERGOPTI_BOOTSTRAP_PYTHON"] == "",
				["arm64", "x86_64"].contains(values["ERGOPTI_NATIVE_ARCH"] ?? ""),
				let resolved = values["ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN"],
				resolved.isEmpty || (resolved.hasPrefix("/") && URL(fileURLWithPath: resolved).standardizedFileURL.path == resolved),
				let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"),
				values["ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR"] == (resolved.isEmpty
					? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Ergopti/ollama").standardizedFileURL.path : "")
			else { return nil }
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

/// A verified installer copy at a private, linked path. Endpoint-security
/// agents on managed Macs kill `/bin/bash /dev/fd/3` over an unlinked file as
/// fileless script execution (field report 2026-10-27 23:55: the same 12 s
/// script survived from a path and died with SIGKILL from /dev/fd/3), so the
/// guardian runs this copy as a regular path. The read-only descriptor kept
/// here is the identity every later check is made through.
struct ManagedPTYSnapshot {
	let descriptor: Int32
	let path: String
	let directory: String
	let identity: stat

	private static func sameFile(_ left: stat, _ right: stat) -> Bool {
		return left.st_dev == right.st_dev && left.st_ino == right.st_ino
			&& left.st_size == right.st_size && left.st_mode == right.st_mode
			&& left.st_uid == right.st_uid && left.st_nlink == right.st_nlink
			&& left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
			&& left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
			&& left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
			&& left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
	}

	/// Proves, immediately before the payload may read it, that the path still
	/// names the verified inode, unchanged (a write or chmod moves its ctime),
	/// and that its bytes still hash to the admitted digest, read through the
	/// retained descriptor.
	/// - Parameter sha256: The admitted lowercase hexadecimal digest.
	/// - Returns: Whether the path may be handed to /bin/bash.
	func verified(sha256: String) -> Bool {
		var held = stat()
		var named = stat()
		guard fstat(descriptor, &held) == 0, lstat(path, &named) == 0,
			(named.st_mode & S_IFMT) == S_IFREG, named.st_nlink == 1,
			Self.sameFile(held, identity), Self.sameFile(named, identity) else { return false }
		var hash = SHA256()
		var offset: off_t = 0
		var bytes = [UInt8](repeating: 0, count: 4096)
		while offset < identity.st_size {
			let count = pread(descriptor, &bytes, bytes.count, offset)
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { return false }
			hash.update(data: Data(bytes.prefix(count)))
			offset += off_t(count)
		}
		guard offset == identity.st_size else { return false }
		return hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256
	}

	/// Unlinks the copy, when the path still names it, and its private folder.
	/// - Returns: Whether neither remains.
	func remove() -> Bool {
		var named = stat()
		if lstat(path, &named) == 0 {
			guard named.st_dev == identity.st_dev, named.st_ino == identity.st_ino,
				Darwin.unlink(path) == 0 else { return false }
		} else if errno != ENOENT { return false }
		return Darwin.rmdir(directory) == 0 || errno == ENOENT
	}
}

/// Copies the admitted installer, before any child exists, into a private
/// linked snapshot whose content matches the request's independent digest.
enum ManagedPTYSource {
	/// Folder of the snapshots, under the person's application data.
	static let folderName = "pty-sources"

	/// The private snapshot root for one home folder.
	/// - Parameter home: Absolute home folder.
	/// - Returns: The root path.
	static func root(home: String) -> String {
		return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ErgoptiPlus")
			.appendingPathComponent(folderName).standardizedFileURL.path
	}

	/// Accepts only a real folder of this user that nobody else may write.
	private static func ownedPrivateFolder(_ path: String, privateMode: Bool) -> Bool {
		var info = stat()
		guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { return false }
		return privateMode ? info.st_mode & 0o077 == 0 : info.st_mode & 0o022 == 0
	}

	/// Creates the root on first use, owner-only, and refuses a symlink, a
	/// foreign owner or a folder group or others may write, at every level
	/// from the application data folder down.
	private static func preparedRoot(_ root: String) -> Bool {
		let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
		if Darwin.mkdir(parent, 0o700) != 0 && errno != EEXIST { return false }
		guard ownedPrivateFolder(parent, privateMode: false) else { return false }
		if Darwin.mkdir(root, 0o700) != 0 && errno != EEXIST { return false }
		return ownedPrivateFolder(root, privateMode: true)
	}

	/// Removes the snapshots of guardians that no longer run. A folder is named
	/// after its guardian's pid, so a live operation's copy is never touched.
	/// - Parameter root: The private snapshot root.
	static func sweepStale(root: String) {
		guard ownedPrivateFolder(root, privateMode: true),
			let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
		for name in names {
			let parts = name.split(separator: ".")
			guard parts.count == 3, parts[0] == "op", let pid = pid_t(parts[1]), pid > 0,
				pid != getpid(), Darwin.kill(pid, 0) != 0, errno == ESRCH else { continue }
			let folder = root + "/" + name
			guard ownedPrivateFolder(folder, privateMode: true),
				let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
			for file in files {
				var info = stat()
				let path = folder + "/" + file
				guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else { continue }
				_ = Darwin.unlink(path)
			}
			_ = Darwin.rmdir(folder)
		}
	}

	/// Copies the installer into `<root>/op.<pid>.XXXXXX/<name>`, created
	/// O_EXCL read-only for its owner, then proves the copy through a fresh
	/// read-only descriptor against the request digest.
	/// - Parameters:
	///   - request: The admitted request.
	///   - root: The private snapshot root.
	///   - interrupted: Polled between reads; true abandons the copy.
	/// - Returns: The verified snapshot, or nil after removing any partial copy.
	static func snapshot(_ request: ManagedPTYRequest, root: String, interrupted: () -> Bool) -> ManagedPTYSnapshot? {
		guard preparedRoot(root) else { return nil }
		let input = Darwin.open(request.sourcePath, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
		guard input >= 0 else { return nil }
		defer { Darwin.close(input) }
		var initial = stat()
		guard fstat(input, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG, initial.st_size > 0 else { return nil }
		var template = Array((root + "/op.\(getpid()).XXXXXX").utf8CString)
		guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else { return nil }
		let directory = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
		let path = directory + "/" + URL(fileURLWithPath: request.sourcePath).lastPathComponent
		var published = false
		defer {
			if !published {
				_ = Darwin.unlink(path)
				_ = Darwin.rmdir(directory)
			}
		}
		guard ownedPrivateFolder(directory, privateMode: true) else { return nil }
		let output = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
		guard output >= 0 else { return nil }
		var written = stat()
		guard fstat(output, &written) == 0 else { Darwin.close(output); return nil }
		var hash = SHA256()
		var remaining = initial.st_size
		var bytes = [UInt8](repeating: 0, count: 4096)
		var copied = true
		while remaining > 0 {
			guard !interrupted() else { copied = false; break }
			let count = Darwin.read(input, &bytes, Int(min(remaining, off_t(bytes.count))))
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { copied = false; break }
			let data = Data(bytes.prefix(count))
			guard ManagedPTYWorker.write(data, to: output) else { copied = false; break }
			hash.update(data: data)
			remaining -= off_t(count)
		}
		let synced = copied && Darwin.fsync(output) == 0
		guard Darwin.close(output) == 0, synced else { return nil }
		var tail: UInt8 = 0
		var final = stat()
		var source = stat()
		guard Darwin.read(input, &tail, 1) == 0, !interrupted(), fstat(input, &final) == 0,
			stat(request.sourcePath, &source) == 0, initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
			initial.st_size == final.st_size, initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
			initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
			initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
			initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
			source.st_dev == final.st_dev, source.st_ino == final.st_ino,
			hash.finalize().map({ String(format: "%02x", $0) }).joined() == request.sourceSHA256 else { return nil }
		// The child and every later check use this read-only capability, never
		// the writer; reopening is fenced by the inode the writer created.
		let retained = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		guard retained >= 0 else { return nil }
		var identity = stat()
		guard fstat(retained, &identity) == 0, identity.st_dev == written.st_dev,
			identity.st_ino == written.st_ino, identity.st_nlink == 1, identity.st_uid == geteuid(),
			identity.st_mode & 0o7777 == 0o400, identity.st_size == initial.st_size, !interrupted() else {
			Darwin.close(retained); return nil
		}
		let snapshot = ManagedPTYSnapshot(descriptor: retained, path: path, directory: directory, identity: identity)
		guard snapshot.verified(sha256: request.sourceSHA256) else { Darwin.close(retained); return nil }
		published = true
		return snapshot
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
	/// The only installers the guardian runs, relative to the driver folder.
	static let admittedSourceNames = ["ensure-mlx-deps.sh", "ensure-ollama-native-deps.sh", "ensure-ollama-deps.sh"]

	/// Absolute installer paths the guardian admits for one Lua source. They live
	/// in the folder the embedded runtime reads its Lua from: the signed payload
	/// of a packaged app, or the clone a developer build records. The driver
	/// builds the request from its own folder, so a developer build that admitted
	/// only the payload refused its clone's installer with exit 64 (field run
	/// 2026-10-27 19:47). A refused selection admits nothing.
	/// - Parameter selection: The launcher's Lua source selection.
	/// - Returns: The standardized admitted paths; empty for a refusal.
	static func admittedSources(for selection: LuaSourceSelection) -> Set<String> {
		guard let configDir = selection.configDir else { return [] }
		let directory = URL(fileURLWithPath: configDir).appendingPathComponent("modules/llm")
		return Set(admittedSourceNames.map { directory.appendingPathComponent($0).standardizedFileURL.path })
	}

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
					if parts.count == 6 && parts[0] == "RETIRED" { terminal = parts }
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
			["0", "1"].contains(terminal[3]), worker != 0 || terminal[3] == "1",
			let ptyBytes = Int(terminal[4]), ptyBytes >= 0,
			let leaderMilliseconds = Int(terminal[5]), leaderMilliseconds >= -1 else { return 74 }
		guard Darwin.close(control) == 0 else { return 74 }
		controlClosed = true
		let result: Int32 = deadline ? 124 : (latch.cancelled ? 130 : worker)
		guard receipt.publish(["version": 1, "nonce": request.nonce, "state": "retired", "group_retired": true,
			"guardian_reaped": true, "pty_eof": true, "handles_closed": true, "status_valid": true,
			"exit_status": exit, "worker_status": result, "source_admitted": terminal[3] == "1"]) else { return 74 }
		reportUnexplainedEnd(exit: exit, result: result, ptyBytes: ptyBytes, leaderMilliseconds: leaderMilliseconds)
		return result
	}

	/// Names, on the worker's stderr, an installer that ran and failed without
	/// a cause of its own: killed by a signal Ergopti did not send, or silent.
	/// The 2026-10-27 field runs ended with 137 and no output at all, and
	/// nothing said whether bash had run, what it printed or how long it
	/// lived. Cancellation (130), the deadline (124) and refusals before
	/// activation already have their own closed status and stay quiet.
	/// - Parameters:
	///   - exit: The leader's exit status, 128 + N for signal N.
	///   - result: The worker's status for the caller.
	///   - ptyBytes: Bytes the leader wrote to the PTY.
	///   - leaderMilliseconds: Time from activation to retirement, -1 when never activated.
	private static func reportUnexplainedEnd(exit: Int32, result: Int32, ptyBytes: Int, leaderMilliseconds: Int) {
		guard leaderMilliseconds >= 0, result != 0, result != 124, result != 130,
			exit > 128 || ptyBytes == 0 else { return }
		let cause = exit > 128 ? "was killed by signal \(exit - 128), not sent by Ergopti" : "exited \(exit)"
		let line = "[PTY-WORKER] The installer \(cause) \(leaderMilliseconds) ms after it started, "
			+ "having written \(ptyBytes) byte(s) to its terminal.\n"
		_ = write(Data(line.utf8), to: STDERR_FILENO)
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
		let admitted = admittedSources(for: LuaSourceSelection.resolve(
			infoDictionary: Bundle.main.infoDictionary,
			bundlePath: Bundle.main.bundlePath,
			fileExists: { FileManager.default.fileExists(atPath: $0) }))
		let expected = URL(fileURLWithPath: request.sourcePath).standardizedFileURL.path
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
		guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
			return write(Data("RETIRED 74 74 0 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		let snapshotRoot = ManagedPTYSource.root(home: home)
		ManagedPTYSource.sweepStale(root: snapshotRoot)
		guard admitted.contains(expected),
			let snapshot = ManagedPTYSource.snapshot(request, root: snapshotRoot,
				interrupted: { consumeControl(); return cancelled }) else {
			return write(Data("RETIRED 64 64 0 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		// Every return below removes the copy; the final one proves it.
		var snapshotRemoved = false
		defer { if !snapshotRemoved { _ = snapshot.remove() } }
		let source = snapshot.descriptor
		var master: Int32 = -1
		var slave: Int32 = -1
		guard openpty(&master, &slave, nil, nil, nil) == 0 else {
			guard Darwin.close(source) == 0 else { return 74 }
			return write(Data("RETIRED 74 74 1 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		guard nonblocking(master) else {
			let closed = [source, master, slave].map { Darwin.close($0) == 0 }.allSatisfy { $0 }
			return closed && write(Data("RETIRED 74 74 1 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		var environment = ProcessInfo.processInfo.environment
		// Noninteractive bash must not run an inherited startup file or exported
		// shell function before the admitted, retained bootstrap source.
		for name in environment.keys.filter({ $0 == "BASH_ENV" || $0 == "ENV" || $0.hasPrefix("BASH_FUNC_") }) {
			environment.removeValue(forKey: name)
		}
		for (name, value) in request.environment { environment[name] = value }
		environment["ERGOPTI_BOOTSTRAP_SCRIPT_DIR"] = URL(fileURLWithPath: expected).deletingLastPathComponent().path
		// The installer recognises its own snapshot by this exact path.
		environment["ERGOPTI_BOOTSTRAP_SNAPSHOT"] = snapshot.path
		// Child phases inherit only the remainder of the original owner budget.
		let remainingMilliseconds = max(1, Int((started + Double(milliseconds) / 1000 - ProcessInfo.processInfo.systemUptime) * 1000))
		environment["ERGOPTI_BOOTSTRAP_TIMEOUT_MS"] = String(remainingMilliseconds)
		guard let argv = duplicateCStringVector(["/bin/bash", snapshot.path]),
			let envp = duplicateCStringVector(environment.keys.sorted().map { $0 + "=" + environment[$0]! }) else {
			let closed = [source, master, slave].map { Darwin.close($0) == 0 }.allSatisfy { $0 }
			return closed && write(Data("RETIRED 74 74 1 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
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
		// bash opens the path only once activated: prove the copy unchanged
		// through the retained descriptor right before that, while it is held.
		let sourceRefused = owner != nil && !snapshot.verified(sha256: request.sourceSHA256)
		let sourceClosed = Darwin.close(source) == 0
		let slaveClosed = Darwin.close(slave) == 0
		let borrowedClosed = sourceClosed && slaveClosed
		guard let prepared = owner else {
			let masterClosed = Darwin.close(master) == 0
			return borrowedClosed && masterClosed && write(Data("RETIRED 74 74 1 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74
		}
		if error != 0 || !borrowedClosed || sourceRefused { cancelled = true }
		consumeControl()
		var activatedAt: TimeInterval?
		if !cancelled {
			let activation = ergopti_owned_program_activate(prepared)
			if !activation.active || activation.cancelled { cancelled = true }
			else { activatedAt = ProcessInfo.processInfo.systemUptime }
		}
		var retired: ergopti_owned_program_receipt?
		var retiredAt: TimeInterval?
		var ptyBytes = 0
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
			if observation.retired {
				retired = observation
				if retiredAt == nil { retiredAt = ProcessInfo.processInfo.systemUptime }
			}
			if !eof && output.count < 65_536 {
				var bytes = [UInt8](repeating: 0, count: min(4096, 65_536 - output.count))
				let count = Darwin.read(master, &bytes, bytes.count)
				if count > 0 {
					ptyBytes += count
					if delivered { output.append(contentsOf: bytes.prefix(count)) }
				}
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
		snapshotRemoved = snapshot.remove()
		guard snapshotRemoved else { return write(Data("RETIRED 74 74 1 0 -1\n".utf8), to: controlDescriptor) ? 0 : 74 }
		// A copy changed after admission is refused like a source that never matched.
		let status: Int32 = deadline ? 124 : (sourceRefused ? 64 : (cancelled ? 130 : retired.exit_status))
		// -1: the leader was never activated, so it cannot have run.
		let leaderMilliseconds = activatedAt.flatMap { start in
			retiredAt.map { max(0, Int(($0 - start) * 1000)) } } ?? -1
		return write(Data("RETIRED \(retired.exit_status) \(status) \(sourceRefused ? 0 : 1) \(ptyBytes) \(leaderMilliseconds)\n".utf8),
			to: controlDescriptor) ? 0 : 74
	}
}

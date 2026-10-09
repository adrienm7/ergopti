// Sources/ErgoptiPlus/OwnedSuspendedImageGuardian.swift
// Holds exact native image ownership before the caller releases session bytes.

import CPOSIXCompatibility
import CoreFoundation
import CryptoKit
import Security
import Darwin
import Foundation

struct ManagedNetworkBootstrapBinding {
	let path: String
	let device: UInt64
	let inode: UInt64
	let storeMode: String
	let cwd: String
}

struct OwnedSuspendedImageRequest {
	let executable: String
	let arguments: [String]
	let device: UInt64
	let inode: UInt64
	let sessionPath: String
	let remainingMilliseconds: UInt32
	let environment: [String: String]
	let outgoingWorker: String
	let outgoingSHA256: String?
	let bootstrap: ManagedNetworkBootstrapBinding?

	private static func unsigned(_ value: Any?) -> UInt64? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			number.doubleValue >= 0, number.stringValue == String(number.uint64Value),
			!String(cString: number.objCType).contains("f"), !String(cString: number.objCType).contains("d"),
			NSNumber(value: number.uint64Value).compare(number) == .orderedSame else { return nil }
		return number.uint64Value
	}

	private static func decimal(_ value: Any?) -> UInt64? {
		guard let text = value as? String, let number = UInt64(text), String(number) == text else { return nil }
		return number
	}

	static func parse(_ data: Data, launcher: String) -> OwnedSuspendedImageRequest? {
		let keys: Set<String> = ["version", "executable", "arguments", "device", "inode", "session_path",
			"remaining_ms", "home", "models_path", "network_policy", "host", "proxy_url"]
		let outgoingKeys: Set<String> = ["outgoing_worker", "outgoing_device", "outgoing_inode", "outgoing_sha256"]
		let bootstrapKeys: Set<String> = ["bootstrap_path", "bootstrap_device", "bootstrap_inode", "store_mode", "store_cwd"]
		guard data.count <= 65_536,
			let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			[keys, keys.union(outgoingKeys), keys.union(bootstrapKeys), keys.union(outgoingKeys).union(bootstrapKeys)].contains(Set(fields.keys)),
			unsigned(fields["version"]) == 1,
			let device = decimal(fields["device"]), device <= UInt64(UInt32.max),
			let inode = decimal(fields["inode"]), inode > 0,
			let remaining = unsigned(fields["remaining_ms"]), remaining > 0, remaining <= 30_000,
			let executable = fields["executable"] as? String, validPath(executable),
			let session = fields["session_path"] as? String, validPath(session),
			let home = fields["home"] as? String, validPath(home),
			let models = fields["models_path"] as? String, !models.utf8.contains(0), models.utf8.count <= ManagedBootstrapPolicy.maximumProxyBytes,
				fields["bootstrap_path"] != nil || models.isEmpty || validPath(models),
			let policy = fields["network_policy"] as? String, validPath(policy),
			let host = fields["host"] as? String, validLoopback(host, prefix: "127.0.0.1:"),
			let proxy = fields["proxy_url"] as? String,
				proxy.isEmpty || validLoopback(proxy, prefix: "http://127.0.0.1:"),
			let arguments = fields["arguments"] as? [String], arguments == ["serve"],
			arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 8192 }),
			validPath(launcher) else { return nil }
		let runtime = home + "/Library/Application Support/Ergopti/ollama-native-http/"
		let sessions = home + "/Library/Application Support/Ergopti/ollama-native-sessions/"
		guard executable.hasPrefix(runtime), session.hasPrefix(sessions),
			fields["bootstrap_path"] != nil || models.isEmpty || models.hasPrefix(home + "/") else { return nil }
		let sessionName = String(session.dropFirst(sessions.count))
		guard sessionName.hasPrefix("daemon-"), sessionName.hasSuffix(".json"), sessionName.utf8.count == 44,
			sessionName.dropFirst(7).dropLast(5).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
		let basename = String(executable.dropFirst(runtime.count))
		let prefix = ".ergopti-image-"
		guard basename.hasPrefix(prefix), basename.utf8.count == prefix.utf8.count + 32,
			basename.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
		let bootstrap: ManagedNetworkBootstrapBinding?
		if fields["bootstrap_path"] != nil {
			guard proxy.isEmpty, let path = fields["bootstrap_path"] as? String, validPath(path),
				path == sessions + "network-" + String(sessionName.dropFirst(7)),
				let device = decimal(fields["bootstrap_device"]), device <= UInt64(UInt32.max),
				let inode = decimal(fields["bootstrap_inode"]), inode > 0,
				let mode = fields["store_mode"] as? String, ["default", "environment"].contains(mode),
				(mode == "default" && models.isEmpty) || (mode == "environment" && !models.isEmpty),
				let cwd = fields["store_cwd"] as? String, validPath(cwd),
				cwd == FileManager.default.currentDirectoryPath else { return nil }
			bootstrap = ManagedNetworkBootstrapBinding(path: path, device: device, inode: inode, storeMode: mode, cwd: cwd)
		} else { bootstrap = nil }
		let outgoing: String
		let outgoingDevice: UInt64
		let outgoingInode: UInt64
		let outgoingSHA256: String?
		if fields["outgoing_worker"] != nil {
			guard let selected = fields["outgoing_worker"] as? String, validPath(selected), selected.hasSuffix("/Contents/MacOS/ErgoptiPlus"),
				let device = decimal(fields["outgoing_device"]), device <= UInt64(UInt32.max),
				let inode = decimal(fields["outgoing_inode"]), inode > 0,
				let digest = fields["outgoing_sha256"] as? String, digest.utf8.count == 64,
				digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
			outgoing = selected; outgoingDevice = device; outgoingInode = inode; outgoingSHA256 = digest
		} else {
			var launcherIdentity = stat()
			guard lstat(launcher, &launcherIdentity) == 0, (launcherIdentity.st_mode & S_IFMT) == S_IFREG else { return nil }
			outgoing = launcher
			outgoingDevice = UInt64(UInt32(bitPattern: launcherIdentity.st_dev))
			outgoingInode = UInt64(launcherIdentity.st_ino)
			outgoingSHA256 = nil
		}
		// These public bindings are not source qualification. The original trusted
		// receiving context supplies them only after its actual source/compile/sign
		// fences, retains its own FD, and withholds every key if that context fails.
		// No inherited environment or credential-bearing proxy URL reaches the child.
		var environment = [
			"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
			"OLLAMA_HOST": host, "ERGOPTI_OLLAMA_NATIVE_HTTP": "1", "ERGOPTI_OLLAMA_NATIVE_SESSION": session,
			"ERGOPTI_OLLAMA_NETWORK_POLICY": policy, "ERGOPTI_OLLAMA_NATIVE_HTTP_IDLE_TIMEOUT": "60",
			"ERGOPTI_LAUNCHER_EXECUTABLE": outgoing,
			"ERGOPTI_LAUNCHER_DEVICE": String(outgoingDevice),
			"ERGOPTI_LAUNCHER_INODE": String(outgoingInode),
		]
		if let bootstrap {
			environment["ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP"] = bootstrap.path
			environment["ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP_DEVICE"] = String(bootstrap.device)
			environment["ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP_INODE"] = String(bootstrap.inode)
		}
		if !models.isEmpty { environment["OLLAMA_MODELS"] = models }
		if !proxy.isEmpty { environment["https_proxy"] = proxy }
		return OwnedSuspendedImageRequest(executable: executable, arguments: arguments, device: device,
			inode: inode, sessionPath: session, remainingMilliseconds: UInt32(remaining), environment: environment,
			outgoingWorker: outgoing, outgoingSHA256: outgoingSHA256, bootstrap: bootstrap)
	}

	private static func validPath(_ value: String) -> Bool {
		value.hasPrefix("/") && !value.utf8.contains(0) && value.utf8.count < Int(PATH_MAX)
			&& value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
				.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
	}
	private static func validLoopback(_ value: String, prefix: String) -> Bool {
		guard value.hasPrefix(prefix) else { return false }
		let port = String(value.dropFirst(prefix.count))
		guard let number = UInt16(port), number > 0, String(number) == port else { return false }
		return true
	}
}

/// A direct guardian role. EOF cancels the held child, including caller death;
/// the guardian retains its native owner until physical group retirement.
enum OwnedSuspendedImageGuardian {
	static let flag = "--owned-suspended-image-guardian"
	static func handles(arguments: [String]) -> Bool { arguments.count > 1 && arguments[1] == flag }

	private static func monotonic() -> UInt64? {
		var value = timespec()
		guard clock_gettime(CLOCK_MONOTONIC, &value) == 0, value.tv_sec >= 0, value.tv_nsec >= 0,
			UInt64(value.tv_sec) <= (UInt64.max - UInt64(value.tv_nsec)) / 1_000_000_000 else { return nil }
		return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 2 else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		// Termination signals cannot dispose the cleanup owner. EOF/CANCEL drives
		// ordinary retirement; a caller must not SIGKILL a guardian with live debt.
		_ = Darwin.signal(SIGTERM, SIG_IGN)
		_ = Darwin.signal(SIGINT, SIG_IGN)
		guard setsid() == getpid() else { return 70 }
		prepareLeaseChildReaping()
		for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
			let flags = fcntl(descriptor, F_GETFL)
			guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return 70 }
		}
		var outputOpen = true
		func send(_ value: String) -> Bool {
			guard outputOpen else { return false }
			let data = Data((value + "\n").utf8)
			let written = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, data.count) }
			if written != data.count { outputOpen = false; return false }
			return true
		}
		var decoder = OwnedProgramLineDecoder(maximumBytes: 65_537)
		var inputOpen = true
		var cancelled = false
		func readLines() -> [Data] {
			guard inputOpen else { return [] }
			var bytes = [UInt8](repeating: 0, count: 4096)
			let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
			if count > 0 {
				guard decoder.append(Data(bytes.prefix(count))) else { cancelled = true; inputOpen = false; return [] }
				var result: [Data] = []
				while let line = decoder.pop() { result.append(line) }
				return result
			}
			if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
				inputOpen = false; cancelled = true
			}
			return []
		}
		func wait() {
			var event = pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0)
			_ = Darwin.poll(&event, 1, 20)
		}
		guard let started = monotonic() else { return 70 }
		var request: OwnedSuspendedImageRequest?
		while request == nil && !cancelled {
			let lines = readLines()
			if !lines.isEmpty {
				guard lines.count == 1, let parsed = OwnedSuspendedImageRequest.parse(lines[0], launcher: arguments[0]) else {
					_ = send("V1 REFUSED \(EINVAL)"); return 0
				}
				request = parsed
			}
			guard let now = monotonic(), now >= started, now - started < 30_000_000_000 else {
				_ = send("V1 REFUSED \(ETIMEDOUT)"); return 0
			}
			if request == nil { wait() }
		}
		guard let request, !cancelled else { return 0 }
		let admissionStarted = started
		guard let admittedNow = monotonic(), admittedNow >= admissionStarted,
			admittedNow - admissionStarted < UInt64(request.remainingMilliseconds) * 1_000_000 else {
			_ = send("V1 REFUSED \(ETIMEDOUT)"); return 0
		}
		func admissionRemaining() -> Bool {
			guard let now = monotonic(), now >= admissionStarted else { return false }
			return now - admissionStarted < UInt64(request.remainingMilliseconds) * 1_000_000
		}
		var outgoingDescriptor = Darwin.open(request.outgoingWorker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard outgoingDescriptor >= 0 else { _ = send("V1 REFUSED \(EIO)"); return 0 }
		defer { if outgoingDescriptor >= 0 { Darwin.close(outgoingDescriptor) } }
		var outgoingInitial = stat()
		guard fstat(outgoingDescriptor, &outgoingInitial) == 0 else { _ = send("V1 REFUSED \(EIO)"); return 0 }
		func outgoingBound() -> Bool {
			var held = stat(); var named = stat()
			return fstat(outgoingDescriptor, &held) == 0 && lstat(request.outgoingWorker, &named) == 0
				&& (held.st_mode & S_IFMT) == S_IFREG && (named.st_mode & S_IFMT) == S_IFREG
				&& (held.st_uid == geteuid() || held.st_uid == 0) && (held.st_mode & 0o6022) == 0 && (held.st_mode & 0o111) != 0
				&& held.st_size > 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
				&& held.st_dev == outgoingInitial.st_dev && held.st_ino == outgoingInitial.st_ino
				&& held.st_size == outgoingInitial.st_size
				&& held.st_mtimespec.tv_sec == outgoingInitial.st_mtimespec.tv_sec
				&& held.st_mtimespec.tv_nsec == outgoingInitial.st_mtimespec.tv_nsec
				&& held.st_ctimespec.tv_sec == outgoingInitial.st_ctimespec.tv_sec
				&& held.st_ctimespec.tv_nsec == outgoingInitial.st_ctimespec.tv_nsec
				&& request.environment["ERGOPTI_LAUNCHER_DEVICE"] == String(UInt64(UInt32(bitPattern: held.st_dev)))
				&& request.environment["ERGOPTI_LAUNCHER_INODE"] == String(UInt64(held.st_ino))
		}
		func outgoingAdmitted() -> Bool {
			guard admissionRemaining(), outgoingBound(), lseek(outgoingDescriptor, 0, SEEK_SET) == 0 else { return false }
			var remaining = outgoingInitial.st_size
			var hash = SHA256(); var bytes = [UInt8](repeating: 0, count: 4096)
			while remaining > 0 {
				guard admissionRemaining() else { return false }
				let count = Darwin.read(outgoingDescriptor, &bytes, Int(min(remaining, off_t(bytes.count))))
				if count < 0 && errno == EINTR { continue }
				guard count > 0 else { return false }
				hash.update(data: Data(bytes.prefix(count))); remaining -= off_t(count)
			}
			var tail: UInt8 = 0
			guard Darwin.read(outgoingDescriptor, &tail, 1) == 0, outgoingBound() else { return false }
			let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
			if let expected = request.outgoingSHA256, digest != expected { return false }
			var code: SecStaticCode?
			guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: request.outgoingWorker) as CFURL, [], &code) == errSecSuccess,
				let code,
				SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures).union(.noNetworkAccess), nil) == errSecSuccess,
				outgoingBound(), admissionRemaining() else { return false }
			return true
		}
		guard outgoingAdmitted() else { _ = send("V1 REFUSED \(ESTALE)"); return 0 }
		let sessionURL = URL(fileURLWithPath: request.sessionPath)
		let sessionDirectoryPath = sessionURL.deletingLastPathComponent().path
		let sessionName = sessionURL.lastPathComponent
		var alias = Darwin.open(request.executable, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		var sessionDirectory = Darwin.open(sessionDirectoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		var session = sessionDirectory >= 0
			? openat(sessionDirectory, sessionName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) : -1
		guard alias >= 0, sessionDirectory >= 0, session >= 0 else {
			if alias >= 0 { Darwin.close(alias) }; if session >= 0 { Darwin.close(session) }
			if sessionDirectory >= 0 { Darwin.close(sessionDirectory) }
			_ = send("V1 REFUSED \(EIO)"); return 0
		}
		defer {
			if alias >= 0 { Darwin.close(alias) }; if session >= 0 { Darwin.close(session) }
			if sessionDirectory >= 0 { Darwin.close(sessionDirectory) }
		}
		var initialSession = stat(); var initialDirectory = stat()
		func sessionAdmitted(empty: Bool) -> Bool {
			var held = stat(); var named = stat(); var heldDirectory = stat(); var namedDirectory = stat()
			return fstat(sessionDirectory, &heldDirectory) == 0 && lstat(sessionDirectoryPath, &namedDirectory) == 0
				&& (heldDirectory.st_mode & S_IFMT) == S_IFDIR && heldDirectory.st_uid == geteuid()
				&& (heldDirectory.st_mode & 0o7777) == 0o700
				&& heldDirectory.st_dev == initialDirectory.st_dev && heldDirectory.st_ino == initialDirectory.st_ino
				&& heldDirectory.st_dev == namedDirectory.st_dev && heldDirectory.st_ino == namedDirectory.st_ino
				&& fstat(session, &held) == 0 && fstatat(sessionDirectory, sessionName, &named, AT_SYMLINK_NOFOLLOW) == 0
				&& (held.st_mode & S_IFMT) == S_IFREG && held.st_uid == geteuid() && held.st_nlink == 1
				&& (held.st_mode & 0o7777) == 0o600 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
				&& held.st_dev == initialSession.st_dev && held.st_ino == initialSession.st_ino
				&& (empty ? held.st_size == 0 : held.st_size > 0 && held.st_size <= 4096)
		}
		guard fstat(sessionDirectory, &initialDirectory) == 0, fstat(session, &initialSession) == 0, sessionAdmitted(empty: true) else {
			_ = send("V1 REFUSED \(ESTALE)"); return 0
		}
		// The caller owns this exclusive empty file before image admission. Only
		// its public pathname and vnode identity enter the suspended environment.
		var bootstrapDescriptor: Int32 = -1
		var initialBootstrap = stat()
		if let bootstrap = request.bootstrap {
			bootstrapDescriptor = openat(sessionDirectory, URL(fileURLWithPath: bootstrap.path).lastPathComponent,
				O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
			guard bootstrapDescriptor >= 0, fstat(bootstrapDescriptor, &initialBootstrap) == 0 else {
				if bootstrapDescriptor >= 0 { Darwin.close(bootstrapDescriptor) }
				_ = send("V1 REFUSED \(EIO)"); return 0
			}
		}
		defer { if bootstrapDescriptor >= 0 { Darwin.close(bootstrapDescriptor) } }
		func bootstrapAdmitted(empty: Bool) -> Bool {
			guard let bootstrap = request.bootstrap else { return true }
			var held = stat(); var named = stat()
			return bootstrap.cwd == FileManager.default.currentDirectoryPath
				&& fstat(bootstrapDescriptor, &held) == 0
				&& fstatat(sessionDirectory, URL(fileURLWithPath: bootstrap.path).lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0
				&& (held.st_mode & S_IFMT) == S_IFREG && (named.st_mode & S_IFMT) == S_IFREG
				&& held.st_uid == geteuid() && held.st_nlink == 1 && (held.st_mode & 0o7777) == 0o600
				&& UInt64(UInt32(bitPattern: held.st_dev)) == bootstrap.device && UInt64(held.st_ino) == bootstrap.inode
				&& held.st_dev == initialBootstrap.st_dev && held.st_ino == initialBootstrap.st_ino
				&& held.st_dev == named.st_dev && held.st_ino == named.st_ino
				&& (empty ? held.st_size == 0 : held.st_size > 0 && held.st_size <= ManagedBootstrapPolicy.maximumMetadataBytes)
		}
		guard bootstrapAdmitted(empty: true) else { _ = send("V1 REFUSED \(ESTALE)"); return 0 }
		guard let argv = duplicateCStringVector([request.executable] + request.arguments) else {
			_ = send("V1 REFUSED \(ENOMEM)"); return 0
		}
		defer { for case let pointer? in argv { free(pointer) } }
		guard let envp = duplicateCStringVector(request.environment.keys.sorted().map { $0 + "=" + request.environment[$0]! }) else {
			_ = send("V1 REFUSED \(ENOMEM)"); return 0
		}
		defer { for case let pointer? in envp { free(pointer) } }
		var mutableArgv = argv; var mutableEnvp = envp; var owner: OpaquePointer?
		let prepareError = mutableArgv.withUnsafeMutableBufferPointer { args in
			mutableEnvp.withUnsafeMutableBufferPointer { env in
				ergopti_owned_program_prepare(request.executable, args.baseAddress, env.baseAddress, &owner)
			}
		}
		guard owner != nil else { _ = send("V1 REFUSED \(prepareError == 0 ? EPROTO : prepareError)"); return 0 }
		func remaining() -> UInt32? {
			guard let now = monotonic(), now >= admissionStarted else { return nil }
			let duration = now - admissionStarted
			guard duration < UInt64(request.remainingMilliseconds) * 1_000_000 else { return nil }
			let elapsed = (duration + 999_999) / 1_000_000
			guard elapsed < UInt64(request.remainingMilliseconds) else { return nil }
			return request.remainingMilliseconds - UInt32(elapsed)
		}
		func imageAdmitted() -> ergopti_listener_identity? {
			guard let remaining = remaining() else { return nil }
			var identity = ergopti_listener_identity()
			guard ergopti_owned_suspended_image_validate(owner, request.executable, alias, request.device,
				request.inode, remaining, &identity) == 0 else { return nil }
			return identity
		}
		var ready = false; var active = false; var pendingSent = false
		if prepareError == 0, sessionAdmitted(empty: true), bootstrapAdmitted(empty: true), let identity = imageAdmitted() {
			ready = send("V1 IMAGE_READY \(identity.pid) \(identity.uid) \(identity.start_seconds) \(identity.start_microseconds) \(identity.device) \(identity.inode)")
			if !ready { cancelled = true }
		} else { cancelled = true }
		while let retained = owner {
			for line in readLines() {
				if line == Data("CANCEL".utf8) { cancelled = true; continue }
				if line == Data("ACTIVATE".utf8), ready, !active, !cancelled,
					sessionAdmitted(empty: false), bootstrapAdmitted(empty: false), outgoingAdmitted(), imageAdmitted() != nil {
					let receipt = ergopti_owned_program_activate(retained)
					active = receipt.active && !receipt.cancelled && receipt.error_code == 0
					if !active || !send("V1 ACTIVE") { cancelled = true }
				} else { cancelled = true }
			}
			if !active && remaining() == nil { cancelled = true }
			if cancelled { _ = ergopti_owned_program_cancel(retained) }
			let receipt = ergopti_owned_program_poll(retained)
			if receipt.retired && receipt.leader_exited && receipt.status_valid && receipt.error_code == 0 {
				if ergopti_owned_program_destroy(&owner) {
					var bootstrapClose: Int32 = 0
					if bootstrapDescriptor >= 0 {
						bootstrapClose = Darwin.close(bootstrapDescriptor) == 0 ? 0 : (errno == 0 ? EIO : errno)
						bootstrapDescriptor = -1
						_ = send("V1 BOOTSTRAP_CLOSED \(bootstrapClose)")
					}
					let outgoingClose = Darwin.close(outgoingDescriptor) == 0 ? 0 : (errno == 0 ? EIO : errno)
					outgoingDescriptor = -1
					_ = send("V1 OUTGOING_CLOSED \(outgoingClose)")
					let aliasClose = Darwin.close(alias) == 0 ? 0 : (errno == 0 ? EIO : errno)
					alias = -1
					let sessionClose = Darwin.close(session) == 0 ? 0 : (errno == 0 ? EIO : errno)
					session = -1
					let directoryClose = Darwin.close(sessionDirectory) == 0 ? 0 : (errno == 0 ? EIO : errno)
					sessionDirectory = -1
					// Original native monitor destruction has no checked close result.
					// handles_closed=0 remains incomplete until the receiver proves exact
					// guardian reap plus EOF and closure of every retained control pipe.
					_ = send("V1 RETIRED \(receipt.exit_status) 1 1 0 \(aliasClose) \(sessionClose) \(directoryClose)")
					return outputOpen && bootstrapClose == 0 && outgoingClose == 0 && aliasClose == 0 && sessionClose == 0 && directoryClose == 0 ? 0 : 74
				}
				// A refused destruction keeps the owner and native cleanup capability.
				cancelled = true
			} else if receipt.retired { cancelled = true }
			if receipt.error_code != 0 { cancelled = true }
			if cancelled && !pendingSent { pendingSent = true; _ = send("V1 PENDING \(receipt.error_code)") }
			wait()
		}
		return 70
	}
}

// Sources/ErgoptiPlus/SuspendedImageProxyRelay.swift
// The managed daemon's sibling sign-in relay, owned by the suspended image guardian.

import CoreFoundation
import Darwin
import Foundation
import Security

/// The relay fields of a suspended image request: the proxy the Python owner
/// probed (it answered "required") and the deadlines it read from the timing
/// registry. No credential is carried: the relay signs in with the user's
/// Kerberos ticket (docs/design/proxy-auth-relay.md).
struct ManagedProxyRelayRequest {
	let upstream: String
	let dialMilliseconds: UInt32
	let handshakeMilliseconds: UInt32
	let idleMilliseconds: UInt32
	/// The Kerberos variables listen reads (KRB5CCNAME, KRB5_CONFIG): the
	/// guardian runs with PATH alone, so a ticket cache named by the user's
	/// environment reaches the relay only through the request.
	let environment: [String: String]

	static let requiredKeys: Set<String> = ["relay_upstream", "relay_dial_ms", "relay_handshake_ms", "relay_idle_ms"]
	/// Every relay field; relay_environment is present only when one variable is set.
	static let keys: Set<String> = requiredKeys.union(["relay_environment"])
	/// proxy_auth_relay.json "sign_in_environment" and "max_sign_in_value_bytes"
	/// (testSignInEnvironmentMirrorsTheRelayContract pins both).
	static let signInEnvironment: Set<String> = ["KRB5CCNAME", "KRB5_CONFIG"]
	static let maximumSignInValueBytes = 4096
	/// The relay's own deadlines stay below ten minutes; a larger value is a caller fault.
	static let maximumMilliseconds: UInt64 = 600_000

	/// Parses the relay fields: the four required ones all present or all absent.
	/// - Parameter fields: The decoded request object.
	/// - Returns: nil when no field is present, .some(nil) for a refused set.
	static func parse(_ fields: [String: Any]) -> ManagedProxyRelayRequest?? {
		let present = Set(fields.keys).intersection(keys)
		if present.isEmpty { return .some(nil) }
		guard present.intersection(requiredKeys) == requiredKeys, let upstream = fields["relay_upstream"] as? String, validUpstream(upstream),
			let dial = milliseconds(fields["relay_dial_ms"]),
			let handshake = milliseconds(fields["relay_handshake_ms"]),
			let idle = milliseconds(fields["relay_idle_ms"]),
			let environment = signIn(fields["relay_environment"]) else { return nil }
		return .some(ManagedProxyRelayRequest(upstream: upstream, dialMilliseconds: dial,
			handshakeMilliseconds: handshake, idleMilliseconds: idle, environment: environment))
	}

	/// The sign-in variables: only the contract's names, each a non-empty bounded
	/// line. An absent field is no variable; an empty object is a caller fault.
	private static func signIn(_ value: Any?) -> [String: String]? {
		guard let value else { return [:] }
		guard let object = value as? [String: Any], !object.isEmpty else { return nil }
		var result: [String: String] = [:]
		for (name, raw) in object {
			guard signInEnvironment.contains(name), let text = raw as? String, !text.isEmpty,
				text.utf8.count <= maximumSignInValueBytes,
				!text.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else { return nil }
			result[name] = text
		}
		return result
	}

	private static func milliseconds(_ value: Any?) -> UInt32? {
		guard let number = integer(value), number > 0, UInt64(number) <= maximumMilliseconds else { return nil }
		return UInt32(number)
	}

	/// A JSON integer: never a boolean, a fraction or a rounded value.
	static func integer(_ value: Any?) -> Int64? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			!String(cString: number.objCType).contains("f"), !String(cString: number.objCType).contains("d"),
			NSNumber(value: number.int64Value).compare(number) == .orderedSame else { return nil }
		return number.int64Value
	}

	/// The plain http proxy without credentials the Python owner probes, the
	/// same shape network-retry.sh admits: `http://HOST:PORT` with an optional slash.
	static func validUpstream(_ value: String) -> Bool {
		guard value.utf8.count <= 512, value.hasPrefix("http://") else { return false }
		var rest = Substring(value.dropFirst("http://".count))
		if rest.hasSuffix("/") { rest = rest.dropLast() }
		guard let colon = rest.lastIndex(of: ":") else { return false }
		let host = rest[..<colon], port = rest[rest.index(after: colon)...]
		guard !host.isEmpty, host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
			|| (97...122).contains($0) || $0 == 46 || $0 == 45 }),
			(1...5).contains(port.utf8.count), port.utf8.allSatisfy({ (48...57).contains($0) }),
			let number = UInt32(port), number > 0, number <= 65_535 else { return false }
		return true
	}
}

/// The sibling relay the guardian starts before it resumes the daemon and ends
/// after the daemon retires (docs/design/proxy-auth-relay.md, "macOS managed
/// daemon"). The relay serves until its stdin reaches EOF, so closing that pipe
/// stops it, and a guardian killed outright closes it too. Its token reaches the
/// Python owner on the guardian's private stdout only, never a log.
final class SuspendedImageProxyRelay {
	static let executableName = "ergopti-proxy-relay"

	enum Outcome: Equatable {
		case route(port: UInt16, token: String)
		case refused(String)
	}

	private var pid: pid_t = 0
	private var input: Int32 = -1
	private var output: Int32 = -1
	private var reaped = false
	private var exitStatus: Int32 = -1

	/// The relay ships beside the admitted launcher, as in network-retry.sh.
	static func path(beside launcher: String) -> String {
		URL(fileURLWithPath: launcher).deletingLastPathComponent().appendingPathComponent(executableName).path
	}

	/// The bundle admission the launcher has: a regular, signed, non-writable image.
	static func admitted(_ path: String) -> Bool {
		var named = stat()
		guard lstat(path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG,
			named.st_uid == geteuid() || named.st_uid == 0, (named.st_mode & 0o6022) == 0,
			(named.st_mode & 0o111) != 0, named.st_size > 0 else { return false }
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
			let code,
			SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures).union(.noNetworkAccess), nil) == errSecSuccess
		else { return false }
		var after = stat()
		return lstat(path, &after) == 0 && after.st_dev == named.st_dev && after.st_ino == named.st_ino
	}

	/// Parses the relay's one line; anything else is relay_unavailable.
	static func parseLine(_ data: Data) -> Outcome? {
		guard data.count <= 256, let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(fields.keys) == ["schema", "port", "token"],
			ManagedProxyRelayRequest.integer(fields["schema"]) == 1,
			let port = ManagedProxyRelayRequest.integer(fields["port"]), port > 0, port <= 65_535,
			let token = fields["token"] as? String, token.utf8.count == 64,
			token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
		return .route(port: UInt16(port), token: token)
	}

	/// Starts `listen` and reads its line before the admission deadline.
	/// - Parameters:
	///   - path: The relay beside the admitted launcher.
	///   - request: The probed proxy and the relay deadlines.
	///   - home: The user's home, for the Kerberos ticket lookup.
	///   - errorDescriptor: The daemon log capture's stderr writer, or -1 for none.
	///   - remaining: Whether the guardian's admission deadline still holds.
	///   - pause: One bounded guardian wait (it drains the log capture).
	/// - Returns: The route, or the closed refusal the Python owner records.
	func start(path: String, request: ManagedProxyRelayRequest, home: String, errorDescriptor: Int32,
		remaining: () -> Bool, pause: () -> Void) -> Outcome {
		guard pid == 0, Self.admitted(path) else { return .refused("relay_unavailable") }
		var stdinPipe = [Int32](repeating: -1, count: 2), stdoutPipe = [Int32](repeating: -1, count: 2)
		guard stdinPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else { return .refused("relay_unavailable") }
		guard stdoutPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
			Darwin.close(stdinPipe[0]); Darwin.close(stdinPipe[1]); return .refused("relay_unavailable")
		}
		input = stdinPipe[1]; output = stdoutPipe[0]
		let nullDescriptor = errorDescriptor >= 0 ? -1 : Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
		// The child's ends close as soon as it holds its own copies, so a relay
		// that exits leaves EOF on its stdout instead of a pipe held open here.
		var childEndsOpen = true
		func closeChildEnds() {
			guard childEndsOpen else { return }
			childEndsOpen = false
			Darwin.close(stdinPipe[0]); Darwin.close(stdoutPipe[1])
			if nullDescriptor >= 0 { Darwin.close(nullDescriptor) }
		}
		defer { closeChildEnds() }
		for descriptor in [input, output] {
			let flags = fcntl(descriptor, F_GETFD)
			guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else { return .refused("relay_unavailable") }
		}
		let readFlags = fcntl(output, F_GETFL)
		guard readFlags >= 0, fcntl(output, F_SETFL, readFlags | O_NONBLOCK) == 0,
			fcntl(input, F_SETNOSIGPIPE, 1) == 0 else { return .refused("relay_unavailable") }
		let stderrDescriptor = errorDescriptor >= 0 ? errorDescriptor : nullDescriptor
		guard stderrDescriptor >= 0 else { return .refused("relay_unavailable") }
		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else { return .refused("relay_unavailable") }
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, stderrDescriptor, STDERR_FILENO) == 0 else { return .refused("relay_unavailable") }
		var attributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&attributes) == 0 else { return .refused("relay_unavailable") }
		defer { posix_spawnattr_destroy(&attributes) }
		// The guardian ignores these; an ignored disposition would survive exec.
		var defaults = sigset_t(); sigemptyset(&defaults)
		for kind in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, kind) }
		var mask = sigset_t(); sigemptyset(&mask)
		guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0, posix_spawnattr_setsigmask(&attributes, &mask) == 0,
			posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
		else { return .refused("relay_unavailable") }
		let arguments = [path, "listen", "--upstream", request.upstream,
			"--dial-timeout-ms", String(request.dialMilliseconds),
			"--handshake-timeout-ms", String(request.handshakeMilliseconds),
			"--idle-timeout-ms", String(request.idleMilliseconds)]
		guard let argv = duplicateCStringVector(arguments),
			let envp = duplicateCStringVector(["HOME=" + home, "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
				+ request.environment.keys.sorted().map { $0 + "=" + request.environment[$0]! }) else {
			return .refused("relay_unavailable")
		}
		defer { for case let pointer? in argv { free(pointer) }; for case let pointer? in envp { free(pointer) } }
		var mutableArgv = argv, mutableEnvp = envp, child: pid_t = 0
		let spawned = mutableArgv.withUnsafeMutableBufferPointer { args in
			mutableEnvp.withUnsafeMutableBufferPointer { env in
				posix_spawn(&child, path, &actions, &attributes, args.baseAddress, env.baseAddress)
			}
		}
		closeChildEnds()
		guard spawned == 0, child > 0 else { return .refused("relay_unavailable") }
		pid = child
		var line = Data()
		while remaining() {
			var bytes = [UInt8](repeating: 0, count: 256)
			let count = Darwin.read(output, &bytes, bytes.count)
			if count > 0 {
				line.append(contentsOf: bytes.prefix(count))
				if let newline = line.firstIndex(of: 10) {
					guard newline == line.count - 1, let outcome = Self.parseLine(line.prefix(upTo: newline)) else { break }
					return outcome
				}
				if line.count > 256 { break }
				continue
			}
			if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { break }
			if reap(blocking: false) { break }
			pause()
		}
		// No line, a foreign line, a closed pipe or an exited relay: the
		// relay is stopped here and its exit status names the refusal.
		_ = stop(pause: pause)
		let reason = exitStatus == 3 ? "relay_listen_failed" : "relay_unavailable"
		// The refused relay is gone; the retirement stop has nothing left to end.
		pid = 0
		return .refused(reason)
	}

	/// Reaps the relay once it has exited.
	/// - Parameter blocking: Whether to wait for the exit.
	/// - Returns: Whether the relay is reaped.
	private func reap(blocking: Bool) -> Bool {
		guard pid > 0, !reaped else { return reaped }
		var status: Int32 = 0
		var waited: pid_t
		repeat { waited = waitpid(pid, &status, blocking ? 0 : WNOHANG) } while waited < 0 && errno == EINTR
		guard waited == pid else { return false }
		reaped = true
		exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
		return true
	}

	/// Ends the relay: EOF on its stdin, then a kill after the registry grace.
	/// - Parameter pause: One bounded guardian wait (it drains the log capture).
	/// - Returns: 0 when the relay exited by itself with status 0 and every
	///   pipe closed, else an errno (the guardian's RELAY_CLOSED value).
	func stop(pause: () -> Void) -> Int32 {
		var result: Int32 = 0
		if input >= 0 {
			if Darwin.close(input) != 0 { result = errno == 0 ? EIO : errno }
			input = -1
		}
		if pid > 0 && !reaped {
			let deadline = ProcessInfo.processInfo.systemUptime + LauncherTimings.proxyRelayStopGrace.seconds
			while !reap(blocking: false) && ProcessInfo.processInfo.systemUptime < deadline { pause() }
			if !reaped {
				_ = Darwin.kill(pid, SIGKILL)
				_ = reap(blocking: true)
				if result == 0 { result = ETIMEDOUT }
			}
		}
		if output >= 0 {
			if Darwin.close(output) != 0 && result == 0 { result = errno == 0 ? EIO : errno }
			output = -1
		}
		if pid > 0 && (!reaped || exitStatus != 0) && result == 0 { result = EIO }
		return result
	}
}

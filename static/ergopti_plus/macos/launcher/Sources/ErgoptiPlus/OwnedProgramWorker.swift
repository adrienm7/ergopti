// Sources/ErgoptiPlus/OwnedProgramWorker.swift
// Signed headless transport and native ownership of a private user-program group.

import CPOSIXCompatibility
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

private let ownedProgramBridgeFlag = "--owned-program-worker"
private let ownedProgramGuardianFlag = "--owned-program-guardian"
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
let ownedProgramFixtureFlag = "--owned-program-fixture"
#endif
private let ownedProgramControlDescriptor: Int32 = 3
private let ownedProgramPollMilliseconds: Int32 = 20

/// Literal launch request. Private bytes are never formatted in diagnostics.
struct OwnedProgramRequest {
	let executable: String
	let arguments: [String]
	let sourcePath: String
	let sourceSHA256: String

	static func parse(_ data: Data) -> OwnedProgramRequest? {
		guard let object = try? JSONSerialization.jsonObject(with: data),
			let fields = object as? [String: Any],
			Set(fields.keys) == Set(["version", "executable", "arguments", "source_path", "source_sha256"]),
			let version = fields["version"] as? NSNumber,
			CFGetTypeID(version) != CFBooleanGetTypeID(), version.int64Value == 1, version.doubleValue == 1,
			let executable = fields["executable"] as? String,
			let arguments = fields["arguments"] as? [String],
			let sourcePath = fields["source_path"] as? String,
			let sourceSHA256 = fields["source_sha256"] as? String,
			executable.hasPrefix("/"), sourcePath.hasPrefix("/"),
			!executable.utf8.contains(0), !sourcePath.utf8.contains(0),
			arguments.allSatisfy({ !$0.utf8.contains(0) }),
			sourceSHA256.utf8.count == 64,
			sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
		else { return nil }
		return OwnedProgramRequest(
			executable: executable, arguments: arguments,
			sourcePath: sourcePath, sourceSHA256: sourceSHA256
		)
	}
}

/// Bounded newline decoder. JSON escapes literal argv newlines before transport.
struct OwnedProgramLineDecoder {
	private(set) var buffered = Data()
	let maximumBytes: Int

	mutating func append(_ data: Data) -> Bool {
		guard data.count <= maximumBytes - buffered.count else { return false }
		buffered.append(data)
		return true
	}

	mutating func pop() -> Data? {
		guard let newline = buffered.firstIndex(of: 10) else { return nil }
		let line = Data(buffered[..<newline])
		buffered.removeSubrange(...newline)
		return line
	}
}

private enum OwnedProgramRead {
	case bytes(Data)
	case pending
	case eof
	case failed
}

private func ownedProgramRead(_ descriptor: Int32) -> OwnedProgramRead {
	var bytes = [UInt8](repeating: 0, count: 4096)
	let count = Darwin.read(descriptor, &bytes, bytes.count)
	if count > 0 { return .bytes(Data(bytes.prefix(count))) }
	if count == 0 { return .eof }
	if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .pending }
	return .failed
}

private func ownedProgramWrite(_ data: Data, to descriptor: Int32) -> Bool {
	var offset = 0
	while offset < data.count {
		let count = data.withUnsafeBytes { bytes in
			Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
		}
		if count > 0 { offset += count; continue }
		if count < 0 && errno == EINTR { continue }
		return false
	}
	return true
}

private func ownedProgramSetNonblocking(_ descriptor: Int32) -> Bool {
	let flags = fcntl(descriptor, F_GETFL)
	return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}

private func ownedProgramWaitReadable(_ descriptor: Int32) {
	var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
	_ = Darwin.poll(&event, 1, ownedProgramPollMilliseconds)
}

/// A raw-byte source fence, including a UTF-8 BOM. No unbounded file buffer.
private func ownedProgramSourceAdmitted(
	_ request: OwnedProgramRequest,
	interrupted: () -> Bool
) -> Bool {
	// Personal config paths support symlinks. Read through the observed target,
	// then fence that exact target against the final pathname resolution.
	// O_NONBLOCK prevents a replaced/retargeted FIFO from trapping cancellation
	// before the regular-file check. Regular source files retain ordinary reads.
	let descriptor = Darwin.open(request.sourcePath, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
	guard descriptor >= 0 else { return false }
	defer { Darwin.close(descriptor) }
	var initial = stat()
	guard fstat(descriptor, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG,
		initial.st_size >= 0 else { return false }
	var remaining = initial.st_size
	var hash = SHA256()
	var bytes = [UInt8](repeating: 0, count: 4096)
	while remaining > 0 {
		if interrupted() { return false }
		let maximum = Int(min(remaining, off_t(bytes.count)))
		let count = Darwin.read(descriptor, &bytes, maximum)
		if count < 0 && errno == EINTR { continue }
		guard count > 0 else { return false }
		hash.update(data: Data(bytes.prefix(count)))
		remaining -= off_t(count)
	}
	var tail: UInt8 = 0
	guard Darwin.read(descriptor, &tail, 1) == 0, !interrupted() else { return false }
	var final = stat()
	var pathname = stat()
	guard fstat(descriptor, &final) == 0, stat(request.sourcePath, &pathname) == 0,
		initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
		initial.st_size == final.st_size,
		initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
		initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
		initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
		initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
		pathname.st_dev == final.st_dev, pathname.st_ino == final.st_ino
	else { return false }
	let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
	return digest == request.sourceSHA256
}

private final class OwnedProgramGuardian {
	private let control: Int32
	private var decoder: OwnedProgramLineDecoder
	private var request: OwnedProgramRequest?
	private var owner: OpaquePointer?
	private var cancelled = false
	private var inputClosed = false
	private var disconnected = false
	private var held = false
	private var activationReceived = false
	private var pendingSent = false
	private var constructorRefused = false

	init(control: Int32, maximumRequestBytes: Int) {
		self.control = control
		decoder = OwnedProgramLineDecoder(maximumBytes: maximumRequestBytes)
	}

	private func send(_ line: String) {
		guard !disconnected else { return }
		if !ownedProgramWrite(Data(line.utf8), to: control) {
			disconnected = true
			inputClosed = true
			cancelled = true
		}
	}

	private func cancel() {
		cancelled = true
		if let owner { _ = ergopti_owned_program_cancel(owner) }
	}

	private func refuseBeforeChild(_ error: Int32) {
		guard owner == nil, !constructorRefused else { cancel(); return }
		constructorRefused = true
		send("V1 REFUSED \(error)\n")
		inputClosed = true
		cancelled = true
	}

	private func consumeControl() {
		if inputClosed { return }
		switch ownedProgramRead(control) {
		case .bytes(let bytes):
			guard decoder.append(bytes) else {
				if owner == nil { refuseBeforeChild(EMSGSIZE) } else { cancel(); inputClosed = true }
				return
			}
			while let line = decoder.pop() {
				if request == nil {
					guard let parsed = OwnedProgramRequest.parse(line) else {
						refuseBeforeChild(EINVAL); return
					}
					request = parsed
					continue
				}
				if line == Data("CANCEL".utf8) { cancel(); continue }
				if line == Data("ACTIVATE".utf8), held, !activationReceived, !cancelled {
					activationReceived = true
					continue
				}
				cancel()
			}
		case .eof, .failed:
			// A closed incoming half orders cancellation, but the outgoing half
			// still delivers physical retirement to the observing bridge.
			inputClosed = true
			if owner == nil { refuseBeforeChild(ECANCELED) } else { cancel() }
		case .pending: break
		}
	}

	func run() -> Int32 {
		guard setsid() == getpid(), ownedProgramSetNonblocking(control) else {
			refuseBeforeChild(errno == 0 ? EIO : errno); return 0
		}
		prepareLeaseChildReaping()
		while request == nil && !cancelled {
			consumeControl()
			if request == nil { ownedProgramWaitReadable(control) }
		}
		guard let request, !cancelled else {
			if !constructorRefused { refuseBeforeChild(ECANCELED) }
			return 0
		}
		guard let arguments = duplicateCStringVector([request.executable] + request.arguments) else {
			send("V1 REFUSED \(ENOMEM)\n"); return 0
		}
		defer { for case let pointer? in arguments { free(pointer) } }
		guard let environment = duplicateProcessEnvironment() else {
			send("V1 REFUSED \(ENOMEM)\n"); return 0
		}
		defer {
			for case let pointer? in environment { free(pointer) }
		}
		var mutableArguments = arguments
		var mutableEnvironment = environment
		let prepareError = mutableArguments.withUnsafeMutableBufferPointer { argv in
			mutableEnvironment.withUnsafeMutableBufferPointer { envp in
				ergopti_owned_program_prepare(request.executable, argv.baseAddress, envp.baseAddress, &owner)
			}
		}
		guard owner != nil else { send("V1 REFUSED \(prepareError == 0 ? EPROTO : prepareError)\n"); return 0 }
		if prepareError == 0 {
			held = true
			send("V1 HELD\n")
		} else { cancel() }
		while let owner {
			consumeControl()
			if activationReceived && held && !cancelled {
				held = false
				let admitted = ownedProgramSourceAdmitted(request) {
					self.consumeControl()
					return self.cancelled
				}
				if admitted && !cancelled {
					let receipt = ergopti_owned_program_activate(owner)
					if receipt.active && !receipt.cancelled { send("V1 ACTIVE\n") }
					else { cancel() }
				} else { cancel() }
			}
			if cancelled { _ = ergopti_owned_program_cancel(owner) }
			let receipt = ergopti_owned_program_poll(owner)
			if receipt.retired {
				guard receipt.status_valid, receipt.error_code == 0,
					ergopti_owned_program_destroy(&self.owner) else { return 70 }
				send("V1 RETIRED \(receipt.exit_status)\n")
				return 0
			}
			if (cancelled || receipt.error_code != 0) && !pendingSent {
				pendingSent = true
				send("V1 PENDING \(receipt.error_code)\n")
			}
			ownedProgramWaitReadable(inputClosed ? -1 : control)
		}
		return 70
	}
}

/// Signed bridge preserves native guardian ownership through every receipt.
enum OwnedProgramWorker {
	static func handles(arguments: [String]) -> Bool {
		guard arguments.count > 1 else { return false }
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if arguments[1] == ownedProgramFixtureFlag { return true }
		#endif
		return [ownedProgramBridgeFlag, ownedProgramGuardianFlag].contains(arguments[1])
	}

	static func run(arguments: [String]) -> Int32 {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if arguments.count > 1 && arguments[1] == ownedProgramFixtureFlag {
			return OwnedProgramNativeFixture.run(arguments: arguments)
		}
		#endif
		guard arguments.count == 2 else { return 64 }
		// Only fixed control bytes reach hs.task. Broken pipes trigger cleanup.
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		let argumentLimit = sysconf(_SC_ARG_MAX)
		guard argumentLimit > 0, argumentLimit <= (Int.max - Int(PATH_MAX) * 6 - 512) / 6 else {
			let descriptor = arguments[1] == ownedProgramGuardianFlag ? ownedProgramControlDescriptor : STDOUT_FILENO
			return ownedProgramWrite(Data("V1 REFUSED \(EOVERFLOW)\n".utf8), to: descriptor) ? 0 : 74
		}
		// JSON UTF-8 escaping can expand literal argument bytes. Spawn still applies
		// the real platform ARG_MAX constraint after decoding the bounded request.
		let maximumRequestBytes = Int(argumentLimit) * 6 + Int(PATH_MAX) * 6 + 512
		if arguments[1] == ownedProgramGuardianFlag {
			return OwnedProgramGuardian(
				control: ownedProgramControlDescriptor, maximumRequestBytes: maximumRequestBytes
			).run()
		}
		return runBridge(executable: arguments[0], maximumRequestBytes: maximumRequestBytes)
	}

	private static func refuseBridgeBeforeGuardian(_ error: Int32) -> Int32 {
		let line = Data("V1 REFUSED \(error)\n".utf8)
		return ownedProgramWrite(line, to: STDOUT_FILENO) ? 0 : 74
	}

	private static func runBridge(executable: String, maximumRequestBytes: Int) -> Int32 {
		prepareLeaseChildReaping()
		guard let expectedExecutable = LeaseExecutableIdentity.capture(at: executable) else {
			return refuseBridgeBeforeGuardian(ESTALE)
		}
		guard let sockets = makeReservedLeaseSocketEndpoints() else { return refuseBridgeBeforeGuardian(errno == 0 ? EIO : errno) }
		let control = sockets.outerDescriptor
		let inner = sockets.innerDescriptor
		defer { Darwin.close(control) }
		var actions: posix_spawn_file_actions_t?
		let actionsError = posix_spawn_file_actions_init(&actions)
		guard actionsError == 0 else { Darwin.close(inner); return refuseBridgeBeforeGuardian(actionsError) }
		defer { posix_spawn_file_actions_destroy(&actions) }
		var attributes: posix_spawnattr_t?
		let attributesError = posix_spawnattr_init(&attributes)
		guard attributesError == 0 else { Darwin.close(inner); return refuseBridgeBeforeGuardian(attributesError) }
		defer { posix_spawnattr_destroy(&attributes) }
		let flagsError = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED))
		let controlError = flagsError == 0
			? posix_spawn_file_actions_adddup2(&actions, inner, ownedProgramControlDescriptor) : flagsError
		guard controlError == 0 else { Darwin.close(inner); return refuseBridgeBeforeGuardian(controlError) }
		for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
			let nullError = posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
			guard nullError == 0 else { Darwin.close(inner); return refuseBridgeBeforeGuardian(nullError) }
		}
		guard let argv = duplicateCStringVector([executable, ownedProgramGuardianFlag]) else {
			Darwin.close(inner); return refuseBridgeBeforeGuardian(ENOMEM)
		}
		defer { for case let pointer? in argv { free(pointer) } }
		guard let envp = duplicateProcessEnvironment() else { Darwin.close(inner); return refuseBridgeBeforeGuardian(ENOMEM) }
		defer {
			for case let pointer? in envp { free(pointer) }
		}
		var mutableArguments = argv
		var mutableEnvironment = envp
		var guardian: pid_t = 0
		let error = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				posix_spawn(&guardian, executable, &actions, &attributes, arguments.baseAddress, environment.baseAddress)
			}
		}
		Darwin.close(inner)
		guard error == 0 else { return refuseBridgeBeforeGuardian(error) }
		// No private request is transferred until this exact suspended signed role
		// passes its post-spawn vnode fence. Refusal proves no payload could exist.
		guard LeaseExecutableIdentity.capture(at: executable) == expectedExecutable else {
			return retireHeldGuardian(guardian, refusal: ESTALE)
		}
		guard ownedProgramSetNonblocking(control), ownedProgramSetNonblocking(STDIN_FILENO) else {
			return retireHeldGuardian(guardian, refusal: errno == 0 ? EIO : errno)
		}
		guard Darwin.kill(guardian, SIGCONT) == 0 else {
			return retireHeldGuardian(guardian, refusal: errno)
		}
		var input = OwnedProgramLineDecoder(maximumBytes: maximumRequestBytes)
		var output = OwnedProgramLineDecoder(maximumBytes: 128)
		var requestSent = false
		var inputOpen = true
		var verifiedTerminal = false
		var guardianOpen = true
		var markers: Set<String> = []
		var outbound = Data()
		var outboundOffset = 0
		var closeAfterFlush = false
		while guardianOpen {
			var events = [
				pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
				pollfd(fd: control, events: Int16(POLLIN | (outboundOffset < outbound.count ? POLLOUT : 0)), revents: 0)
			]
			_ = Darwin.poll(&events, nfds_t(events.count), ownedProgramPollMilliseconds)
			if inputOpen {
				switch ownedProgramRead(STDIN_FILENO) {
				case .bytes(let data):
					if !input.append(data) { inputOpen = false; outbound.removeAll(); outboundOffset = 0; _ = shutdown(control, SHUT_WR); break }
					while let line = input.pop() {
						if !requestSent {
							guard OwnedProgramRequest.parse(line) != nil else {
								inputOpen = false; _ = shutdown(control, SHUT_WR); break
							}
							requestSent = true
						} else if line != Data("ACTIVATE".utf8) && line != Data("CANCEL".utf8) {
							inputOpen = false; _ = shutdown(control, SHUT_WR); break
						}
						guard outbound.count - outboundOffset + line.count + 1 <= maximumRequestBytes else {
							inputOpen = false; outbound.removeAll(); outboundOffset = 0; _ = shutdown(control, SHUT_WR); break
						}
						if outboundOffset > 0 { outbound.removeSubrange(..<outboundOffset); outboundOffset = 0 }
						outbound.append(line)
						outbound.append(10)
					}
				case .eof, .failed:
					inputOpen = false
					closeAfterFlush = true
				case .pending: break
				}
			}
			if outboundOffset < outbound.count {
				let count = outbound.withUnsafeBytes { bytes in
					Darwin.write(control, bytes.baseAddress!.advanced(by: outboundOffset), outbound.count - outboundOffset)
				}
				if count > 0 { outboundOffset += count }
				else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
					inputOpen = false; outbound.removeAll(); outboundOffset = 0; _ = shutdown(control, SHUT_WR)
				}
			}
			if outboundOffset == outbound.count {
				outbound.removeAll(keepingCapacity: true); outboundOffset = 0
				if closeAfterFlush { _ = shutdown(control, SHUT_WR); closeAfterFlush = false }
			}
			switch ownedProgramRead(control) {
			case .bytes(let data):
				guard output.append(data) else { _ = shutdown(control, SHUT_WR); return reapGuardian(guardian, verifiedTerminal: false) }
				while let line = output.pop() {
					guard let marker = String(data: line, encoding: .utf8),
						validReceipt(marker), !markers.contains(marker.components(separatedBy: " ").prefix(2).joined(separator: " "))
					else { _ = shutdown(control, SHUT_WR); return reapGuardian(guardian, verifiedTerminal: false) }
					markers.insert(marker.components(separatedBy: " ").prefix(2).joined(separator: " "))
					if marker.hasPrefix("V1 RETIRED ") { verifiedTerminal = true }
					if marker.hasPrefix("V1 REFUSED ") { verifiedTerminal = true }
					if !ownedProgramWrite(line + Data([10]), to: STDOUT_FILENO) { _ = shutdown(control, SHUT_WR); inputOpen = false }
				}
			case .eof: guardianOpen = false
			case .failed: _ = shutdown(control, SHUT_WR); guardianOpen = false
			case .pending: break
			}
		}
		guard output.buffered.isEmpty else { verifiedTerminal = false; return reapGuardian(guardian, verifiedTerminal: false) }
		return reapGuardian(guardian, verifiedTerminal: verifiedTerminal)
	}

	static func validReceipt(_ line: String) -> Bool {
		if line == "V1 HELD" || line == "V1 ACTIVE" { return true }
		let fields = line.split(separator: " ", omittingEmptySubsequences: false)
		guard fields.count == 3, fields[0] == "V1",
			["PENDING", "RETIRED", "REFUSED"].contains(String(fields[1])),
			let code = Int32(fields[2]), code >= 0, String(code) == String(fields[2])
		else { return false }
		return fields[1] != "RETIRED" || code <= 255
	}

	private static func retireHeldGuardian(_ guardian: pid_t, refusal: Int32) -> Int32 {
		var pendingSent = false
		var ownershipLost = false
		while true {
			if !ownershipLost {
				let signalError = Darwin.kill(guardian, SIGKILL) == 0 ? 0 : errno
				var status: Int32 = 0
				let waited = waitpid(guardian, &status, WNOHANG)
				if waited == guardian { return refuseBridgeBeforeGuardian(refusal) }
				let waitError = waited == -1 ? errno : 0
				// No numeric operation is safe once another actor reaped the child.
				// Keep the bridge/debt alive rather than returning a false receipt.
				if waitError == ECHILD { ownershipLost = true }
				let error = waitError != 0 && waitError != EINTR ? waitError : signalError
				if error != 0 && !pendingSent {
					pendingSent = true
					_ = ownedProgramWrite(Data("V1 PENDING \(error)\n".utf8), to: STDOUT_FILENO)
				}
			}
			ownedProgramWaitReadable(-1)
		}
	}

	private static func reapGuardian(_ guardian: pid_t, verifiedTerminal: Bool) -> Int32 {
		var status: Int32 = 0
		var waited: pid_t
		repeat { waited = waitpid(guardian, &status, 0) } while waited == -1 && errno == EINTR
		guard waited == guardian, verifiedTerminal else { return 70 }
		// Raw status zero is the only expected successful guardian termination.
		return status == 0 ? 0 : 70
	}
}

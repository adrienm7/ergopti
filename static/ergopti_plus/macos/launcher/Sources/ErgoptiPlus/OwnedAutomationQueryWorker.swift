// Sources/ErgoptiPlus/OwnedAutomationQueryWorker.swift
// Signed bounded read-only Shortcuts query with exact native group retirement.

import CPOSIXCompatibility
import Carbon
import CoreFoundation
import Darwin
import Foundation
import ScriptingBridge
import Security

private let automationQueryFlag = "--automation-query-worker"
private let automationRoleFlag = "--automation-query-role"
private let automationGuardianFlag = "--automation-query-guardian"
private let automationMaximumBytes = 65536

/// Errors stay private; native permission codes never become successful empty lists.
private final class AutomationQueryErrors: NSObject, SBApplicationDelegate {
	var failure: String?
	func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
		failure = (error as NSError).code == -1743 ? "automation_permission_refused" : "native_refused"
		return nil
	}
}

/// Static roles run only from the shipped signed launcher, never a user script.
enum OwnedAutomationQueryWorker {
	static func handles(arguments: [String]) -> Bool {
		return arguments.count > 1 && [automationQueryFlag, automationRoleFlag, automationGuardianFlag].contains(arguments[1])
	}

	static func validIdentifier(_ value: String) -> Bool {
		return value.utf8.count == 36 && UUID(uuidString: value) != nil
	}

	static func validRequest(arguments: [String]) -> Bool {
		guard arguments.count >= 4, let nonce = Int64(arguments[3]), nonce > 0,
			nonce <= 9007199254740991, String(nonce) == arguments[3] else { return false }
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if ["fixture", "fixture-overflow", "fixture-stderr", "fixture-wait"].contains(arguments[2]) {
			return arguments.count == 4
		}
		#endif
		return arguments[2] == "discover" && arguments.count == 4
			|| arguments[2] == "revalidate" && arguments.count == 5 && validIdentifier(arguments[4])
	}

	private static func write(_ bytes: Data) -> Bool {
		var offset = 0
		while offset < bytes.count {
			let count = bytes.withUnsafeBytes { buffer in
				Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
			}
			if count > 0 { offset += count }
			else if count < 0 && errno == EINTR { continue }
			else { return false }
		}
		return true
	}

	private static func marker(_ value: String) -> Bool { return write(Data((value + "\n").utf8)) }

	private static func nonblocking(_ descriptor: Int32) -> Bool {
		let flags = fcntl(descriptor, F_GETFL)
		return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
	}

	private static func makePipe() -> [Int32]? {
		var descriptors: [Int32] = [-1, -1]
		guard pipe(&descriptors) == 0 else { return nil }
		guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
			nonblocking(descriptors[0]) else {
			for descriptor in descriptors { Darwin.close(descriptor) }
			return nil
		}
		return descriptors
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Debug fixture refusal facts only; raw process identifiers never leave here.
	private static func fixtureSetup() -> (accepted: Bool, error: Int32, facts: [String]) {
		var facts: [String] = []
		func context() -> String {
			let saved = errno
			let pid = getpid(), group = getpgrp(), session = getsid(0)
			errno = saved
			return "\(pid == group ? 1 : 0) \(pid == session ? 1 : 0) \(group == session ? 1 : 0) \(session > 0 ? 1 : 0)"
		}
		func observe(_ phase: String, identityResult: Bool = false, _ syscall: () -> Int32) -> Int32 {
			let before = context(), beforeError = errno
			let result = syscall(), afterError = errno
			let after = context()
			// Identity returns become -1/error, 0/non-self or 1/self, never raw PIDs.
			let code = identityResult ? (result < 0 ? -1 : (result == getpid() ? 1 : 0)) : result
			facts.append("Q1 SETUP \(phase) \(before) \(code) \(beforeError) \(afterError) \(after)")
			errno = afterError
			return result
		}
		func refused() -> (accepted: Bool, error: Int32, facts: [String]) {
			return (false, errno == 0 ? EIO : errno, facts)
		}
		let session = observe("getsid", identityResult: true) { getsid(0) }
		if session != getpid() {
			guard observe("setsid", identityResult: true, { setsid() }) == getpid() else { return refused() }
		}
		let flags = observe("getfl") { fcntl(STDIN_FILENO, F_GETFL) }
		guard flags >= 0,
			observe("setfl", { fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) }) == 0 else { return refused() }
		return (true, 0, facts)
	}
	#endif

	/// Native group custody is retained until the C owner's acknowledged destruction.
	static func run(arguments: [String]) -> Int32 {
		guard validRequest(arguments: arguments) else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		if arguments[1] == automationRoleFlag { return queryRole(arguments: arguments) }
		if arguments[1] == automationGuardianFlag { return runGuardian(arguments: arguments) }
		guard arguments[1] == automationQueryFlag else { return 64 }
		// Only the retained pipe's EOF cancels a guardian with native query custody.
		_ = Darwin.signal(SIGTERM, SIG_IGN)
		_ = Darwin.signal(SIGINT, SIG_IGN)
		return runBridge(arguments: arguments)
	}

	private static func runGuardian(arguments: [String]) -> Int32 {
		guard validRequest(arguments: arguments) else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		if arguments[1] == automationRoleFlag { return queryRole(arguments: arguments) }
		guard arguments[1] == automationGuardianFlag else { return 64 }
		// Hammerspoon cancels by EOF. Signals cannot interrupt a live custody frame.
		_ = Darwin.signal(SIGTERM, SIG_IGN)
		_ = Darwin.signal(SIGINT, SIG_IGN)
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if ["fixture", "fixture-overflow", "fixture-stderr", "fixture-wait"].contains(arguments[2]) {
			let setup = fixtureSetup()
			if !setup.accepted {
				for fact in setup.facts { guard marker(fact) else { return 74 } }
				return marker("Q1 REFUSED \(setup.error)") ? 0 : 74
			}
		} else {
		guard (getsid(0) == getpid() || setsid() == getpid()), nonblocking(STDIN_FILENO) else {
			return marker("Q1 REFUSED \(errno == 0 ? EIO : errno)") ? 0 : 74
		}
		}
		#else
		guard (getsid(0) == getpid() || setsid() == getpid()), nonblocking(STDIN_FILENO) else {
			return marker("Q1 REFUSED \(errno == 0 ? EIO : errno)") ? 0 : 74
		}
		#endif
		prepareLeaseChildReaping()
		guard let output = makePipe() else { return marker("Q1 REFUSED \(EIO)") ? 0 : 74 }
		defer { Darwin.close(output[0]) }
		guard let errors = makePipe() else {
			Darwin.close(output[1]); return marker("Q1 REFUSED \(EIO)") ? 0 : 74
		}
		defer { Darwin.close(errors[0]) }
		let executable = arguments[0]
		guard let expected = LeaseExecutableIdentity.capture(at: executable),
			let argv = duplicateCStringVector([executable, automationRoleFlag] + Array(arguments.dropFirst(2))) else {
			Darwin.close(output[1]); Darwin.close(errors[1])
			return marker("Q1 REFUSED \(ESTALE)") ? 0 : 74
		}
		guard let envp = duplicateProcessEnvironment() else {
			for case let pointer? in argv { free(pointer) }
			Darwin.close(output[1]); Darwin.close(errors[1])
			return marker("Q1 REFUSED \(ENOMEM)") ? 0 : 74
		}
		defer {
			for case let pointer? in argv { free(pointer) }
			for case let pointer? in envp { free(pointer) }
		}
		var mutableArguments = argv, mutableEnvironment = envp
		var owner: OpaquePointer?
		let prepared = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				ergopti_owned_query_prepare(executable, arguments.baseAddress, environment.baseAddress,
					output[1], errors[1], &owner)
			}
		}
		Darwin.close(output[1]); Darwin.close(errors[1])
		guard owner != nil else { return marker("Q1 REFUSED \(prepared == 0 ? EPROTO : prepared)") ? 0 : 74 }
		var cancelled = prepared != 0 || LeaseExecutableIdentity.capture(at: executable) != expected
		var activated = false, pendingSent = false, outputEOF = false, errorEOF = false
		var payload = Data(), control = OwnedProgramLineDecoder(maximumBytes: 32)
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		if !cancelled && !marker("Q1 HELD") { cancelled = true }
		func drain(_ descriptor: Int32, into buffer: inout Data, eof: inout Bool, maximum: Int, afterRetirement: Bool = false) -> Bool {
			if eof { return true }
			var bytes = [UInt8](repeating: 0, count: 4096)
			let count = Darwin.read(descriptor, &bytes, bytes.count)
			if count == 0 { eof = true; return true }
			if count < 0 { return !afterRetirement && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) }
			guard count <= maximum - buffer.count else { return false }
			buffer.append(contentsOf: bytes.prefix(count))
			return true
		}
		var discardedErrors = Data()
		while let retained = owner {
			var input = [UInt8](repeating: 0, count: 64)
			let count = Darwin.read(STDIN_FILENO, &input, input.count)
			if count == 0 { cancelled = true }
			else if count > 0 {
				if !control.append(Data(input.prefix(count))) { cancelled = true }
				while let line = control.pop() {
					if line == Data("ACTIVATE".utf8), !activated, !cancelled {
						let receipt = ergopti_owned_program_activate(retained)
						activated = receipt.active && !receipt.cancelled
						if !activated { cancelled = true }
					} else { cancelled = true }
				}
			} else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { cancelled = true }
			if !drain(output[0], into: &payload, eof: &outputEOF, maximum: automationMaximumBytes)
				|| !drain(errors[0], into: &discardedErrors, eof: &errorEOF, maximum: 0)
				|| ProcessInfo.processInfo.systemUptime >= deadline { cancelled = true }
			if cancelled { _ = ergopti_owned_program_cancel(retained) }
			let receipt = ergopti_owned_program_poll(retained)
			if receipt.retired {
				guard receipt.status_valid, receipt.error_code == 0,
					ergopti_owned_program_destroy(&owner) else { return 70 }
				// Drain remaining finite pipe bytes after every inherited writer retired.
				while !outputEOF {
					if !drain(output[0], into: &payload, eof: &outputEOF, maximum: automationMaximumBytes, afterRetirement: true) {
						cancelled = true; break
					}
				}
				while !errorEOF {
					if !drain(errors[0], into: &discardedErrors, eof: &errorEOF, maximum: 0, afterRetirement: true) {
						cancelled = true; break
					}
				}
				if activated && !cancelled && receipt.exit_status == 0 && !payload.isEmpty {
					guard marker("Q1 DATA " + payload.base64EncodedString()) else { return 74 }
				}
				return marker("Q1 RETIRED \(receipt.exit_status)") ? 0 : 74
			}
			if (cancelled || receipt.error_code != 0) && !pendingSent {
				pendingSent = true
				if !marker("Q1 PENDING \(receipt.error_code)") { cancelled = true }
			}
			var event = pollfd(fd: outputEOF ? -1 : output[0], events: Int16(POLLIN), revents: 0)
			_ = Darwin.poll(&event, 1, 20)
		}
		return 70
	}

	/// A held regular source, including metadata changed by replacement/restoration.
	struct SourceGeneration: Equatable {
		let fields: [String]

		private static func capture(_ value: stat) -> SourceGeneration? {
			guard (value.st_mode & S_IFMT) == S_IFREG, value.st_size > 0, value.st_nlink > 0 else { return nil }
			return SourceGeneration(fields: [String(value.st_dev), String(value.st_ino), String(value.st_mode),
				String(value.st_nlink), String(value.st_size), String(value.st_mtimespec.tv_sec),
				String(value.st_mtimespec.tv_nsec), String(value.st_ctimespec.tv_sec), String(value.st_ctimespec.tv_nsec)])
		}

		static func descriptor(_ descriptor: Int32) -> SourceGeneration? {
			var value = stat()
			guard descriptor >= 0, Darwin.fstat(descriptor, &value) == 0 else { return nil }
			return capture(value)
		}

		static func path(_ path: String) -> SourceGeneration? {
			var value = stat()
			guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
			return capture(value)
		}
	}

	static func sameImageDigest(_ expected: Data?, _ observed: Data?) -> Bool {
		// The kernel's current CS_OPS_CDHASH identity is exactly twenty bytes.
		guard let expected, let observed, expected.count == 20, observed.count == 20 else { return false }
		return expected == observed
	}

	/// Dynamic validity binds the host/kernel image to its static CodeDirectory.
	/// Signing-information/path equality alone cannot authenticate a loaded image.
	private final class OriginalQueryImage {
		let descriptor: Int32
		let path: String
		let generation: SourceGeneration
		let code: SecCode
		let digest: Data

		private init(descriptor: Int32, path: String, generation: SourceGeneration, code: SecCode, digest: Data) {
			self.descriptor = descriptor; self.path = path; self.generation = generation; self.code = code; self.digest = digest
		}

		deinit { Darwin.close(descriptor) }

		private static func validated(_ code: SecCode) -> (digest: Data, path: String)? {
			// Dynamic offline validation is supported starting with macOS 11.3.
			// Earlier/unsigned/unknown observations close admission without fallback.
			guard #available(macOS 11.3, *),
				SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSNoNetworkAccess), nil) == errSecSuccess else { return nil }
			var staticCode: SecStaticCode?
			guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
			var information: CFDictionary?
			guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
				let information = information as? [String: Any],
				let digest = information[kSecCodeInfoUnique as String] as? Data, digest.count == 20,
				let executable = information[kSecCodeInfoMainExecutable as String] as? URL else { return nil }
			return (digest, executable.path)
		}

		static func capture(_ path: String) -> OriginalQueryImage? {
			let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
			guard descriptor >= 0 else { return nil }
			var accepted = false
			defer { if !accepted { Darwin.close(descriptor) } }
			guard let generation = SourceGeneration.descriptor(descriptor), SourceGeneration.path(path) == generation else { return nil }
			var code: SecCode?
			guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
				let observed = validated(code), SourceGeneration.path(observed.path) == generation,
				SourceGeneration.descriptor(descriptor) == generation, SourceGeneration.path(path) == generation else { return nil }
			accepted = true
			return OriginalQueryImage(descriptor: descriptor, path: path, generation: generation, code: code, digest: observed.digest)
		}

		func current() -> Bool {
			guard SourceGeneration.descriptor(descriptor) == generation, SourceGeneration.path(path) == generation,
				let observed = Self.validated(code), SourceGeneration.path(observed.path) == generation,
				OwnedAutomationQueryWorker.sameImageDigest(digest, observed.digest) else { return false }
			return SourceGeneration.descriptor(descriptor) == generation && SourceGeneration.path(path) == generation
		}

		func stoppedChildMatches(_ child: pid_t) -> Bool {
			// PID reuse is excluded by the bridge's retained unreaped direct child.
			guard child > 1, child != getpid(), current() else { return false }
			let attributes = [kSecGuestAttributePid as String: NSNumber(value: child)] as CFDictionary
			var guest: SecCode?
			guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest) == errSecSuccess,
				let guest, let observed = Self.validated(guest),
				OwnedAutomationQueryWorker.sameImageDigest(digest, observed.digest),
				SourceGeneration.path(observed.path) == generation else { return false }
			return current()
		}
	}

	/// The pipe transcript is subordinate to the exact suspended child's wait receipt.
	/// DATA is retained privately until both native query and guardian retirement.
	struct BridgeTranscript {
		private(set) var held = false
		private(set) var pending = false
		private(set) var payload: String?
		private(set) var terminal: String?
		private(set) var setup: [String] = []

		mutating func accept(_ line: String, arguments: [String]) -> Bool {
			guard terminal == nil, OwnedAutomationQueryWorker.validBridgeReceipt(line) else { return false }
			#if ERGOPTI_GUARDIAN_TEST_SUPPORT
			if line.hasPrefix("Q1 SETUP ") {
				guard !held, setup.count < 4,
					["fixture", "fixture-overflow", "fixture-stderr", "fixture-wait"].contains(arguments[2]) else { return false }
				let phases = (setup + [line]).map { $0.split(separator: " ")[2] }.map(String.init)
				guard [["getsid"], ["getsid", "setsid"], ["getsid", "getfl"], ["getsid", "getfl", "setfl"],
					["getsid", "setsid", "getfl"], ["getsid", "setsid", "getfl", "setfl"]].contains(phases) else { return false }
				setup.append(line); return true
			}
			#endif
			if line == "Q1 HELD" {
				guard !held, !pending, setup.isEmpty else { return false }
				held = true; return true
			}
			if line.hasPrefix("Q1 DATA ") {
				guard held, !pending, payload == nil,
					let bytes = Data(base64Encoded: String(line.dropFirst(8))),
					OwnedAutomationQueryWorker.bridgePacketMatches(bytes, arguments: arguments) else { return false }
				payload = line; return true
			}
			if line.hasPrefix("Q1 PENDING ") {
				guard !pending, payload == nil, setup.isEmpty else { return false }
				pending = true; return true
			}
			if line.hasPrefix("Q1 RETIRED ") {
				// A preparation failure may retire before HELD/PENDING. It grants
				// no DATA authority, but still closes the authentic original group.
				guard setup.isEmpty, payload == nil || line == "Q1 RETIRED 0" else { return false }
				terminal = line; return true
			}
			guard !held, payload == nil, !pending, line.hasPrefix("Q1 REFUSED ") else { return false }
			terminal = line; return true
		}

		func publishablePayload(guardianStatus: Int32?, cancelled: Bool, beforeDeadline: Bool) -> String? {
			guard guardianStatus == 0, terminal == "Q1 RETIRED 0", !pending,
				!cancelled, beforeDeadline else { return nil }
			return payload
		}
	}

	static func validBridgeReceipt(_ line: String) -> Bool {
		if line == "Q1 HELD" { return true }
		let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if fields.count == 14, fields[0] == "Q1", fields[1] == "SETUP",
			["getsid", "setsid", "getfl", "setfl"].contains(fields[2]) {
			let raw = Array(fields.dropFirst(3)), values = raw.compactMap { Int32($0) }
			guard values.count == 11, zip(raw, values).allSatisfy({ $0.0 == String($0.1) }),
				[0, 1, 2, 3, 7, 8, 9, 10].allSatisfy({ values[$0] == 0 || values[$0] == 1 }),
				values[5] >= 0, values[6] >= 0 else { return false }
			if fields[2] == "getsid" || fields[2] == "setsid" { return [-1, 0, 1].contains(values[4]) }
			return fields[2] == "getfl" ? values[4] >= -1 : [-1, 0].contains(values[4])
		}
		#endif
		guard fields.count == 3, fields[0] == "Q1" else { return false }
		if fields[1] == "DATA" {
			guard let bytes = Data(base64Encoded: fields[2]), !bytes.isEmpty,
				bytes.count <= automationMaximumBytes else { return false }
			return bytes.base64EncodedString() == fields[2]
		}
		guard let code = Int32(fields[2]), String(code) == fields[2], code >= 0 else { return false }
		switch fields[1] {
		case "PENDING": return true
		case "RETIRED": return code <= 255
		case "REFUSED": return code > 0
		default: return false
		}
	}

	/// Neither a stale nonce nor another fixed role may publish this query's bytes.
	static func bridgePacketMatches(_ bytes: Data, arguments: [String]) -> Bool {
		guard bytes.count <= automationMaximumBytes, validRequest(arguments: arguments),
			let packet = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
			let version = packet["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1",
			let nonce = packet["nonce"] as? NSNumber, CFGetTypeID(nonce) != CFBooleanGetTypeID(), nonce.stringValue == arguments[3],
			let operation = packet["operation"] as? String else { return false }
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if arguments[2] == "fixture" { return operation == "discover" }
		#endif
		return ["discover", "revalidate"].contains(arguments[2]) && operation == arguments[2]
	}

	private static func refuseBeforeGuardian(_ code: Int32) -> Int32 {
		return marker("Q1 REFUSED \(code == 0 ? EIO : code)") ? 0 : 74
	}

	/// This child is still stopped: no query/native group was allowed to exist.
	private static func retireStoppedGuardian(_ guardian: pid_t, refusal: Int32) -> Int32 {
		var ownershipLost = false
		while true {
			if !ownershipLost {
				// A captured unreaped child reserves its PID until this exact wait.
				_ = Darwin.kill(guardian, SIGKILL)
				var status: Int32 = 0
				let result = waitpid(guardian, &status, WNOHANG)
				if result == guardian { return refuseBeforeGuardian(refusal) }
				if result < 0 && errno != EINTR { ownershipLost = true }
			}
			// Unknown child ownership retains debt; never signal a reused PID.
			usleep(20_000)
		}
	}

	private static func runBridge(arguments: [String]) -> Int32 {
		// Includes acquisition/source witnesses. Expiry denies admission rather
		// than pretending native allocation/uncertain retirement is interruptible.
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		prepareLeaseChildReaping()
		let executable = arguments[0]
		guard let image = OriginalQueryImage.capture(executable) else { return refuseBeforeGuardian(ESTALE) }
		defer { withExtendedLifetime(image) {} }
		guard let expected = LeaseExecutableIdentity.capture(at: executable),
			let controls = makePipe() else { return refuseBeforeGuardian(ESTALE) }
		guard let results = makePipe() else {
			Darwin.close(controls[0]); Darwin.close(controls[1]); return refuseBeforeGuardian(EIO)
		}
		var inputDescriptor = controls[1]
		defer {
			if inputDescriptor >= 0 { Darwin.close(inputDescriptor) }
			Darwin.close(results[0])
		}
		func closeUnused() { Darwin.close(controls[0]); Darwin.close(results[1]) }
		guard (controls + results).allSatisfy({ $0 > STDERR_FILENO }) else {
			closeUnused(); return refuseBeforeGuardian(EBADF)
		}
		var actions: posix_spawn_file_actions_t?
		let actionError = posix_spawn_file_actions_init(&actions)
		guard actionError == 0 else { closeUnused(); return refuseBeforeGuardian(actionError) }
		defer { posix_spawn_file_actions_destroy(&actions) }
		var attributes: posix_spawnattr_t?
		let attributeError = posix_spawnattr_init(&attributes)
		guard attributeError == 0 else { closeUnused(); return refuseBeforeGuardian(attributeError) }
		defer { posix_spawnattr_destroy(&attributes) }
		// NO SETPGROUP: the guardian inherits the bridge's group, then the exact
		// original setsid guard creates its own session before native preparation.
		var setupError = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED))
		if setupError == 0 { setupError = posix_spawn_file_actions_adddup2(&actions, controls[0], STDIN_FILENO) }
		if setupError == 0 { setupError = posix_spawn_file_actions_adddup2(&actions, results[1], STDOUT_FILENO) }
		if setupError == 0 { setupError = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) }
		guard setupError == 0 else { closeUnused(); return refuseBeforeGuardian(setupError) }
		guard let argv = duplicateCStringVector([executable, automationGuardianFlag] + Array(arguments.dropFirst(2))) else {
			closeUnused(); return refuseBeforeGuardian(ENOMEM)
		}
		defer { for case let pointer? in argv { free(pointer) } }
		guard let envp = duplicateProcessEnvironment() else { closeUnused(); return refuseBeforeGuardian(ENOMEM) }
		defer { for case let pointer? in envp { free(pointer) } }
		var mutableArguments = argv, mutableEnvironment = envp
		var guardian: pid_t = 0
		let spawned = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				posix_spawn(&guardian, executable, &actions, &attributes, arguments.baseAddress, environment.baseAddress)
			}
		}
		// Only these original endpoints were inherited into the stopped guardian.
		closeUnused()
		guard spawned == 0 else { return refuseBeforeGuardian(spawned) }
		// An impossible PID cannot authorize a numeric signal; retain ownership debt.
		guard guardian > 1, guardian != getpid() else { while true { usleep(20_000) } }
		guard LeaseExecutableIdentity.capture(at: executable) == expected, image.stoppedChildMatches(guardian),
			nonblocking(STDIN_FILENO), nonblocking(inputDescriptor),
			ProcessInfo.processInfo.systemUptime < deadline else {
			return retireStoppedGuardian(guardian, refusal: ESTALE)
		}
		guard Darwin.kill(guardian, SIGCONT) == 0 else { return retireStoppedGuardian(guardian, refusal: errno) }
		var input = OwnedProgramLineDecoder(maximumBytes: 32), output = OwnedProgramLineDecoder(maximumBytes: 90000)
		var transcript = BridgeTranscript()
		var outbound = Data(), offset = 0, inputOpen = true, closeAfterFlush = false
		var cancelled = false, streamValid = true, resultEOF = false, closeAcknowledged = true
		var guardianStatus: Int32?, ownershipLost = false, resultBytes = 0
		var activationSent = false, activationDispatched = false
		func closeInput() {
			guard inputDescriptor >= 0 else { return }
			let original = inputDescriptor
			inputDescriptor = -1
			// An uncertain close cannot be retried against a potentially reused FD.
			if Darwin.close(original) != 0 { closeAcknowledged = false }
		}
		func cancel() {
			cancelled = true; inputOpen = false
			outbound.removeAll(); offset = 0; closeAfterFlush = false; closeInput()
		}
		func readInput() {
			guard inputOpen else { return }
			var bytes = [UInt8](repeating: 0, count: 64)
			let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
			if count == 0 { inputOpen = false; closeAfterFlush = true; cancelled = true }
			else if count < 0 {
				if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { cancel() }
			} else {
				guard input.append(Data(bytes.prefix(count))) else { cancel(); return }
				while let line = input.pop() {
					guard line == Data("ACTIVATE".utf8), outbound.isEmpty, offset == 0, !activationSent else { cancel(); return }
					outbound = line + Data([10]); activationSent = true
				}
			}
		}
		while true {
			if ProcessInfo.processInfo.systemUptime >= deadline { cancel() }
			readInput()
			if inputDescriptor >= 0, offset < outbound.count {
				let count = outbound.withUnsafeBytes { buffer in
					Darwin.write(inputDescriptor, buffer.baseAddress!.advanced(by: offset), outbound.count - offset)
				}
				if count > 0 { offset += count }
				else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { cancel() }
			}
			if offset == outbound.count {
				if !outbound.isEmpty { activationDispatched = true }
				outbound.removeAll(keepingCapacity: true); offset = 0
				if closeAfterFlush { closeAfterFlush = false; closeInput() }
			}
			if !resultEOF {
				var bytes = [UInt8](repeating: 0, count: 4096)
				let count = Darwin.read(results[0], &bytes, bytes.count)
				if count == 0 { resultEOF = true; closeInput() }
				else if count < 0 {
					if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { streamValid = false; cancel() }
				} else {
					resultBytes += count
					if resultBytes > 90000 || !output.append(Data(bytes.prefix(count))) { streamValid = false; cancel() }
					while let line = output.pop() {
						guard let value = String(data: line, encoding: .utf8), transcript.accept(value, arguments: arguments) else {
							streamValid = false; cancel(); continue
						}
						if value == "Q1 HELD" || value.hasPrefix("Q1 PENDING ") {
							if !marker(value) { cancel() }
						}
					}
				}
			}
			if guardianStatus == nil && !ownershipLost {
				var status: Int32 = 0
				let result = waitpid(guardian, &status, WNOHANG)
				if result == guardian { guardianStatus = status }
				else if result < 0 && errno != EINTR { ownershipLost = true; cancel() }
			}
			if let status = guardianStatus, resultEOF {
				// EOF or a normal helper exit alone cannot acknowledge an inner group.
				guard status == 0, let terminal = transcript.terminal, closeAcknowledged else {
					usleep(20_000); continue
				}
				guard streamValid, output.buffered.isEmpty else { return 70 }
				for fact in transcript.setup { guard marker(fact) else { return 74 } }
				if let payload = transcript.publishablePayload(guardianStatus: status, cancelled: cancelled || !activationDispatched || !image.current(),
					beforeDeadline: ProcessInfo.processInfo.systemUptime < deadline) {
					guard marker(payload) else { return 74 }
				}
				return marker(terminal) ? 0 : 74
			}
			var events = [pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
				pollfd(fd: resultEOF ? -1 : results[0], events: Int16(POLLIN), revents: 0),
				pollfd(fd: inputDescriptor, events: Int16(offset < outbound.count ? POLLOUT : 0), revents: 0)]
			_ = Darwin.poll(&events, nfds_t(events.count), 20)
		}
	}

	/// Read-only AppleEvents stay isolated from the interactive Hammerspoon runloop.
	private static func queryRole(arguments: [String]) -> Int32 {
		let operation = arguments[2], nonce = Int64(arguments[3])!
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		// Fixed owned native fixtures never issue AppleEvents or run user input.
		if operation == "fixture-overflow" { return write(Data(repeating: 65, count: 65537)) ? 0 : 74 }
		if operation == "fixture-stderr" {
			let sentinel = Array("PRIVATE_NATIVE_QUERY_ERROR".utf8)
			_ = sentinel.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, sentinel.count) }
			return 0
		}
		if operation == "fixture-wait" { usleep(30_000_000); return 0 }
		if operation == "fixture" {
			let packet: [String: Any] = ["version": 1, "nonce": nonce, "operation": "discover", "status": "observed",
				"rows": [["id": "11111111-1111-1111-1111-111111111111", "name": "日本 e\u{301}\n", "accepts_input": false]],
				"truncated": false]
			return write(try! JSONSerialization.data(withJSONObject: packet)) ? 0 : 74
		}
		#endif
		let observer = AutomationQueryErrors()
		func refusal(_ reason: String) -> [String: Any] {
			return ["version": 1, "operation": operation, "nonce": nonce, "status": "refused", "reason": reason]
		}
		func publish(_ packet: [String: Any]) -> Int32 {
			guard let bytes = try? JSONSerialization.data(withJSONObject: packet),
				bytes.count <= automationMaximumBytes else {
				let bytes = try! JSONSerialization.data(withJSONObject: refusal("native_refused"))
				return write(bytes) ? 0 : 74
			}
			return write(bytes) ? 0 : 74
		}
		// Ask only whether existing consent permits the readonly request. Discovery
		// must not open a TCC prompt or silently grant automation permission.
		var target = AEAddressDesc()
		let address = Array("com.apple.shortcuts.events".utf8)
		let addressError = address.withUnsafeBytes { bytes in
			AECreateDesc(typeApplicationBundleID, bytes.baseAddress, address.count, &target)
		}
		guard addressError == noErr else { return publish(refusal("native_refused")) }
		defer { AEDisposeDesc(&target) }
		let permission = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
		guard permission == noErr else {
			return publish(refusal(permission == -1743 || permission == -1744
				? "automation_permission_refused" : "native_refused"))
		}
		guard let app = SBApplication(bundleIdentifier: "com.apple.shortcuts.events") else {
			return publish(refusal("native_refused"))
		}
		app.delegate = observer
		app.timeout = 600
		guard let catalogue = app.value(forKey: "shortcuts") as? SBElementArray else {
			return publish(refusal(observer.failure ?? "native_refused"))
		}
		func row(_ object: Any) -> [String: Any]? {
			guard let object = object as? SBObject,
				let id = object.value(forKey: "id") as? String, validIdentifier(id),
				let name = object.value(forKey: "name") as? String, !name.utf8.contains(0), name.utf8.count <= 4096,
				let accepts = object.value(forKey: "acceptsInput") as? NSNumber,
				CFGetTypeID(accepts) == CFBooleanGetTypeID(), observer.failure == nil else { return nil }
			return ["id": id, "name": name, "accepts_input": accepts.boolValue]
		}
		var rows: [[String: Any]] = [], truncated = false
		if operation == "discover" {
			let count = catalogue.count
			if let failure = observer.failure { return publish(refusal(failure)) }
			guard count <= 256 else { return publish(refusal("catalogue_limit")) }
			var ids = Set<String>()
			for index in 0..<min(count, 64) {
				guard let value = row(catalogue.object(at: index)), let id = value["id"] as? String,
					ids.insert(id).inserted else { return publish(refusal(observer.failure ?? "native_refused")) }
				rows.append(value)
			}
			guard catalogue.count == count, observer.failure == nil else {
				return publish(refusal(observer.failure ?? "native_refused"))
			}
			truncated = count > 64
		} else {
			let identifier = arguments[4]
			guard let chosen = row(catalogue.object(withID: identifier)), chosen["id"] as? String == identifier,
				let after = row(catalogue.object(withID: identifier)), NSDictionary(dictionary: chosen).isEqual(to: after)
			else { return publish(refusal(observer.failure ?? "missing")) }
			rows = [chosen]
		}
		return publish(["version": 1, "operation": operation, "nonce": nonce,
			"status": "observed", "rows": rows, "truncated": truncated])
	}
}

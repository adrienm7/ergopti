// Sources/ErgoptiPlus/OwnedRuntimeUserConsoleOwner.swift
// Explicit user Console process custody never substitutes for Core, capture or VirtualHID retirement.
import CPOSIXCompatibility
import Darwin
import Dispatch
import Foundation
import Security
import SystemConfiguration

final class OwnedRuntimeUserConsoleOwner {
	enum Phase: Equatable { case pinned, starting, running, stopping, retired, cleanupRefused }
	enum Failure { case admission, spawn, guest, stream, process, cleanup }
	private static let debtLock = NSLock()
	private static var unresolved: [OwnedRuntimeUserConsoleOwner] = []
	private static var active: [ObjectIdentifier: OwnedRuntimeUserConsoleOwner] = [:]
	private let peer: OwnedRuntimeInstalledPeerOwner, image: OwnedRuntimeInstalledPeerOwner.ConsoleImageLease
	private let lock = NSRecursiveLock()
	private let worker = DispatchQueue(label: "com.ergoptiplus.runtime.console-owner")
	private var phase: Phase = .pinned, primary: Failure?, stopRequested = false, debtRetained = false
	private var birth: ergopti_owned_program_observation?
	private var programDebt: OpaquePointer?
	private var descriptorDebt = Set<Int32>()
	private var configuration: OpaquePointer?, configurationRoot: String?
	private var configurationCleanupAttempted = false, configurationSettled = false
	private init(peer: OwnedRuntimeInstalledPeerOwner, image: OwnedRuntimeInstalledPeerOwner.ConsoleImageLease) {
		self.peer = peer; self.image = image
	}
	/// Pins the original installed peer and image only; construction never spawns or enables capture.
	static func acquire(peer: OwnedRuntimeInstalledPeerOwner) -> OwnedRuntimeUserConsoleOwner? {
		guard peer.current(), let image = peer.acquireConsoleImage() else { return nil }
		let owner = OwnedRuntimeUserConsoleOwner(peer: peer, image: image)
		// Root the original owner before any token acquisition; caller ARC never retires unresolved native custody.
		Self.debtLock.lock(); Self.active[ObjectIdentifier(owner)] = owner; Self.debtLock.unlock()
		guard peer.current(), image.current(), owner.acquireConfiguration() else {
			owner.refuse(.admission); owner.settleImage(); return nil
		}
		return owner
	}
	/// Explicit single admission request; accepted means queued, never capture-ready.
	func requestStart() -> Bool {
		lock.lock(); defer { lock.unlock() }
		// Recheck the actual file after foreign peer/image observations.
		guard phase == .pinned, !stopRequested, configurationCurrent(), peer.current(), image.current(), configurationCurrent() else { return false }
		phase = .starting
		worker.async { self.run() }
		return true
	}
	func requestRetirement() {
		lock.lock(); defer { lock.unlock() }; stopRequested = true
		if phase == .pinned { settleImage() }
		else if phase == .starting || phase == .running { phase = .stopping }
	}
	/// This is only the original Console process observation, never its Core control or native device cohort.
	func current() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard phase == .running, !stopRequested, let birth, Self.currentConsoleUser(),
			peer.current(), image.current(), configurationCurrent() else { return false }
		return image.guestCurrent(birth)
	}
	func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return phase == .retired }
	func failure() -> Failure? { lock.lock(); defer { lock.unlock() }; return primary }
	private func stopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
	private func refuse(_ failure: Failure) { lock.lock(); defer { lock.unlock() }; if primary == nil { primary = failure } }
	private func retainDebt() {
		lock.lock(); defer { lock.unlock() }; phase = .cleanupRefused
		if primary == nil { primary = .cleanup }
		guard !debtRetained else { return }; debtRetained = true
		Self.debtLock.lock(); Self.unresolved.append(self); Self.debtLock.unlock()
	}
	private func acquireConfiguration() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard configuration == nil, !configurationCleanupAttempted,
			let token = ergopti_owned_configuration_acquire() else { return false }
		configuration = token
		var route = ergopti_owned_configuration_route()
		guard ergopti_owned_configuration_observe_route(token, &route) == 1,
			route.pid == getpid(), route.uid == getuid(), let pointer = route.root,
			let root = String(validatingUTF8: pointer), root.hasPrefix("/"),
			!root.contains("\n"), !root.contains("\r"),
			ergopti_owned_configuration_namespace_current(token) == 1,
			ergopti_owned_configuration_capture(token) == 1,
			ergopti_owned_configuration_current(token) == 1 else { return false }
		// Native route is the parent of the fixed karabiner file. Its constructor nonce is not a remap generation.
		configurationRoot = root
		return true
	}
	private func configurationCurrent() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !configurationCleanupAttempted, let configuration, configurationRoot != nil else { return false }
		return ergopti_owned_configuration_current(configuration) == 1
	}
	private func settleConfiguration() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if configurationCleanupAttempted { return configurationSettled }
		configurationCleanupAttempted = true
		guard let token = configuration else { configurationSettled = true; return true }
		guard ergopti_owned_configuration_release(token) == 1,
			ergopti_owned_configuration_retired(token) == 1,
			ergopti_owned_configuration_destroy(token) == 1 else { return false }
		configuration = nil; configurationRoot = nil; configurationSettled = true
		return true
	}
	private func settleImage() {
		lock.lock(); defer { lock.unlock() }
		guard phase != .cleanupRefused, phase != .retired else { return }
		// Call only after every actual original process/pipe/descriptor consumer has settled, or before any spawn.
		guard settleConfiguration() else { retainDebt(); return }
		image.requestRetirement()
		if image.retired() {
			phase = .retired
			Self.debtLock.lock(); Self.active.removeValue(forKey: ObjectIdentifier(self)); Self.debtLock.unlock()
		} else { retainDebt() }
	}
	private static func currentConsoleUser() -> Bool {
		var uid: uid_t = 0, gid: gid_t = 0
		guard getuid() != 0, getuid() == geteuid(),
			let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, name != "loginwindow" else { return false }
		return uid == getuid()
	}
	private static func nativeEnvironment(configurationRoot: String) -> [String]? {
		guard currentConsoleUser() else { return nil }
		let size = sysconf(_SC_GETPW_R_SIZE_MAX)
		guard size > 0, size <= 1_048_576 else { return nil }
		var storage = [CChar](repeating: 0, count: Int(size))
		return storage.withUnsafeMutableBufferPointer { bytes in
			var account = passwd(), result: UnsafeMutablePointer<passwd>?
			guard getpwuid_r(getuid(), &account, bytes.baseAddress, bytes.count, &result) == 0, result != nil,
				account.pw_uid == getuid(), let homePointer = account.pw_dir, let namePointer = account.pw_name else { return nil }
			let home = String(cString: homePointer), name = String(cString: namePointer)
			guard home.hasPrefix("/"), !home.contains("\n"), !home.contains("\r"), !name.isEmpty,
				!name.contains("="), !name.contains("\n"), !name.contains("\r") else { return nil }
			// Account data is native current-user context, not a caller environment or publisher capability.
			return ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + home, "USER=" + name, "LOGNAME=" + name, "XDG_CONFIG_HOME=" + configurationRoot]
		}
	}
	private static func vector(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?]? {
		var result: [UnsafeMutablePointer<CChar>?] = []
		for string in strings {
			guard let pointer = strdup(string) else { for case let retained? in result { free(retained) }; return nil }
			result.append(pointer)
		}
		result.append(nil); return result
	}
	private static func closeDescriptor(_ descriptor: Int32, refused: inout Bool) {
		if Darwin.close(descriptor) != 0 { refused = true }
	}
	private static func pipePair(closeRefused: inout Bool) -> [Int32]? {
		var descriptors: [Int32] = [-1, -1]
		guard pipe(&descriptors) == 0 else { return nil }
		let readFlags = fcntl(descriptors[0], F_GETFL)
		guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }), readFlags >= 0,
			fcntl(descriptors[0], F_SETFL, readFlags | O_NONBLOCK) == 0 else {
			for descriptor in descriptors { closeDescriptor(descriptor, refused: &closeRefused) }
			return nil
		}
		return descriptors
	}
	private static func drain(_ descriptor: Int32, eof: inout Bool) -> Bool {
		if eof { return true }
		var block = [UInt8](repeating: 0, count: 4096)
		let count = Darwin.read(descriptor, &block, block.count)
		if count == 0 { eof = true; return true }
		if count < 0 { return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK }
		// Discard a bounded block; no arbitrary Console/log string is retained or exported.
		return true
	}
	private func run() {
		var ownedDescriptors = Set<Int32>(), closeRefused = false
		func closeOwned(_ descriptor: Int32) {
			guard ownedDescriptors.remove(descriptor) != nil else { return }
			let acknowledged = Darwin.close(descriptor) == 0
			lock.lock()
			if acknowledged { descriptorDebt.remove(descriptor) } else { closeRefused = true }
			lock.unlock()
		}
		func closeAll() { for descriptor in Array(ownedDescriptors) { closeOwned(descriptor) } }
		func finish() {
			closeAll()
			if closeRefused { retainDebt() } else { settleImage() }
		}
		guard !stopping(), getsid(0) == getpid(), Self.currentConsoleUser(), peer.current(), image.current(),
			configurationCurrent(), let root = configurationRoot,
			let nativeEnvironment = Self.nativeEnvironment(configurationRoot: root) else { refuse(.admission); finish(); return }
		func makePipe() -> [Int32]? {
			guard let pair = Self.pipePair(closeRefused: &closeRefused) else { return nil }
			for descriptor in pair { ownedDescriptors.insert(descriptor) }
			lock.lock(); descriptorDebt.formUnion(pair); lock.unlock(); return pair
		}
		guard let input = makePipe(), let output = makePipe(), let errors = makePipe() else { refuse(.stream); finish(); return }
		guard var argv = Self.vector([image.executablePath]) else { refuse(.spawn); finish(); return }
		defer { for case let pointer? in argv { free(pointer) } }
		guard var envp = Self.vector(nativeEnvironment) else { refuse(.spawn); finish(); return }
		defer { for case let pointer? in envp { free(pointer) } }
		var owner: OpaquePointer?
		let inheritance: ergopti_owned_stream_inheritance = { context, actions in
			guard let context, let actions else { return EINVAL }
			let lease = Unmanaged<OwnedRuntimeInstalledPeerOwner.ConsoleImageLease>.fromOpaque(context).takeUnretainedValue()
			guard lease.current() else { return ESTALE }
			do { try lease.installLifecycleInheritance(actions: &actions.pointee); return lease.current() ? 0 : ESTALE }
			catch { return EACCES }
		}
		guard !stopping(), peer.current(), image.current(), configurationCurrent() else { refuse(.admission); finish(); return }
		let prepared = argv.withUnsafeMutableBufferPointer { arguments in
			envp.withUnsafeMutableBufferPointer { environment in
				ergopti_owned_stream_prepare(image.executablePath, arguments.baseAddress, environment.baseAddress,
					input[0], output[1], errors[1], inheritance, Unmanaged.passUnretained(image).toOpaque(), &owner)
			}
		}
		lock.lock(); programDebt = owner; lock.unlock()
		for descriptor in [input[0], input[1], output[1], errors[1]] { closeOwned(descriptor) }
		guard let retained = owner else { refuse(.spawn); finish(); return }
		var cancelled = prepared != 0 || closeRefused || stopping() || !peer.current() || !image.current() || !configurationCurrent()
		if prepared != 0 { refuse(.spawn) }
		let original = ergopti_owned_program_prepared_identity(retained)
		if !cancelled && (!Self.currentConsoleUser() || !image.guestCurrent(original)) { cancelled = true; refuse(.guest) }
		if !cancelled {
			lock.lock(); birth = original; lock.unlock()
			if stopping() || !configurationCurrent() { cancelled = true }
			else {
				let activated = ergopti_owned_program_activate(retained)
				cancelled = !activated.active || activated.cancelled || activated.error_code != 0
				if cancelled { refuse(.process) }
				else { lock.lock(); phase = stopRequested ? .stopping : .running; lock.unlock() }
			}
		}
		var cancellationSent = false, outputEOF = false, errorEOF = false
		while true {
			if stopping() || !Self.currentConsoleUser() || !peer.current() || !image.current() || !configurationCurrent() { cancelled = true }
			if !cancelled && !image.guestCurrent(original) { cancelled = true; refuse(.guest) }
			if !Self.drain(output[0], eof: &outputEOF) { cancelled = true; refuse(.stream) }
			if !Self.drain(errors[0], eof: &errorEOF) { cancelled = true; refuse(.stream) }
			if cancelled && !cancellationSent { _ = ergopti_owned_program_cancel(retained); cancellationSent = true }
			let receipt = ergopti_owned_program_poll(retained)
			if receipt.error_code != 0 { cancelled = true; refuse(.process) }
			if receipt.leader_exited && !cancelled && !stopping() { refuse(.process) }
			if receipt.retired && outputEOF && errorEOF {
				guard ergopti_owned_program_destroy(&owner), owner == nil else { closeAll(); retainDebt(); return }
				lock.lock(); programDebt = nil; lock.unlock()
				finish(); return
			}
			// Exact native refusal or debt remains owned; elapsed time never fabricates process/EOF retirement.
			usleep(25_000)
		}
	}
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixturePipe(closeRefused: inout Bool) -> [Int32]? { pipePair(closeRefused: &closeRefused) }
	static func fixtureDrain(_ descriptor: Int32, eof: inout Bool) -> Bool { drain(descriptor, eof: &eof) }
	static func fixtureClose(_ descriptor: Int32, refused: inout Bool) { closeDescriptor(descriptor, refused: &refused) }
	static func fixtureUnqualifiedConsoleGuest(_ pid: pid_t) -> Bool {
		guard pid > 0 else { return false }
		var guest: SecCode?
		let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
		return OwnedRuntimePublisherSignature.currentLeaf(guest, role: .console) != nil
	}
#endif
	// Original active/debt roots are released only by checked retirement, never by caller ARC.
}

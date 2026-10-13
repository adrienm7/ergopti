// Sources/ErgoptiPlus/OwnedRuntimeInstalledPeerOwner.swift
// Same-process native installed-image custody; no serialized token, READY flag or transferable Swift object.
import CPOSIXCompatibility
import Darwin
import Foundation
import Security

final class OwnedRuntimeInstalledPeerOwner {
	// Native custody survives caller reference loss until fully acknowledged explicit retirement.
	private static let rootLock = NSLock()
	private static var active: [ObjectIdentifier: OwnedRuntimeInstalledPeerOwner] = [:]
	private static let runtime = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/Runtime", isDirectory: true)
	private static let cliRelative = "bin/ergoptiplus_remap_cli"
	private static let consoleRelative = "ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console"
	private let lock = NSRecursiveLock()
	private let publisher: OwnedRuntimePublisherIdentity
	private let principal: SecCode, leaf: Data, launcher: OwnedRuntimeInstallTree, runtimeTree: OwnedRuntimeInstallTree
	private let lifecycle: OwnedRuntimeServiceLifecycleLock
	private var revoked = false, closeAttempted = false, closeRefused = false, outstanding = 0
	private init(publisher: OwnedRuntimePublisherIdentity, principal: SecCode, leaf: Data, launcher: OwnedRuntimeInstallTree,
		runtime: OwnedRuntimeInstallTree, lifecycle: OwnedRuntimeServiceLifecycleLock) {
		self.publisher = publisher; self.principal = principal; self.leaf = leaf; self.launcher = launcher
		self.runtimeTree = runtime; self.lifecycle = lifecycle
	}
	/// Only the actual normal signed launcher may bind its actual protected installed inventory.
	/// No caller principal, path, fixture receipt, token or readiness boolean is admitted.
	static func acquire() -> OwnedRuntimeInstalledPeerOwner? {
		guard getuid() != 0, getuid() == geteuid(), Bundle.main.bundleIdentifier == kErgoptiBundleId,
			Bundle.main.bundleURL.pathExtension == "app" else { return nil }
		guard let publisher = OwnedRuntimePublisherIdentity.currentLauncher() else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal,
			let leaf = signingLeaf(principal), leaf == publisher.leaf, let lifecycle = OwnedRuntimeServiceLifecycleLock.acquireShared() else { return nil }
		var completed = false
		defer { if !completed { _ = lifecycle.retire() } }
		do {
			let launcher = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: false, includeChildren: false)
			let runtime = try OwnedRuntimeInstallTree(root: Self.runtime, protected: true)
			try runtime.verify()
			try OwnedRuntimeInstallOwner.validateInstalledProductsForPeer(at: Self.runtime, leaf: leaf)
			try runtime.verify(); try launcher.verifyAnchor()
			guard publisher.current(), lifecycle.current(), lifecycle.permitsInstalledImages(), signingLeaf(principal) == leaf else { throw OwnedRuntimeInstallFailure.principal }
			let owner = OwnedRuntimeInstalledPeerOwner(publisher: publisher, principal: principal, leaf: leaf, launcher: launcher,
				runtime: runtime, lifecycle: lifecycle)
			Self.rootLock.lock(); Self.active[ObjectIdentifier(owner)] = owner; Self.rootLock.unlock()
			completed = true; return owner
		} catch { return nil }
	}
	private static func signingLeaf(_ principal: SecCode) -> Data? {
		OwnedRuntimePublisherSignature.currentLeaf(principal, role: .launcher)
	}
	private func verify() throws {
		guard !revoked, !closeRefused, publisher.current(), getuid() != 0, getuid() == geteuid(), Bundle.main.bundleIdentifier == kErgoptiBundleId,
			Self.signingLeaf(principal) == leaf, lifecycle.current(), lifecycle.permitsInstalledImages() else { throw OwnedRuntimeInstallFailure.principal }
		try launcher.verifyAnchor(); try runtimeTree.verify()
	}
	/// Native currentness observation only; this creates no peer, image lease, process or readiness authority.
	func current() -> Bool { lock.lock(); defer { lock.unlock() }; do { try verify(); return true } catch { return false } }
	func acquireCLIImage() -> CLIImageLease? {
		lock.lock(); defer { lock.unlock() }
		do {
			try verify()
			let root = try runtimeTree.duplicateRootDescriptor(); defer { Darwin.close(root) }
			let bin = openat(root, "bin", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard bin >= 0 else { throw OwnedRuntimeInstallFailure.source }; defer { Darwin.close(bin) }
			let descriptor = openat(bin, "ergoptiplus_remap_cli", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
			var admitted = false; defer { if !admitted { Darwin.close(descriptor) } }
			var identity = stat()
			guard fstat(descriptor, &identity) == 0, identity.st_uid == 0,
				identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), identity.st_nlink == 1 else { throw OwnedRuntimeInstallFailure.protection }
			guard leaseCurrent(descriptor, identity: identity) else { throw OwnedRuntimeInstallFailure.mutated }
			outstanding += 1; admitted = true
			return CLIImageLease(owner: self, descriptor: descriptor, identity: identity)
		} catch { return nil }
	}
	private func leaseCurrent(_ descriptor: Int32, identity: stat) -> Bool {
		lock.lock(); defer { lock.unlock() }
		do {
			try verify()
			var held = stat(), named = stat()
			guard fstat(descriptor, &held) == 0,
				lstat(Self.runtime.appendingPathComponent(Self.cliRelative).path, &named) == 0,
				held.st_dev == identity.st_dev, held.st_ino == identity.st_ino,
				named.st_dev == held.st_dev, named.st_ino == held.st_ino,
				held.st_uid == 0, held.st_mode == identity.st_mode, held.st_size == identity.st_size,
				held.st_nlink == 1 else { return false }
			return true
		} catch { return false }
	}
	private func inheritance(_ descriptor: Int32, identity: stat, actions: inout posix_spawn_file_actions_t?) throws {
		lock.lock(); defer { lock.unlock() }
		guard leaseCurrent(descriptor, identity: identity) else { throw OwnedRuntimeInstallFailure.mutated }
		try lifecycle.installInheritance(actions: &actions)
	}
	/// The Console image is a distinct protected leaf, not a CLI or process capability.
	func acquireConsoleImage() -> ConsoleImageLease? {
		lock.lock(); defer { lock.unlock() }
		var ancestors: [Int32] = [], descriptor: Int32 = -1, published = false
		func closeAncestors() -> Bool {
			var acknowledged = true
			for retained in ancestors.reversed() { if Darwin.close(retained) != 0 { acknowledged = false; closeRefused = true } }
			ancestors.removeAll(); return acknowledged
		}
		defer {
			_ = closeAncestors()
			if !published && descriptor >= 0 && Darwin.close(descriptor) != 0 { closeRefused = true }
		}
		do {
			try verify()
			var parent = try runtimeTree.duplicateRootDescriptor(); ancestors.append(parent)
			for component in ["ErgoptiPlus-Remap-Console.app", "Contents", "MacOS"] {
				let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
				guard next >= 0 else { throw OwnedRuntimeInstallFailure.source }
				ancestors.append(next); parent = next
			}
			descriptor = openat(parent, "ErgoptiPlus-Remap-Console", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
			var identity = stat()
			guard fstat(descriptor, &identity) == 0, identity.st_uid == 0,
				identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), identity.st_nlink == 1,
				consoleLeaseCurrent(descriptor, identity: identity), closeAncestors() else { throw OwnedRuntimeInstallFailure.protection }
			try verify()
			outstanding += 1; published = true
			return ConsoleImageLease(owner: self, descriptor: descriptor, identity: identity)
		} catch { return nil }
	}
	private func consoleLeaseCurrent(_ descriptor: Int32, identity: stat) -> Bool {
		lock.lock(); defer { lock.unlock() }
		do {
			try verify()
			var held = stat(), named = stat()
			guard fstat(descriptor, &held) == 0, lstat(Self.runtime.appendingPathComponent(Self.consoleRelative).path, &named) == 0,
				held.st_dev == identity.st_dev, held.st_ino == identity.st_ino, named.st_dev == held.st_dev, named.st_ino == held.st_ino,
				held.st_uid == 0, held.st_mode == identity.st_mode, held.st_size == identity.st_size, held.st_nlink == 1 else { return false }
			return true
		} catch { return false }
	}
	private func consoleInheritance(_ descriptor: Int32, identity: stat, actions: inout posix_spawn_file_actions_t?) throws {
		lock.lock(); defer { lock.unlock() }
		guard consoleLeaseCurrent(descriptor, identity: identity) else { throw OwnedRuntimeInstallFailure.mutated }
		try lifecycle.installInheritance(actions: &actions)
	}
	private func consoleGuestCurrent(_ observation: ergopti_owned_program_observation, descriptor: Int32, identity: stat) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard consoleLeaseCurrent(descriptor, identity: identity), observation.error_code == 0, !observation.nonlive,
			observation.process_id > 0, observation.process_group_id == observation.process_id else { return false }
		let before = ergopti_owned_program_observe(observation.process_id)
		guard Self.sameConsoleBirth(observation, before) else { return false }
		var guest: SecCode?, code: SecStaticCode?, path: CFURL?, information: CFDictionary?
		let attributes = [kSecGuestAttributePid as String: NSNumber(value: observation.process_id)] as CFDictionary
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
			OwnedRuntimePublisherSignature.currentLeaf(guest, role: .console) == leaf,
			SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
			SecCodeCopyPath(code, [], &path) == errSecSuccess, let path,
			SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any], let main = fields[kSecCodeInfoMainExecutable as String] as? URL else { return false }
		let executable = Self.runtime.appendingPathComponent(Self.consoleRelative).standardizedFileURL
		let bundle = Self.runtime.appendingPathComponent("ErgoptiPlus-Remap-Console.app").standardizedFileURL
		let actual = (path as URL).standardizedFileURL
		guard main.standardizedFileURL == executable, actual == bundle || actual == executable else { return false }
		let after = ergopti_owned_program_observe(observation.process_id)
		return Self.sameConsoleBirth(observation, after) && consoleLeaseCurrent(descriptor, identity: identity)
	}
	private static func sameConsoleBirth(_ original: ergopti_owned_program_observation, _ current: ergopti_owned_program_observation) -> Bool {
		current.error_code == 0 && !current.nonlive && original.process_id == current.process_id
			&& original.process_group_id == current.process_group_id && original.start_seconds == current.start_seconds
			&& original.start_microseconds == current.start_microseconds
	}
	/// The supplied observation is compared to original native kernel observations; it is never itself authority.
	private func cliGuestCurrent(_ observation: ergopti_owned_program_observation, descriptor: Int32, identity: stat) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard leaseCurrent(descriptor, identity: identity), let guest = Self.cliExecutableGuest(observation),
			OwnedRuntimePublisherSignature.currentLeaf(guest, role: .cli) == leaf,
			Self.sameConsoleBirth(observation, ergopti_owned_program_observe(observation.process_id)),
			Self.currentNativeParent(observation.process_id), leaseCurrent(descriptor, identity: identity) else { return false }
		return true
	}
	private static func currentNativeParent(_ identifier: pid_t) -> Bool {
		guard identifier > 0 else { return false }
		var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identifier]
		var native = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
		let status = query.withUnsafeMutableBufferPointer { values in
			sysctl(values.baseAddress, u_int(values.count), &native, &size, nil, 0)
		}
		return status == 0 && size == MemoryLayout<kinfo_proc>.size
			&& native.kp_proc.p_pid == identifier && native.kp_eproc.e_ppid == getpid()
	}
	private static func cliExecutableGuest(_ observation: ergopti_owned_program_observation) -> SecCode? {
		guard observation.error_code == 0, !observation.nonlive, observation.process_id > 0,
			observation.process_group_id == observation.process_id,
			sameConsoleBirth(observation, ergopti_owned_program_observe(observation.process_id)), currentNativeParent(observation.process_id) else { return nil }
		var guest: SecCode?, code: SecStaticCode?, path: CFURL?, information: CFDictionary?
		let attributes = [kSecGuestAttributePid as String: NSNumber(value: observation.process_id)] as CFDictionary
		guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
			OwnedRuntimePublisherSignature.currentLeaf(guest, role: .cli) != nil,
			SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
			SecCodeCopyPath(code, [], &path) == errSecSuccess, let path,
			SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any], let main = fields[kSecCodeInfoMainExecutable as String] as? URL else { return nil }
		let expected = runtime.appendingPathComponent(cliRelative).standardizedFileURL
		guard main.standardizedFileURL == expected, (path as URL).standardizedFileURL == expected,
			sameConsoleBirth(observation, ergopti_owned_program_observe(observation.process_id)), currentNativeParent(observation.process_id) else { return nil }
		return guest
	}
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Observation-only negatives; these do not acquire a peer/image lease or accept caller path/leaf authority.
	static func fixtureCLIExecutableGuest(_ observation: ergopti_owned_program_observation) -> Bool { cliExecutableGuest(observation) != nil }
	static func fixtureCurrentNativeParent(_ identifier: pid_t) -> Bool { currentNativeParent(identifier) }
#endif
	private func releaseLease(closeAcknowledged: Bool) {
		lock.lock(); defer { lock.unlock() }
		if !closeAcknowledged { closeRefused = true }
		guard outstanding > 0 else { closeRefused = true; return }
		outstanding -= 1; finishIfUnreferenced()
	}
	func requestRetirement() { lock.lock(); defer { lock.unlock() }; revoked = true; finishIfUnreferenced() }
	private func finishIfUnreferenced() {
		guard revoked, outstanding == 0, !closeAttempted else { return }; closeAttempted = true
		if !runtimeTree.releaseOwnedDescriptors() { closeRefused = true }
		if !launcher.releaseOwnedDescriptors() { closeRefused = true }
		if !publisher.retire() { closeRefused = true }
		// The actual namespace fence remains held if any earlier native custody is unresolved.
		if !closeRefused && !lifecycle.retire() { closeRefused = true }
		if !closeRefused { Self.rootLock.lock(); Self.active.removeValue(forKey: ObjectIdentifier(self)); Self.rootLock.unlock() }
	}
	func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return revoked && closeAttempted && outstanding == 0 && !closeRefused }
	deinit { requestRetirement() }

	/// Fixed Console leaf and native namespace custody; caller must settle its original child and pipes first.
	final class ConsoleImageLease {
		private let owner: OwnedRuntimeInstalledPeerOwner, descriptor: Int32, identity: stat
		private let lock = NSLock()
		private var revoked = false, closeRefused = false
		fileprivate init(owner: OwnedRuntimeInstalledPeerOwner, descriptor: Int32, identity: stat) {
			self.owner = owner; self.descriptor = descriptor; self.identity = identity
		}
		var executablePath: String { OwnedRuntimeInstalledPeerOwner.runtime.appendingPathComponent(OwnedRuntimeInstalledPeerOwner.consoleRelative).path }
		func current() -> Bool { lock.lock(); defer { lock.unlock() }; return !revoked && owner.consoleLeaseCurrent(descriptor, identity: identity) }
		func guestCurrent(_ observation: ergopti_owned_program_observation) -> Bool {
			lock.lock(); defer { lock.unlock() }
			return !revoked && owner.consoleGuestCurrent(observation, descriptor: descriptor, identity: identity)
		}
		func installLifecycleInheritance(actions: inout posix_spawn_file_actions_t?) throws {
			lock.lock(); defer { lock.unlock() }; guard !revoked else { throw OwnedRuntimeInstallFailure.cleanupPending }
			try owner.consoleInheritance(descriptor, identity: identity, actions: &actions)
		}
		func requestRetirement() {
			lock.lock(); defer { lock.unlock() }; guard !revoked else { return }; revoked = true
			closeRefused = Darwin.close(descriptor) != 0; owner.releaseLease(closeAcknowledged: !closeRefused)
		}
		func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return revoked && !closeRefused }
		deinit { requestRetirement() }
	}

	/// Private factory-owned image reference. Caller must retire its real child/socket/pipe owners before this reference.
	/// Native inheritance keeps replacement fenced through abrupt launcher death, independently of Swift object lifetime.
	final class CLIImageLease {
		private let owner: OwnedRuntimeInstalledPeerOwner, descriptor: Int32, identity: stat
		private let lock = NSLock()
		private var revoked = false, closeRefused = false
		fileprivate init(owner: OwnedRuntimeInstalledPeerOwner, descriptor: Int32, identity: stat) {
			self.owner = owner; self.descriptor = descriptor; self.identity = identity
		}
		var executablePath: String { OwnedRuntimeInstalledPeerOwner.runtime.appendingPathComponent(OwnedRuntimeInstalledPeerOwner.cliRelative).path }
		func current() -> Bool { lock.lock(); defer { lock.unlock() }; return !revoked && owner.leaseCurrent(descriptor, identity: identity) }
		func guestCurrent(_ observation: ergopti_owned_program_observation) -> Bool {
			lock.lock(); defer { lock.unlock() }
			return !revoked && owner.cliGuestCurrent(observation, descriptor: descriptor, identity: identity)
		}
		func installLifecycleInheritance(actions: inout posix_spawn_file_actions_t?) throws {
			lock.lock(); defer { lock.unlock() }
			guard !revoked else { throw OwnedRuntimeInstallFailure.cleanupPending }
			try owner.inheritance(descriptor, identity: identity, actions: &actions)
		}
		func requestRetirement() {
			lock.lock(); defer { lock.unlock() }
			guard !revoked else { return }; revoked = true
			closeRefused = Darwin.close(descriptor) != 0
			owner.releaseLease(closeAcknowledged: !closeRefused)
		}
		func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return revoked && !closeRefused }
		deinit { requestRetirement() }
	}
}

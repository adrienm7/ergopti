// Sources/ErgoptiPlus/OwnedRuntimeServiceLifecycleLock.swift
// Kernel namespace custody: CLI inherits the same flock open-file-description, including after launcher death.
import Darwin
import Foundation
import Security

@_silgen_name("ergopti_owned_runtime_lifecycle_child_descriptor")
private func ownedRuntimeLifecycleChildDescriptor() -> Int32

/// Shared image leases prevent a cooperating root installer from replacing live images.
/// Neither holding a lock nor releasing it proves process/capture/VHD readiness or retirement.
final class OwnedRuntimeServiceLifecycleLock {
	private static let parentURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private static let name = ".runtime-service-lifecycle-lock"
	private let lock = NSLock()
	private let parent: OwnedRuntimeInstallTree, parentDescriptor: Int32, descriptor: Int32
	private let identity: stat, protected: Bool
	private let admission: () throws -> Void
	private let admissionTree: OwnedRuntimeInstallTree?
	private var revoked = false, closeRefused = false

	/// Normal signed launcher obtains shared namespace custody; no caller options or image paths are accepted.
	static func acquireShared() -> OwnedRuntimeServiceLifecycleLock? { acquire(exclusive: false) }
	/// Only the distinct protected privileged helper obtains exclusive replacement/service namespace custody.
	static func acquireExclusive() -> OwnedRuntimeServiceLifecycleLock? { acquire(exclusive: true) }
	private static func acquire(exclusive: Bool) -> OwnedRuntimeServiceLifecycleLock? {
		let identifier = exclusive ? "com.ergoptiplus.app.runtime-installer" : kErgoptiBundleId
		guard Bundle.main.bundleIdentifier == identifier, Bundle.main.bundleURL.pathExtension == "app",
			getuid() == geteuid(), exclusive ? getuid() == 0 : getuid() != 0 else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let leaf = signingLeaf(principal, identifier: identifier) else { return nil }
		do {
			let image = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: exclusive, includeChildren: exclusive)
			let admission = {
				guard getuid() == geteuid(), exclusive ? getuid() == 0 : getuid() != 0,
					signingLeaf(principal, identifier: identifier) == leaf else { throw OwnedRuntimeInstallFailure.principal }
				try image.verifyAnchor()
				if exclusive { try image.verify() }
			}
			return try OwnedRuntimeServiceLifecycleLock(parentURL: parentURL, protected: true,
				exclusive: exclusive, create: exclusive, admissionTree: image, admission: admission)
		} catch { return nil }
	}
	private static func signingLeaf(_ principal: SecCode, identifier: String) -> Data? {
		guard let role = OwnedRuntimePublisherSignature.Role(rawValue: identifier),
			role == .launcher || role == .installer else { return nil }
		// The original publisher checks real CMS, all slices and the exact same leaf.
		// Lifecycle custody must not independently exclude that owned self-signed publisher.
		return OwnedRuntimePublisherSignature.currentLeaf(principal, role: role)
	}
	private init(parentURL: URL, protected: Bool, exclusive: Bool, create: Bool,
		admissionTree: OwnedRuntimeInstallTree?, admission: @escaping () throws -> Void) throws {
		self.protected = protected; self.admission = admission; self.admissionTree = admissionTree
		parent = try OwnedRuntimeInstallTree(root: parentURL, protected: protected, includeChildren: false)
		let acquiredParentDescriptor = try parent.duplicateRootDescriptor()
		parentDescriptor = acquiredParentDescriptor
		var opened: Int32 = -1, completed = false
		defer { if !completed { if opened >= 0 { Darwin.close(opened) }; Darwin.close(acquiredParentDescriptor) } }
		try admission(); try parent.verifyAnchor()
		if create {
			opened = openat(parentDescriptor, Self.name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
			if opened >= 0 {
				guard fchmod(opened, 0o644) == 0, fsync(opened) == 0, fsync(parentDescriptor) == 0 else {
					throw OwnedRuntimeInstallFailure.cleanupPending
				}
			} else { guard errno == EEXIST else { throw OwnedRuntimeInstallFailure.cleanupPending } }
		}
		if opened < 0 { opened = openat(parentDescriptor, Self.name, (exclusive ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
		guard opened >= 0, flock(opened, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var held = stat(); guard fstat(opened, &held) == 0 else { throw OwnedRuntimeInstallFailure.source }
		descriptor = opened; identity = held
		completed = true // All stored properties are initialized; deinit now owns both descriptors.
		try verify()
	}
	deinit { _ = retire() }
	private static func emptyACL(_ descriptor: Int32) throws {
		guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { throw OwnedRuntimeInstallFailure.protection }
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		var entry: acl_entry_t?; errno = 0
		guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
			throw OwnedRuntimeInstallFailure.protection
		}
	}
	private func verify() throws {
		guard !revoked else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try admission(); try parent.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0, fstatat(parentDescriptor, Self.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == identity.st_dev, held.st_ino == identity.st_ino, named.st_dev == held.st_dev, named.st_ino == held.st_ino,
			held.st_uid == identity.st_uid, named.st_uid == held.st_uid, !protected || held.st_uid == 0,
			held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o7777 == 0o644,
			held.st_nlink == 1, held.st_size == 0 else { throw OwnedRuntimeInstallFailure.protection }
		try Self.emptyACL(descriptor)
	}
	func current() -> Bool { lock.lock(); defer { lock.unlock() }; do { try verify(); return true } catch { return false } }
	/// The fixed dup2 action preserves the same OFD under CLOEXEC_DEFAULT. No raw lock FD leaves this owner.
	/// Caller retains its image lease until the exact child/socket/pipe retirement; this action is not a child ACK.
	func installInheritance(actions: inout posix_spawn_file_actions_t?) throws {
		lock.lock(); defer { lock.unlock() }
		try verify()
		let destination = ownedRuntimeLifecycleChildDescriptor()
		guard destination > STDERR_FILENO, destination != descriptor,
			posix_spawn_file_actions_adddup2(&actions, descriptor, destination) == 0 else { throw OwnedRuntimeInstallFailure.source }
	}
	/// Close this process's references only. Explicit LOCK_UN would also unlock a surviving inherited CLI reference.
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !revoked else { return !closeRefused }; revoked = true
		if Darwin.close(descriptor) != 0 { closeRefused = true }
		if Darwin.close(parentDescriptor) != 0 { closeRefused = true }
		if !parent.releaseOwnedDescriptors() { closeRefused = true }
		if let admissionTree, !admissionTree.releaseOwnedDescriptors() { closeRefused = true }
		return !closeRefused
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Native disposable actors inspect only their real executing closed-role signature.
	/// This does not acquire a lifecycle lock or any publisher/install/capture capability.
	static func fixtureCurrentPublisherSignature() -> Bool {
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal else { return false }
		return signingLeaf(principal, identifier: kErgoptiBundleId) != nil
			|| signingLeaf(principal, identifier: "com.ergoptiplus.app.runtime-installer") != nil
	}
	/// Actual disposable native flock controls contain no production SecCode/peer/CLI-image capability.
	static func fixtureAcquire(parent: URL, exclusive: Bool, create: Bool = false) throws -> OwnedRuntimeServiceLifecycleLock {
		try OwnedRuntimeServiceLifecycleLock(parentURL: parent, protected: false, exclusive: exclusive, create: create,
			admissionTree: nil, admission: {})
	}
	#endif
}

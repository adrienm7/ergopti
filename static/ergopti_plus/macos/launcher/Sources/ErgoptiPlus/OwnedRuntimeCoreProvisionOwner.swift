// Sources/ErgoptiPlus/OwnedRuntimeCoreProvisionOwner.swift
// An explicit protected helper transaction starts only the owned Core service, never claiming capture READY.
import CoreFoundation
import Darwin
import Foundation
import Security

final class OwnedRuntimeCoreProvisionOwner {
	private static let identifier = "com.ergoptiplus.app.runtime-installer"
	private static let runtimeURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/Runtime", isDirectory: true)
	private static let dataURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/RemapRuntime", isDirectory: true)
	private static let target = "system/com.ergoptiplus.runtime.core"
	private let creator = getpid()
	private let publisher: OwnedRuntimePublisherIdentity
	private let principal: SecCode, leaf: Data, helper: OwnedRuntimeInstallTree, runtime: OwnedRuntimeInstallTree, payload: OwnedRuntimeInstallTree
	private let lifecycle: OwnedRuntimeServiceLifecycleLock
	private let publicationParent: OwnedRuntimeFirstInstallOwner?
	private let lock = NSRecursiveLock()
	private var custody: OwnedRuntimeCorePlistCustody?, serviceTouched = false, committed = false, closeAttempted = false, closeRefused = false
	private init(publisher: OwnedRuntimePublisherIdentity, principal: SecCode, leaf: Data, helper: OwnedRuntimeInstallTree, runtime: OwnedRuntimeInstallTree, payload: OwnedRuntimeInstallTree,
		lifecycle: OwnedRuntimeServiceLifecycleLock, publicationParent: OwnedRuntimeFirstInstallOwner?) {
		self.publisher = publisher; self.principal = principal; self.leaf = leaf; self.helper = helper; self.runtime = runtime; self.payload = payload; self.lifecycle = lifecycle; self.publicationParent = publicationParent
	}
	/// No paths, signatures, PIDs, flags or serialized receipts can create production provision authority.
	static func acquire() -> OwnedRuntimeCoreProvisionOwner? {
		guard !Thread.isMainThread, let lifecycle = OwnedRuntimeServiceLifecycleLock.acquireExclusive() else { return nil }
		return acquireOriginalNamespace(lifecycle: lifecycle, publicationParent: nil)
	}
	/// Only the actual first-publication owner lends its existing native EX custody. No pathname/Boolean parameter is authority.
	static func acquire(afterPublication owner: OwnedRuntimeFirstInstallOwner) -> OwnedRuntimeCoreProvisionOwner? {
		do {
			let result = try owner.withPublishedNamespace { acquireOriginalNamespace(lifecycle: $0, publicationParent: owner) }
			guard let result else { return nil }
			try result.verifyForPlistCustody(); return result
		} catch { return nil }
	}
	private static func acquireOriginalNamespace(lifecycle: OwnedRuntimeServiceLifecycleLock,
		publicationParent: OwnedRuntimeFirstInstallOwner?) -> OwnedRuntimeCoreProvisionOwner? {
		var complete = false; defer { if !complete && publicationParent == nil { _ = lifecycle.retire() } }
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0, Bundle.main.bundleIdentifier == identifier,
			Bundle.main.bundleURL.pathExtension == "app", let publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller() else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let leaf = signingLeaf(principal), leaf == publisher.leaf,
			lifecycle.current(), lifecycle.permitsServiceProvision() else { return nil }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			let runtime = try OwnedRuntimeInstallTree(root: runtimeURL, protected: true)
			guard let resources = Bundle.main.resourceURL else { throw OwnedRuntimeInstallFailure.source }
			let payload = try OwnedRuntimeInstallTree(root: resources.appendingPathComponent("OwnedRuntime"), protected: true)
			guard try payload.matchesBytes(of: runtime), idleRevision(try Data(contentsOf: runtimeURL.appendingPathComponent("ErgoptiPlus-Remap-Core.app/Contents/Info.plist"))) else { throw OwnedRuntimeInstallFailure.source }
			try OwnedRuntimeInstallOwner.validateSignedProductsForBuild(at: runtimeURL, leaf: leaf)
			try helper.verify(); try runtime.verify(); try payload.verify()
			guard publisher.current(), lifecycle.current(), lifecycle.permitsServiceProvision(), signingLeaf(principal) == leaf else {
				throw OwnedRuntimeInstallFailure.principal
			}
			let result = OwnedRuntimeCoreProvisionOwner(publisher: publisher, principal: principal, leaf: leaf, helper: helper,
				runtime: runtime, payload: payload, lifecycle: lifecycle, publicationParent: publicationParent)
			complete = true; return result
		} catch { return nil }
	}
	deinit { _ = closeOwnedObservations() }
	private static func signingLeaf(_ principal: SecCode) -> Data? {
		OwnedRuntimePublisherSignature.currentLeaf(principal, role: .installer)
	}
	func verifyForPlistCustody() throws {
		guard !closeAttempted, publisher.current(), getpid() == creator, getuid() == 0, geteuid() == 0, Self.signingLeaf(principal) == leaf,
			lifecycle.current(), lifecycle.permitsServiceProvision() else { throw OwnedRuntimeInstallFailure.principal }
		if let publicationParent {
			guard try publicationParent.withPublishedNamespace({ $0 === lifecycle }) else { throw OwnedRuntimeInstallFailure.principal }
		}
		try helper.verify(); try runtime.verify(); try payload.verify()
	}
	func fixedPlistBytes() throws -> Data {
		try verifyForPlistCustody(); return try Self.plistBytes()
	}
	private static func idleRevision(_ bytes: Data) -> Bool {
		guard let fields = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
			let revision = fields["ErgoptiOwnedCoreIdleAdmissionRevision"] as? String, revision == "1" else { return false }
		return true
	}
	private static func plistBytes() throws -> Data {
		let fields: [String: Any] = ["Label": "com.ergoptiplus.runtime.core", "ProgramArguments": [runtimeURL.path + "/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core"],
			"UserName": "root", "RunAtLoad": false, "KeepAlive": false]
		return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
	}
	/// Until native producer admission closes early auto-grab, first start requires actual global config absence.
	/// This is a refusal fence, never configuration, dependency or capture readiness authority.
	private static func configurationAbsent(parent: URL, protected: Bool) throws -> Bool {
		let tree = try OwnedRuntimeInstallTree(root: parent, protected: protected, includeChildren: false)
		let fd = try tree.duplicateRootDescriptor(); defer { Darwin.close(fd) }
		try tree.verifyAnchor(); var value = stat(); errno = 0
		let absent = fstatat(fd, "core.json", &value, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT
		try tree.verifyAnchor(); guard tree.releaseOwnedDescriptors() else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return absent
	}
	private static func prepareDirectories(parent: URL, protected: Bool, admission: () throws -> Void) throws {
		let tree = try OwnedRuntimeInstallTree(root: parent, protected: protected, includeChildren: false)
		let root = try tree.duplicateRootDescriptor()
		var rootOwned = true; defer { if rootOwned { Darwin.close(root) } }
		func directory(parent: Int32, name: String) throws -> Int32 {
			try admission(); try tree.verifyAnchor()
			let created = mkdirat(parent, name, 0o700) == 0
			if !created { guard errno == EEXIST else { throw OwnedRuntimeInstallFailure.copy } }
			let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard fd >= 0 else { throw OwnedRuntimeInstallFailure.protection }
			var owned = true; defer { if owned { Darwin.close(fd) } }
			if created { guard fchmod(fd, 0o755) == 0, fsync(fd) == 0, fsync(parent) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending } }
			var value = stat(), named = stat()
			guard fstat(fd, &value) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
				value.st_dev == named.st_dev, value.st_ino == named.st_ino,
				value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_mode & 0o6022 == 0,
				!protected || value.st_uid == 0 else { throw OwnedRuntimeInstallFailure.protection }
			guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { throw OwnedRuntimeInstallFailure.protection }
			defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?; errno = 0
			guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw OwnedRuntimeInstallFailure.protection }
			owned = false; return fd
		}
		let data = try directory(parent: root, name: "RemapRuntime")
		var dataOwned = true; defer { if dataOwned { Darwin.close(data) } }
		let dataTree = try OwnedRuntimeInstallTree(root: parent.appendingPathComponent("RemapRuntime"), protected: protected, includeChildren: false)
		func verifyData() throws {
			try tree.verifyAnchor(); try dataTree.verifyAnchor(); try admission()
			var held = stat(), named = stat()
			guard fstat(data, &held) == 0, fstatat(root, "RemapRuntime", &named, AT_SYMLINK_NOFOLLOW) == 0,
				held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw OwnedRuntimeInstallFailure.mutated }
		}
		for name in ["config", "tmp", "log"] {
			try verifyData()
			let fd = try directory(parent: data, name: name)
			guard Darwin.close(fd) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		}
		try verifyData()
		guard dataTree.releaseOwnedDescriptors() else { throw OwnedRuntimeInstallFailure.cleanupPending }
		dataOwned = false; guard Darwin.close(data) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		rootOwned = false; guard Darwin.close(root) == 0, tree.releaseOwnedDescriptors() else { throw OwnedRuntimeInstallFailure.cleanupPending }
	}
	private func requireConfigurationAbsence() throws {
		// Missing ancestors and denied observations refuse. They never become guessed ENOENT grants.
		guard try Self.configurationAbsent(parent: Self.dataURL.appendingPathComponent("config"), protected: true) else {
			throw OwnedRuntimeInstallFailure.source
		}
	}
	func provisionAndStartCore() throws -> OwnedRuntimeCoreServiceOwner {
		guard !Thread.isMainThread else { throw OwnedRuntimeInstallFailure.principal }
		lock.lock(); defer { lock.unlock() }
		guard !serviceTouched, !committed, custody == nil else { throw OwnedRuntimeInstallFailure.destination }
		try verifyForPlistCustody()
		let absent = try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", Self.target])
		guard absent.status == 113 else { throw OwnedRuntimeInstallFailure.destination }
		let custody = try OwnedRuntimeCorePlistCustody.createProduction(owner: self); self.custody = custody
		try custody.prepare()
		try Self.prepareDirectories(parent: Self.dataURL.deletingLastPathComponent(), protected: true, admission: { try self.verifyForPlistCustody() })
		try verifyForPlistCustody(); try requireConfigurationAbsence()
		guard custody.current() else { throw OwnedRuntimeInstallFailure.cleanupPending }
		serviceTouched = true
		let bootstrap = try OwnedRuntimeCoreLaunchctl.run(arguments: ["bootstrap", "system", "/Library/LaunchDaemons/com.ergoptiplus.runtime.core.plist"])
		guard bootstrap.status == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try verifyForPlistCustody(); try requireConfigurationAbsence()
		guard custody.current() else { throw OwnedRuntimeInstallFailure.cleanupPending }
		let start = try OwnedRuntimeCoreLaunchctl.run(arguments: ["kickstart", Self.target])
		guard start.status == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		// Real dynamic code, kernel birth, launchd observation and native exit monitor are required separately.
		let deadline = ProcessInfo.processInfo.systemUptime + 10
		var observed: OwnedRuntimeCoreServiceOwner?
		repeat {
			try verifyForPlistCustody(); guard custody.current() else { throw OwnedRuntimeInstallFailure.cleanupPending }
			observed = OwnedRuntimeCoreServiceOwner.acquire(afterProvision: self)
			if observed != nil { break }
			if ProcessInfo.processInfo.systemUptime >= deadline { throw OwnedRuntimeInstallFailure.cleanupPending }
			usleep(10_000)
		} while true
		guard let core = observed, core.startedCoreObservation(forProvision: self),
			custody.commitRegistered(core: core, owner: self) else { throw OwnedRuntimeInstallFailure.cleanupPending }
		committed = true; return core
	}
	/// A typed original owner supplies the same kernel EX custody; no second independent lock is acquired.
	func withCoreNamespace<T>(_ body: (OwnedRuntimeServiceLifecycleLock) throws -> T) throws -> T {
		lock.lock(); defer { lock.unlock() }
		guard serviceTouched, !committed, let custody, custody.current() else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try verifyForPlistCustody(); return try body(lifecycle)
	}
	/// Releases only this helper's completed provision observations, never the persistent idle Core process.
	func retireCommittedObservations() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if closeAttempted { return !closeRefused }
		guard committed else { return false }
		do { try verifyForPlistCustody(); return closeOwnedObservations() } catch { return false }
	}
	private func closeOwnedObservations() -> Bool {
		if closeAttempted { return !closeRefused }; closeAttempted = true
		if !helper.releaseOwnedDescriptors() { closeRefused = true }
		if !runtime.releaseOwnedDescriptors() { closeRefused = true }
		if !payload.releaseOwnedDescriptors() { closeRefused = true }
		if !publisher.retire() { closeRefused = true }
		if publicationParent == nil && !lifecycle.retire() { closeRefused = true }
		return !closeRefused
	}
	func rollbackUnregisteredPlist() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !serviceTouched, !committed, let custody else { return false }
		do { try verifyForPlistCustody(); return custody.rollbackUnregistered() } catch { return false }
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixturePrepareDirectories(parent: URL) throws { try prepareDirectories(parent: parent, protected: false, admission: {}) }
	static func fixtureIdleRevision(_ bytes: Data) -> Bool { idleRevision(bytes) }
	static func fixturePlist() throws -> Data { try plistBytes() }
	static func fixtureRollback(parent: URL, afterPin: (() throws -> Void)? = nil) throws -> Bool {
		try OwnedRuntimeCorePlistCustody.fixtureRollback(parent: parent, bytes: plistBytes(), restart: false, afterPin: afterPin)
	}
	static func fixtureRestartRollback(parent: URL, afterPin: (() throws -> Void)? = nil) throws -> Bool {
		try OwnedRuntimeCorePlistCustody.fixtureRollback(parent: parent, bytes: plistBytes(), restart: true, afterPin: afterPin)
	}
	static func fixtureConfigurationAbsent(parent: URL) throws -> Bool { try configurationAbsent(parent: parent, protected: false) }
	#endif
}

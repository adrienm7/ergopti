// Sources/ErgoptiPlus/OwnedRuntimeCorePlistCustody.swift
// Durable, exact-vnode custody for the fixed owned launchd plist, without guessing unknown-file ownership.
import CryptoKit
import Darwin
import Foundation

final class OwnedRuntimeCorePlistCustody {
	private static let name = "com.ergoptiplus.runtime.core.plist"
	private static let ledgerName = ".runtime-service-journal"
	private static let pending = Data("CORE_PLIST|1|pending\n".utf8)
	private let plistParent: OwnedRuntimeInstallTree, ledgerParent: OwnedRuntimeInstallTree
	private let plistDirectory: Int32, ledgerDirectory: Int32, ledger: Int32
	private let protected: Bool, bytes: Data, admission: () throws -> Void
	private let ledgerIdentity: stat
	private var file: Int32 = -1, fileIdentity: stat?, closed = false, closeRefused = false, removed = false
	private var ledgerBytes = Data()
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private final class InitializerRetirementObservation { var result: Bool? }
	private static let initializerObservationKey = "com.ergoptiplus.tests.core-plist-custody-initializer-retirement"
	private var initializerRetirementObservation: InitializerRetirementObservation?
	#endif
	private init(plistParentURL: URL, ledgerParentURL: URL, bytes: Data, protected: Bool, admission: @escaping () throws -> Void) throws {
		self.protected = protected; self.bytes = bytes; self.admission = admission
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation = Thread.current.threadDictionary[Self.initializerObservationKey] as? InitializerRetirementObservation
		#endif
		plistParent = try OwnedRuntimeInstallTree(root: plistParentURL, protected: protected, includeChildren: false)
		ledgerParent = try OwnedRuntimeInstallTree(root: ledgerParentURL, protected: protected, includeChildren: false)
		let acquiredPlistDirectory = try plistParent.duplicateRootDescriptor()
		plistDirectory = acquiredPlistDirectory
		var ledgerDirectory: Int32 = -1, ledger: Int32 = -1, openedFile: Int32 = -1, completed = false
		defer { if !completed { if openedFile >= 0 { Darwin.close(openedFile) }; if ledger >= 0 { Darwin.close(ledger) }; if ledgerDirectory >= 0 { Darwin.close(ledgerDirectory) }; Darwin.close(acquiredPlistDirectory) } }
		ledgerDirectory = try ledgerParent.duplicateRootDescriptor(); self.ledgerDirectory = ledgerDirectory
		try admission(); try plistParent.verifyAnchor(); try ledgerParent.verifyAnchor()
		// Refuse a foreign destination before creating a new transaction; existing debt still requires exact native recovery.
		var priorLedger = stat(); errno = 0
		let ledgerAbsent = fstatat(ledgerDirectory, Self.ledgerName, &priorLedger, AT_SYMLINK_NOFOLLOW) == -1
		if ledgerAbsent {
			guard errno == ENOENT else { throw OwnedRuntimeInstallFailure.cleanupPending }
			var priorPlist = stat(); errno = 0
			guard fstatat(plistDirectory, Self.name, &priorPlist, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
				throw OwnedRuntimeInstallFailure.destination
			}
		}
		ledger = openat(ledgerDirectory, Self.ledgerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		let created = ledger >= 0
		if !created {
			guard errno == EEXIST else { throw OwnedRuntimeInstallFailure.cleanupPending }
			ledger = openat(ledgerDirectory, Self.ledgerName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		}
		guard ledger >= 0, flock(ledger, LOCK_EX | LOCK_NB) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var identity = stat(); guard fstat(ledger, &identity) == 0 else { throw OwnedRuntimeInstallFailure.source }
		self.ledger = ledger; ledgerIdentity = identity
		completed = true // All stored properties are initialized; subsequent ledger/file debt belongs to deinit.
		if created {
			try writeLedger(Self.pending)
			guard fsync(ledgerDirectory) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		} else {
			try protection(ledger, identity, mode: 0o600)
			guard identity.st_size > 0, identity.st_size <= 256 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			ledgerBytes = try read(ledger, count: Int(identity.st_size))
			if ledgerBytes != Self.pending {
				guard let parsed = Self.parse(ledgerBytes, bytes: bytes) else { throw OwnedRuntimeInstallFailure.cleanupPending }
				openedFile = openat(plistDirectory, Self.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
				file = openedFile
				guard file >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
				var value = stat(); guard fstat(file, &value) == 0, UInt64(bitPattern: Int64(value.st_dev)) == parsed.0, UInt64(value.st_ino) == parsed.1 else {
					throw OwnedRuntimeInstallFailure.cleanupPending
				}
				fileIdentity = value
			}
		}
		try verifyLedger()
	}
	deinit {
		let acknowledged = closeOwnedDescriptors()
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation?.result = acknowledged
		#endif
	}
	private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
	private static func parse(_ data: Data, bytes: Data) -> (UInt64, UInt64)? {
		guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"), !text.contains("\0") else { return nil }
		let parts = text.dropLast().split(separator: "|", omittingEmptySubsequences: false)
		guard parts.count == 6, parts[0] == "CORE_PLIST", parts[1] == "1", parts[2] == "owned",
			parts[3].utf8.allSatisfy({ (48...57).contains($0) }), parts[4].utf8.allSatisfy({ (48...57).contains($0) }),
			let device = UInt64(parts[3]), let inode = UInt64(parts[4]), inode > 0,
			String(device) == parts[3], String(inode) == parts[4], parts[5] == Substring(digest(bytes)) else { return nil }
		return (device, inode)
	}
	private func protection(_ fd: Int32, _ value: stat, mode: mode_t) throws {
		guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_mode & 0o7777 == mode,
			value.st_nlink == 1, !protected || value.st_uid == 0 else { throw OwnedRuntimeInstallFailure.protection }
		guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { throw OwnedRuntimeInstallFailure.protection }
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		var entry: acl_entry_t?; errno = 0
		guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
			throw OwnedRuntimeInstallFailure.protection
		}
	}
	private func read(_ fd: Int32, count: Int) throws -> Data {
		var data = Data(count: count)
		guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == count else { throw OwnedRuntimeInstallFailure.source }
		return data
	}
	private func writeLedger(_ data: Data) throws {
		try verifyLedger()
		guard ftruncate(ledger, 0) == 0, data.withUnsafeBytes({ pwrite(ledger, $0.baseAddress, $0.count, 0) }) == data.count,
			fsync(ledger) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		ledgerBytes = data
		try verifyLedger()
	}
	private func verifyLedger() throws {
		guard !closed, !removed else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try admission(); try ledgerParent.verifyAnchor(); try plistParent.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(ledger, &held) == 0, fstatat(ledgerDirectory, Self.ledgerName, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == ledgerIdentity.st_dev, held.st_ino == ledgerIdentity.st_ino,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino, held.st_size == ledgerBytes.count,
			try read(ledger, count: ledgerBytes.count) == ledgerBytes else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try protection(ledger, held, mode: 0o600)
	}
	private func verifyFile() throws {
		try verifyLedger()
		guard let identity = fileIdentity, file >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var held = stat(), named = stat()
		guard fstat(file, &held) == 0, fstatat(plistDirectory, Self.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == identity.st_dev, held.st_ino == identity.st_ino, named.st_dev == held.st_dev, named.st_ino == held.st_ino,
			held.st_size == bytes.count, try read(file, count: bytes.count) == bytes else { throw OwnedRuntimeInstallFailure.mutated }
		try protection(file, held, mode: 0o644)
	}
	func prepare() throws {
		try verifyLedger()
		if fileIdentity != nil { try verifyFile(); return }
		var existing = stat(); errno = 0
		guard fstatat(plistDirectory, Self.name, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
			throw OwnedRuntimeInstallFailure.destination
		}
		file = openat(plistDirectory, Self.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard file >= 0 else { throw OwnedRuntimeInstallFailure.copy }
		var value = stat(); guard fstat(file, &value) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }; fileIdentity = value
		// Durable inode admission precedes the first plist byte. A crash before this record conservatively keeps unknown debt.
		try writeLedger(Data(("CORE_PLIST|1|owned|" + String(UInt64(bitPattern: Int64(value.st_dev))) + "|" + String(UInt64(value.st_ino)) + "|" + Self.digest(bytes) + "\n").utf8))
		guard bytes.withUnsafeBytes({ pwrite(file, $0.baseAddress, $0.count, 0) }) == bytes.count,
			fchmod(file, 0o644) == 0, fsync(file) == 0, fsync(plistDirectory) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try verifyFile()
	}
	func current() -> Bool { do { try verifyFile(); return true } catch { return false } }
	/// Called only before any service effect, or after the original Core process/job has actually retired.
	func rollbackUnregistered() -> Bool {
		do {
			try verifyLedger()
			if fileIdentity != nil {
				try verifyFile()
				guard unlinkat(plistDirectory, Self.name, 0) == 0, fsync(plistDirectory) == 0 else { return false }
			} else {
				var value = stat(); errno = 0
				guard fstatat(plistDirectory, Self.name, &value, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { return false }
			}
			return removeLedger()
		} catch { return false }
	}
	/// The caller holds its original authenticated Core observation before committing plist publication.
	func commitRegistered(core: OwnedRuntimeCoreServiceOwner, owner: OwnedRuntimeCoreProvisionOwner) -> Bool {
		guard core.startedCoreObservation(forProvision: owner) else { return false }
		do { try verifyFile(); return removeLedger() } catch { return false }
	}
	private func removeLedger() -> Bool {
		do {
			try verifyLedger()
			guard unlinkat(ledgerDirectory, Self.ledgerName, 0) == 0 else { return false }
			removed = true
			guard fsync(ledgerDirectory) == 0 else { return false }
			return closeOwnedDescriptors()
		} catch { return false }
	}
	private func closeOwnedDescriptors() -> Bool {
		if closed { return !closeRefused }; closed = true
		for fd in [file, ledger, plistDirectory, ledgerDirectory] where fd >= 0 { if Darwin.close(fd) != 0 { closeRefused = true } }
		if !plistParent.releaseOwnedDescriptors() { closeRefused = true }; if !ledgerParent.releaseOwnedDescriptors() { closeRefused = true }
		return !closeRefused
	}
	static func createProduction(owner: OwnedRuntimeCoreProvisionOwner) throws -> OwnedRuntimeCorePlistCustody {
		try OwnedRuntimeCorePlistCustody(plistParentURL: URL(fileURLWithPath: "/Library/LaunchDaemons"),
			ledgerParentURL: URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus"), bytes: try owner.fixedPlistBytes(), protected: true, admission: { [weak owner] in
				guard let owner else { throw OwnedRuntimeInstallFailure.principal }; try owner.verifyForPlistCustody()
			})
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Actual temporary descriptor/flock cleanup only; retained journal bytes never become authority.
	static func fixtureRejectedInitializerRetirement(parent: URL, rejectAt: Int) throws -> Bool? {
		guard (0...2).contains(rejectAt), Thread.current.threadDictionary[initializerObservationKey] == nil else { throw OwnedRuntimeInstallFailure.source }
		let observation = InitializerRetirementObservation()
		Thread.current.threadDictionary[initializerObservationKey] = observation
		defer { Thread.current.threadDictionary.removeObject(forKey: initializerObservationKey) }
		var admissions = 0
		do {
			let unexpected = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent, bytes: Data("fixture-plist".utf8), protected: false, admission: {
				admissions += 1
				if admissions == rejectAt { throw OwnedRuntimeInstallFailure.principal }
			})
			_ = unexpected.closeOwnedDescriptors(); throw OwnedRuntimeInstallFailure.destination
		} catch OwnedRuntimeInstallFailure.principal {
			guard admissions == rejectAt else { throw OwnedRuntimeInstallFailure.source }; return observation.result
		} catch OwnedRuntimeInstallFailure.cleanupPending {
			guard rejectAt == 0 else { throw OwnedRuntimeInstallFailure.source }; return observation.result
		}
	}
	static func fixtureRollback(parent: URL, bytes: Data, restart: Bool, afterPin: (() throws -> Void)?) throws -> Bool {
		do {
			var custody: OwnedRuntimeCorePlistCustody? = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent,
				bytes: bytes, protected: false, admission: {})
			try custody!.prepare(); try afterPin?()
			if restart {
				custody = nil
				custody = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent, bytes: bytes, protected: false, admission: {})
			}
			return custody!.rollbackUnregistered()
		} catch { return false }
	}
	#endif
}

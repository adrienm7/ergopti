// Sources/ErgoptiPlus/OwnedRuntimeCorePlistCustody.swift
// Durable, exact-vnode custody for the fixed owned launchd plist, without guessing unknown-file ownership.
import CryptoKit
import Darwin
import Foundation

final class OwnedRuntimeCorePlistCustody {
	/// One owned LaunchDaemon: its plist name, its durable ledger and the ledger's record tag.
	struct Job {
		let name: String, ledgerName: String, tag: String
		var pending: Data { Data((tag + "|1|pending\n").utf8) }
		static let core = Job(name: "\(Identifiers.ServiceLabels.macosCore).plist", ledgerName: ".runtime-service-journal", tag: "CORE_PLIST")
		/// The VirtualHIDDevice daemon job keeps its own ledger, so a Core debt never names its plist.
		static let virtualHID = Job(name: "\(Identifiers.ServiceLabels.macosVirtualHid).plist", ledgerName: ".runtime-vhid-service-journal", tag: "VHID_PLIST")
	}
	private let job: Job
	private let plistParent: OwnedRuntimeInstallTree, ledgerParent: OwnedRuntimeInstallTree
	private let plistDirectory: Int32, ledgerDirectory: Int32, ledger: Int32
	private let protected: Bool, bytes: Data, admission: () throws -> Void
	private let ledgerIdentity: stat
	private var file: Int32 = -1, fileIdentity: stat?, closed = false, closeRefused = false, removed = false
	/// The plist was already on disk with the exact bytes when this custody began (service repair), so a rollback
	/// gives it back instead of removing it. The ledger records it as `adopted`, which a restart reads back.
	private var adopted = false
	private var ledgerBytes = Data()
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private final class InitializerRetirementObservation { var result: Bool? }
	private static let initializerObservationKey = "com.ergoptiplus.tests.core-plist-custody-initializer-retirement"
	private var initializerRetirementObservation: InitializerRetirementObservation?
	#endif
	private init(job: Job = .core, plistParentURL: URL, ledgerParentURL: URL, bytes: Data, protected: Bool, adoptExisting: Bool = false,
		admission: @escaping () throws -> Void) throws {
		self.job = job; self.protected = protected; self.bytes = bytes; self.admission = admission
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation = Thread.current.threadDictionary[Self.initializerObservationKey] as? InitializerRetirementObservation
		#endif
		plistParent = try OwnedRuntimeInstallTree(root: plistParentURL, protected: protected, includeChildren: false)
		ledgerParent = try OwnedRuntimeInstallTree(root: ledgerParentURL, protected: protected, includeChildren: false)
		let acquiredPlistDirectory = try plistParent.duplicateRootDescriptor()
		plistDirectory = acquiredPlistDirectory
		var ledgerDirectory: Int32 = -1, ledger: Int32 = -1, openedFile: Int32 = -1, completed = false
		var adoptedIdentity: stat?
		defer { if !completed { if openedFile >= 0 { Darwin.close(openedFile) }; if ledger >= 0 { Darwin.close(ledger) }; if ledgerDirectory >= 0 { Darwin.close(ledgerDirectory) }; Darwin.close(acquiredPlistDirectory) } }
		ledgerDirectory = try ledgerParent.duplicateRootDescriptor(); self.ledgerDirectory = ledgerDirectory
		try admission(); try plistParent.verifyAnchor(); try ledgerParent.verifyAnchor()
		// Refuse a foreign destination before creating a new transaction; existing debt still requires exact native recovery.
		var priorLedger = stat(); errno = 0
		let ledgerAbsent = fstatat(ledgerDirectory, job.ledgerName, &priorLedger, AT_SYMLINK_NOFOLLOW) == -1
		if ledgerAbsent {
			guard errno == ENOENT else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
			var priorPlist = stat(); errno = 0
			if fstatat(plistDirectory, job.name, &priorPlist, AT_SYMLINK_NOFOLLOW) == -1 {
				guard errno == ENOENT else { throw OwnedRuntimeInstallFailure.traced(.destination) }
			} else {
				// Only a service repair adopts a present plist, and only the exact owned bytes, root-owned 0644 with no
				// ACL or second link: anything else stays untouched and refuses, as a first install does.
				guard adoptExisting else { throw OwnedRuntimeInstallFailure.traced(.destination) }
				openedFile = openat(plistDirectory, job.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
				guard openedFile >= 0 else { throw OwnedRuntimeInstallFailure.traced(.destination) }
				var held = stat()
				guard fstat(openedFile, &held) == 0, held.st_dev == priorPlist.st_dev, held.st_ino == priorPlist.st_ino,
					held.st_size == bytes.count else { throw OwnedRuntimeInstallFailure.traced(.destination) }
				try Self.requireProtection(openedFile, held, mode: 0o644, protected: protected)
				var present = Data(count: bytes.count)
				guard present.withUnsafeMutableBytes({ pread(openedFile, $0.baseAddress, $0.count, 0) }) == bytes.count,
					present == bytes else { throw OwnedRuntimeInstallFailure.traced(.destination) }
				adoptedIdentity = held
			}
		}
		ledger = openat(ledgerDirectory, job.ledgerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		let created = ledger >= 0
		if !created {
			// A ledger that appeared after the adoption check is another transaction's debt.
			guard errno == EEXIST, adoptedIdentity == nil else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
			ledger = openat(ledgerDirectory, job.ledgerName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
		}
		guard ledger >= 0, flock(ledger, LOCK_EX | LOCK_NB) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		var identity = stat(); guard fstat(ledger, &identity) == 0 else { throw OwnedRuntimeInstallFailure.traced(.source) }
		self.ledger = ledger; ledgerIdentity = identity
		completed = true // All stored properties are initialized; subsequent ledger/file debt belongs to deinit.
		if created, let held = adoptedIdentity {
			file = openedFile; fileIdentity = held; adopted = true
			try writeLedger(Self.record(tag: job.tag, state: Self.adoptedState, identity: held, bytes: bytes))
			guard fsync(ledgerDirectory) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
			try verifyFile()
		} else if created {
			try writeLedger(job.pending)
			guard fsync(ledgerDirectory) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		} else {
			try protection(ledger, identity, mode: 0o600)
			guard identity.st_size > 0, identity.st_size <= 256 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
			ledgerBytes = try read(ledger, count: Int(identity.st_size))
			if ledgerBytes != job.pending {
				guard let parsed = Self.parse(ledgerBytes, bytes: bytes, tag: job.tag) else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
				adopted = parsed.2
				openedFile = openat(plistDirectory, job.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
				file = openedFile
				guard file >= 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
				var value = stat(); guard fstat(file, &value) == 0, UInt64(bitPattern: Int64(value.st_dev)) == parsed.0, UInt64(value.st_ino) == parsed.1 else {
					throw OwnedRuntimeInstallFailure.traced(.cleanupPending)
				}
				fileIdentity = value
			}
		}
		try verifyLedger()
	}
	/// The ledger state of a plist this custody created, and of one a service repair adopted.
	private static let ownedState = "owned", adoptedState = "adopted"
	private static func record(tag: String, state: String, identity: stat, bytes: Data) -> Data {
		Data((tag + "|1|" + state + "|" + String(UInt64(bitPattern: Int64(identity.st_dev))) + "|" + String(UInt64(identity.st_ino))
			+ "|" + digest(bytes) + "\n").utf8)
	}
	deinit {
		let acknowledged = closeOwnedDescriptors()
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation?.result = acknowledged
		#endif
	}
	private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
	private static func parse(_ data: Data, bytes: Data, tag: String) -> (UInt64, UInt64, Bool)? {
		guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"), !text.contains("\0") else { return nil }
		let parts = text.dropLast().split(separator: "|", omittingEmptySubsequences: false)
		guard parts.count == 6, parts[0] == Substring(tag), parts[1] == "1",
			parts[2] == Substring(ownedState) || parts[2] == Substring(adoptedState),
			parts[3].utf8.allSatisfy({ (48...57).contains($0) }), parts[4].utf8.allSatisfy({ (48...57).contains($0) }),
			let device = UInt64(parts[3]), let inode = UInt64(parts[4]), inode > 0,
			String(device) == parts[3], String(inode) == parts[4], parts[5] == Substring(digest(bytes)) else { return nil }
		return (device, inode, parts[2] == Substring(adoptedState))
	}
	private func protection(_ fd: Int32, _ value: stat, mode: mode_t) throws {
		try Self.requireProtection(fd, value, mode: mode, protected: protected)
	}
	private static func requireProtection(_ fd: Int32, _ value: stat, mode: mode_t, protected: Bool) throws {
		guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_mode & 0o7777 == mode,
			value.st_nlink == 1, !protected || value.st_uid == 0 else { throw OwnedRuntimeInstallFailure.traced(.protection) }
		errno = 0
		if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
			defer { acl_free(UnsafeMutableRawPointer(acl)) }
			var entry: acl_entry_t?; errno = 0
			guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
				throw OwnedRuntimeInstallFailure.traced(.protection)
			}
		} else if errno != ENOENT { throw OwnedRuntimeInstallFailure.traced(.protection) } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
	}
	private func read(_ fd: Int32, count: Int) throws -> Data {
		var data = Data(count: count)
		guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, $0.count, 0) }) == count else { throw OwnedRuntimeInstallFailure.traced(.source) }
		return data
	}
	private func writeLedger(_ data: Data) throws {
		try verifyLedger()
		guard ftruncate(ledger, 0) == 0, data.withUnsafeBytes({ pwrite(ledger, $0.baseAddress, $0.count, 0) }) == data.count,
			fsync(ledger) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		ledgerBytes = data
		try verifyLedger()
	}
	private func verifyLedger() throws {
		guard !closed, !removed else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		try admission(); try ledgerParent.verifyAnchor(); try plistParent.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(ledger, &held) == 0, fstatat(ledgerDirectory, job.ledgerName, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == ledgerIdentity.st_dev, held.st_ino == ledgerIdentity.st_ino,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino, held.st_size == ledgerBytes.count,
			try read(ledger, count: ledgerBytes.count) == ledgerBytes else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		try protection(ledger, held, mode: 0o600)
	}
	private func verifyFile() throws {
		try verifyLedger()
		guard let identity = fileIdentity, file >= 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		var held = stat(), named = stat()
		guard fstat(file, &held) == 0, fstatat(plistDirectory, job.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == identity.st_dev, held.st_ino == identity.st_ino, named.st_dev == held.st_dev, named.st_ino == held.st_ino,
			held.st_size == bytes.count, try read(file, count: bytes.count) == bytes else { throw OwnedRuntimeInstallFailure.traced(.mutated) }
		try protection(file, held, mode: 0o644)
	}
	func prepare() throws {
		try verifyLedger()
		if fileIdentity != nil { try verifyFile(); return }
		var existing = stat(); errno = 0
		guard fstatat(plistDirectory, job.name, &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
			throw OwnedRuntimeInstallFailure.traced(.destination)
		}
		file = openat(plistDirectory, job.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard file >= 0 else { throw OwnedRuntimeInstallFailure.traced(.copy) }
		var value = stat(); guard fstat(file, &value) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }; fileIdentity = value
		// Durable inode admission precedes the first plist byte. A crash before this record conservatively keeps unknown debt.
		try writeLedger(Self.record(tag: job.tag, state: Self.ownedState, identity: value, bytes: bytes))
		guard bytes.withUnsafeBytes({ pwrite(file, $0.baseAddress, $0.count, 0) }) == bytes.count,
			fchmod(file, 0o644) == 0, fsync(file) == 0, fsync(plistDirectory) == 0 else { throw OwnedRuntimeInstallFailure.traced(.cleanupPending) }
		try verifyFile()
	}
	func current() -> Bool { do { try verifyFile(); return true } catch { return false } }
	/// Called only before any service effect, or after the original Core process/job has actually retired.
	func rollbackUnregistered() -> Bool {
		do {
			try verifyLedger()
			if fileIdentity != nil {
				try verifyFile()
				// An adopted plist was there before this custody: it stays, exactly as found.
				if !adopted { guard unlinkat(plistDirectory, job.name, 0) == 0, fsync(plistDirectory) == 0 else { return false } }
			} else {
				var value = stat(); errno = 0
				guard fstatat(plistDirectory, job.name, &value, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { return false }
			}
			return removeLedger()
		} catch { return false }
	}
	/// The caller holds its original authenticated Core observation before committing plist publication.
	func commitRegistered(core: OwnedRuntimeCoreServiceOwner, owner: OwnedRuntimeCoreProvisionOwner) -> Bool {
		guard core.startedCoreObservation(forProvision: owner) else { return false }
		do { try verifyFile(); return removeLedger() } catch { return false }
	}
	/// The VirtualHIDDevice daemon is pqrs' signed program, not an owned Core peer: its custody commits once
	/// launchd answers for the exact label the caller bootstrapped from this exact plist.
	func commitLoaded(_ loaded: OwnedRuntimeCoreLaunchctl.Observation) -> Bool {
		guard job.name == Job.virtualHID.name, loaded.status == 0 else { return false }
		do { try verifyFile(); return removeLedger() } catch { return false }
	}
	private func removeLedger() -> Bool {
		do {
			try verifyLedger()
			guard unlinkat(ledgerDirectory, job.ledgerName, 0) == 0 else { return false }
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
	static func createProduction(owner: OwnedRuntimeCoreProvisionOwner, adoptExisting: Bool = false) throws -> OwnedRuntimeCorePlistCustody {
		try OwnedRuntimeCorePlistCustody(plistParentURL: URL(fileURLWithPath: "/Library/LaunchDaemons"),
			ledgerParentURL: URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus"), bytes: try owner.fixedPlistBytes(), protected: true,
			adoptExisting: adoptExisting, admission: { [weak owner] in
				guard let owner else { throw OwnedRuntimeInstallFailure.traced(.principal) }; try owner.verifyForPlistCustody()
			})
	}
	/// The VirtualHIDDevice daemon job, admitted by the same Core provision custody that started the Core.
	static func createProductionVirtualHID(owner: OwnedRuntimeCoreProvisionOwner, bytes: Data, adoptExisting: Bool = false) throws -> OwnedRuntimeCorePlistCustody {
		try owner.verifyForPlistCustody()
		return try OwnedRuntimeCorePlistCustody(job: .virtualHID, plistParentURL: URL(fileURLWithPath: "/Library/LaunchDaemons"),
			ledgerParentURL: URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus"), bytes: bytes, protected: true,
			adoptExisting: adoptExisting, admission: { [weak owner] in
				guard let owner else { throw OwnedRuntimeInstallFailure.traced(.principal) }; try owner.verifyForPlistCustody()
			})
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Actual temporary descriptor/flock cleanup only; retained journal bytes never become authority.
	static func fixtureRejectedInitializerRetirement(parent: URL, rejectAt: Int) throws -> Bool? {
		guard (0...2).contains(rejectAt), Thread.current.threadDictionary[initializerObservationKey] == nil else { throw OwnedRuntimeInstallFailure.traced(.source) }
		let observation = InitializerRetirementObservation()
		Thread.current.threadDictionary[initializerObservationKey] = observation
		defer { Thread.current.threadDictionary.removeObject(forKey: initializerObservationKey) }
		var admissions = 0
		do {
			let unexpected = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent, bytes: Data("fixture-plist".utf8), protected: false, admission: {
				admissions += 1
				if admissions == rejectAt { throw OwnedRuntimeInstallFailure.traced(.principal) }
			})
			_ = unexpected.closeOwnedDescriptors(); throw OwnedRuntimeInstallFailure.traced(.destination)
		} catch OwnedRuntimeInstallFailure.principal {
			guard admissions == rejectAt else { throw OwnedRuntimeInstallFailure.traced(.source) }; return observation.result
		} catch OwnedRuntimeInstallFailure.cleanupPending {
			guard rejectAt == 0 else { throw OwnedRuntimeInstallFailure.traced(.source) }; return observation.result
		}
	}
	/// A service repair's custody over a fixture directory: adopts a present exact plist, then rolls back,
	/// optionally after a restart that must read the adoption back from the ledger.
	static func fixtureAdoptRollback(parent: URL, bytes: Data, restart: Bool) throws -> Bool {
		do {
			var custody: OwnedRuntimeCorePlistCustody? = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent,
				bytes: bytes, protected: false, adoptExisting: true, admission: {})
			try custody!.prepare()
			if restart {
				custody = nil
				custody = try OwnedRuntimeCorePlistCustody(plistParentURL: parent, ledgerParentURL: parent, bytes: bytes, protected: false, admission: {})
			}
			return custody!.rollbackUnregistered()
		} catch { return false }
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

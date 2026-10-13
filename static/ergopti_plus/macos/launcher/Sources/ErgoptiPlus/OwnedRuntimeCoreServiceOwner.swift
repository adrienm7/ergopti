// Sources/ErgoptiPlus/OwnedRuntimeCoreServiceOwner.swift
// Exact Core process/job retirement; static installation, GUI exit and job absence never grant runtime READY.
import CPOSIXCompatibility
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// This owner must execute on a dedicated privileged worker, independently of the resident Lua heartbeat.
final class OwnedRuntimeCoreServiceOwner {
	final class RetirementProof {
		private let owner: OwnedRuntimeCoreServiceOwner
		fileprivate init(owner: OwnedRuntimeCoreServiceOwner) { self.owner = owner }
		/// Holding this original owner keeps its native EX namespace custody. It is never whole-runtime STOPPED.
		func current() -> Bool { owner.coreRetiredObservation() }
	}
	private static let unknownServiceStatus: Int32 = 113
	private static let helperIdentifier = "com.ergoptiplus.app.runtime-installer"
	private static let label = "com.ergoptiplus.runtime.core"
	private static let target = "system/" + label
	private static let runtime = "/Library/Application Support/ErgoptiPlus/Runtime"
	private static let core = runtime + "/ErgoptiPlus-Remap-Core.app"
	private static let executable = core + "/Contents/MacOS/ErgoptiPlus-Remap-Core"
	private static let plist = "/Library/LaunchDaemons/" + label + ".plist"
	private let lock = NSRecursiveLock()
	private let publisher: OwnedRuntimePublisherIdentity
	private let principal: SecCode, code: SecCode, leaf: Data, pid: pid_t, seconds: UInt64, microseconds: UInt64
	private let helperTree: OwnedRuntimeInstallTree, runtimeTree: OwnedRuntimeInstallTree
	private let plistFile: OwnedRuntimeCoreServicePlist
	private var monitor: OwnedRuntimeCoreExitObservation?
	private var exited = false, requested = false, refused = false, observationClosed = false, observationCloseRefused = false
	private let lifecycle: OwnedRuntimeServiceLifecycleLock
	private let provisionParent: OwnedRuntimeCoreProvisionOwner?
	private init(publisher: OwnedRuntimePublisherIdentity, principal: SecCode, code: SecCode, leaf: Data, pid: pid_t, seconds: UInt64, microseconds: UInt64,
		helper: OwnedRuntimeInstallTree, runtime: OwnedRuntimeInstallTree, plist: OwnedRuntimeCoreServicePlist, lifecycle: OwnedRuntimeServiceLifecycleLock, provisionParent: OwnedRuntimeCoreProvisionOwner?) {
		self.publisher = publisher; self.principal = principal; self.code = code; self.leaf = leaf; self.pid = pid; self.seconds = seconds; self.microseconds = microseconds
		helperTree = helper; runtimeTree = runtime; plistFile = plist; self.lifecycle = lifecycle; self.provisionParent = provisionParent
	}
	deinit { _ = closeOwnedObservations() }

	/// No caller path, PID, code identifier, certificate or mock launchd receipt can construct this authority.
	static func acquire() -> OwnedRuntimeCoreServiceOwner? {
		guard !Thread.isMainThread else { return nil }
		guard let lifecycle = OwnedRuntimeServiceLifecycleLock.acquireExclusive() else { return nil }
		return acquireOriginalNamespace(lifecycle: lifecycle, provisionParent: nil)
	}
	/// Only an original protected provision owner may transfer the same held EX namespace; no Boolean/PID receipt.
	static func acquire(afterProvision owner: OwnedRuntimeCoreProvisionOwner) -> OwnedRuntimeCoreServiceOwner? {
		do { return try owner.withCoreNamespace { acquireOriginalNamespace(lifecycle: $0, provisionParent: owner) } } catch { return nil }
	}
	private static func acquireOriginalNamespace(lifecycle: OwnedRuntimeServiceLifecycleLock, provisionParent: OwnedRuntimeCoreProvisionOwner?) -> OwnedRuntimeCoreServiceOwner? {
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0, Bundle.main.bundleIdentifier == helperIdentifier,
			Bundle.main.bundleURL.pathExtension == "app" else { return nil }
		guard let publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller() else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let leaf = signedLeaf(principal, identifier: helperIdentifier), leaf == publisher.leaf,
			lifecycle.current() else { return nil }
		var completed = false; defer { if !completed && provisionParent == nil { _ = lifecycle.retire() } }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			let runtime = try OwnedRuntimeInstallTree(root: URL(fileURLWithPath: Self.runtime), protected: true)
			let plist = try OwnedRuntimeCoreServicePlist(path: Self.plist)
			try validatePlist(plist.bytes)
			let observation = try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", target])
			guard observation.status == 0, let text = String(data: observation.bytes, encoding: .utf8), let pid = parseJobPID(text) else { return nil }
			let before = ergopti_owned_program_observe(pid)
			guard before.error_code == 0, !before.nonlive, before.start_microseconds < 1_000_000,
				let code = coreCode(pid: pid, leaf: leaf) else { return nil }
			let after = ergopti_owned_program_observe(pid)
			guard after.error_code == 0, !after.nonlive, before.start_seconds == after.start_seconds,
				before.start_microseconds == after.start_microseconds else { return nil }
			let owner = OwnedRuntimeCoreServiceOwner(publisher: publisher, principal: principal, code: code, leaf: leaf, pid: pid,
				seconds: before.start_seconds, microseconds: before.start_microseconds, helper: helper, runtime: runtime, plist: plist, lifecycle: lifecycle, provisionParent: provisionParent)
			owner.lock.lock(); defer { owner.lock.unlock() }
			owner.monitor = OwnedRuntimeCoreExitObservation.attach(process: pid)
			guard owner.monitor != nil, try owner.current() else { return nil }
			completed = true; return owner
		} catch { return nil }
	}
	private static func signedLeaf(_ code: SecCode, identifier: String) -> Data? {
		guard let role = OwnedRuntimePublisherSignature.Role(rawValue: identifier) else { return nil }
		return OwnedRuntimePublisherSignature.currentLeaf(code, role: role)
	}
	private static func coreCode(pid: pid_t, leaf: Data) -> SecCode? {
		var code: SecCode?, staticCode: SecStaticCode?, path: CFURL?
		guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
			signedLeaf(code, identifier: "com.ergoptiplus.remap.core") == leaf,
			SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
			SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path,
			(path as URL).path == executable || (path as URL).path == core else { return nil }
		return code
	}
	private func current() throws -> Bool {
		guard !observationClosed, let monitor else { refused = true; return false }
		switch monitor.observe() {
		case .waiting: break
		case .exited: exited = true
		case .refused, .retired: refused = true
		}
		guard publisher.current(), !requested, !refused, !exited, getuid() == 0, geteuid() == 0,
			Self.signedLeaf(principal, identifier: Self.helperIdentifier) == leaf, lifecycle.current() else { return false }
		try helperTree.verify(); try runtimeTree.verify(); try plistFile.verify()
		let before = ergopti_owned_program_observe(pid)
		guard before.error_code == 0, !before.nonlive, before.start_seconds == seconds, before.start_microseconds == microseconds,
			Self.coreCode(pid: pid, leaf: leaf) != nil, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
		let job = try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", Self.target])
		guard job.status == 0, let text = String(data: job.bytes, encoding: .utf8), Self.parseJobPID(text) == pid else { return false }
		let after = ergopti_owned_program_observe(pid)
		return !exited && after.error_code == 0 && !after.nonlive && after.start_seconds == seconds && after.start_microseconds == microseconds
	}
	/// Core process/job currentness only. It is never capture/configuration/VirtualHID READY.
	func startedCoreObservation(forProvision owner: OwnedRuntimeCoreProvisionOwner) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard provisionParent === owner else { return false }
		do { return try current() } catch { return false }
	}
	/// Releases this helper's live Core observation only; the installed idle control service remains running.
	func retireStartedObservation(forProvision owner: OwnedRuntimeCoreProvisionOwner) -> Bool {
		lock.lock(); defer { lock.unlock() }
		if observationClosed { return provisionParent === owner && !observationCloseRefused }
		guard provisionParent === owner else { return false }
		do { guard try current() else { return false }; return closeOwnedObservations() } catch { return false }
	}
	private func closeOwnedObservations() -> Bool {
		if observationClosed { return !observationCloseRefused }; observationClosed = true
		if monitor?.retire() != true { observationCloseRefused = true }
		if !helperTree.releaseOwnedDescriptors() { observationCloseRefused = true }
		if !runtimeTree.releaseOwnedDescriptors() { observationCloseRefused = true }
		if !plistFile.retire() { observationCloseRefused = true }
		if !publisher.retire() { observationCloseRefused = true }
		if provisionParent == nil && !lifecycle.retire() { observationCloseRefused = true }
		return !observationCloseRefused
	}
	/// Requests retirement of this exact validated job, never signals a daemon or an unrelated stock backend.
	/// True means the owned launchctl child succeeded; it is not a process, capture or VHD retirement ACK.
	func requestRetirement() -> Bool {
		guard !Thread.isMainThread else { return false }
		lock.lock(); defer { lock.unlock() }
		do {
			guard try current() else { refused = true; return false }
			requested = true
			let result = try OwnedRuntimeCoreLaunchctl.run(arguments: ["bootout", Self.target])
			guard result.status == 0 else { refused = true; return false }
			return true
		} catch { refused = true; return false }
	}
	/// Produces only an exact Core process-and-job proof. Console/capture/broker cleanup must join separately.
	func retiredCore() -> RetirementProof? {
		guard coreRetiredObservation() else { return nil }
		return RetirementProof(owner: self)
	}
	private func coreRetiredObservation() -> Bool {
		guard !Thread.isMainThread else { return false }
		lock.lock(); defer { lock.unlock() }
		guard !observationClosed, let monitor else { refused = true; return false }
		switch monitor.observe() {
		case .exited: exited = true
		case .waiting: return false
		case .refused, .retired: refused = true; return false
		}
		guard publisher.current(), requested, !refused, exited, lifecycle.current(),
			Self.signedLeaf(principal, identifier: Self.helperIdentifier) == leaf else { return false }
		do {
			try helperTree.verify(); try runtimeTree.verify(); try plistFile.verify()
			let result = try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", Self.target])
			guard result.status == Self.unknownServiceStatus, monitor.retire() else { refused = true; return false }
			return true
		} catch { refused = true; return false }
	}
	private static func validatePlist(_ bytes: Data) throws {
		guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
			Set(fields.keys) == Set(["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "UserName"]),
			fields["Label"] as? String == label, fields["ProgramArguments"] as? [String] == [executable],
			fields["UserName"] as? String == "root", let run = fields["RunAtLoad"] as? NSNumber,
			CFGetTypeID(run) == CFBooleanGetTypeID(), !run.boolValue, let keep = fields["KeepAlive"] as? NSNumber,
			CFGetTypeID(keep) == CFBooleanGetTypeID(), !keep.boolValue else { throw OwnedRuntimeInstallFailure.source }
	}
	private static func parseJobPID(_ text: String) -> pid_t? {
		guard text.utf8.count <= 131_072, !text.contains("\0") else { return nil }
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard lines.first == target + " = {" else { return nil }
		var depth = 1, fields: [String: String] = [:], arguments: [String] = [], inArguments = false
		for line in lines.dropFirst() {
			if depth == 0 { guard line.isEmpty else { return nil }; continue }
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed == "}" { depth -= 1; if inArguments && depth == 1 { inArguments = false }; continue }
			if trimmed.hasSuffix(" = {") {
				if depth == 1 && trimmed == "arguments = {" {
					guard !fields.keys.contains("arguments") else { return nil }; fields["arguments"] = "present"; inArguments = true
				}
				depth += 1; guard depth <= 8 else { return nil }; continue
			}
			if inArguments && depth == 2 { arguments.append(trimmed); continue }
			if depth == 1, let split = trimmed.range(of: " = ") {
				let key = String(trimmed[..<split.lowerBound]), value = String(trimmed[split.upperBound...])
				if ["path", "state", "program", "pid"].contains(key) {
					guard fields[key] == nil else { return nil }; fields[key] = value
				}
			}
		}
		guard depth == 0, !inArguments, fields["path"] == plist, fields["state"] == "running", fields["program"] == executable,
			arguments == [executable], let value = fields["pid"], !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
			let pid = Int32(value), pid > 0 else { return nil }
		return pid
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixtureJobPID(_ text: String) -> pid_t? { parseJobPID(text) }
	/// Temporary file construction reports actual initialized-self cleanup; no service or protected-file owner escapes.
	static func fixtureRejectedServicePlistInitialization(file: URL) throws -> Bool? {
		try OwnedRuntimeCoreServicePlist.fixtureRejectedInitialization(file: file)
	}
	#endif
}

/// Holds only the fixed protected plist; arbitrary extra files never join its ownership.
private final class OwnedRuntimeCoreServicePlist {
	private let parent: OwnedRuntimeInstallTree, parentDescriptor: Int32, descriptor: Int32, name: String
	private let identity: stat
	private var closeAttempted = false, closeRefused = false
	let bytes: Data
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private final class InitializerRetirementObservation { var result: Bool? }
	private static let initializerObservationKey = "com.ergoptiplus.tests.core-service-plist-initializer-retirement"
	private var initializerRetirementObservation: InitializerRetirementObservation?
	#endif
	convenience init(path: String) throws {
		let url = URL(fileURLWithPath: path)
		try self.init(parent: OwnedRuntimeInstallTree(root: url.deletingLastPathComponent(), protected: true, includeChildren: false), name: url.lastPathComponent)
	}
	private init(parent: OwnedRuntimeInstallTree, name: String) throws {
		self.parent = parent; self.name = name
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation = Thread.current.threadDictionary[Self.initializerObservationKey] as? InitializerRetirementObservation
		#endif
		let acquiredParentDescriptor = try parent.duplicateRootDescriptor()
		parentDescriptor = acquiredParentDescriptor
		var opened: Int32 = -1, completed = false
		defer { if !completed { if opened >= 0 { Darwin.close(opened) }; Darwin.close(acquiredParentDescriptor) } }
		opened = openat(parentDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard opened >= 0 else { throw OwnedRuntimeInstallFailure.source }
		var value = stat(); guard fstat(opened, &value) == 0, value.st_size > 0, value.st_size <= 65_536 else { throw OwnedRuntimeInstallFailure.source }
		identity = value; descriptor = opened
		var data = Data(count: Int(value.st_size))
		guard data.withUnsafeMutableBytes({ pread(opened, $0.baseAddress, $0.count, 0) }) == data.count else { throw OwnedRuntimeInstallFailure.source }
		bytes = data
		completed = true // Initialized self owns both descriptors before any final verification can throw.
		try verify()
	}
	deinit {
		let acknowledged = retire()
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerRetirementObservation?.result = acknowledged
		#endif
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixtureRejectedInitialization(file: URL) throws -> Bool? {
		guard Thread.current.threadDictionary[initializerObservationKey] == nil else { throw OwnedRuntimeInstallFailure.source }
		let observation = InitializerRetirementObservation()
		Thread.current.threadDictionary[initializerObservationKey] = observation
		defer { Thread.current.threadDictionary.removeObject(forKey: initializerObservationKey) }
		do {
			let unexpected = try OwnedRuntimeCoreServicePlist(parent: OwnedRuntimeInstallTree(root: file.deletingLastPathComponent(), protected: false, includeChildren: false), name: file.lastPathComponent)
			_ = unexpected.retire(); throw OwnedRuntimeInstallFailure.destination
		} catch OwnedRuntimeInstallFailure.source { return observation.result }
		catch OwnedRuntimeInstallFailure.protection { return observation.result }
	}
	#endif
	func retire() -> Bool {
		if closeAttempted { return !closeRefused }; closeAttempted = true
		if Darwin.close(descriptor) != 0 { closeRefused = true }
		if Darwin.close(parentDescriptor) != 0 { closeRefused = true }
		if !parent.releaseOwnedDescriptors() { closeRefused = true }
		return !closeRefused
	}
	func verify() throws {
		guard !closeAttempted else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try parent.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0, fstatat(parentDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == identity.st_dev, held.st_ino == identity.st_ino, held.st_size == identity.st_size,
			held.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec, held.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
			held.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec, held.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino, held.st_uid == 0, named.st_uid == 0,
			held.st_nlink == 1, held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o6022 == 0 else {
			throw OwnedRuntimeInstallFailure.protection
		}
		guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { throw OwnedRuntimeInstallFailure.protection }
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		var entry: acl_entry_t?; errno = 0
		guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
			throw OwnedRuntimeInstallFailure.protection
		}
		var current = Data(count: bytes.count)
		guard current.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, $0.count, 0) }) == current.count, current == bytes else {
			throw OwnedRuntimeInstallFailure.mutated
		}
	}
}

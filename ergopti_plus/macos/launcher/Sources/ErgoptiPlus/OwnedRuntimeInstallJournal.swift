// Sources/ErgoptiPlus/OwnedRuntimeInstallJournal.swift
// Durable exact-vnode scratch custody survives helper exit without sweeping a directory or granting execution.
import CryptoKit
import Darwin
import Foundation
import Security

/// Dormant privileged role: packaging must provide this distinct minimal helper before production acquisition.
final class OwnedRuntimeInstallJournal {
	private static let identifier = "com.ergoptiplus.app.runtime-installer"
	private static let parentURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private static let journalName = ".runtime-install-journal"
	private struct Record: Codable {
		let kind: String
		let path: String?
		let device: UInt64?
		let inode: UInt64?
		let owner: UInt32?
		let directory: Bool?
		let leaf: String?
	}
	private struct Node {
		let path: String, device: UInt64, inode: UInt64, owner: UInt32, directory: Bool
	}
	private let lock = NSLock()
	private let parentTree: OwnedRuntimeInstallTree, parentDescriptor: Int32, descriptor: Int32
	private let journalIdentity: stat, leaf: String, protected: Bool
	private let admission: () throws -> Void
	private var nodes: [Node] = []
	private var stageName: String?
	private var publicationIntent = false
	private var retireIntent: String?
	private var removed = Set<String>()
	private var completed = false

	deinit { Darwin.close(descriptor); Darwin.close(parentDescriptor) }
	/// Only the executing, protected, signed minimal helper obtains this production authority.
	/// Returning a journal grants no service readiness, shipping receipt or administrator consent.
	static func acquire() -> OwnedRuntimeInstallJournal? {
		guard getuid() == 0, geteuid() == 0, Bundle.main.bundleIdentifier == identifier,
			Bundle.main.bundleURL.pathExtension == "app" else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let certificate = signingLeaf(principal) else { return nil }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			try helper.verify()
			let admission = {
				guard getuid() == 0, geteuid() == 0, signingLeaf(principal) == certificate else { throw OwnedRuntimeInstallFailure.principal }
				try helper.verify()
			}
			return try OwnedRuntimeInstallJournal(parent: parentURL, leaf: Data(SHA256.hash(data: certificate)).hex,
				protected: true, recover: true, admission: admission)
		} catch { return nil }
	}
	/// New transactions are admitted only when no durable previous owner occupies the fixed journal name.
	static func create() -> OwnedRuntimeInstallJournal? {
		guard getuid() == 0, geteuid() == 0, Bundle.main.bundleIdentifier == identifier,
			Bundle.main.bundleURL.pathExtension == "app" else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let certificate = signingLeaf(principal) else { return nil }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			try helper.verify()
			return try OwnedRuntimeInstallJournal(parent: parentURL, leaf: Data(SHA256.hash(data: certificate)).hex,
				protected: true, recover: false, admission: {
					guard getuid() == 0, geteuid() == 0, signingLeaf(principal) == certificate else { throw OwnedRuntimeInstallFailure.principal }
					try helper.verify()
				})
		} catch { return nil }
	}
	private static func signingLeaf(_ principal: SecCode) -> Data? {
		var code: SecStaticCode?, information: CFDictionary?
		let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
		guard SecCodeCheckValidity(principal, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
			SecCodeCopyStaticCode(principal, [], &code) == errSecSuccess, let code,
			SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess,
			SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier,
			let cms = fields[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
			let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first else { return nil }
		return SecCertificateCopyData(first) as Data
	}
	private init(parent: URL, leaf: String, protected: Bool, recover: Bool, admission: @escaping () throws -> Void) throws {
		self.leaf = leaf; self.protected = protected; self.admission = admission
		parentTree = try OwnedRuntimeInstallTree(root: parent, protected: protected, includeChildren: false)
		let acquiredParentDescriptor = try parentTree.duplicateRootDescriptor()
		parentDescriptor = acquiredParentDescriptor
		var initialized = false
		var opened: Int32 = -1
		defer { if !initialized { if opened >= 0 { Darwin.close(opened) }; Darwin.close(acquiredParentDescriptor) } }
		try admission(); try parentTree.verifyAnchor()
		opened = openat(parentDescriptor, Self.journalName,
			O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (recover ? 0 : O_CREAT | O_EXCL), 0o600)
		guard opened >= 0, flock(opened, LOCK_EX | LOCK_NB) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var held = stat(), named = stat()
		guard fstat(opened, &held) == 0, fstatat(parentDescriptor, Self.journalName, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino,
			held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_nlink == 1,
			held.st_mode & 0o7777 == 0o600, !protected || held.st_uid == 0 else { throw OwnedRuntimeInstallFailure.protection }
		try Self.emptyACL(opened)
		descriptor = opened; journalIdentity = held
		initialized = true // All stored properties are initialized; deinit now owns both descriptors.
		if recover { try load() }
		else { try append(Record(kind: "header-v2", path: nil, device: nil, inode: nil, owner: nil, directory: nil, leaf: leaf)) }
	}
	private static func emptyACL(_ descriptor: Int32) throws {
		errno = 0
		if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
			defer { acl_free(UnsafeMutableRawPointer(acl)) }
			var entry: acl_entry_t?; errno = 0
			guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
				errno == EINVAL else { throw OwnedRuntimeInstallFailure.protection }
		} else if errno != ENOENT { throw OwnedRuntimeInstallFailure.protection } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
	}
	private func verify() throws {
		guard !completed else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try admission(); try parentTree.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0, fstatat(parentDescriptor, Self.journalName, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == journalIdentity.st_dev, held.st_ino == journalIdentity.st_ino,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino, held.st_nlink == 1,
			held.st_uid == journalIdentity.st_uid, held.st_mode & 0o7777 == 0o600,
			held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw OwnedRuntimeInstallFailure.mutated }
		try Self.emptyACL(descriptor)
	}
	private func append(_ record: Record) throws {
		try verify()
		let data = try JSONEncoder().encode(record) + Data([10])
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= 1_048_576 - off_t(data.count),
			lseek(descriptor, 0, SEEK_END) >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var offset = 0
		try data.withUnsafeBytes { bytes in
			while offset < bytes.count {
				let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
				guard count > 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }; offset += count
			}
		}
		guard fsync(descriptor) == 0, fsync(parentDescriptor) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
	}
	private func load() throws {
		try verify()
		var info = stat(); guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= 1_048_576 else {
			throw OwnedRuntimeInstallFailure.cleanupPending
		}
		var data = Data(count: Int(info.st_size))
		let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
		guard count == data.count, data.last == 10 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		let lines = data.dropLast().split(separator: 10, omittingEmptySubsequences: false)
		guard !lines.isEmpty, lines.count <= 12_292 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		for (index, line) in lines.enumerated() {
			let bytes = Data(line)
			guard let keys = Self.closedKeys(bytes) else { throw OwnedRuntimeInstallFailure.cleanupPending }
			let record = try JSONDecoder().decode(Record.self, from: bytes)
			let expected: Set<String>
			switch record.kind {
			case "header-v2": expected = ["kind", "leaf"]
			case "created": expected = ["kind", "path", "device", "inode", "owner", "directory"]
			case "publication-intent": expected = ["kind"]
			case "retire-intent", "retired": expected = ["kind", "path"]
			default: throw OwnedRuntimeInstallFailure.cleanupPending
			}
			guard keys == expected else { throw OwnedRuntimeInstallFailure.cleanupPending }
			if index == 0 {
				guard record.kind == "header-v2", record.leaf == leaf else { throw OwnedRuntimeInstallFailure.principal }
				continue
			}
			try accept(record)
		}
		try verify()
	}
	/// Ledger records are flat closed scalar objects. Decode key strings before uniqueness checks,
	/// so escaped equivalent names cannot bypass duplicate rejection or field-set admission.
	private static func closedKeys(_ data: Data) -> Set<String>? {
		let bytes = Array(data)
		var cursor = 0, keys = Set<String>()
		func whitespace() { while cursor < bytes.count && [UInt8(9), 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
		func string() -> String? {
			guard cursor < bytes.count, bytes[cursor] == 34 else { return nil }
			let start = cursor; cursor += 1
			while cursor < bytes.count {
				let byte = bytes[cursor]
				if byte == 34 {
					cursor += 1
					return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
				}
				guard byte >= 32 else { return nil }
				if byte == 92 { cursor += 2 } else { cursor += 1 }
			}
			return nil
		}
		func scalar() -> Bool {
			guard cursor < bytes.count else { return false }
			if bytes[cursor] == 34 { return string() != nil }
			for literal in ["true", "false"] {
				let expected = Array(literal.utf8)
				if cursor <= bytes.count - expected.count, Array(bytes[cursor..<(cursor + expected.count)]) == expected {
					cursor += expected.count; return true
				}
			}
			guard (48...57).contains(bytes[cursor]) else { return false }
			let start = cursor
			while cursor < bytes.count && (48...57).contains(bytes[cursor]) { cursor += 1 }
			return bytes[start] != 48 || cursor == start + 1
		}
		whitespace(); guard cursor < bytes.count, bytes[cursor] == 123 else { return nil }; cursor += 1; whitespace()
		while cursor < bytes.count {
			guard let key = string(), keys.insert(key).inserted else { return nil }
			whitespace(); guard cursor < bytes.count, bytes[cursor] == 58 else { return nil }; cursor += 1; whitespace()
			guard scalar() else { return nil }; whitespace()
			guard cursor < bytes.count else { return nil }
			if bytes[cursor] == 125 { cursor += 1; whitespace(); return cursor == bytes.count ? keys : nil }
			guard bytes[cursor] == 44 else { return nil }; cursor += 1; whitespace()
		}
		return nil
	}
	private func accept(_ record: Record) throws {
		switch record.kind {
		case "created":
			guard !publicationIntent, retireIntent == nil, removed.isEmpty,
				let path = record.path, let device = record.device, let inode = record.inode, let owner = record.owner,
				let directory = record.directory, record.leaf == nil, nodes.count < 4096,
				!nodes.contains(where: { $0.path == path }), inode > 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			if nodes.isEmpty {
				guard directory, Self.stage(path) else { throw OwnedRuntimeInstallFailure.cleanupPending }; stageName = path
			} else {
				guard validRelative(path), nodes.contains(where: { $0.path == parentPath(path) && $0.directory }) else {
					throw OwnedRuntimeInstallFailure.cleanupPending
				}
			}
			nodes.append(Node(path: path, device: device, inode: inode, owner: owner, directory: directory))
		case "publication-intent":
			guard nodes.count > 0, !publicationIntent, removed.isEmpty, retireIntent == nil, record.path == nil,
				record.device == nil, record.inode == nil, record.owner == nil, record.directory == nil, record.leaf == nil else {
				throw OwnedRuntimeInstallFailure.cleanupPending
			}; publicationIntent = true
		case "retire-intent":
			guard !publicationIntent, retireIntent == nil, let path = record.path,
				let next = nodes.reversed().first(where: { !removed.contains($0.path) }), next.path == path,
				record.device == nil, record.inode == nil, record.owner == nil, record.directory == nil, record.leaf == nil else {
				throw OwnedRuntimeInstallFailure.cleanupPending
			}; retireIntent = path
		case "retired":
			guard let path = record.path, retireIntent == path, record.device == nil, record.inode == nil,
				record.owner == nil, record.directory == nil, record.leaf == nil else { throw OwnedRuntimeInstallFailure.cleanupPending }
			removed.insert(path); retireIntent = nil
		default: throw OwnedRuntimeInstallFailure.cleanupPending
		}
	}
	private static func stage(_ name: String) -> Bool {
		guard name.hasPrefix(".runtime-install-") else { return false }
		return UUID(uuidString: String(name.dropFirst(".runtime-install-".count))) != nil
	}
	private func validRelative(_ path: String) -> Bool {
		guard let stageName, path != stageName, path.hasPrefix(stageName + "/"), path.utf8.count <= 1024 else { return false }
		return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
			!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
		}
	}
	private func parentPath(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
	private func same(_ node: Node, _ value: stat) -> Bool {
		UInt64(UInt32(bitPattern: value.st_dev)) == node.device && UInt64(value.st_ino) == node.inode && value.st_uid == node.owner
			&& value.st_mode & mode_t(S_IFMT) == mode_t(node.directory ? S_IFDIR : S_IFREG)
			&& (node.directory || value.st_nlink == 1) && value.st_mode & 0o6022 == 0 && (!protected || value.st_uid == 0)
	}
	/// Opens only previously recorded exact directories from the held protected parent, never arbitrary paths.
	private func openParent(_ path: String) throws -> Int32 {
		let parts = path.split(separator: "/").dropLast().map(String.init)
		var descriptor = dup(parentDescriptor)
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		do {
			var prefix = ""
			for part in parts {
				prefix = prefix.isEmpty ? part : prefix + "/" + part
				guard let node = nodes.first(where: { $0.path == prefix && $0.directory }), !removed.contains(prefix) else {
					throw OwnedRuntimeInstallFailure.cleanupPending
				}
				let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
				guard next >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
				var held = stat(), named = stat()
				do {
					guard fstat(next, &held) == 0, fstatat(descriptor, part, &named, AT_SYMLINK_NOFOLLOW) == 0,
						same(node, held), same(node, named) else { throw OwnedRuntimeInstallFailure.mutated }
					try Self.emptyACL(next)
				} catch { Darwin.close(next); throw error }
				Darwin.close(descriptor); descriptor = next
			}
			return descriptor
		} catch { Darwin.close(descriptor); throw error }
	}
	func recordRoot(name: String, descriptor: Int32) throws {
		lock.lock(); defer { lock.unlock() }
		guard nodes.isEmpty, Self.stage(name) else { throw OwnedRuntimeInstallFailure.source }
		try record(path: name, descriptor: descriptor)
	}
	/// Record immediately after exclusive creation, before writing bytes or any publication effect.
	func recordCreated(relative: String, descriptor: Int32) throws {
		lock.lock(); defer { lock.unlock() }
		guard let stageName else { throw OwnedRuntimeInstallFailure.source }
		let path = stageName + "/" + relative
		guard validRelative(path) else { throw OwnedRuntimeInstallFailure.source }
		try record(path: path, descriptor: descriptor)
	}
	private func record(path: String, descriptor: Int32) throws {
		try verify()
		guard !publicationIntent, retireIntent == nil, removed.isEmpty, !nodes.contains(where: { $0.path == path }) else {
			throw OwnedRuntimeInstallFailure.cleanupPending
		}
		let parent = try openParent(path); defer { Darwin.close(parent) }
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0, fstatat(parent, String(path.split(separator: "/").last!), &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw OwnedRuntimeInstallFailure.mutated }
		let directory = held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
		let node = Node(path: path, device: UInt64(UInt32(bitPattern: held.st_dev)), inode: UInt64(held.st_ino), owner: held.st_uid, directory: directory)
		guard same(node, held), same(node, named), directory || held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
			throw OwnedRuntimeInstallFailure.protection
		}
		try Self.emptyACL(descriptor)
		let record = Record(kind: "created", path: path, device: node.device, inode: node.inode, owner: node.owner, directory: directory, leaf: nil)
		guard fsync(parent) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try append(record); try accept(record)
	}
	/// Must become durable before rename. Recovery never rolls back any transaction that crossed this boundary.
	func beginPublication() throws {
		lock.lock(); defer { lock.unlock() }
		guard !nodes.isEmpty, !publicationIntent, retireIntent == nil, removed.isEmpty else { throw OwnedRuntimeInstallFailure.cleanupPending }
		let record = Record(kind: "publication-intent", path: nil, device: nil, inode: nil, owner: nil, directory: nil, leaf: nil)
		try append(record); try accept(record)
	}
	/// Only the real protected helper entry may discharge a published transaction.
	/// This is a file-publication acknowledgment, never service/physical-source readiness.
	func finishPublished() throws {
		guard protected else { throw OwnedRuntimeInstallFailure.principal }
		try finishPublication()
	}
	private func finishPublication() throws {
		lock.lock(); defer { lock.unlock() }
		try verify()
		guard publicationIntent, removed.isEmpty, retireIntent == nil, let stageName,
			let root = nodes.first, root.path == stageName, root.directory else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var absent = stat(); errno = 0
		guard fstatat(parentDescriptor, stageName, &absent, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
			throw OwnedRuntimeInstallFailure.cleanupPending
		}
		let publishedRoot = openat(parentDescriptor, "Runtime", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		guard publishedRoot >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }; defer { Darwin.close(publishedRoot) }
		var currentRoot = stat(), namedRoot = stat()
		guard fstat(publishedRoot, &currentRoot) == 0, fstatat(parentDescriptor, "Runtime", &namedRoot, AT_SYMLINK_NOFOLLOW) == 0,
			same(root, currentRoot), same(root, namedRoot) else { throw OwnedRuntimeInstallFailure.mutated }
		try Self.emptyACL(publishedRoot)
		// Traverse each recorded ancestor via native no-follow descriptors. Every leaf remains the created inode.
		for node in nodes.dropFirst() {
			let relative = String(node.path.dropFirst(stageName.count + 1))
			let parts = relative.split(separator: "/").map(String.init)
			var parent = fcntl(publishedRoot, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
			guard parent >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			do {
				var prefix = stageName
				for (index, part) in parts.enumerated() {
					prefix += "/" + part
					guard let recorded = nodes.first(where: { $0.path == prefix }) else { throw OwnedRuntimeInstallFailure.cleanupPending }
					let last = index == parts.count - 1
					guard last || recorded.directory else { throw OwnedRuntimeInstallFailure.cleanupPending }
					let next = openat(parent, part, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (recorded.directory ? O_DIRECTORY : 0))
					guard next >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
					var held = stat(), named = stat()
					do {
						guard fstat(next, &held) == 0, fstatat(parent, part, &named, AT_SYMLINK_NOFOLLOW) == 0,
							same(recorded, held), same(recorded, named) else { throw OwnedRuntimeInstallFailure.mutated }
						try Self.emptyACL(next)
					} catch { Darwin.close(next); throw error }
					Darwin.close(parent); parent = next
				}
				Darwin.close(parent)
			} catch { Darwin.close(parent); throw error }
		}
		try verify()
		guard fstatat(parentDescriptor, "Runtime", &namedRoot, AT_SYMLINK_NOFOLLOW) == 0, same(root, namedRoot),
			fsync(parentDescriptor) == 0, unlinkat(parentDescriptor, Self.journalName, 0) == 0,
			fsync(parentDescriptor) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		completed = true
	}
	/// Removes only an unpublished recorded namespace. No service retirement or execution absence is inferred.
	func retireUnpublished() throws {
		lock.lock(); defer { lock.unlock() }
		try verify()
		guard !publicationIntent, !nodes.isEmpty else { throw OwnedRuntimeInstallFailure.cleanupPending }
		for node in nodes.reversed() where !removed.contains(node.path) {
			let parent = try openParent(node.path); defer { Darwin.close(parent) }
			if retireIntent == nil {
				let intent = Record(kind: "retire-intent", path: node.path, device: nil, inode: nil, owner: nil, directory: nil, leaf: nil)
				try append(intent); try accept(intent)
			}
			guard retireIntent == node.path else { throw OwnedRuntimeInstallFailure.cleanupPending }
			try verify()
			let name = String(node.path.split(separator: "/").last!)
			var named = stat(); errno = 0
			let result = fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW)
			if result == 0 {
				guard same(node, named) else { throw OwnedRuntimeInstallFailure.mutated }
				let heldDescriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (node.directory ? O_DIRECTORY : 0))
				guard heldDescriptor >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
				defer { Darwin.close(heldDescriptor) }
				var held = stat(), rechecked = stat()
				guard fstat(heldDescriptor, &held) == 0, same(node, held) else { throw OwnedRuntimeInstallFailure.mutated }
				try Self.emptyACL(heldDescriptor); try verify()
				guard fstatat(parent, name, &rechecked, AT_SYMLINK_NOFOLLOW) == 0, same(node, rechecked),
					unlinkat(parent, name, node.directory ? AT_REMOVEDIR : 0) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			} else { guard errno == ENOENT else { throw OwnedRuntimeInstallFailure.cleanupPending } }
			guard fsync(parent) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			let done = Record(kind: "retired", path: node.path, device: nil, inode: nil, owner: nil, directory: nil, leaf: nil)
			try append(done); try accept(done)
		}
		try verify()
		guard unlinkat(parentDescriptor, Self.journalName, 0) == 0, fsync(parentDescriptor) == 0 else {
			throw OwnedRuntimeInstallFailure.cleanupPending
		}; completed = true
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Native fixture completion grants no production helper/publication authority.
	func fixtureFinishPublished() throws { try finishPublication() }
	/// Private native filesystem controls use no SecCode principal and cannot construct the production entry.
	static func fixtureCreate(parent: URL) throws -> OwnedRuntimeInstallJournal {
		try OwnedRuntimeInstallJournal(parent: parent, leaf: "fixture-only", protected: false, recover: false, admission: {})
	}
	static func fixtureRecover(parent: URL, foreignLeaf: Bool = false) throws -> OwnedRuntimeInstallJournal {
		try OwnedRuntimeInstallJournal(parent: parent, leaf: foreignLeaf ? "foreign-fixture" : "fixture-only", protected: false, recover: true, admission: {})
	}
	#endif
}

private extension Data {
	var hex: String { map { String(format: "%02x", $0) }.joined() }
}

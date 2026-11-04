// Sources/ErgoptiPlus/OwnedRuntimeInstallWorker.swift
// Protected first-install publication; no launch, privilege acquisition or active-service retirement.
import CryptoKit
import Darwin
import Foundation

/// Errors keep publication refusal separate from custody that still needs cleanup.
enum OwnedRuntimeInstallFailure: Error, Equatable {
	case principal, source, protection, mutated, destination, copy, signature, cleanupPending
}

/// A scratch owns only vnodes created with exclusive native operations; cleanup never walks unknown children.
final class OwnedRuntimeInstallScratch {
	private struct Node {
		let descriptor: Int32, parent: Int32, name: String, relative: String, identity: stat
		let directory: Bool
	}
	private let parentTree: OwnedRuntimeInstallTree
	private let parentDescriptor: Int32
	private var nodes: [Node] = []
	private var directories: [String: Int32] = [:]
	private var published = false
	private let afterCreation: ((String, Int32) throws -> Void)?
	init(destination: URL, protected: Bool, afterCreation: ((String, Int32) throws -> Void)? = nil) throws {
		self.afterCreation = afterCreation
		parentTree = try OwnedRuntimeInstallTree(root: destination.deletingLastPathComponent(), protected: protected, includeChildren: false)
		parentDescriptor = try parentTree.duplicateRootDescriptor()
		var completed = false
		defer { if !completed { Darwin.close(parentDescriptor); for node in nodes { Darwin.close(node.descriptor) } } }
		let name = destination.lastPathComponent
		guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
			mkdirat(parentDescriptor, name, 0o755) == 0 else { throw OwnedRuntimeInstallFailure.destination }
		try retain(parent: parentDescriptor, name: name, relative: "", directory: true)
		completed = true
	}
	deinit { for node in nodes { Darwin.close(node.descriptor) }; Darwin.close(parentDescriptor) }
	private func retain(parent: Int32, name: String, relative: String, directory: Bool, opened: Int32? = nil) throws {
		let descriptor = opened ?? openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0 else { Darwin.close(descriptor); throw OwnedRuntimeInstallFailure.cleanupPending }
		nodes.append(Node(descriptor: descriptor, parent: parent, name: name, relative: relative, identity: held, directory: directory))
		guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino,
			held.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
			directory || held.st_nlink == 1 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		try afterCreation?(relative, descriptor)
		if directory { directories[relative] = descriptor }
	}
	private func location(_ relative: String) throws -> (Int32, String) {
		let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
			let parent = directories[parts.dropLast().joined(separator: "/")] else { throw OwnedRuntimeInstallFailure.copy }
		return (parent, parts.last!)
	}
	func directory(_ relative: String) throws {
		let (parent, name) = try location(relative)
		guard mkdirat(parent, name, 0o755) == 0 else { throw OwnedRuntimeInstallFailure.copy }
		try retain(parent: parent, name: name, relative: relative, directory: true)
	}
	func file(_ relative: String, data: Data, executable: mode_t) throws {
		let (parent, name) = try location(relative)
		let descriptor = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.copy }
		try retain(parent: parent, name: name, relative: relative, directory: false, opened: descriptor)
		var offset = 0
		try data.withUnsafeBytes { buffer in
			while offset < buffer.count {
				let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
				guard count > 0 else { throw OwnedRuntimeInstallFailure.copy }; offset += count
			}
		}
		guard fchmod(descriptor, 0o644 | executable) == 0, fsync(descriptor) == 0 else { throw OwnedRuntimeInstallFailure.copy }
	}
	/// Native publication uses the same retained parent and exact still-named created root.
	func publishRuntime() throws {
		guard !published, let root = nodes.first else { throw OwnedRuntimeInstallFailure.destination }
		try parentTree.verifyAnchor()
		var held = stat(), named = stat()
		guard fstat(root.descriptor, &held) == 0, fstatat(parentDescriptor, root.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == root.identity.st_dev, held.st_ino == root.identity.st_ino,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw OwnedRuntimeInstallFailure.mutated }
		guard renameatx_np(parentDescriptor, root.name, parentDescriptor, "Runtime", UInt32(RENAME_EXCL)) == 0 else {
			throw OwnedRuntimeInstallFailure.destination
		}
		published = true
	}
	/// Retry keeps unretired exact custody; changed names and foreign children refuse rather than get deleted.
	func retire() -> Bool {
		guard !published else { return false }
		do { try parentTree.verifyAnchor() } catch { return false }
		while let node = nodes.last {
			var held = stat(), named = stat()
			guard fstat(node.descriptor, &held) == 0, fstatat(node.parent, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
				held.st_dev == node.identity.st_dev, held.st_ino == node.identity.st_ino,
				named.st_dev == held.st_dev, named.st_ino == held.st_ino, named.st_uid == node.identity.st_uid,
				named.st_mode & mode_t(S_IFMT) == mode_t(node.directory ? S_IFDIR : S_IFREG),
				node.directory || named.st_nlink == 1 else { return false }
			guard unlinkat(node.parent, node.name, node.directory ? AT_REMOVEDIR : 0) == 0 else { return false }
			Darwin.close(node.descriptor); nodes.removeLast(); directories[node.relative] = nil
		}
		return fsync(parentDescriptor) == 0
	}
}

/// Retains exact no-follow files, their bytes and every ancestor until publication completes.
final class OwnedRuntimeInstallTree {
	private struct Entry {
		let relative: String, descriptor: Int32, parent: Int32, name: String
		let observed: stat, directory: Bool, digest: Data?
	}
	private let root: URL
	private let protected: Bool
	private var entries: [Entry] = []
	private var ancestors: [Int32] = []
	private var ancestorNames: [(parent: Int32, name: String, observed: stat)] = []
	private var byteCount = 0
	private var descriptorsClosed = false
	private var descriptorCloseRefused = false
	init(root: URL, protected: Bool, includeChildren: Bool = true) throws {
		self.root = root; self.protected = protected
		var completed = false
		defer { if !completed { closeDescriptors() } }
		try pinRoot()
		guard let held = entries.first else { throw OwnedRuntimeInstallFailure.source }
		if includeChildren { try descend(held) }
		try verify(); completed = true
	}
	deinit { closeDescriptors() }
	@discardableResult
	private func closeDescriptors() -> Bool {
		guard !descriptorsClosed else { return !descriptorCloseRefused }; descriptorsClosed = true
		for entry in entries.reversed() { if Darwin.close(entry.descriptor) != 0 { descriptorCloseRefused = true } }
		for descriptor in ancestors.reversed() { if Darwin.close(descriptor) != 0 { descriptorCloseRefused = true } }
		return !descriptorCloseRefused
	}
	/// Closes each owned descriptor once. Unknown native close debt is retained without numeric-FD retries.
	func releaseOwnedDescriptors() -> Bool { closeDescriptors() }
	private func same(_ a: stat, _ b: stat) -> Bool {
		a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
			&& a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
			&& a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
			&& a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
	}
	private func protection(_ descriptor: Int32, _ value: stat) throws {
		guard value.st_mode & 0o022 == 0, value.st_mode & 0o6000 == 0,
			!protected || value.st_uid == 0 else { throw OwnedRuntimeInstallFailure.protection }
		try aclProtection(descriptor)
	}
	private func aclProtection(_ descriptor: Int32) throws {
		errno = 0
		guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
			if errno == ENOENT { return } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
			throw OwnedRuntimeInstallFailure.protection
		}
		defer { acl_free(UnsafeMutableRawPointer(acl)) }
		guard acl_valid(acl) == 0 else { throw OwnedRuntimeInstallFailure.protection }
		var entry: acl_entry_t?; errno = 0
		let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry), observedError = errno
		guard result == -1, observedError == EINVAL else { throw OwnedRuntimeInstallFailure.protection }
	}
	private func pinRoot() throws {
		guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"), !root.path.contains("//") else {
			throw OwnedRuntimeInstallFailure.source
		}
		let parts = root.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw OwnedRuntimeInstallFailure.source }
		var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
		guard parent >= 0 else { throw OwnedRuntimeInstallFailure.source }
		ancestors.append(parent)
		for part in parts {
			var named = stat(), observed = stat()
			guard fstatat(parent, part, &named, AT_SYMLINK_NOFOLLOW) == 0, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
				throw OwnedRuntimeInstallFailure.source
			}
			let descriptor = openat(parent, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
			ancestors.append(descriptor)
			guard fstat(descriptor, &observed) == 0, same(named, observed) else { throw OwnedRuntimeInstallFailure.mutated }
			if protected { try protection(descriptor, observed) }
			ancestorNames.append((parent: parent, name: part, observed: observed))
			parent = descriptor
		}
		// A separate root descriptor gives the root node normal recursive custody.
		let descriptor = dup(parent)
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
		var observed = stat(); guard fstat(descriptor, &observed) == 0 else { Darwin.close(descriptor); throw OwnedRuntimeInstallFailure.source }
		entries.append(Entry(relative: "", descriptor: descriptor, parent: ancestors[ancestors.count - 2],
			name: parts.last!, observed: observed, directory: true, digest: nil))
		try protection(descriptor, observed)
	}
	private func bytes(_ descriptor: Int32, size: off_t) throws -> Data {
		guard size >= 0, size <= 268_435_456 else { throw OwnedRuntimeInstallFailure.source }
		var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536), offset: off_t = 0
		while offset < size {
			let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, min($0.count, Int(size - offset)), offset) }
			guard count > 0 else { throw OwnedRuntimeInstallFailure.source }
			output.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
		}
		return output
	}
	private func descend(_ parent: Entry) throws {
		let path = parent.relative.isEmpty ? root : root.appendingPathComponent(parent.relative)
		let names = try FileManager.default.contentsOfDirectory(atPath: path.path).sorted()
		for name in names {
			guard entries.count < 4096, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
				throw OwnedRuntimeInstallFailure.source
			}
			var named = stat(), observed = stat()
			guard fstatat(parent.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnedRuntimeInstallFailure.source }
			let directory = named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
			guard directory || (named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && named.st_nlink == 1) else {
				throw OwnedRuntimeInstallFailure.source
			}
			let descriptor = openat(parent.descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
			// Retain before any throwing validation; rejected entries still close their exact FD.
			let relative = parent.relative.isEmpty ? name : parent.relative + "/" + name
			entries.append(Entry(relative: relative, descriptor: descriptor, parent: parent.descriptor, name: name,
				observed: named, directory: directory, digest: nil))
			guard fstat(descriptor, &observed) == 0, same(named, observed) else { throw OwnedRuntimeInstallFailure.mutated }
			try protection(descriptor, observed)
			var digest: Data?
			if !directory {
				let data = try bytes(descriptor, size: observed.st_size); byteCount += data.count
				guard byteCount <= 536_870_912 else { throw OwnedRuntimeInstallFailure.source }
				digest = Data(SHA256.hash(data: data))
			}
			let held = Entry(relative: relative, descriptor: descriptor, parent: parent.descriptor, name: name,
				observed: observed, directory: directory, digest: digest)
			entries[entries.count - 1] = held
			if directory { try descend(held) }
		}
	}
	func verifyAnchor() throws {
		guard !descriptorsClosed else { throw OwnedRuntimeInstallFailure.cleanupPending }
		guard let root = entries.first else { throw OwnedRuntimeInstallFailure.source }
		var held = stat(), named = stat()
		guard fstat(root.descriptor, &held) == 0, fstatat(root.parent, root.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == root.observed.st_dev, held.st_ino == root.observed.st_ino,
			named.st_dev == held.st_dev, named.st_ino == held.st_ino,
			held.st_mode == root.observed.st_mode, held.st_uid == root.observed.st_uid,
			held.st_gid == root.observed.st_gid else { throw OwnedRuntimeInstallFailure.mutated }
		try protection(root.descriptor, held)
		for descriptor in ancestors {
			var current = stat()
			guard fstat(descriptor, &current) == 0 else { throw OwnedRuntimeInstallFailure.mutated }
			if protected { try protection(descriptor, current) }
			else { try aclProtection(descriptor) }
		}
		for ancestor in ancestorNames {
			var current = stat()
			guard fstatat(ancestor.parent, ancestor.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
				current.st_dev == ancestor.observed.st_dev, current.st_ino == ancestor.observed.st_ino,
				current.st_mode == ancestor.observed.st_mode, current.st_uid == ancestor.observed.st_uid,
				current.st_gid == ancestor.observed.st_gid else { throw OwnedRuntimeInstallFailure.mutated }
		}
	}
	func verify() throws {
		guard !descriptorsClosed else { throw OwnedRuntimeInstallFailure.cleanupPending }
		for ancestor in ancestorNames {
			var named = stat()
			guard fstatat(ancestor.parent, ancestor.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
				named.st_dev == ancestor.observed.st_dev, named.st_ino == ancestor.observed.st_ino,
				named.st_mode == ancestor.observed.st_mode, named.st_uid == ancestor.observed.st_uid,
				named.st_gid == ancestor.observed.st_gid else { throw OwnedRuntimeInstallFailure.mutated }
		}
		for descriptor in ancestors {
			var current = stat(); guard fstat(descriptor, &current) == 0 else { throw OwnedRuntimeInstallFailure.mutated }
			if protected { try protection(descriptor, current) }
		}
		for entry in entries {
			var current = stat(), named = stat()
			guard fstat(entry.descriptor, &current) == 0, fstatat(entry.parent, entry.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
				same(entry.observed, current), same(entry.observed, named) else { throw OwnedRuntimeInstallFailure.mutated }
			try protection(entry.descriptor, current)
			if let digest = entry.digest {
				guard Data(SHA256.hash(data: try bytes(entry.descriptor, size: current.st_size))) == digest else { throw OwnedRuntimeInstallFailure.mutated }
			}
		}
	}
	func synchronize() throws {
		try verify()
		for entry in entries.reversed() where entry.directory {
			guard fsync(entry.descriptor) == 0 else { throw OwnedRuntimeInstallFailure.copy }
		}
	}
	func matchesBytes(of other: OwnedRuntimeInstallTree) throws -> Bool {
		try verify(); try other.verify()
		guard entries.count == other.entries.count else { return false }
		return zip(entries, other.entries).allSatisfy { source, target in
			source.relative == target.relative && source.directory == target.directory && source.digest == target.digest
		}
	}
	func duplicateRootDescriptor() throws -> Int32 {
		guard !descriptorsClosed else { throw OwnedRuntimeInstallFailure.cleanupPending }
		guard let root = entries.first else { throw OwnedRuntimeInstallFailure.source }
		let descriptor = fcntl(root.descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
		return descriptor
	}
	func copy(into destination: URL, custody: ((OwnedRuntimeInstallScratch) -> Void)? = nil,
		afterCreatedFile: ((URL) throws -> Void)? = nil,
		afterCreation: ((String, Int32) throws -> Void)? = nil) throws {
		try verify()
		let scratch = try OwnedRuntimeInstallScratch(destination: destination, protected: protected, afterCreation: afterCreation)
		custody?(scratch)
		for entry in entries.dropFirst() {
			if entry.directory { try scratch.directory(entry.relative) }
			else {
				try scratch.file(entry.relative, data: bytes(entry.descriptor, size: entry.observed.st_size),
					executable: entry.observed.st_mode & 0o111)
				try afterCreatedFile?(destination.appendingPathComponent(entry.relative))
			}
		}
		try verify()
		let copied = try OwnedRuntimeInstallTree(root: destination, protected: protected)
		guard try matchesBytes(of: copied) else { throw OwnedRuntimeInstallFailure.copy }
		try copied.synchronize()
	}

}

/// The worker has no arbitrary caller-controlled installation paths or administrative fallback.
enum OwnedRuntimeInstallWorker {
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// A real held ancestor ACL observation; fixture ownership grants no privileged installer principal.
	static func fixtureAnchor(source: URL, afterPin: () throws -> Void) throws {
		let tree = try OwnedRuntimeInstallTree(root: source, protected: false)
		try afterPin(); try tree.verifyAnchor()
	}
	/// Actual disposable filesystem effects; this test bridge never constructs a production owner.
	static func fixtureCopy(source: URL, destination: URL, beforeCopy: (() throws -> Void)? = nil,
		afterCreatedFile: ((URL) throws -> Void)? = nil) throws {
		let source = try OwnedRuntimeInstallTree(root: source, protected: false)
		try beforeCopy?()
		var scratch: OwnedRuntimeInstallScratch?
		do { try source.copy(into: destination, custody: { scratch = $0 }, afterCreatedFile: afterCreatedFile) }
		catch {
			if let scratch, !scratch.retire() { throw OwnedRuntimeInstallFailure.cleanupPending }
			throw error
		}
	}
	#endif
}

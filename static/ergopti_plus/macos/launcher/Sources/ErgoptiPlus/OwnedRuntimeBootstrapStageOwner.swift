// Sources/ErgoptiPlus/OwnedRuntimeBootstrapStageOwner.swift
// Retires this signed helper's exact protected bootstrap copy after its actual file publication.
import CryptoKit
import Darwin
import Foundation
import Security

final class OwnedRuntimeBootstrapStageOwner {
	private static let parentURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private let publication: OwnedRuntimeFirstInstallOwner
	private let creator = getpid()
	private let plan: OwnedRuntimeBootstrapStagePlan
	private init(publication: OwnedRuntimeFirstInstallOwner, plan: OwnedRuntimeBootstrapStagePlan) {
		self.publication = publication; self.plan = plan
	}
	/// The argument is an original private-factory native owner, not a caller-supplied publication flag or path.
	/// The scope is the executing signed helper's own fixed UUID bootstrap copy, never an installed app/profile.
	static func acquire(afterPublication publication: OwnedRuntimeFirstInstallOwner) -> OwnedRuntimeBootstrapStageOwner? {
		guard publication.authorizesBootstrapStageRetirement(), getuid() == 0, geteuid() == 0,
			Bundle.main.bundleIdentifier == "com.ergoptiplus.app.runtime-installer",
			Bundle.main.bundleURL.lastPathComponent == "Helper.app" else { return nil }
		let stage = Bundle.main.bundleURL.deletingLastPathComponent()
		guard stage.deletingLastPathComponent().standardizedFileURL == parentURL,
			stage.lastPathComponent.hasPrefix(".runtime-installer-"),
			UUID(uuidString: String(stage.lastPathComponent.dropFirst(".runtime-installer-".count))) != nil else { return nil }
		var principal: SecCode?, code: SecStaticCode?, nativePath: CFURL?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal,
			SecCodeCopyStaticCode(principal, [], &code) == errSecSuccess, let code,
			SecCodeCopyPath(code, [], &nativePath) == errSecSuccess, let nativePath,
			(nativePath as URL).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
				|| (nativePath as URL).standardizedFileURL == Bundle.main.executableURL?.standardizedFileURL else { return nil }
		do {
			let plan = try OwnedRuntimeBootstrapStagePlan(stage: stage, protected: true)
			guard publication.authorizesBootstrapStageRetirement() else { return nil }
			return OwnedRuntimeBootstrapStageOwner(publication: publication, plan: plan)
		} catch { return nil }
	}
	func retire() -> Bool {
		guard getpid() == creator, getuid() == 0, geteuid() == 0,
			Bundle.main.bundleIdentifier == "com.ergoptiplus.app.runtime-installer" else { return false }
		// After the first owned unlink, the helper's own signature/resource paths intentionally cease to exist.
		// The original native owner/EX lock and immutable held-vnode plan remain in this same process until exit.
		return plan.retire()
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	struct InitializerCloseResult: Equatable { let status: Int32, error: Int32 }
	/// Observes real direct-descriptor closes; never returns a production stage/publication owner.
	static func fixtureRejectedInitializerRetirement(stage: URL) throws -> [InitializerCloseResult]? {
		try OwnedRuntimeBootstrapStagePlan.fixtureRejectedInitializerRetirement(stage: stage)
	}
	static func fixtureRetire(stage: URL, afterPin: (() throws -> Void)? = nil) throws -> Bool {
		let plan = try OwnedRuntimeBootstrapStagePlan(stage: stage, protected: false)
		try afterPin?(); return plan.retire()
	}
	#endif
}

private final class OwnedRuntimeBootstrapStagePlan {
	private struct Node { let descriptor: Int32, parent: Int32, name: String, relative: String, identity: stat, directory: Bool, digest: Data? }
	private let lock = NSLock()
	private let stage: URL, protected: Bool, parentTree: OwnedRuntimeInstallTree, snapshot: OwnedRuntimeInstallTree
	private let parentDescriptor: Int32
	private var nodes: [Node] = []
	private var closeRefused = false, started = false, completed = false, parentClosed = false
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private final class InitializerRetirementObservation { var result: [OwnedRuntimeBootstrapStageOwner.InitializerCloseResult]? }
	private static let observationKey = "com.ergoptiplus.tests.bootstrap-stage-initializer-retirement"
	private var initializerObservation: InitializerRetirementObservation?
	#endif
	init(stage: URL, protected: Bool) throws {
		self.stage = stage; self.protected = protected
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerObservation = Thread.current.threadDictionary[Self.observationKey] as? InitializerRetirementObservation
		#endif
		parentTree = try OwnedRuntimeInstallTree(root: stage.deletingLastPathComponent(), protected: protected, includeChildren: false)
		snapshot = try OwnedRuntimeInstallTree(root: stage, protected: protected)
		parentDescriptor = try parentTree.duplicateRootDescriptor()
		// Initialized self owns the parent and captured nodes; deinit also runs after a late throw.
		guard try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted() == ["Helper.app"] else { throw OwnedRuntimeInstallFailure.source }
		try snapshot.verify(); try capture(parent: parentDescriptor, name: stage.lastPathComponent, relative: "")
		try snapshot.verify(); try parentTree.verifyAnchor()
	}
	deinit {
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		var results: [OwnedRuntimeBootstrapStageOwner.InitializerCloseResult] = []
		#endif
		for node in nodes {
			let status = Darwin.close(node.descriptor)
			#if ERGOPTI_GUARDIAN_TEST_SUPPORT
			let closeError = status == 0 ? 0 : errno
			results.append(.init(status: status, error: closeError))
			#endif
			if status != 0 { closeRefused = true }
		}
		if !parentClosed {
			parentClosed = true
			let status = Darwin.close(parentDescriptor)
			#if ERGOPTI_GUARDIAN_TEST_SUPPORT
			let closeError = status == 0 ? 0 : errno
			results.append(.init(status: status, error: closeError))
			#endif
			if status != 0 { closeRefused = true }
		}
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		initializerObservation?.result = results
		#endif
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixtureRejectedInitializerRetirement(stage: URL) throws -> [OwnedRuntimeBootstrapStageOwner.InitializerCloseResult]? {
		guard Thread.current.threadDictionary[observationKey] == nil else { throw OwnedRuntimeInstallFailure.source }
		let observation = InitializerRetirementObservation()
		Thread.current.threadDictionary[observationKey] = observation
		defer { Thread.current.threadDictionary.removeObject(forKey: observationKey) }
		do {
			_ = try OwnedRuntimeBootstrapStagePlan(stage: stage, protected: false)
			throw OwnedRuntimeInstallFailure.destination
		} catch OwnedRuntimeInstallFailure.destination { throw OwnedRuntimeInstallFailure.destination }
		catch { return observation.result }
	}
	#endif
	private func protection(_ descriptor: Int32, _ value: stat) throws {
		guard value.st_mode & 0o6022 == 0, !protected || value.st_uid == 0 else { throw OwnedRuntimeInstallFailure.protection }
		errno = 0
		if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
			defer { acl_free(UnsafeMutableRawPointer(acl)) }
			var entry: acl_entry_t?; errno = 0
			guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
				errno == EINVAL else { throw OwnedRuntimeInstallFailure.protection }
		} else if errno != ENOENT { throw OwnedRuntimeInstallFailure.protection } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
	}
	private func bytes(_ descriptor: Int32, size: off_t) throws -> Data {
		guard size >= 0, size <= 268_435_456 else { throw OwnedRuntimeInstallFailure.source }
		var output = Data(count: Int(size)), offset = 0
		try output.withUnsafeMutableBytes { buffer in
			while offset < buffer.count {
				let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
				if count < 0, errno == EINTR { continue }
				guard count > 0 else { throw OwnedRuntimeInstallFailure.source }; offset += count
			}
		}; return output
	}
	private func same(_ expected: stat, _ value: stat, directory: Bool) -> Bool {
		expected.st_dev == value.st_dev && expected.st_ino == value.st_ino && expected.st_uid == value.st_uid
			&& expected.st_gid == value.st_gid && expected.st_mode == value.st_mode
			&& (directory || (value.st_nlink == 1 && value.st_size == expected.st_size
				&& value.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
				&& value.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec))
	}
	private func capture(parent: Int32, name: String, relative: String) throws {
		guard nodes.count < 4096 else { throw OwnedRuntimeInstallFailure.source }
		var named = stat()
		guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnedRuntimeInstallFailure.source }
		let directory = named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
		guard directory || named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && named.st_nlink == 1 else { throw OwnedRuntimeInstallFailure.source }
		let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
		guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
		var retained = false; defer { if !retained { Darwin.close(descriptor) } }
		var held = stat(); guard fstat(descriptor, &held) == 0, same(named, held, directory: directory) else { throw OwnedRuntimeInstallFailure.mutated }
		try protection(descriptor, held)
		let digest = directory ? nil : Data(SHA256.hash(data: try bytes(descriptor, size: held.st_size)))
		nodes.append(Node(descriptor: descriptor, parent: parent, name: name, relative: relative, identity: held, directory: directory, digest: digest)); retained = true
		if directory {
			let path = relative.isEmpty ? stage : stage.appendingPathComponent(relative)
			for child in try FileManager.default.contentsOfDirectory(atPath: path.path).sorted() {
				guard !child.isEmpty, child != ".", child != "..", !child.contains("/"), !child.contains("\0") else { throw OwnedRuntimeInstallFailure.source }
				try capture(parent: descriptor, name: child, relative: relative.isEmpty ? child : relative + "/" + child)
			}
		}
	}
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !completed else { return !closeRefused }
		do {
			if !started { try snapshot.verify(); try parentTree.verifyAnchor(); started = true }
			while let node = nodes.last {
				try parentTree.verifyAnchor()
				var held = stat(), named = stat()
				guard fstat(node.descriptor, &held) == 0, fstatat(node.parent, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
					same(node.identity, held, directory: node.directory), same(node.identity, named, directory: node.directory) else { return false }
				try protection(node.descriptor, held)
				if let digest = node.digest { guard Data(SHA256.hash(data: try bytes(node.descriptor, size: held.st_size))) == digest else { return false } }
				guard unlinkat(node.parent, node.name, node.directory ? AT_REMOVEDIR : 0) == 0 else { return false }
				if Darwin.close(node.descriptor) != 0 { closeRefused = true }
				nodes.removeLast()
			}
			guard fsync(parentDescriptor) == 0 else { return false }
			if !snapshot.releaseOwnedDescriptors() { closeRefused = true }
			if !parentTree.releaseOwnedDescriptors() { closeRefused = true }
			parentClosed = true; if Darwin.close(parentDescriptor) != 0 { closeRefused = true }
			completed = true; return !closeRefused
		} catch { return false }
	}
}

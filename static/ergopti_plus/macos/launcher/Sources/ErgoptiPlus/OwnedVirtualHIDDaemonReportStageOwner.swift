// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportStageOwner.swift
import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import Security

/// Only the original authenticated report request can capture its exact protected temporary helper stage.
final class OwnedVirtualHIDDaemonReportStageOwner {
	private struct Anchor {
		let parent: OwnedVHDReportDescriptor, child: OwnedVHDReportDescriptor, name: String, identity: stat
		func current() -> Bool {
			guard parent.current(), child.current() else { return false }; var named = stat()
			return fstatat(parent.number, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && OwnedVHDReportDescriptor.same(identity, named) && parent.current() && child.current()
		}
	}
	private struct Node {
		let held: OwnedVHDReportDescriptor, parent: OwnedVHDReportDescriptor, name: String, identity: stat, directory: Bool, digest: Data?, ancestors: [Anchor]
		var removed = false
	}
	private static let rootsLock = NSLock(); private static var roots: [OwnedVirtualHIDDaemonReportStageOwner] = []
	private let lock = NSRecursiveLock(), request: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request, creator = getpid()
	private var publisher: OwnedRuntimePublisherIdentity?, publisherAttempted = false, publisherClosed = false
	private var parentTree: OwnedRuntimeInstallTree?, snapshot: OwnedRuntimeInstallTree?, treeAttempted = false
	private var imageWitness: OwnedVHDReportDescriptor?
	private var parent: OwnedVHDReportDescriptor?, nodes: [Node] = [], stage: URL?, sourceCode: SecCode?, birth = ergopti_owned_program_observation(), leaf: Data?
	private var image = ergopti_vhd_report_self_image(), imageAdmitted = false
	private var complete = false, failed = false, closed = false, started = false, bytesSeen = 0
	private init(_ request: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request) { self.request = request }
	static func capture(from request: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request) -> OwnedVirtualHIDDaemonReportStageOwner {
		let owner = OwnedVirtualHIDDaemonReportStageOwner(request); rootsLock.lock(); roots.append(owner); rootsLock.unlock()
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0, request.stageCaptureCurrent(), CommandLine.arguments.count == 2,
			CommandLine.arguments[1] == "--virtual-hid-daemon-report-worker" else { owner.failed = true; return owner }
		owner.publisherAttempted = true; owner.publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller()
		owner.birth = ergopti_owned_program_observe(owner.creator)
		guard owner.publisher?.current() == true, SecCodeCopySelf([], &owner.sourceCode) == errSecSuccess else { owner.failed = true; return owner }
		owner.leaf = owner.publisher?.leaf
		let stage = Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent(); owner.stage = stage
		owner.treeAttempted = true
		do {
			owner.parentTree = try OwnedRuntimeInstallTree(root: stage.deletingLastPathComponent(), protected: true, includeChildren: false)
			owner.snapshot = try OwnedRuntimeInstallTree(root: stage, protected: true)
			guard let parentTree = owner.parentTree, let snapshot = owner.snapshot else { throw OwnedRuntimeInstallFailure.source }
			let raw = try parentTree.duplicateRootDescriptor(); let parent = OwnedVHDReportDescriptor(raw); owner.parent = parent
			guard parent.capture(), try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted() == ["Helper.app"] else { throw OwnedRuntimeInstallFailure.source }
			try parentTree.verifyAnchor(); try snapshot.verify(); try owner.capture(parent: parent, name: stage.lastPathComponent, relative: "", ancestors: [])
			try snapshot.verify(); try parentTree.verifyAnchor()
			guard owner.admitImage(), request.stageCaptureCurrent(), owner.nativeCurrent() else { throw OwnedRuntimeInstallFailure.principal }; owner.complete = true
		} catch { owner.failed = true }
		return owner
	}
	/// Capture status is descriptive. It never grants report, install or driver permission.
	func captured() -> Bool { lock.lock(); defer { lock.unlock() }; return complete && !failed && !closed && nativeCurrent() }
	private func admitImage() -> Bool {
		guard let sourceCode, publisher?.current() == true, imageWitness?.current() == true else { return false }; var code: SecStaticCode?
		guard SecCodeCopyStaticCode(sourceCode, [], &code) == errSecSuccess, let code,
			let info = OwnedRuntimePublisherSignature.information(code, role: .installer), let hashes = info[kSecCodeInfoCdHashes as String] as? [Data], hashes.count == 2,
			ergopti_vhd_report_self_image_capture(&image) == 0 else { return false }
		let actual = withUnsafeBytes(of: &image.cdhash) { Data($0) }
		guard hashes.contains(where: { Data($0.prefix(20)) == actual }), image.pid == creator, image.seconds == birth.start_seconds, image.microseconds == birth.start_microseconds else { return false }
		imageAdmitted = true; return true
	}
	private func nativeCurrent() -> Bool {
		guard creator == getpid(), getuid() == 0, geteuid() == 0, let sourceCode, let leaf,
			(started ? imageAdmitted && imageWitness?.current() == true && ergopti_vhd_report_self_image_matches(&image) == 0 : OwnedRuntimePublisherSignature.currentLeaf(sourceCode, role: .installer) == leaf) else { return false }
		let now = ergopti_owned_program_observe(creator)
		return now.error_code == 0 && !now.nonlive && now.process_id == creator && birth.error_code == 0 && !birth.nonlive && birth.process_id == creator
			&& now.start_seconds == birth.start_seconds && now.start_microseconds == birth.start_microseconds
	}
	private func same(_ original: stat, _ value: stat, directory: Bool) -> Bool {
		OwnedVHDReportDescriptor.same(original, value) && (directory || value.st_nlink == 1 && value.st_size == original.st_size
			&& value.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec
			&& value.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec)
	}
	private func protected(_ fd: OwnedVHDReportDescriptor, _ value: stat) -> Bool {
		guard fd.current(), value.st_uid == 0, value.st_mode & 0o6022 == 0 else { return false }
		errno = 0
		guard let acl = acl_get_fd_np(fd.number, ACL_TYPE_EXTENDED) else { return errno == ENOENT && fd.current() } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
		defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?; errno = 0
		let valid = acl_valid(acl), result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry), saved = errno
		return fd.current() && valid == 0 && result == -1 && saved == EINVAL
	}
	private func digest(_ held: OwnedVHDReportDescriptor, size: off_t) throws -> Data {
		guard size >= 0, size <= 268_435_456 else { throw OwnedRuntimeInstallFailure.source }
		var hash = SHA256(), offset: off_t = 0, buffer = [UInt8](repeating: 0, count: 65_536)
		while offset < size {
			guard held.current(), nativeCurrent() else { throw OwnedRuntimeInstallFailure.mutated }
			let count = pread(held.number, &buffer, min(buffer.count, Int(size - offset)), offset), saved = errno
			guard held.current(), nativeCurrent() else { throw OwnedRuntimeInstallFailure.mutated }
			if count < 0 && saved == EINTR { continue }; guard count > 0 else { throw OwnedRuntimeInstallFailure.source }
			hash.update(data: Data(buffer.prefix(count))); offset += off_t(count)
		}
		return Data(hash.finalize())
	}
	private func capture(parent: OwnedVHDReportDescriptor, name: String, relative: String, ancestors: [Anchor]) throws {
		guard nodes.count < 4096, parent.current(), ancestors.allSatisfy({ $0.current() }), nativeCurrent(), let parentTree else { throw OwnedRuntimeInstallFailure.source }; try parentTree.verifyAnchor()
		var named = stat(); guard fstatat(parent.number, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnedRuntimeInstallFailure.source }
		let directory = named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
		guard directory || named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && named.st_nlink == 1 else { throw OwnedRuntimeInstallFailure.source }
		let raw = openat(parent.number, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
		guard raw >= 0 else { throw OwnedRuntimeInstallFailure.source }
		let held = OwnedVHDReportDescriptor(raw)
		// Retain the actual descriptor BEFORE capture/protection/hash can fail.
		nodes.append(Node(held: held, parent: parent, name: name, identity: named, directory: directory, digest: nil, ancestors: ancestors))
		guard held.capture(), let observed = held.identity, same(named, observed, directory: directory), protected(held, observed) else { throw OwnedRuntimeInstallFailure.mutated }
		if relative == "Helper.app/Contents/MacOS/ErgoptiPlus-Runtime-Installer" {
			guard imageWitness == nil, held.current() else { throw OwnedRuntimeInstallFailure.source }
			let raw = fcntl(held.number, F_DUPFD_CLOEXEC, 0); guard raw >= 0 else { throw OwnedRuntimeInstallFailure.source }
			let witness = OwnedVHDReportDescriptor(raw); imageWitness = witness
			guard witness.capture(), let identity = witness.identity, OwnedVHDReportDescriptor.same(observed, identity), held.current() else { throw OwnedRuntimeInstallFailure.mutated }
		}
		let hash = directory ? nil : try digest(held, size: observed.st_size)
		if !directory { bytesSeen += Int(observed.st_size); guard bytesSeen <= 536_870_912 else { throw OwnedRuntimeInstallFailure.source } }
		let index = nodes.count - 1; nodes[index] = Node(held: held, parent: parent, name: name, identity: observed, directory: directory, digest: hash, ancestors: ancestors)
		if directory {
			guard let stage else { throw OwnedRuntimeInstallFailure.source }; let path = relative.isEmpty ? stage : stage.appendingPathComponent(relative)
			for child in try FileManager.default.contentsOfDirectory(atPath: path.path).sorted() {
				guard !child.isEmpty, child != ".", child != "..", !child.contains("/"), !child.contains("\0") else { throw OwnedRuntimeInstallFailure.source }
				try capture(parent: held, name: child, relative: relative.isEmpty ? child : relative + "/" + child,
					ancestors: ancestors + [Anchor(parent: parent, child: held, name: name, identity: observed)])
			}
		}
		try parentTree.verifyAnchor()
	}
	/// A private same-request transport-retirement receipt is necessary; no caller Boolean or path is accepted.
	func retire(after retirement: OwnedVirtualHIDDaemonReportRequestChannel.Root.Retirement) -> Bool {
		lock.lock(); defer { lock.unlock() }; if closed { return true }
		guard retirement.matches(request), complete, !failed, nativeCurrent(), let parentTree, let snapshot, let parent, parent.current() else { return false }
		do {
			if !started {
				try snapshot.verify(); try parentTree.verifyAnchor()
				guard publisher?.current() == true, admitImage() else { return false }
				guard publisher?.retire() == true else { failed = true; return false }; publisherClosed = true; started = true
			}
			for index in nodes.indices.reversed() {
				let node = nodes[index]; if node.removed { continue }
				guard nativeCurrent(), node.held.current(), node.parent.current(), node.ancestors.allSatisfy({ $0.current() }), parent.current() else { return false }; try parentTree.verifyAnchor()
				var value = stat(), named = stat()
				guard fstat(node.held.number, &value) == 0, fstatat(node.parent.number, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
					same(node.identity, value, directory: node.directory), same(node.identity, named, directory: node.directory), protected(node.held, value) else { return false }
				if let expected = node.digest { guard try digest(node.held, size: value.st_size) == expected else { return false } }
				try parentTree.verifyAnchor()
				var finalHeld = stat(), finalNamed = stat()
				guard node.held.current(), node.parent.current(), node.ancestors.allSatisfy({ $0.current() }), nativeCurrent(),
					fstat(node.held.number, &finalHeld) == 0, fstatat(node.parent.number, node.name, &finalNamed, AT_SYMLINK_NOFOLLOW) == 0,
					same(node.identity, finalHeld, directory: node.directory), same(node.identity, finalNamed, directory: node.directory),
					node.parent.current(), node.ancestors.allSatisfy({ $0.current() }), unlinkat(node.parent.number, node.name, node.directory ? AT_REMOVEDIR : 0) == 0 else { return false }
				nodes[index].removed = true // Keep close debt/original FD even after a successful namespace effect.
				try parentTree.verifyAnchor(); guard node.parent.current(), node.ancestors.allSatisfy({ $0.current() }), node.held.close() else { failed = true; return false }
			}
			guard nativeCurrent(), parent.current(), fsync(parent.number) == 0 else { return false }
			guard imageWitness?.close() == true, snapshot.releaseOwnedDescriptors(), parentTree.releaseOwnedDescriptors(), parent.close(), publisherClosed else { failed = true; return false }
			closed = true; Self.rootsLock.lock(); Self.roots.removeAll { $0 === self }; Self.rootsLock.unlock(); return true
		} catch { return false }
	}
	func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

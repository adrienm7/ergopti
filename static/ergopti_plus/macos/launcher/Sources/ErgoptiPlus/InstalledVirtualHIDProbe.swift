// Sources/ErgoptiPlus/InstalledVirtualHIDProbe.swift
// Read-only static observations. Package trust, live broker and driver approval are separate.
import CryptoKit
import Darwin
import Foundation
import Security

struct InstalledVHDArchitectureObservation: Encodable {
	let architecture: String
	let securityStatus: Int32?
	let cdhash: String?
	enum CodingKeys: String, CodingKey { case architecture, cdhash; case securityStatus = "security_status" }
}
struct InstalledVHDComponentObservation: Encodable {
	let role: String
	var status: String
	var ordinaryRootOwned: Bool?
	var bundleIdentityValid: Bool?
	var signatureValid: Bool?
	var matchesFixedBytes: Bool?
	var architectures: [InstalledVHDArchitectureObservation] = []
	var reason: String?
	var errorDomain: String?
	var errorCode: Int32?
	enum CodingKeys: String, CodingKey {
		case role, status, architectures, reason
		case ordinaryRootOwned = "ordinary_root_owned", bundleIdentityValid = "bundle_identity_valid"
		case signatureValid = "signature_valid", matchesFixedBytes = "matches_fixed_bytes"
		case errorDomain = "error_domain", errorCode = "error_code"
	}
}
struct InstalledVHDProbeReceipt: Encodable {
	let schema = 1
	let sourceCommit = "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb"
	// No actual Darwin package/reference qualification exists in this source tranche.
	let referenceQualified = false
	let status: String
	let components: [InstalledVHDComponentObservation]
	let reason: String?
	enum CodingKeys: String, CodingKey {
		case schema, status, components, reason
		case sourceCommit = "source_commit", referenceQualified = "reference_qualified"
	}
}
struct InstalledVHDProbeLocations {
	let daemon: URL
	let dext: URL
	static let installed = InstalledVHDProbeLocations(
		daemon: URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app"),
		dext: URL(fileURLWithPath: "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext"))
}
struct InstalledVHDProbeBoundary { let role: String; let stage: String }
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
struct InstalledVHDProbeTestHooks { var boundary: (InstalledVHDProbeBoundary) throws -> Void }
#endif

private struct InstalledVHDProbeFailure: Error {
	let status: String
	let reason: String
	var domain: String? = nil
	var code: Int32? = nil
}

enum InstalledVHDProbeNative {
	/// Darwin returns zero FOR an entry, and -1/EINVAL for an empty valid ACL.
	static func aclIsEmpty(_ value: acl_t) throws -> Bool {
		guard acl_valid(value) == 0 else { throw InstalledVHDProbeFailure(status: "unverified", reason: "acl_unknown", domain: "posix", code: errno) }
		var entry: acl_entry_t?
		errno = 0
		let outcome = acl_get_entry(value, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
		let observedError = errno
		if outcome == 0, entry != nil { return false }
		if outcome == -1, observedError == EINVAL { return true }
		throw InstalledVHDProbeFailure(status: "unverified", reason: "acl_unknown", domain: "posix", code: observedError)
	}
	fileprivate static func aclState(_ descriptor: Int32) throws -> Bool {
		guard let value = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
			throw InstalledVHDProbeFailure(status: "unverified", reason: "acl_unknown", domain: "posix", code: errno)
		}
		let outcome: Result<Bool, Error>
		do { outcome = .success(try aclIsEmpty(value)) } catch { outcome = .failure(error) }
		guard acl_free(UnsafeMutableRawPointer(value)) == 0 else { throw InstalledVHDProbeFailure(status: "refused", reason: "acl_release_failed", domain: "posix", code: errno) }
		return try outcome.get()
	}
}

struct InstalledVHDFileIdentity: Equatable {
	let device: dev_t, inode: ino_t
	let mode: mode_t, uid: uid_t, gid: gid_t
	let size: off_t, modified: time_t, modifiedNS: Int, changed: time_t, changedNS: Int
	init(_ s: stat) {
		device = s.st_dev; inode = s.st_ino; mode = s.st_mode; uid = s.st_uid; gid = s.st_gid
		let directory = (s.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
		size = directory ? 0 : s.st_size
		modified = directory ? 0 : s.st_mtimespec.tv_sec; modifiedNS = directory ? 0 : s.st_mtimespec.tv_nsec
		changed = directory ? 0 : s.st_ctimespec.tv_sec; changedNS = directory ? 0 : s.st_ctimespec.tv_nsec
	}
}
final class InstalledVHDStaticSnapshot {
	struct Node {
		let fd: Int32, parent: Int32?, name: String, path: String
		let identity: InstalledVHDFileIdentity
		let acl: Bool?
		var aclObserved = false
		var digest: String? = nil
		var members: [String]? = nil
	}
	var nodes: [Node] = []
	var ordinaryRootOwned: Bool? = true
	var partialReason: String?
	var consumedBytes = 0
	private let maximumNodes = 256, maximumBytes = 16_777_216

	private func posix(_ reason: String, code: Int32 = errno) -> InstalledVHDProbeFailure {
		InstalledVHDProbeFailure(status: code == ENOENT ? "missing" : "refused", reason: code == ENOENT ? "missing_path" : reason, domain: "posix", code: code)
	}
	private func protected(_ fd: Int32, directory: Bool, s: stat) throws -> Bool? {
		guard s.st_uid == 0 else { ordinaryRootOwned = false; throw InstalledVHDProbeFailure(status: "refused", reason: directory ? "unowned_ancestor" : "unowned_file") }
		if s.st_mode & 0o022 != 0 {
			if !directory { ordinaryRootOwned = false; throw InstalledVHDProbeFailure(status: "refused", reason: "writable_file") }
			ordinaryRootOwned = false; partialReason = partialReason ?? "writable_ancestor"
		}
		do {
			let empty = try InstalledVHDProbeNative.aclState(fd)
			if !empty {
				if ordinaryRootOwned == true { ordinaryRootOwned = false }
				partialReason = partialReason ?? (directory ? "ancestor_acl_present" : "file_acl_present")
			}
			return empty
		} catch let failure as InstalledVHDProbeFailure {
			if failure.reason == "acl_release_failed" { throw failure }
			if ordinaryRootOwned == true { ordinaryRootOwned = nil }
			partialReason = partialReason ?? "acl_unknown"
			return nil
		}
	}
	private func hold(parent: Int32?, name: String, path: String, directory: Bool) throws -> Int32 {
		guard nodes.count < maximumNodes else { throw InstalledVHDProbeFailure(status: "refused", reason: "reference_inventory_limit") }
		var named = stat()
		let namedResult = parent.map { fstatat($0, name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(path, &named)
		guard namedResult == 0 else { throw posix("path_unavailable") }
		let expectedType = directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
		guard named.st_mode & mode_t(S_IFMT) == expectedType else { throw InstalledVHDProbeFailure(status: "refused", reason: "nonordinary_path") }
		let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
		let fd = parent.map { openat($0, name, flags) } ?? open(path, flags)
		guard fd >= 0 else { throw posix("file_open_failed") }
		// Own every admitted FD immediately, even if subsequent checks refuse it.
		let index = nodes.count
		nodes.append(Node(fd: fd, parent: parent, name: name, path: path, identity: InstalledVHDFileIdentity(named), acl: nil))
		var held = stat()
		guard fstat(fd, &held) == 0, InstalledVHDFileIdentity(held) == InstalledVHDFileIdentity(named) else {
			throw InstalledVHDProbeFailure(status: "changed", reason: "file_identity_changed")
		}
		let acl = try protected(fd, directory: directory, s: held)
		nodes[index] = Node(fd: fd, parent: parent, name: name, path: path, identity: InstalledVHDFileIdentity(held), acl: acl, aclObserved: true)
		return fd
	}
	func pin(_ path: String) throws -> Int32 {
		guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("//") else { throw InstalledVHDProbeFailure(status: "refused", reason: "invalid_fixed_path") }
		let parts = path.split(separator: "/").map(String.init)
		guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw InstalledVHDProbeFailure(status: "refused", reason: "invalid_fixed_path") }
		var fd = try hold(parent: nil, name: "", path: "/", directory: true)
		var prefix = ""
		for part in parts { prefix += "/" + part; fd = try hold(parent: fd, name: part, path: prefix, directory: true) }
		return fd
	}
	private func members(_ path: String) throws -> [String] {
		let names: [String]
		do { names = try FileManager.default.contentsOfDirectory(atPath: path).sorted() }
		catch { throw InstalledVHDProbeFailure(status: "refused", reason: "resource_inventory_failed") }
		guard names.count <= maximumNodes, names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
			throw InstalledVHDProbeFailure(status: "refused", reason: "resource_inventory_limit")
		}
		return names
	}
	func digest(_ index: Int) throws -> String {
		let node = nodes[index]
		guard node.identity.size >= 0, node.identity.size <= 8_388_608 else { throw InstalledVHDProbeFailure(status: "refused", reason: "reference_size_limit") }
		var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
		var offset: off_t = 0
		while offset < node.identity.size {
			let wanted = min(buffer.count, Int(node.identity.size - offset))
			let count = buffer.withUnsafeMutableBytes { pread(node.fd, $0.baseAddress, wanted, offset) }
			guard count > 0 else { throw InstalledVHDProbeFailure(status: "changed", reason: "reference_read_changed", domain: "posix", code: count < 0 ? errno : nil) }
			hash.update(data: Data(buffer.prefix(count))); offset += off_t(count)
		}
		return hash.finalize().map { String(format: "%02x", $0) }.joined()
	}
	func inventory(_ fd: Int32, path: String) throws {
		let names = try members(path)
		guard let i = nodes.firstIndex(where: { $0.fd == fd }) else { throw InstalledVHDProbeFailure(status: "refused", reason: "descriptor_owner_lost") }
		nodes[i].members = names
		for name in names {
			var info = stat()
			guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("resource_unavailable") }
			let directory = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
			let childPath = path + "/" + name
			let child = try hold(parent: fd, name: name, path: childPath, directory: directory)
			if directory { try inventory(child, path: childPath) }
			else {
				let index = nodes.count - 1
				consumedBytes += Int(nodes[index].identity.size)
				guard consumedBytes >= 0, consumedBytes <= maximumBytes else { throw InstalledVHDProbeFailure(status: "refused", reason: "reference_size_limit") }
				nodes[index].digest = try digest(index)
			}
		}
	}
	func requireFile(_ relativePath: String, root: Int32, path: String) throws {
		let parts = relativePath.split(separator: "/").map(String.init)
		var parent = root, prefix = path
		for (index, name) in parts.enumerated() {
			var named = stat()
			guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("path_unavailable") }
			let expectedType = index == parts.count - 1 ? mode_t(S_IFREG) : mode_t(S_IFDIR)
			guard named.st_mode & mode_t(S_IFMT) == expectedType else { throw InstalledVHDProbeFailure(status: "refused", reason: "nonordinary_path") }
			prefix += "/" + name
			guard let retained = nodes.first(where: { $0.parent == parent && $0.name == name && $0.path == prefix }),
				InstalledVHDFileIdentity(named) == retained.identity else {
				throw InstalledVHDProbeFailure(status: "changed", reason: "file_identity_changed")
			}
			parent = retained.fd
		}
	}
	func verify() throws {
		for (i, node) in nodes.enumerated() {
			var held = stat(), named = stat()
			let namedResult = node.parent.map { fstatat($0, node.name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(node.path, &named)
			guard fstat(node.fd, &held) == 0, namedResult == 0,
				InstalledVHDFileIdentity(held) == node.identity, InstalledVHDFileIdentity(named) == node.identity else {
				throw InstalledVHDProbeFailure(status: "changed", reason: "file_identity_changed")
			}
			if node.aclObserved {
				let currentACL: Bool?
				do { currentACL = try InstalledVHDProbeNative.aclState(node.fd) }
				catch let f as InstalledVHDProbeFailure {
					if f.reason == "acl_release_failed" { throw f }
					currentACL = nil
				}
				guard currentACL == node.acl else { throw InstalledVHDProbeFailure(status: "changed", reason: "file_acl_changed") }
			}
			if let before = node.digest, try digest(i) != before { throw InstalledVHDProbeFailure(status: "changed", reason: "file_content_changed") }
			if let before = node.members, try members(node.path) != before { throw InstalledVHDProbeFailure(status: "changed", reason: "resource_inventory_changed") }
		}
	}
	func closeAll() throws {
		var errorCode: Int32?
		for node in nodes.reversed() { if close(node.fd) != 0, errorCode == nil { errorCode = errno } }
		nodes.removeAll()
		if let errorCode { throw InstalledVHDProbeFailure(status: "refused", reason: "descriptor_close_failed", domain: "posix", code: errorCode) }
	}
}

struct InstalledVHDReference {
	let role: String, identifier: String, executable: String, version: String
	let executableHash: String, plistHash: String
	let daemonHashes: [String: String]
	var plist: String { role == "daemon" ? "Contents/Info.plist" : "Info.plist" }
	static let daemon = InstalledVHDReference(role: "daemon", identifier: "org.pqrs.Karabiner-VirtualHIDDevice-Daemon", executable: "Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon", version: "8.5.0", executableHash: "9620bd06cbbfbd377689fb5a0ba2f1e1bd346effe089fe49a083d7963f1a76ab", plistHash: "0fb5e8877dbbf929dd5fb8f1cfce7fe737971bf355c39d29a4fc5c7c44e05f99", daemonHashes: ["x86_64": "3736778029bc84c96bf1af782f81b86bb164bb3f", "arm64": "c10ecd105806ecfc53c3c71b9b49affbe7a369f2"])
	static let dext = InstalledVHDReference(role: "dext", identifier: "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice", executable: "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice", version: "1.8.0", executableHash: "1ad5457b892121eff4b9ecedd0528af0e6ea82928827ad76fb7c5b9c247c0b6e", plistHash: "60863adaa1ffe6b1c954df12dac7b563933389803752d44df24c788a8620b0db", daemonHashes: [:])
}

enum InstalledVirtualHIDProbe {
	static func observe() -> InstalledVHDProbeReceipt { collect(.installed, boundary: nil) }
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func observeTestFixture(locations: InstalledVHDProbeLocations, hooks: InstalledVHDProbeTestHooks? = nil) -> InstalledVHDProbeReceipt {
		collect(locations, boundary: hooks?.boundary)
	}
	#endif
	private static func collect(_ locations: InstalledVHDProbeLocations, boundary: ((InstalledVHDProbeBoundary) throws -> Void)?) -> InstalledVHDProbeReceipt {
		let components = [observeComponent(locations.daemon, reference: .daemon, boundary: boundary), observeComponent(locations.dext, reference: .dext, boundary: boundary)]
		let refused = components.first { $0.status != "observed" }
		return InstalledVHDProbeReceipt(status: refused?.status ?? "observed", components: components, reason: refused?.reason)
	}
	/// Transfers custody before any native acquisition; diagnostics never request this seam.
	static func retainComponent(_ url: URL, reference: InstalledVHDReference,
		custody: @escaping (InstalledVHDStaticSnapshot) -> Void,
		boundary: ((InstalledVHDProbeBoundary) throws -> Void)?) -> InstalledVHDComponentObservation {
		observeComponent(url, reference: reference, boundary: boundary, custody: custody)
	}

	private static func observeComponent(_ url: URL, reference: InstalledVHDReference,
		boundary: ((InstalledVHDProbeBoundary) throws -> Void)?,
		custody: ((InstalledVHDStaticSnapshot) -> Void)? = nil) -> InstalledVHDComponentObservation {
		let snapshot = InstalledVHDStaticSnapshot()
		custody?(snapshot)
		var result = InstalledVHDComponentObservation(role: reference.role, status: "unverified")
		func invoke(_ stage: String) throws {
			do { try boundary?(InstalledVHDProbeBoundary(role: reference.role, stage: stage)) }
			catch { throw InstalledVHDProbeFailure(status: "refused", reason: "probe_boundary_refused") }
		}
		func check(_ outcome: OSStatus) throws {
			guard outcome == errSecSuccess else { throw InstalledVHDProbeFailure(status: "unverified", reason: "security_validation_failed", domain: "security", code: outcome) }
		}
		do {
			let root = try snapshot.pin(url.path)
			try snapshot.inventory(root, path: url.path)
			try invoke("afterFilesPinned"); try snapshot.verify()
			let expected = [(reference.executable, reference.executableHash), (reference.plist, reference.plistHash)]
			for pair in expected { try snapshot.requireFile(pair.0, root: root, path: url.path) }
			result.matchesFixedBytes = expected.allSatisfy { pair in snapshot.nodes.contains { $0.path == url.path + "/" + pair.0 && $0.digest == pair.1 } }
			guard result.matchesFixedBytes == true else { throw InstalledVHDProbeFailure(status: "unverified", reason: "unsupported_fixed_reference") }
			var staticCode: SecStaticCode?
			try check(SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode))
			guard let staticCode else { throw InstalledVHDProbeFailure(status: "unverified", reason: "security_object_missing") }
			let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
			try check(SecStaticCodeCheckValidity(staticCode, strict, nil))
			try snapshot.verify(); try invoke("afterSecurityValidated"); try snapshot.verify()
			for architecture in ["x86_64", "arm64"] {
				var slice: SecStaticCode?
				let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
				try check(SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &slice))
				guard let slice else { throw InstalledVHDProbeFailure(status: "unverified", reason: "security_object_missing") }
				try check(SecStaticCodeCheckValidity(slice, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
				var information: CFDictionary?
				try check(SecCodeCopySigningInformation(slice, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
				guard let information = information as? [String: Any],
					let hash = information[kSecCodeInfoUnique as String] as? Data, hash.count == 20,
					let cms = information[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
					let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty,
					information[kSecCodeInfoIdentifier as String] as? String == reference.identifier,
					let plist = information[kSecCodeInfoPList as String] as? [String: Any],
					plist["CFBundleIdentifier"] as? String == reference.identifier,
					plist["CFBundleVersion"] as? String == reference.version,
					plist["CFBundleShortVersionString"] as? String == reference.version,
					plist["CFBundleExecutable"] as? String == reference.executable.split(separator: "/").last.map(String.init) else {
					throw InstalledVHDProbeFailure(status: "unverified", reason: "secured_bundle_fields_unknown")
				}
				let encoded = hash.map { String(format: "%02x", $0) }.joined()
				if let fixed = reference.daemonHashes[architecture], fixed != encoded { throw InstalledVHDProbeFailure(status: "unverified", reason: "slice_reference_mismatch") }
				result.architectures.append(InstalledVHDArchitectureObservation(architecture: architecture, securityStatus: errSecSuccess, cdhash: encoded))
				try snapshot.verify()
			}
			result.bundleIdentityValid = true; result.signatureValid = true
			try invoke("beforePublication"); try snapshot.verify()
			result.ordinaryRootOwned = snapshot.ordinaryRootOwned
			result.status = snapshot.ordinaryRootOwned == true ? "observed" : "unverified"
			result.reason = snapshot.partialReason
		} catch {
			var failure = error as? InstalledVHDProbeFailure ?? InstalledVHDProbeFailure(status: "refused", reason: "probe_operation_refused")
			// A changed real source outranks any later Security/foreign diagnostic result.
			do { try snapshot.verify() } catch let changed as InstalledVHDProbeFailure { failure = changed } catch { failure = InstalledVHDProbeFailure(status: "refused", reason: "probe_operation_refused") }
			result.status = failure.status; result.reason = failure.reason; result.errorDomain = failure.domain; result.errorCode = failure.code
			result.ordinaryRootOwned = snapshot.ordinaryRootOwned == true ? nil : snapshot.ordinaryRootOwned
			result.bundleIdentityValid = nil; result.signatureValid = nil
		}
		if custody == nil {
			do { try snapshot.closeAll() } catch let failure as InstalledVHDProbeFailure {
				result.status = failure.status; result.reason = failure.reason; result.errorDomain = failure.domain; result.errorCode = failure.code
				result.ordinaryRootOwned = nil; result.signatureValid = nil; result.bundleIdentityValid = nil
			} catch { result.status = "refused"; result.reason = "descriptor_close_failed"; result.ordinaryRootOwned = nil; result.signatureValid = nil }
		}
		return result
	}
}

enum InstalledVirtualHIDProbeWorker {
	static let role = "--installed-virtual-hid-probe"
	static func handles(arguments: [String]) -> Bool { arguments.count > 1 && arguments[1] == role }
	static func run(arguments: [String], probe: () -> InstalledVHDProbeReceipt = InstalledVirtualHIDProbe.observe,
		writeOutput: (Data) -> Bool = { data in do { try FileHandle.standardOutput.write(contentsOf: data); return true } catch { return false } }) -> Int32 {
		guard arguments.count == 2, arguments[1] == role else { return 64 }
		let receipt = probe()
		let statuses = ["observed", "missing", "unverified", "changed", "refused"]
		guard statuses.contains(receipt.status),
			receipt.components.map(\.role) == ["daemon", "dext"],
			receipt.components.allSatisfy({ statuses.contains($0.status) }), receipt.referenceQualified == false else { return 70 }
		do { return writeOutput(try JSONEncoder().encode(receipt)) ? 0 : 74 } catch { return 70 }
	}
}

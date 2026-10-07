// Sources/ErgoptiPlus/OwnedRuntimeServiceReferenceOwner.swift
// Read-only fixed Core source custody; code proof never grants installation or start authority.
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

private enum OwnedRuntimeReferenceFailure: Error {
	case unavailable, source, policy, signature
}

/// Holds actual native files. Official reference inventory limits remain unchanged.
private final class OwnedRuntimeReferenceFiles {
	private struct Node {
		let descriptor: Int32, parent: Int32?, name: String, path: String
		let identity: InstalledVHDFileIdentity
		let directory: Bool, protected: Bool
		let digest: Data?
	}
	private var directories: [InstalledVHDStaticSnapshot] = []
	private var nodes: [Node] = []
	private var bytes = 0
	private var stopped = false
	private let maximumFileBytes = 33_554_432, maximumBytes = 67_108_864

	private func identity(_ descriptor: Int32) throws -> stat {
		var value = stat()
		guard fstat(descriptor, &value) == 0 else { throw OwnedRuntimeReferenceFailure.source }
		return value
	}

	private func hold(parent: Int32?, name: String, path: String, directory: Bool, protected: Bool = false) throws -> Int32 {
		guard !stopped, nodes.count < 128 else { throw OwnedRuntimeReferenceFailure.source }
		var named = stat()
		let result = parent.map { fstatat($0, name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(path, &named)
		let kind = directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
		guard result == 0, named.st_mode & mode_t(S_IFMT) == kind,
			directory || named.st_nlink == 1 else { throw OwnedRuntimeReferenceFailure.source }
		let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
		let descriptor = parent.map { openat($0, name, flags) } ?? open(path, flags)
		guard descriptor >= 0 else { throw OwnedRuntimeReferenceFailure.source }
		// Custody precedes every possible post-open refusal.
		nodes.append(Node(descriptor: descriptor, parent: parent, name: name, path: path,
			identity: InstalledVHDFileIdentity(named), directory: directory, protected: protected, digest: nil))
		let held = try identity(descriptor)
		guard InstalledVHDFileIdentity(held) == InstalledVHDFileIdentity(named),
			directory || held.st_nlink == 1 else { throw OwnedRuntimeReferenceFailure.source }
		return descriptor
	}

	private func canonicalParts(_ path: String) throws -> [String] {
		guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("//") else { throw OwnedRuntimeReferenceFailure.source }
		let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw OwnedRuntimeReferenceFailure.source }
		return parts
	}

	private func read(_ descriptor: Int32, size: off_t) throws -> Data {
		guard size >= 0, size <= off_t(maximumFileBytes) else { throw OwnedRuntimeReferenceFailure.source }
		var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536), offset: off_t = 0
		while offset < size {
			let wanted = min(buffer.count, Int(size - offset))
			let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, offset) }
			guard count > 0 else { throw OwnedRuntimeReferenceFailure.source }
			result.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
		}
		try recut(descriptor)
		return result
	}

	/// Protected service ancestors use the existing genuine root/ACL snapshot implementation.
	func retain(_ path: String, protected: Bool, dataLimit: Int? = nil) throws -> Data {
		let parts = try canonicalParts(path)
		let parentPath = "/" + parts.dropLast().joined(separator: "/")
		let parent: Int32
		if protected {
			let snapshot = InstalledVHDStaticSnapshot()
			directories.append(snapshot)
			parent = try snapshot.pin(parentPath)
			guard snapshot.ordinaryRootOwned == true else { throw OwnedRuntimeReferenceFailure.source }
		} else {
			var held = try hold(parent: nil, name: "", path: "/", directory: true)
			var prefix = ""
			for part in parts.dropLast() {
				prefix += "/" + part
				held = try hold(parent: held, name: part, path: prefix, directory: true)
			}
			parent = held
		}
		guard let name = parts.last else { throw OwnedRuntimeReferenceFailure.source }
		let descriptor = try hold(parent: parent, name: name, path: path, directory: false, protected: protected)
		let held = try identity(descriptor)
		if protected { try protectedFile(descriptor, held: held) }
		guard held.st_size >= 0, held.st_size <= off_t(maximumFileBytes),
			dataLimit.map({ held.st_size <= off_t($0) }) ?? true else { throw OwnedRuntimeReferenceFailure.source }
		bytes += Int(held.st_size)
		guard bytes <= maximumBytes else { throw OwnedRuntimeReferenceFailure.source }
		let data = try read(descriptor, size: held.st_size)
		let previous = nodes.removeLast()
		nodes.append(Node(descriptor: descriptor, parent: parent, name: name, path: path,
			identity: previous.identity, directory: false, protected: protected, digest: Data(SHA256.hash(data: data))))
		try verify()
		return data
	}

	private func protectedFile(_ descriptor: Int32, held: stat) throws {
		guard held.st_uid == 0, held.st_mode & 0o022 == 0,
			let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { throw OwnedRuntimeReferenceFailure.source }
		let observation: Result<Bool, Error>
		do { observation = .success(try InstalledVHDProbeNative.aclIsEmpty(acl)) }
		catch { observation = .failure(error) }
		guard acl_free(UnsafeMutableRawPointer(acl)) == 0,
			try observation.get() else { throw OwnedRuntimeReferenceFailure.source }
	}

	/// Metadata and protection are sampled again after bytes/hash; no new authority is supplied.
	private func recut(_ descriptor: Int32) throws {
		guard !stopped, let node = nodes.first(where: { $0.descriptor == descriptor }) else { throw OwnedRuntimeReferenceFailure.source }
		for snapshot in directories {
			guard snapshot.ordinaryRootOwned == true else { throw OwnedRuntimeReferenceFailure.source }
			try snapshot.verify()
		}
		let held = try identity(node.descriptor)
		var named = stat()
		let result = node.parent.map { fstatat($0, node.name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(node.path, &named)
		guard result == 0, InstalledVHDFileIdentity(held) == node.identity,
			InstalledVHDFileIdentity(named) == node.identity,
			node.directory || (held.st_nlink == 1 && named.st_nlink == 1) else { throw OwnedRuntimeReferenceFailure.source }
		if node.protected { try protectedFile(node.descriptor, held: held) }
	}

	func recutAll() throws {
		guard !stopped else { throw OwnedRuntimeReferenceFailure.source }
		for node in nodes { try recut(node.descriptor) }
	}

	func verify() throws {
		guard !stopped else { throw OwnedRuntimeReferenceFailure.source }
		for snapshot in directories {
			guard snapshot.ordinaryRootOwned == true else { throw OwnedRuntimeReferenceFailure.source }
			try snapshot.verify()
		}
		for node in nodes {
			let held = try identity(node.descriptor)
			var named = stat()
			let result = node.parent.map { fstatat($0, node.name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(node.path, &named)
			guard result == 0, InstalledVHDFileIdentity(held) == node.identity,
				InstalledVHDFileIdentity(named) == node.identity,
				node.directory || (held.st_nlink == 1 && named.st_nlink == 1) else { throw OwnedRuntimeReferenceFailure.source }
			if node.protected { try protectedFile(node.descriptor, held: held) }
			if let digest = node.digest {
				guard Data(SHA256.hash(data: try read(node.descriptor, size: held.st_size))) == digest else { throw OwnedRuntimeReferenceFailure.source }
			}
			try recut(node.descriptor)
		}
	}

	/// Close once, retaining refusal at the owner; numeric descriptors cannot be retried.
	func closeAll() -> Bool {
		guard !stopped else { return false }
		stopped = true
		var complete = true
		for node in nodes.reversed() { if close(node.descriptor) != 0 { complete = false } }
		nodes.removeAll()
		for snapshot in directories.reversed() { do { try snapshot.closeAll() } catch { complete = false } }
		directories.removeAll()
		return complete
	}

	deinit { if !stopped { _ = closeAll() } }
}

private struct OwnedRuntimeServiceSource {
	let label: String, plist: String, bundle: String, executableRelative: String, identifier: String
	var executable: String { bundle + "/" + executableRelative }
	private static func absolute(_ value: String) -> Bool {
		value.hasPrefix("/") && !value.contains("\0") &&
			value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
	}
	static func decode(_ data: Data) throws -> OwnedRuntimeServiceSource {
		guard let text = String(data: data, encoding: .utf8), !text.contains("\\") else { throw OwnedRuntimeReferenceFailure.policy }
		let keys = ["schema", "roles", "service", "runtime_identifiers", "policy_sha256", "identities_source_sha256",
			"role", "label", "plist", "bundle", "executable_relative", "run_at_load", "keep_alive", "user_name", "core", "console", "cli"]
		for key in keys {
			let expression = try NSRegularExpression(pattern: "\"" + key + "\"\\s*:")
			guard expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1 else { throw OwnedRuntimeReferenceFailure.policy }
		}
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			Set(object.keys) == Set(["schema", "roles", "service", "runtime_identifiers", "policy_sha256", "identities_source_sha256"]),
			let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), !["f", "d"].contains(String(cString: schema.objCType)), schema.intValue == 1,
			object["roles"] as? [String] == ["core", "console", "cli"],
			let identifiers = object["runtime_identifiers"] as? [String: String], Set(identifiers.keys) == Set(["core", "console", "cli"]),
			Set(identifiers.values).count == 3, identifiers.values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
			let service = object["service"] as? [String: Any],
			Set(service.keys) == Set(["role", "label", "plist", "bundle", "executable_relative", "run_at_load", "keep_alive", "user_name"]),
			service["role"] as? String == "core", service["user_name"] as? String == "root",
			let run = service["run_at_load"] as? NSNumber, CFGetTypeID(run) == CFBooleanGetTypeID(), !run.boolValue,
			let keep = service["keep_alive"] as? NSNumber, CFGetTypeID(keep) == CFBooleanGetTypeID(), !keep.boolValue,
			let label = service["label"] as? String, !label.isEmpty,
			label.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)) }),
			let plist = service["plist"] as? String, absolute(plist), plist.hasSuffix(".plist"),
			let bundle = service["bundle"] as? String, absolute(bundle), bundle.hasSuffix(".app"),
			let executable = service["executable_relative"] as? String,
			!executable.hasPrefix("/"), absolute("/" + executable), executable.hasPrefix("Contents/MacOS/"), executable.filter({ $0 == "/" }).count == 2,
			let identifier = identifiers["core"] else { throw OwnedRuntimeReferenceFailure.policy }
		// Hashes are build provenance only. They never supply signer, currentness or admission.
		return OwnedRuntimeServiceSource(label: label, plist: plist, bundle: bundle,
			executableRelative: executable, identifier: identifier)
	}

	func validatePlist(_ data: Data) throws {
		guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			Set(object.keys) == Set(["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "UserName"]),
			object["Label"] as? String == label, object["ProgramArguments"] as? [String] == [executable],
			object["UserName"] as? String == "root",
			let run = object["RunAtLoad"] as? NSNumber, CFGetTypeID(run) == CFBooleanGetTypeID(), !run.boolValue,
			let keep = object["KeepAlive"] as? NSNumber, CFGetTypeID(keep) == CFBooleanGetTypeID(), !keep.boolValue else { throw OwnedRuntimeReferenceFailure.policy }
	}
}

/// Owns static code/source proof only, independently of user consent and native service lifecycle.
final class OwnedRuntimeServiceReferenceOwner {
	final class Token { fileprivate init() {} }
	enum Refusal: Equatable { case launcherPrincipalUnavailable, sourceUnavailable, policyRefused, signatureRefused }
	private let lock = NSRecursiveLock(), token = Token(), files = OwnedRuntimeReferenceFiles()
	private var frames: UInt = 0
	private var admitted = false, stopped = false, closing = false, settled = false, closeRefused = false
	private var failure: Refusal?
	private var principal: SecCode?
	private var launcherPath: String?, launcherBundle: URL?, principalLeaf: Data?
	private var source: OwnedRuntimeServiceSource?
	private init() {}

	/// No caller certificate, path, provider, status, PID or JSON can mint production authority.
	static func acquire() -> OwnedRuntimeServiceReferenceOwner {
		let owner = OwnedRuntimeServiceReferenceOwner()
		owner.lock.lock(); defer { owner.lock.unlock() }
		owner.frames = 1; defer { owner.leaveFrame() }
		do {
			try owner.retainPrincipal()
			guard let bundle = owner.launcherBundle else { throw OwnedRuntimeReferenceFailure.unavailable }
			let reference = try owner.files.retain(bundle.path + "/Contents/Resources/static/ergopti_plus/_shared/data/owned_runtime_service_reference.generated.json", protected: false, dataLimit: 65_536)
			try owner.validatePrincipal()
			let source = try OwnedRuntimeServiceSource.decode(reference)
			owner.source = source
			let executable = try owner.files.retain(source.executable, protected: true)
			guard !executable.isEmpty else { throw OwnedRuntimeReferenceFailure.source }
			let info = try owner.files.retain(source.bundle + "/Contents/Info.plist", protected: true, dataLimit: 1_048_576)
			guard let fields = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
				fields["CFBundleIdentifier"] as? String == source.identifier,
				fields["CFBundleExecutable"] as? String == source.executableRelative.split(separator: "/").last.map(String.init) else { throw OwnedRuntimeReferenceFailure.policy }
			try source.validatePlist(owner.files.retain(source.plist, protected: true, dataLimit: 65_536))
			try owner.validateAll()
			guard !owner.stopped else { throw OwnedRuntimeReferenceFailure.unavailable }
			owner.admitted = true
		} catch {
			owner.stopped = true
			switch error {
			case OwnedRuntimeReferenceFailure.unavailable: owner.failure = .launcherPrincipalUnavailable
			case OwnedRuntimeReferenceFailure.policy: owner.failure = .policyRefused
			case OwnedRuntimeReferenceFailure.signature: owner.failure = .signatureRefused
			default: owner.failure = .sourceUnavailable
			}
		}
		return owner
	}

	private func check(_ status: OSStatus) throws {
		guard status == errSecSuccess else { throw OwnedRuntimeReferenceFailure.signature }
	}

	private func signing(_ code: SecStaticCode, identifier: String) throws -> Data {
		var information: CFDictionary?
		try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
		guard let fields = information as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier,
			let cms = fields[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
			let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first else { throw OwnedRuntimeReferenceFailure.signature }
		let leaf = SecCertificateCopyData(certificate) as Data
		guard !leaf.isEmpty, leaf.count <= 1_048_576 else { throw OwnedRuntimeReferenceFailure.signature }
		return leaf
	}

	private func validateBundle(_ bundle: URL, identifier: String, leaf: Data) throws {
		try files.verify()
		var code: SecStaticCode?
		try check(SecStaticCodeCreateWithPath(bundle as CFURL, [], &code))
		guard let code else { throw OwnedRuntimeReferenceFailure.signature }
		let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
		try check(SecStaticCodeCheckValidity(code, flags, nil))
		for architecture in ["x86_64", "arm64"] {
			try files.verify()
			var slice: SecStaticCode?
			let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
			try check(SecStaticCodeCreateWithPathAndAttributes(bundle as CFURL, [], attributes, &slice))
			guard let slice else { throw OwnedRuntimeReferenceFailure.signature }
			try check(SecStaticCodeCheckValidity(slice, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
			guard try signing(slice, identifier: identifier) == leaf else { throw OwnedRuntimeReferenceFailure.signature }
			try files.verify()
		}
		try files.verify()
	}

	private func retainPrincipal() throws {
		guard Bundle.main.bundleIdentifier == kErgoptiBundleId, Bundle.main.bundleURL.pathExtension == "app",
			let executable = Bundle.main.executableURL else { throw OwnedRuntimeReferenceFailure.unavailable }
		var live: SecCode?, path: CFURL?, code: SecStaticCode?
		guard SecCodeCopySelf([], &live) == errSecSuccess, let live,
			SecCodeCopyPath(live, [], &path) == errSecSuccess, let path else { throw OwnedRuntimeReferenceFailure.unavailable }
		let nativePath = (path as URL).path
		guard nativePath == executable.path || nativePath == Bundle.main.bundleURL.path else { throw OwnedRuntimeReferenceFailure.unavailable }
		try check(SecCodeCheckValidity(live, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
		try check(SecCodeCopyStaticCode(live, [], &code))
		guard let code else { throw OwnedRuntimeReferenceFailure.unavailable }
		let leaf: Data
		do { leaf = try signing(code, identifier: kErgoptiBundleId) }
		catch { throw OwnedRuntimeReferenceFailure.unavailable }
		principal = live; principalLeaf = leaf; launcherPath = nativePath; launcherBundle = Bundle.main.bundleURL
		_ = try files.retain(executable.path, protected: false)
		try validatePrincipal()
	}

	private func validatePrincipal() throws {
		guard !stopped, let principal, let leaf = principalLeaf, let bundle = launcherBundle, let launcherPath else { throw OwnedRuntimeReferenceFailure.unavailable }
		try files.verify()
		var path: CFURL?, code: SecStaticCode?
		try check(SecCodeCopyPath(principal, [], &path))
		guard let path, (path as URL).path == launcherPath else { throw OwnedRuntimeReferenceFailure.unavailable }
		try check(SecCodeCheckValidity(principal, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
		try check(SecCodeCopyStaticCode(principal, [], &code))
		guard let code, try signing(code, identifier: kErgoptiBundleId) == leaf else { throw OwnedRuntimeReferenceFailure.signature }
		try validateBundle(bundle, identifier: kErgoptiBundleId, leaf: leaf)
	}

	private func validateAll() throws {
		try validatePrincipal()
		guard let source, let leaf = principalLeaf else { throw OwnedRuntimeReferenceFailure.unavailable }
		try validateBundle(URL(fileURLWithPath: source.bundle), identifier: source.identifier, leaf: leaf)
		try validatePrincipal(); try files.verify()
		try files.recutAll()
	}

	func refusal() -> Refusal? {
		lock.lock(); defer { lock.unlock() }
		return failure
	}

	func identity() -> Token? {
		lock.lock(); defer { lock.unlock() }
		return admitted && !stopped ? token : nil
	}

	func current(_ expected: Token) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard expected === token, admitted, !stopped, !closing, frames < UInt.max else { return false }
		frames += 1; defer { leaveFrame() }
		do { try validateAll(); return admitted && !stopped }
		catch { stopped = true; admitted = false; return false }
	}

	/// Acknowledges only this static owner's completed descriptor custody retirement.
	@discardableResult
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		stopped = true; admitted = false
		if frames == 0 { drain() }
		return settled && !closeRefused
	}

	func retired() -> Bool {
		lock.lock(); defer { lock.unlock() }
		return settled && !closeRefused
	}

	private func leaveFrame() {
		precondition(frames > 0)
		frames -= 1
		if stopped, frames == 0 { drain() }
	}

	private func drain() {
		guard stopped, frames == 0, !closing, !settled, !closeRefused else { return }
		closing = true; frames = 1
		closeRefused = !files.closeAll()
		principal = nil; principalLeaf = nil; launcherPath = nil; launcherBundle = nil; source = nil
		frames = 0; closing = false
		if !closeRefused { settled = true }
	}

	deinit { _ = retire() }
}

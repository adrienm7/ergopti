// Sources/ErgoptiPlus/OwnedRuntimePublisherIdentity.swift
// Owned-publisher trust binds native current images and explicit protected staging, never caller certificates.
import CryptoKit
#if SWIFT_PACKAGE
import CPOSIXCompatibility
#endif
import Darwin
import Foundation
import Security

/// Signature observations alone are not publisher, installation, consent or runtime readiness capabilities.
enum OwnedRuntimePublisherSignature {
	enum Role: String {
		case launcher = "com.ergoptiplus.app"
		case hammerspoon = "com.ergoptiplus.app.hammerspoon"
		case installer = "com.ergoptiplus.app.runtime-installer"
		case core = "com.ergoptiplus.remap.core"
		case console = "com.ergoptiplus.remap.console"
		case cli = "com.ergoptiplus.remap.cli"
		case installedSource = "com.ergoptiplus.app.installed-physical-source"
	}
	static let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
	private static func requirement(_ role: Role, leaf: Data? = nil) -> SecRequirement? {
		var expression = "identifier \"" + role.rawValue + "\""
		if let leaf {
			let digest = Insecure.SHA1.hash(data: leaf).map { String(format: "%02x", $0) }.joined()
			expression += " and certificate leaf = H\"" + digest + "\""
		}
		var result: SecRequirement?
		guard SecRequirementCreateWithString(expression as CFString, [], &result) == errSecSuccess else { return nil }
		return result
	}
	/// All slices must cryptographically match the same observed CMS leaf and exact closed role.
	/// The native code object is inspected; no decoded certificate, Team ID or JSON field grants trust.
	static func information(_ code: SecStaticCode, role: Role) -> [String: Any]? {
		guard let identity = requirement(role), SecStaticCodeCheckValidity(code, strict, identity) == errSecSuccess else { return nil }
		var result: CFDictionary?
		guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
			let fields = result as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == role.rawValue,
			let cms = fields[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
			let flags = fields[kSecCodeInfoFlags as String] as? NSNumber, flags.uint32Value & ergopti_owned_runtime_signature_adhoc_flag() == 0,
			let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first else { return nil }
		let leaf = SecCertificateCopyData(certificate) as Data
		guard !leaf.isEmpty, let sameLeaf = requirement(role, leaf: leaf),
			SecStaticCodeCheckValidity(code, strict, sameLeaf) == errSecSuccess else { return nil }
		return fields
	}
	static func leaf(_ code: SecStaticCode, role: Role) -> Data? {
		guard let fields = information(code, role: role),
			let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first else { return nil }
		return SecCertificateCopyData(first) as Data
	}
	static func currentLeaf(_ principal: SecCode, role: Role) -> Data? {
		var code: SecStaticCode?
		guard SecCodeCheckValidity(principal, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
			SecCodeCopyStaticCode(principal, [], &code) == errSecSuccess, let code, let leaf = leaf(code, role: role),
			let sameLeaf = requirement(role, leaf: leaf),
			SecCodeCheckValidity(principal, SecCSFlags(rawValue: kSecCSStrictValidate), sameLeaf) == errSecSuccess else { return nil }
		return leaf
	}
}

/// Only the actual executing fixed launcher or its explicitly administrator-staged helper can create this owner.
/// Self-signed CMS is supported for owned code; the official Apple/pqrs dependency has a separate trust policy.
final class OwnedRuntimePublisherIdentity {
	private static let stageParent = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private let principal: SecCode, role: OwnedRuntimePublisherSignature.Role, tree: OwnedRuntimeInstallTree
	private let executable: URL, descriptor: Int32, identity: stat, bundle: URL
	private let creator = getpid(), originalUID: uid_t
	let leaf: Data
	private let lock = NSRecursiveLock()
	private var revoked = false, closeAttempted = false, closeRefused = false
	private init(principal: SecCode, role: OwnedRuntimePublisherSignature.Role, tree: OwnedRuntimeInstallTree,
		executable: URL, descriptor: Int32, identity: stat, bundle: URL, leaf: Data) {
		self.principal = principal; self.role = role; self.tree = tree; self.executable = executable
		self.descriptor = descriptor; self.identity = identity; self.bundle = bundle; self.leaf = leaf; originalUID = getuid()
	}
	static func currentLauncher() -> OwnedRuntimePublisherIdentity? { acquire(role: .launcher, protected: false) }
	static func currentStagedInstaller() -> OwnedRuntimePublisherIdentity? { acquire(role: .installer, protected: true) }
	private static func acquire(role: OwnedRuntimePublisherSignature.Role, protected: Bool) -> OwnedRuntimePublisherIdentity? {
		let bundle = Bundle.main.bundleURL.standardizedFileURL
		guard getuid() == geteuid(), (protected ? getuid() == 0 : getuid() != 0),
			Bundle.main.bundleIdentifier == role.rawValue, bundle.pathExtension == "app",
			let executable = Bundle.main.executableURL?.standardizedFileURL else { return nil }
		if protected {
			let stage = bundle.deletingLastPathComponent(), prefix = ".runtime-installer-"
			guard bundle.lastPathComponent == "Helper.app", stage.deletingLastPathComponent() == stageParent,
				stage.lastPathComponent.hasPrefix(prefix),
				UUID(uuidString: String(stage.lastPathComponent.dropFirst(prefix.count))) != nil,
				executable == bundle.appendingPathComponent("Contents/MacOS/ErgoptiPlus-Runtime-Installer") else { return nil }
		}
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal,
			let leaf = OwnedRuntimePublisherSignature.currentLeaf(principal, role: role),
			nativePath(principal, bundle: bundle, executable: executable) else { return nil }
		do {
			let tree = try OwnedRuntimeInstallTree(root: bundle, protected: protected, includeChildren: false)
			let descriptor = open(executable.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.source }
			var admitted = false; defer { if !admitted { Darwin.close(descriptor); _ = tree.releaseOwnedDescriptors() } }
			var identity = stat()
			guard fstat(descriptor, &identity) == 0, identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
				identity.st_nlink == 1, identity.st_size > 0, identity.st_size <= 268_435_456,
				!protected || (identity.st_uid == 0 && identity.st_mode & 0o6022 == 0) else { throw OwnedRuntimeInstallFailure.protection }
			let owner = OwnedRuntimePublisherIdentity(principal: principal, role: role, tree: tree, executable: executable,
				descriptor: descriptor, identity: identity, bundle: bundle, leaf: leaf)
			admitted = true
			guard owner.current() else { _ = owner.retire(); return nil }; return owner
		} catch { return nil }
	}
	private static func nativePath(_ principal: SecCode, bundle: URL, executable: URL) -> Bool {
		var code: SecStaticCode?, path: CFURL?, information: CFDictionary?
		guard SecCodeCopyStaticCode(principal, [], &code) == errSecSuccess, let code,
			SecCodeCopyPath(code, [], &path) == errSecSuccess, let path,
			SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any], let main = fields[kSecCodeInfoMainExecutable as String] as? URL,
			main.standardizedFileURL == executable else { return false }
		let actual = (path as URL).standardizedFileURL
		return actual == bundle || actual == executable
	}
	private static func sameImage(_ before: stat, _ after: stat) -> Bool {
		before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_mode == after.st_mode
			&& before.st_uid == after.st_uid && before.st_gid == after.st_gid && before.st_nlink == after.st_nlink
			&& before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
			&& before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
			&& before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
	}
	func current() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !revoked, getpid() == creator, getuid() == originalUID, geteuid() == originalUID,
			Bundle.main.bundleURL.standardizedFileURL == bundle,
			OwnedRuntimePublisherSignature.currentLeaf(principal, role: role) == leaf,
			Self.nativePath(principal, bundle: bundle, executable: executable) else { return false }
		do { try tree.verifyAnchor() } catch { return false }
		var held = stat(), named = stat()
		return fstat(descriptor, &held) == 0 && lstat(executable.path, &named) == 0
			&& Self.sameImage(identity, held) && Self.sameImage(held, named)
	}
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }; revoked = true
		if !closeAttempted {
			closeAttempted = true; closeRefused = Darwin.close(descriptor) != 0
			if !tree.releaseOwnedDescriptors() { closeRefused = true }
		}
		return !closeRefused
	}
	deinit { _ = retire() }
}

/// Installed publisher observation derives only from the fixed actual protected Core image and its original tree.
/// It is not a process, shared namespace lease, capture owner, dependency approval or READY acknowledgement.
final class OwnedRuntimeInstalledPublisher {
	private static let runtime = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/Runtime", isDirectory: true)
	private static let coreRelative = "ErgoptiPlus-Remap-Core.app"
	private let tree: OwnedRuntimeInstallTree, code: SecStaticCode
	let leaf: Data
	private let lock = NSLock()
	private var retired = false, closeRefused = false
	private init(tree: OwnedRuntimeInstallTree, code: SecStaticCode, leaf: Data) { self.tree = tree; self.code = code; self.leaf = leaf }
	static func acquire() -> OwnedRuntimeInstalledPublisher? {
		do {
			let tree = try OwnedRuntimeInstallTree(root: runtime, protected: true)
			var admitted = false; defer { if !admitted { _ = tree.releaseOwnedDescriptors() } }
			var code: SecStaticCode?
			guard SecStaticCodeCreateWithPath(runtime.appendingPathComponent(coreRelative) as CFURL, [], &code) == errSecSuccess,
				let code, let leaf = OwnedRuntimePublisherSignature.leaf(code, role: .core) else { return nil }
			try OwnedRuntimeInstallOwner.validateInstalledProductsForPeer(at: runtime, leaf: leaf); try tree.verify()
			let owner = OwnedRuntimeInstalledPublisher(tree: tree, code: code, leaf: leaf)
			admitted = true
			guard owner.current() else { _ = owner.retire(); return nil }; return owner
		} catch { return nil }
	}
	func current() -> Bool {
		lock.lock(); defer { lock.unlock() }; guard !retired else { return false }
		do { return try Self.observeOriginalTree(tree, code: code, role: .core, expected: leaf) } catch { return false }
	}
	private static func observeOriginalTree(_ tree: OwnedRuntimeInstallTree, code: SecStaticCode,
		role: OwnedRuntimePublisherSignature.Role, expected: Data, afterObservation: (() throws -> Void)? = nil) throws -> Bool {
		try tree.verify()
		let observed = OwnedRuntimePublisherSignature.leaf(code, role: role)
		try afterObservation?()
		// Security is a foreign boundary: an original tree must still be current after its signature observation.
		try tree.verify()
		return observed == expected
	}
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if !retired { retired = true; closeRefused = !tree.releaseOwnedDescriptors() }; return !closeRefused
	}
	deinit { _ = retire() }
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Actual filesystem/signature ordering control returns only an observation, never a protected publisher owner.
	static func fixtureObserveOriginalTree(root: URL, code: SecStaticCode, afterObservation: (() throws -> Void)? = nil) throws -> Bool {
		let tree = try OwnedRuntimeInstallTree(root: root, protected: false)
		defer { _ = tree.releaseOwnedDescriptors() }
		guard let leaf = OwnedRuntimePublisherSignature.leaf(code, role: .launcher) else { throw OwnedRuntimeInstallFailure.signature }
		return try observeOriginalTree(tree, code: code, role: .launcher, expected: leaf, afterObservation: afterObservation)
	}
	#endif
}

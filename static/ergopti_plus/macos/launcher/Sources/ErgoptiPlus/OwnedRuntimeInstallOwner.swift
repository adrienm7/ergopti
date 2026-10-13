// Sources/ErgoptiPlus/OwnedRuntimeInstallOwner.swift
// First-install custody derives from a signed, protected privileged helper, never a caller receipt.
import Darwin
import Foundation
import Security

/// Files can be published without claiming service start, dependency compatibility or capture readiness.
final class OwnedRuntimeInstallOwner {
	enum State: String { case held, published, refused, cleanupPending = "cleanup-pending" }
	private struct Product {
		let path: String, identifier: String, executableRelative: String?
	}
	// Fixed native product identity, rather than selectable paths or application defaults.
	private static let products = [
		Product(path: "ErgoptiPlus-Remap-Core.app", identifier: "com.ergoptiplus.remap.core", executableRelative: "Contents/MacOS/ErgoptiPlus-Remap-Core"),
		Product(path: "ErgoptiPlus-Remap-Console.app", identifier: "com.ergoptiplus.remap.console", executableRelative: "Contents/MacOS/ErgoptiPlus-Remap-Console"),
		Product(path: "bin/ergoptiplus_remap_cli", identifier: "com.ergoptiplus.remap.cli", executableRelative: nil)
	]
	private static let parent = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private let lock = NSLock()
	private let publisher: OwnedRuntimePublisherIdentity
	private let principal: SecCode, leaf: Data, payload: URL, source: OwnedRuntimeInstallTree
	private let helper: OwnedRuntimeInstallTree
	private var staging: URL?
	private var journalDescriptor: Int32?
	private var scratch: OwnedRuntimeInstallScratch?
	private var filesPublished = false
	private var installParent: OwnedRuntimeInstallTree?
	private var installParentDescriptor: Int32?
	private(set) var state = State.held
	private init(publisher: OwnedRuntimePublisherIdentity, principal: SecCode, leaf: Data, payload: URL, source: OwnedRuntimeInstallTree, helper: OwnedRuntimeInstallTree) {
		self.publisher = publisher; self.principal = principal; self.leaf = leaf; self.payload = payload; self.source = source; self.helper = helper
	}

	deinit { if let descriptor = journalDescriptor { Darwin.close(descriptor) }; if let descriptor = installParentDescriptor { Darwin.close(descriptor) } }

	/// No caller arguments: only an already administrator-staged launcher can acquire installation custody.
	static func acquire() -> OwnedRuntimeInstallOwner? {
		guard geteuid() == 0, getuid() == 0, Bundle.main.bundleIdentifier == "com.ergoptiplus.app.runtime-installer",
			Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL else { return nil }
		guard let publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller() else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal,
			let leaf = signingLeaf(principal: principal, identifier: "com.ergoptiplus.app.runtime-installer"), publisher.current(), leaf == publisher.leaf else { return nil }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			let payload = resources.appendingPathComponent("OwnedRuntime", isDirectory: true)
			let source = try OwnedRuntimeInstallTree(root: payload, protected: true)
			try validateProducts(at: payload, leaf: leaf)
			try source.verify(); try helper.verify()
			return OwnedRuntimeInstallOwner(publisher: publisher, principal: principal, leaf: leaf, payload: payload, source: source, helper: helper)
		} catch { return nil }
	}
	private static let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
	private static func leafOf(_ code: SecStaticCode, identifier: String) -> Data? {
		guard let role = OwnedRuntimePublisherSignature.Role(rawValue: identifier) else { return nil }
		return OwnedRuntimePublisherSignature.leaf(code, role: role)
	}
	private static func signingLeaf(principal: SecCode, identifier: String) -> Data? {
		var code: SecStaticCode?
		guard SecCodeCheckValidity(principal, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
			SecCodeCopyStaticCode(principal, [], &code) == errSecSuccess, let code else { return nil }
		return leafOf(code, identifier: identifier)
	}
	/// Supporting validator only. The peer factory supplies its own fixed native protected tree and executing leaf.
	/// Calling this byte/signature inventory validator never constructs an installed peer or grants launch authority.
	static func validateInstalledProductsForPeer(at directory: URL, leaf: Data) throws {
		try validateProducts(at: directory, leaf: leaf)
	}
	/// Inert packaging validation reuses the actual parser/product roster and never calls a privileged factory.
	static func validateSignedProductsForBuild(at directory: URL, leaf: Data) throws {
		try validateProducts(at: directory, leaf: leaf)
		for product in products {
			let path = directory.appendingPathComponent(product.path)
			var code: SecStaticCode?, requirement: SecRequirement?
			let expression = "identifier \"" + product.identifier + "\""
			guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
				SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
				SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else { throw OwnedRuntimeInstallFailure.signature }
		}
	}
	static func validateSignedInstallerForBuild(at helper: URL, leaf: Data) throws {
		let identifier = "com.ergoptiplus.app.runtime-installer"
		guard helper.pathExtension == "app", Set(try FileManager.default.contentsOfDirectory(atPath: helper.path)) == ["Contents"] else {
			throw OwnedRuntimeInstallFailure.signature
		}
		let contents = helper.appendingPathComponent("Contents", isDirectory: true)
		let names = Set(try FileManager.default.contentsOfDirectory(atPath: contents.path))
		let required: Set<String> = ["Info.plist", "MacOS", "Resources", "_CodeSignature"]
		guard names == required || names == required.union(["PkgInfo"]),
			try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("MacOS").path) == ["ErgoptiPlus-Runtime-Installer"],
			try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("Resources").path) == ["OwnedRuntime"] else {
			throw OwnedRuntimeInstallFailure.signature
		}
		if names.contains("PkgInfo") {
			guard try Data(contentsOf: contents.appendingPathComponent("PkgInfo")) == Data("APPL????".utf8) else { throw OwnedRuntimeInstallFailure.signature }
		}
		var code: SecStaticCode?, requirement: SecRequirement?
		let expression = "identifier \"" + identifier + "\""
		guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
			SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess,
			leafOf(code, identifier: identifier) == leaf,
			universalExecutable(try Data(contentsOf: contents.appendingPathComponent("MacOS/ErgoptiPlus-Runtime-Installer"))) else {
			throw OwnedRuntimeInstallFailure.signature
		}
		try validateSignedProductsForBuild(at: contents.appendingPathComponent("Resources/OwnedRuntime", isDirectory: true), leaf: leaf)
	}
	private static func validateProducts(at directory: URL, leaf: Data) throws {
		guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(["ErgoptiPlus-Remap-Core.app", "ErgoptiPlus-Remap-Console.app", "bin"]) else {
			throw OwnedRuntimeInstallFailure.signature
		}
		guard try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("bin").path) == ["ergoptiplus_remap_cli"] else {
			throw OwnedRuntimeInstallFailure.signature
		}
		for product in products {
			let bundle = directory.appendingPathComponent(product.path)
			var code: SecStaticCode?
			guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
				leafOf(code, identifier: product.identifier) == leaf else { throw OwnedRuntimeInstallFailure.signature }
			let executable = product.executableRelative.map { bundle.appendingPathComponent($0) } ?? bundle
			let bytes = try Data(contentsOf: executable)
			guard universalExecutable(bytes) else { throw OwnedRuntimeInstallFailure.signature }
		}
	}
	/// The fixed native module has its own exact bundle file type and signed role, never an executable grant.
	static func validateSignedInstalledSourceForBuild(at module: URL, leaf: Data) throws {
		let identifier = "com.ergoptiplus.app.installed-physical-source"
		guard module.lastPathComponent == "installed_physical_source.so" else { throw OwnedRuntimeInstallFailure.signature }
		let parent = try OwnedRuntimeInstallTree(root: module.deletingLastPathComponent(), protected: false)
		try parent.verify()
		var code: SecStaticCode?, requirement: SecRequirement?
		let expression = "identifier \"" + identifier + "\""
		guard SecStaticCodeCreateWithPath(module as CFURL, [], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
			SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess, leafOf(code, identifier: identifier) == leaf,
			systemClosedBundleForInstalledSource(try Data(contentsOf: module)) else { throw OwnedRuntimeInstallFailure.signature }
		try parent.verify()
		guard parent.releaseOwnedDescriptors() else { throw OwnedRuntimeInstallFailure.cleanupPending }
	}
	/// Both intended native slices and their load paths must be closed before these bytes can be published.
	/// Private/framework dependencies are unavailable until a signed packaging closure is implemented.
	private static func universalExecutable(_ data: Data) -> Bool { universalImage(data, expectedType: 2) }
	private static func universalImage(_ data: Data, expectedType: UInt32) -> Bool {
		func word(_ offset: Int, little: Bool) -> UInt32? {
			guard offset >= 0, offset <= data.count - 4 else { return nil }
			let bytes = Array(data[offset..<(offset + 4)])
			return little ? UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
				: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
		}
		func wide(_ offset: Int, little: Bool) -> UInt64? {
			guard let first = word(offset, little: little), let second = word(offset + 4, little: little) else { return nil }
			return little ? UInt64(second) << 32 | UInt64(first) : UInt64(first) << 32 | UInt64(second)
		}
		func systemPath(_ path: String, rpath: Bool = false) -> Bool {
			guard !path.contains("//"), path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { return false }
			if rpath { return path == "/usr/lib/swift" || path == "/System/Library/Frameworks" }
			return path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/Frameworks/")
		}
		func thin(offset: Int, size: Int, cpu: UInt32) -> Bool {
			guard size >= 32, offset <= data.count - size, let magic = word(offset, little: false),
				magic == 0xcffaedfe || magic == 0xfeedfacf else { return false }
			let little = magic == 0xcffaedfe
			guard word(offset + 4, little: little) == cpu, word(offset + 12, little: little) == expectedType,
				let commands = word(offset + 16, little: little), commands <= 128,
				let commandBytes = word(offset + 20, little: little), commandBytes <= 65536,
				Int(commandBytes) <= size - 32 else { return false }
			var cursor = offset + 32
			let end = cursor + Int(commandBytes)
			for _ in 0..<commands {
				guard let command = word(cursor, little: little), let length = word(cursor + 4, little: little),
					length >= 8, length % 8 == 0, Int(length) <= end - cursor else { return false }
				let load = [UInt32(0xc), 0x80000018, 0x8000001f, 0x80000023, 0x20].contains(command)
				if load || command == 0x8000001c || command == 0xe {
					let minimum = load ? 24 : 12
					guard Int(length) >= minimum, let name = word(cursor + 8, little: little),
						Int(name) >= minimum, name < length else { return false }
					let bytes = data[(cursor + Int(name))..<(cursor + Int(length))]
					guard let zero = bytes.firstIndex(of: 0),
						let path = String(data: Data(bytes[..<zero]), encoding: .utf8), !path.isEmpty else { return false }
					if command == 0xe { guard path == "/usr/lib/dyld" else { return false } }
					else { guard systemPath(path, rpath: command == 0x8000001c) else { return false } }
				} else {
					// Only known non-path commands are admitted. DYLD_ENVIRONMENT and unclassified commands refuse.
					let ordinary: Set<UInt32> = [0x19, 0x2, 0xb, 0x1b, 0x1d, 0x26, 0x29, 0x32,
						0x24, 0x80000022, 0x22, 0x80000028, 0x80000033, 0x80000034, 0x1a, 0x16, 0x2a, 0x2b]
					guard ordinary.contains(command) else { return false }
				}
				cursor += Int(length)
			}
			return cursor == end
		}
		guard data.count >= 48, let magic = word(0, little: false) else { return false }
		let little = magic == 0xbebafeca || magic == 0xbfbafeca
		let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
		guard [UInt32(0xcafebabe), 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic),
			word(4, little: little) == 2 else { return false }
		var cpus = Set<UInt32>(), ranges: [Range<Int>] = []
		let stride = fat64 ? 32 : 20, header = 8 + 2 * stride
		for index in 0..<2 {
			let record = 8 + index * stride
			guard let cpu = word(record, little: little), [UInt32(0x01000007), 0x0100000c].contains(cpu), cpus.insert(cpu).inserted else { return false }
			let rawOffset = fat64 ? wide(record + 8, little: little) : word(record + 8, little: little).map(UInt64.init)
			let rawSize = fat64 ? wide(record + 16, little: little) : word(record + 12, little: little).map(UInt64.init)
			guard let rawOffset, let rawSize, rawOffset >= UInt64(header), rawOffset <= UInt64(data.count),
				rawSize <= UInt64(data.count) - rawOffset else { return false }
			let offset = Int(rawOffset), size = Int(rawSize), range = offset..<(offset + size)
			guard !ranges.contains(where: { $0.overlaps(range) }), thin(offset: offset, size: size, cpu: cpu) else { return false }
			ranges.append(range)
		}
		return cpus.count == 2
	}
	/// Administrative staging admits only the same reviewed two-slice closed load inventory.
	/// This byte-shape seam supplies no signer, consent, installed principal or runtime readiness.
	static func systemClosedExecutableForInstaller(_ data: Data) -> Bool { universalExecutable(data) }
	/// Exact native bundle shape only; it supplies no signer, installed owner or load/READY authority.
	static func systemClosedBundleForInstalledSource(_ data: Data) -> Bool { universalImage(data, expectedType: 8) }
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Shape controls supply no production principal, signer or installer authority.
	static func fixtureSystemClosedExecutable(_ data: Data) -> Bool { universalExecutable(data) }
	#endif

	/// Publishes only into an absent fixed destination. Existing installations require an exact retirement owner.
	/// The caller runs this blocking filesystem role in its dedicated privileged worker, never the Lua loop.
	func publishFirstInstallation() throws {
		lock.lock(); defer { lock.unlock() }
		guard state == .held, staging == nil else { throw OwnedRuntimeInstallFailure.destination }
		do {
			guard publisher.current(), Self.signingLeaf(principal: principal, identifier: "com.ergoptiplus.app.runtime-installer") == leaf else { throw OwnedRuntimeInstallFailure.principal }
			try helper.verify(); try source.verify()
			// Parent provisioning and administrative authorization remain separate explicit installer work.
			let parent = try OwnedRuntimeInstallTree(root: Self.parent, protected: true, includeChildren: false)
			installParent = parent
			let parentDescriptor = try parent.duplicateRootDescriptor(); installParentDescriptor = parentDescriptor
			let daemonParent = try OwnedRuntimeInstallTree(root: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
				protected: true, includeChildren: false)
			let daemonDescriptor = try daemonParent.duplicateRootDescriptor(); defer { Darwin.close(daemonDescriptor) }
			let destination = Self.parent.appendingPathComponent("Runtime", isDirectory: true)
			var existing = stat(); errno = 0
			guard fstatat(parentDescriptor, "Runtime", &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
				throw OwnedRuntimeInstallFailure.destination
			}
			errno = 0
			guard fstatat(daemonDescriptor, "com.ergoptiplus.runtime.core.plist", &existing, AT_SYMLINK_NOFOLLOW) == -1,
				errno == ENOENT else { throw OwnedRuntimeInstallFailure.destination }
			let stage = Self.parent.appendingPathComponent(".runtime-install-" + UUID().uuidString, isDirectory: true)
			let journal = Self.parent.appendingPathComponent(".runtime-install-journal")
			let descriptor = openat(parentDescriptor, journal.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
			guard descriptor >= 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
			journalDescriptor = descriptor; staging = stage
			// A persistent exclusive journal fences successor helpers after interruption or unknown copy custody.
			let record = Data(("1\n" + stage.lastPathComponent + "\n").utf8)
			let written = record.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
			guard written == record.count, fsync(descriptor) == 0, fsync(parentDescriptor) == 0 else { throw OwnedRuntimeInstallFailure.copy }
			try source.copy(into: stage, custody: { self.scratch = $0 })
			let copied = try OwnedRuntimeInstallTree(root: stage, protected: true)
			try Self.validateProducts(at: stage, leaf: leaf)
			try copied.verify(); try copied.synchronize(); try source.verify(); try helper.verify()
			// Adding the staging directory changes parent metadata, so pin its ancestry again before publication.
			try parent.verifyAnchor()
			let protectedStage = try OwnedRuntimeInstallTree(root: stage, protected: true)
			try protectedStage.verify()
			guard publisher.current(), Self.signingLeaf(principal: principal, identifier: "com.ergoptiplus.app.runtime-installer") == leaf else { throw OwnedRuntimeInstallFailure.principal }
			guard let scratch else { throw OwnedRuntimeInstallFailure.cleanupPending }
			try scratch.publishRuntime(); filesPublished = true
			let installed = try OwnedRuntimeInstallTree(root: destination, protected: true)
			try Self.validateProducts(at: destination, leaf: leaf)
			guard try source.matchesBytes(of: installed) else { throw OwnedRuntimeInstallFailure.mutated }
			var heldJournal = stat(), namedJournal = stat()
			guard fstat(descriptor, &heldJournal) == 0, fstatat(parentDescriptor, journal.lastPathComponent, &namedJournal, AT_SYMLINK_NOFOLLOW) == 0,
				heldJournal.st_dev == namedJournal.st_dev, heldJournal.st_ino == namedJournal.st_ino,
				namedJournal.st_uid == 0, namedJournal.st_nlink == 1,
				namedJournal.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), namedJournal.st_mode & 0o077 == 0 else {
				throw OwnedRuntimeInstallFailure.cleanupPending
			}
			try parent.verifyAnchor()
			guard fsync(parentDescriptor) == 0, unlinkat(parentDescriptor, journal.lastPathComponent, 0) == 0, fsync(parentDescriptor) == 0 else {
				throw OwnedRuntimeInstallFailure.cleanupPending
			}
			Darwin.close(descriptor); journalDescriptor = nil
			staging = nil; state = .published
		} catch {
			// Never guess deletion authority after a partial copy or failed verification.
			state = staging == nil && (error as? OwnedRuntimeInstallFailure) != .cleanupPending ? .refused : .cleanupPending
			throw error
		}
	}
	/// Explicit rollback removes only exact created, still unpublished files. Unknown/live installation debt stays fenced.
	func rollbackUnpublishedFiles() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard state == .cleanupPending, !filesPublished, let scratch, let descriptor = journalDescriptor,
			let parent = installParent, let parentDescriptor = installParentDescriptor,
			publisher.current(), Self.signingLeaf(principal: principal, identifier: "com.ergoptiplus.app.runtime-installer") == leaf else { return false }
		do { try helper.verify(); try parent.verifyAnchor() } catch { return false }
		guard scratch.retire() else { return false }
		let journal = Self.parent.appendingPathComponent(".runtime-install-journal")
		var held = stat(), named = stat()
		guard fstat(descriptor, &held) == 0, fstatat(parentDescriptor, journal.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino, named.st_uid == 0,
			named.st_nlink == 1, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
			named.st_mode & 0o077 == 0 else { return false }
		guard unlinkat(parentDescriptor, journal.lastPathComponent, 0) == 0, fsync(parentDescriptor) == 0 else { return false }
		Darwin.close(descriptor); journalDescriptor = nil
		self.scratch = nil; staging = nil; state = .refused
		return true
	}
	/// A closed enum snapshot carries neither caller paths, signed material nor raw errors.
	func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }
}

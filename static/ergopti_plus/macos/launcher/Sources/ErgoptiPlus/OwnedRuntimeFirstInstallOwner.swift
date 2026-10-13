// Sources/ErgoptiPlus/OwnedRuntimeFirstInstallOwner.swift
// Distinct privileged-helper role: durable copy custody and exact first publication, without service start.
import Darwin
import Foundation
import Security

final class OwnedRuntimeFirstInstallOwner {
	enum State { case held, filesPublished, refused, cleanupPending }
	private static let identifier = "com.ergoptiplus.app.runtime-installer"
	private static let parentURL = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus", isDirectory: true)
	private let lock = NSLock()
	private let publisher: OwnedRuntimePublisherIdentity
	private let principal: SecCode, leaf: Data, payloadURL: URL, helper: OwnedRuntimeInstallTree, source: OwnedRuntimeInstallTree
	private let lifecycle: OwnedRuntimeServiceLifecycleLock
	private var journal: OwnedRuntimeInstallJournal?, scratch: OwnedRuntimeInstallScratch?
	private var state: State = .held
	private init(publisher: OwnedRuntimePublisherIdentity, principal: SecCode, leaf: Data, payloadURL: URL, helper: OwnedRuntimeInstallTree,
		source: OwnedRuntimeInstallTree, lifecycle: OwnedRuntimeServiceLifecycleLock) {
		self.publisher = publisher; self.principal = principal; self.leaf = leaf; self.payloadURL = payloadURL; self.helper = helper
		self.source = source; self.lifecycle = lifecycle
	}
	/// Production entry is derived only from the executing administrator-staged distinct signed helper.
	static func acquire() -> OwnedRuntimeFirstInstallOwner? {
		guard getuid() == 0, geteuid() == 0, Bundle.main.bundleIdentifier == identifier,
			Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL else { return nil }
		guard let publisher = OwnedRuntimePublisherIdentity.currentStagedInstaller() else { return nil }
		var principal: SecCode?
		guard SecCodeCopySelf([], &principal) == errSecSuccess, let principal, let leaf = signingLeaf(principal), leaf == publisher.leaf,
			let lifecycle = OwnedRuntimeServiceLifecycleLock.acquireExclusive() else { return nil }
		var completed = false; defer { if !completed { _ = lifecycle.retire() } }
		do {
			let helper = try OwnedRuntimeInstallTree(root: Bundle.main.bundleURL, protected: true)
			let payload = resources.appendingPathComponent("OwnedRuntime", isDirectory: true)
			let source = try OwnedRuntimeInstallTree(root: payload, protected: true)
			try source.verify(); try helper.verify()
			try OwnedRuntimeInstallOwner.validateInstalledProductsForPeer(at: payload, leaf: leaf)
			try source.verify(); try helper.verify()
			guard publisher.current(), lifecycle.current(), signingLeaf(principal) == leaf else { throw OwnedRuntimeInstallFailure.principal }
			let owner = OwnedRuntimeFirstInstallOwner(publisher: publisher, principal: principal, leaf: leaf, payloadURL: payload,
				helper: helper, source: source, lifecycle: lifecycle)
			completed = true; return owner
		} catch { return nil }
	}
	private static func signingLeaf(_ principal: SecCode) -> Data? {
		OwnedRuntimePublisherSignature.currentLeaf(principal, role: .installer)
	}
	private func verify() throws {
		guard publisher.current(), getuid() == 0, geteuid() == 0, Self.signingLeaf(principal) == leaf, lifecycle.current() else { throw OwnedRuntimeInstallFailure.principal }
		try source.verify(); try helper.verify()
	}
	/// File publication is performed in this helper's dedicated worker, never a resident Lua/launcher event loop.
	func publishFirstInstallation() throws {
		lock.lock(); defer { lock.unlock() }
		guard !Thread.isMainThread, state == .held, journal == nil else { throw OwnedRuntimeInstallFailure.destination }
		do {
			try verify()
			let parent = try OwnedRuntimeInstallTree(root: Self.parentURL, protected: true, includeChildren: false)
			let parentDescriptor = try parent.duplicateRootDescriptor(); defer { Darwin.close(parentDescriptor) }
			let daemonParent = try OwnedRuntimeInstallTree(root: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), protected: true, includeChildren: false)
			let daemonDescriptor = try daemonParent.duplicateRootDescriptor(); defer { Darwin.close(daemonDescriptor) }
			var existing = stat(); errno = 0
			guard fstatat(parentDescriptor, "Runtime", &existing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { throw OwnedRuntimeInstallFailure.destination }
			errno = 0
			guard fstatat(daemonDescriptor, "com.ergoptiplus.runtime.core.plist", &existing, AT_SYMLINK_NOFOLLOW) == -1,
				errno == ENOENT else { throw OwnedRuntimeInstallFailure.destination }
			guard let journal = OwnedRuntimeInstallJournal.create() else { throw OwnedRuntimeInstallFailure.cleanupPending }
			self.journal = journal
			let stageName = ".runtime-install-" + UUID().uuidString
			let stage = Self.parentURL.appendingPathComponent(stageName, isDirectory: true)
			try source.copy(into: stage, custody: { self.scratch = $0 }, afterCreation: { relative, descriptor in
				if relative.isEmpty { try journal.recordRoot(name: stageName, descriptor: descriptor) }
				else { try journal.recordCreated(relative: relative, descriptor: descriptor) }
			})
			let copied = try OwnedRuntimeInstallTree(root: stage, protected: true)
			try OwnedRuntimeInstallOwner.validateInstalledProductsForPeer(at: stage, leaf: leaf)
			try copied.verify(); try copied.synchronize(); try verify(); try parent.verifyAnchor()
			guard let scratch else { throw OwnedRuntimeInstallFailure.cleanupPending }
			try journal.beginPublication()
			try scratch.publishRuntime()
			let installedURL = Self.parentURL.appendingPathComponent("Runtime", isDirectory: true)
			let installed = try OwnedRuntimeInstallTree(root: installedURL, protected: true)
			try OwnedRuntimeInstallOwner.validateInstalledProductsForPeer(at: installedURL, leaf: leaf)
			guard try source.matchesBytes(of: installed) else { throw OwnedRuntimeInstallFailure.mutated }
			try installed.verify(); try verify(); try parent.verifyAnchor()
			try journal.finishPublished()
			guard installed.releaseOwnedDescriptors(), copied.releaseOwnedDescriptors(),
				parent.releaseOwnedDescriptors(), daemonParent.releaseOwnedDescriptors() else { throw OwnedRuntimeInstallFailure.cleanupPending }
			state = .filesPublished
		} catch { state = journal == nil && (error as? OwnedRuntimeInstallFailure) != .cleanupPending ? .refused : .cleanupPending; throw error }
	}
	/// Explicit recovery removes only vnodes recorded by this unpublished durable transaction.
	/// After publication-intent it refuses; it never guesses a process/service is gone or rolls back a live Runtime.
	func rollbackUnpublishedFiles() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard state == .cleanupPending, let journal else { return false }
		do { try verify(); try journal.retireUnpublished(); self.journal = nil; scratch = nil; state = .refused; return true } catch { return false }
	}
	/// Original private-factory native publication capability, consumed only by this helper's stage retirement.
	/// No caller-provided boolean/path/receipt can establish this state or replace its EX custody.
	func authorizesBootstrapStageRetirement() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard state == .filesPublished else { return false }
		do { try verify(); return true } catch { return false }
	}
	func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }
	deinit { _ = source.releaseOwnedDescriptors(); _ = helper.releaseOwnedDescriptors(); _ = lifecycle.retire() }
}

/// Headless minimal-helper entry. Main/build enrollment is deliberately external to this source owner.
/// Exit zero is permitted only after the actual first-install owner verified and discharged exact publication custody.
/// It does not mean Core, Console, capture or VirtualHID is running or available.
enum OwnedRuntimeInstallerEntry {
	enum Result: String {
		case filesPublishedStagingRetired = "files-published-staging-retired"
		case filesPublishedCleanupPending = "files-published-cleanup-pending"
		case refused, cleanupPending = "cleanup-pending"
	}
	static func runFirstInstallation() -> Result {
		guard let owner = OwnedRuntimeFirstInstallOwner.acquire() else { return .refused }
		let done = DispatchSemaphore(value: 0)
		var result: Result = .cleanupPending
		DispatchQueue(label: "com.ergoptiplus.runtime.first-install", qos: .userInitiated).async {
			defer { done.signal() }
			do {
				try owner.publishFirstInstallation()
				guard owner.snapshot() == .filesPublished else { return }
				result = .filesPublishedCleanupPending
				if let stage = OwnedRuntimeBootstrapStageOwner.acquire(afterPublication: owner), stage.retire() {
					result = .filesPublishedStagingRetired
				}
			} catch { result = owner.rollbackUnpublishedFiles() ? .refused : .cleanupPending }
		}
		done.wait(); return result
	}
}

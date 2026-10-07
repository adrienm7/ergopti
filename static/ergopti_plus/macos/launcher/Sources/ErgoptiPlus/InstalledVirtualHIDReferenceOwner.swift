// Sources/ErgoptiPlus/InstalledVirtualHIDReferenceOwner.swift
// Holds fixed static references; package trust, approval and runtime readiness are separate.
import Foundation

/// Owns actual native descriptor custody without promoting historical JSON observations.
final class InstalledVirtualHIDReferenceOwner {
	/// Identity is meaningful only to the exact native owner which minted it.
	final class Token { fileprivate init() {} }

	private let lock = NSRecursiveLock()
	private let token = Token()
	private var snapshots: [InstalledVHDStaticSnapshot] = []
	private var frames: UInt = 0
	private var held = false, stopped = false, closing = false, settled = false, closeRefused = false
	private var boundary: ((InstalledVirtualHIDReferenceOwner, InstalledVHDProbeBoundary) throws -> Void)?
	private enum AcquisitionRefusal: Error { case stopped }
	private init() {}

	/// Acquires the fixed installed official bundles only, never caller-selected paths or flags.
	static func acquire() -> InstalledVirtualHIDReferenceOwner {
		collect(locations: .installed, boundary: nil)
	}

#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Exercises the same native checks against externally provisioned protected fixtures.
	static func acquireTestFixture(locations: InstalledVHDProbeLocations,
		boundary: ((InstalledVirtualHIDReferenceOwner, InstalledVHDProbeBoundary) throws -> Void)? = nil) -> InstalledVirtualHIDReferenceOwner {
		collect(locations: locations, boundary: boundary)
	}
	/// Raw descriptors are diagnostic witnesses only; they cannot mint a production capability.
	func descriptorWitnessesForTest() -> [Int32] {
		lock.lock(); defer { lock.unlock() }
		return snapshots.flatMap { $0.nodes.map(\.fd) }
	}
#endif

	private static func collect(locations: InstalledVHDProbeLocations,
		boundary: ((InstalledVirtualHIDReferenceOwner, InstalledVHDProbeBoundary) throws -> Void)?) -> InstalledVirtualHIDReferenceOwner {
		let owner = InstalledVirtualHIDReferenceOwner()
		owner.lock.lock(); defer { owner.lock.unlock() }
		owner.boundary = boundary
		owner.frames = 1
		defer { owner.leaveFrame() }
		for (url, reference) in [(locations.daemon, InstalledVHDReference.daemon), (locations.dext, InstalledVHDReference.dext)] {
			guard !owner.stopped else { break }
			let observation = InstalledVirtualHIDProbe.retainComponent(url, reference: reference,
				custody: { owner.snapshots.append($0) }, boundary: { event in
					guard !owner.stopped else { throw AcquisitionRefusal.stopped }
					try owner.boundary?(owner, event)
					guard !owner.stopped else { throw AcquisitionRefusal.stopped }
				})
			guard !owner.stopped, observation.status == "observed", observation.ordinaryRootOwned == true,
				observation.matchesFixedBytes == true, observation.signatureValid == true,
				observation.bundleIdentityValid == true else {
				owner.stopped = true
				break
			}
		}
		if !owner.stopped, owner.snapshots.count == 2 {
			do {
				for snapshot in owner.snapshots { try snapshot.verify() }
				owner.held = true
			} catch { owner.stopped = true }
		} else { owner.stopped = true }
		return owner
	}

	/// Returns this owner's opaque identity while the retained static reference is admitted.
	func identity() -> Token? {
		lock.lock(); defer { lock.unlock() }
		return held && !stopped ? token : nil
	}

	/// Revalidates every held native file and ACL inside a retirement-blocking frame.
	func current(_ expected: Token) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard expected === token, held, !stopped, !closing, frames < UInt.max else { return false }
		frames += 1; defer { leaveFrame() }
		do {
			try boundary?(self, InstalledVHDProbeBoundary(role: "owner", stage: "beforeCurrentValidation"))
			guard !stopped else { return false }
			for snapshot in snapshots {
				try snapshot.verify()
				guard !stopped else { return false }
			}
			return held && !stopped
		} catch {
			stopped = true; held = false
			return false
		}
	}

	/// Revokes immediately and acknowledges only completed native descriptor closes.
	@discardableResult
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }
		stopped = true; held = false
		if frames == 0 { drain() }
		return settled && !closeRefused
	}

	/// A stopped flag or callback acceptance never establishes physical retirement.
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
		for snapshot in snapshots.reversed() {
			// A diagnostic boundary cannot replace or suppress actual descriptor close.
			do { try boundary?(self, InstalledVHDProbeBoundary(role: "owner", stage: "beforeDescriptorClose")) }
			catch { held = false }
			do { try snapshot.closeAll() } catch { closeRefused = true }
		}
		frames = 0; closing = false
		if !closeRefused {
			snapshots.removeAll(); boundary = nil; settled = true
		}
		// A refused close retains its exact tombstone; it cannot be retried through reused FD numbers.
	}

	deinit { _ = retire() }
}

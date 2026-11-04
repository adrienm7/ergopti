// Sources/ErgoptiPlus/OwnedRuntimeIdleServiceEntry.swift
// One confirmed administrator transaction installs the owned files, the idle Core service and the VirtualHIDDevice daemon job.
import Foundation

/// The result never certifies Console, physical capture, DriverKit approval or full Runtime retirement.
enum OwnedRuntimeIdleServiceEntry {
	enum Result: String {
		case servicesObservedStagingRetired = "files-published-services-observed-staging-retired"
		case filesPublishedServiceCleanupPending = "files-published-service-cleanup-pending"
		case refused, cleanupPending = "cleanup-pending"
	}
	static func runFirstInstallation() -> Result {
		guard let publication = OwnedRuntimeFirstInstallOwner.acquire() else { return .refused }
		let done = DispatchSemaphore(value: 0)
		var result: Result = .cleanupPending
		DispatchQueue(label: "com.ergoptiplus.runtime.idle-service-install", qos: .userInitiated).async {
			defer { done.signal() }
			do {
				try publication.publishFirstInstallation()
				guard publication.snapshot() == .filesPublished else { return }
				result = .filesPublishedServiceCleanupPending
				guard let provision = OwnedRuntimeCoreProvisionOwner.acquire(afterPublication: publication) else { return }
				let core = try provision.provisionAndStartCore()
				// Inside the same custody: the provision's observations are retired only after the daemon job loads.
				_ = try OwnedRuntimeVirtualHIDProvisionOwner.provision(within: provision)
				guard core.retireStartedObservation(forProvision: provision), provision.retireCommittedObservations(),
					let stage = OwnedRuntimeBootstrapStageOwner.acquire(afterPublication: publication), stage.retire() else { return }
				result = .servicesObservedStagingRetired
			} catch {
				if publication.snapshot() == .filesPublished { result = .filesPublishedServiceCleanupPending }
				else { result = publication.rollbackUnpublishedFiles() ? .refused : .cleanupPending }
			}
		}
		done.wait(); return result
	}
}

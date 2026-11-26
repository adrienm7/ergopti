// Sources/ErgoptiPlus/OwnedRuntimeServiceRepairEntry.swift
// One confirmed administrator transaction repairs the services of an already published owned Runtime (MRT-004).
import Foundation

/// The first install refuses an existing Runtime by design (OwnedRuntimeFirstInstallOwner), so a Runtime whose
/// files were published but whose Core or VirtualHIDDevice job is not loaded (an install that ended
/// `files-published-service-cleanup-pending`, or a job launchd lost) gets its own role. It acquires the same
/// standalone provision authority as the original namespace (OwnedRuntimeCoreProvisionOwner.acquire: root, the
/// staged installer's signature, the exclusive lifecycle lock, no install journal, and the installed Runtime
/// byte-identical to this helper's payload), adopts only the exact owned plists already on disk, starts what is
/// not loaded and leaves a loaded job alone. The Core's first-start `core.json` fence applies unchanged. The
/// result never certifies Console, physical capture or DriverKit approval.
enum OwnedRuntimeServiceRepairEntry {
	/// The helper's argument for this role.
	static let argument = "--owned-repair-service"
	enum Result: String {
		case servicesObserved = "service-repaired-observed"
		case servicePending = "service-repair-pending"
		case refused, cleanupPending = "cleanup-pending"
	}
	static func run() -> Result {
		let done = DispatchSemaphore(value: 0)
		var result: Result = .refused
		DispatchQueue(label: "com.ergoptiplus.runtime.service-repair", qos: .userInitiated).async {
			defer { done.signal() }
			var step = "core-provision-acquire"
			guard let provision = OwnedRuntimeCoreProvisionOwner.acquire() else {
				OwnedRuntimeInstallTrail.note(step + "-refused"); return
			}
			do {
				step = "core-start"
				let core = try provision.repairAndStartCore()
				step = "vhid-provision"
				try OwnedRuntimeVirtualHIDProvisionOwner.provision(within: provision, adoptExisting: true)
				step = "retire"
				let retired: Bool
				if let core { retired = core.retireStartedObservation(forProvision: provision) && provision.retireCommittedObservations() }
				else { retired = provision.retireUntouchedObservations() }
				guard retired else { OwnedRuntimeInstallTrail.note(step + "-refused"); result = .servicePending; return }
				result = .servicesObserved
			} catch {
				OwnedRuntimeInstallTrail.note(step + "-failed-" + String(describing: error))
				// After a service step, or a job ledger left as debt, the next repair resumes from the recorded
				// ledger. Before any, an adopted or created Core plist is given back exactly, or it is debt.
				if provision.touchedService() || (error as? OwnedRuntimeInstallFailure) == .cleanupPending { result = .servicePending }
				else if !provision.holdsPlistCustody() { result = .refused }
				else { result = provision.rollbackUnregisteredPlist() ? .refused : .cleanupPending }
			}
		}
		done.wait(); return result
	}
}

// Sources/ErgoptiPlus/OwnedRuntimeVirtualHIDProvisionOwner.swift
// The first install's VirtualHIDDevice half: the owned daemon job for pqrs' installed daemon program.
import Darwin
import Foundation

/// Runs only inside the Core provision's custody, after the Core started. pqrs' driver package is installed by the
/// same administrator shell before this helper runs (OwnedRuntimeInstallMainOperation, from the pinned, verified
/// download), never by the helper: the live helper profile carries no driver payload. It never activates the
/// DriverKit extension: macOS ties that to the console user's approval, so the Lua install port asks pqrs' manager
/// once this helper has exited. An incompatible installed driver is the owner's named block and its driver-only
/// update row (runtime_vhid_update.lua).
enum OwnedRuntimeVirtualHIDProvisionOwner {
	private static let target = "system/\(Identifiers.ServiceLabels.macosVirtualHid)"
	private static let plistPath = "/Library/LaunchDaemons/\(Identifiers.ServiceLabels.macosVirtualHid).plist"
	/// launchctl's status for a label it does not know.
	private static let unknownService: Int32 = 113

	/// Writes and bootstraps the owned daemon job once pqrs' daemon program is installed.
	static func provision(within core: OwnedRuntimeCoreProvisionOwner) throws {
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0 else { throw OwnedRuntimeInstallFailure.traced(.principal) }
		try core.verifyForPlistCustody()
		guard daemonInstalled() else {
			OwnedRuntimeInstallTrail.note("vhid-daemon-absent"); throw OwnedRuntimeInstallFailure.traced(.source)
		}
		guard try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", target]).status == unknownService else {
			throw OwnedRuntimeInstallFailure.traced(.destination)
		}
		let custody = try OwnedRuntimeCorePlistCustody.createProductionVirtualHID(owner: core, bytes: try jobBytes())
		try custody.prepare()
		let bootstrap = try OwnedRuntimeCoreLaunchctl.run(arguments: ["bootstrap", "system", plistPath])
		guard bootstrap.status == 0 else {
			// A refused bootstrap registered nothing, so the plist and its ledger can go.
			OwnedRuntimeInstallTrail.note("vhid-bootstrap-" + String(bootstrap.status))
			_ = custody.rollbackUnregistered(); throw OwnedRuntimeInstallFailure.traced(.cleanupPending)
		}
		// KeepAlive starts the daemon at load; launchd answers print only for a loaded job.
		guard custody.commitLoaded(try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", target])) else {
			throw OwnedRuntimeInstallFailure.traced(.cleanupPending)
		}
	}

	/// The owned job: the keys of pqrs' own daemon plist (Karabiner-DriverKit-VirtualHIDDevice v8.5.0,
	/// files/LaunchDaemons) under Ergopti's label.
	static func jobBytes() throws -> Data {
		let fields: [String: Any] = [
			"Label": Identifiers.ServiceLabels.macosVirtualHid,
			"ProgramArguments": [OwnedVirtualHIDDaemonReportReference.daemonExecutable],
			"KeepAlive": true,
			"ProcessType": "Interactive",
		]
		return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
	}

	/// Whether pqrs' package already put its root-owned daemon program on this Mac.
	static func daemonInstalled() -> Bool {
		var value = stat()
		return lstat(OwnedVirtualHIDDaemonReportReference.daemonExecutable, &value) == 0
			&& value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_uid == 0 && value.st_mode & 0o022 == 0
	}
}

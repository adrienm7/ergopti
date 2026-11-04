// Sources/ErgoptiPlus/OwnedRuntimeVirtualHIDProvisionOwner.swift
// The first install's VirtualHIDDevice half: pqrs' package when no driver is installed, then the owned daemon job.
import Darwin
import Foundation

/// Runs only inside the Core provision's custody, after the Core started. It never activates the DriverKit
/// extension: macOS ties that to the console user's approval, so the Lua install port asks pqrs' manager once
/// this helper has exited. A driver already installed, compatible or not, is left as it is: the owner names an
/// incompatible one and the Tap-Holds menu offers the driver-only update (runtime_vhid_update.lua).
enum OwnedRuntimeVirtualHIDProvisionOwner {
	enum Driver: String { case installed = "driver-installed", present = "driver-present" }
	/// The helper's resource folder the product build stages (owned_runtime_product_build.py VIRTUAL_HID_RESOURCE_NAMES).
	static let payloadDirectory = "VirtualHIDDriverPayload"
	/// pqrs' own daemon plist (Karabiner-DriverKit-VirtualHIDDevice files/LaunchDaemons) is the one source of the job's keys.
	private static let pqrsLabel = "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon"
	private static let pqrsTeam = "G43BCU2T37"
	private static let target = "system/\(Identifiers.ServiceLabels.macosVirtualHid)"
	private static let plistPath = "/Library/LaunchDaemons/\(Identifiers.ServiceLabels.macosVirtualHid).plist"
	/// launchctl's status for a label it does not know.
	private static let unknownService: Int32 = 113

	/// Installs the package when no pqrs daemon is installed, then writes and bootstraps the owned daemon job.
	static func provision(within core: OwnedRuntimeCoreProvisionOwner) throws -> Driver {
		guard !Thread.isMainThread, getuid() == 0, geteuid() == 0 else { throw OwnedRuntimeInstallFailure.principal }
		try core.verifyForPlistCustody()
		guard let resources = Bundle.main.resourceURL else { throw OwnedRuntimeInstallFailure.source }
		let payloadURL = resources.appendingPathComponent(payloadDirectory, isDirectory: true)
		let payload = try OwnedRuntimeInstallTree(root: payloadURL, protected: true)
		defer { _ = payload.releaseOwnedDescriptors() }
		let names = try FileManager.default.contentsOfDirectory(atPath: payloadURL.path).sorted()
		let plistName = pqrsLabel + ".plist", packages = names.filter { $0.hasSuffix(".pkg") }
		guard names.count == 2, names.contains(plistName), packages.count == 1 else { throw OwnedRuntimeInstallFailure.source }
		try payload.verify()
		let bytes = try jobBytes(pqrs: Data(contentsOf: payloadURL.appendingPathComponent(plistName)))
		var driver = Driver.present
		if !daemonInstalled() {
			let package = payloadURL.appendingPathComponent(packages[0])
			let signature = try OwnedRuntimeCoreLaunchctl.packageSignature(package)
			guard signature.status == 0, signedByPqrs(signature.bytes) else { throw OwnedRuntimeInstallFailure.signature }
			try payload.verify(); try core.verifyForPlistCustody()
			let installed = try OwnedRuntimeCoreLaunchctl.installPackage(package)
			guard installed.status == 0, daemonInstalled() else { throw OwnedRuntimeInstallFailure.copy }
			driver = .installed
		}
		try core.verifyForPlistCustody()
		guard try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", target]).status == unknownService else {
			throw OwnedRuntimeInstallFailure.destination
		}
		let custody = try OwnedRuntimeCorePlistCustody.createProductionVirtualHID(owner: core, bytes: bytes)
		try custody.prepare()
		let bootstrap = try OwnedRuntimeCoreLaunchctl.run(arguments: ["bootstrap", "system", plistPath])
		guard bootstrap.status == 0 else {
			// A refused bootstrap registered nothing, so the plist and its ledger can go.
			_ = custody.rollbackUnregistered(); throw OwnedRuntimeInstallFailure.cleanupPending
		}
		// KeepAlive starts the daemon at load; launchd answers print only for a loaded job.
		guard custody.commitLoaded(try OwnedRuntimeCoreLaunchctl.run(arguments: ["print", target])) else {
			throw OwnedRuntimeInstallFailure.cleanupPending
		}
		return driver
	}

	/// The owned job is pqrs' plist under Ergopti's label, refused when pqrs' keys are not the expected ones.
	static func jobBytes(pqrs: Data) throws -> Data {
		guard var fields = try PropertyListSerialization.propertyList(from: pqrs, format: nil) as? [String: Any],
			fields["Label"] as? String == pqrsLabel,
			fields["ProgramArguments"] as? [String] == [OwnedVirtualHIDDaemonReportReference.daemonExecutable],
			fields["KeepAlive"] as? Bool == true else { throw OwnedRuntimeInstallFailure.source }
		fields["Label"] = Identifiers.ServiceLabels.macosVirtualHid
		return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
	}

	/// Whether pqrs' package already put its root-owned daemon program on this Mac.
	private static func daemonInstalled() -> Bool {
		var value = stat()
		return lstat(OwnedVirtualHIDDaemonReportReference.daemonExecutable, &value) == 0
			&& value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_uid == 0 && value.st_mode & 0o022 == 0
	}

	/// pkgutil's chain must start with pqrs' Developer ID Installer certificate, issued by Apple.
	static func signedByPqrs(_ output: Data) -> Bool {
		guard let text = String(data: output, encoding: .utf8) else { return false }
		let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
		return lines.contains { $0.hasPrefix("Status: signed by a developer certificate issued by Apple") }
			&& lines.contains { $0.hasPrefix("1. Developer ID Installer: ") && $0.hasSuffix("(" + pqrsTeam + ")") }
	}
}

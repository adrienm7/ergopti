// Sources/ErgoptiPlus/UninstallWorker.swift

// ==============================================================================
// MODULE: Confirmed Application Uninstall Worker
// DESCRIPTION:
// Moves only its own validated application bundle to the Trash after an explicit
// stdin commit and a clean kernel-observed parent exit. Personal data is retained.
// ==============================================================================

import AppKit
import Darwin
import Foundation
import ServiceManagement

/// A failed ownership proof never authorizes filesystem removal.
enum UninstallFailure: Error {
	case invalidBundle, invalidProtocol, parentExit, activeLease, guardian
}

/// Revalidates the immutable bundle target without following aliases or accepting
/// a source checkout. Environment identity comes from the running outer launcher.
func validateUninstallBundle(
	bundle: URL,
	bundleIdentifier: String?,
	environment: [String: String],
	expectedIdentity: (device: String, inode: String)?
) throws {
	let executable = bundle.appendingPathComponent("Contents/MacOS/ErgoptiPlus").path
	var attributes = stat()
	guard bundleIdentifier == kErgoptiBundleId,
		bundle.pathExtension == "app",
		bundle.resolvingSymlinksInPath().path == bundle.path,
		environment["ERGOPTI_LAUNCHER_EXECUTABLE"] == executable,
		let expectedIdentity,
		expectedIdentity.device == environment["ERGOPTI_LAUNCHER_DEVICE"],
		expectedIdentity.inode == environment["ERGOPTI_LAUNCHER_INODE"],
		Darwin.lstat(executable, &attributes) == 0,
		(attributes.st_mode & S_IFMT) == S_IFREG,
		String(attributes.st_dev) == expectedIdentity.device,
		String(attributes.st_ino) == expectedIdentity.inode
	else { throw UninstallFailure.invalidBundle }
	var ancestor = bundle
	while ancestor.path != "/" {
		let marker = ancestor.appendingPathComponent(".git").path
		if Darwin.lstat(marker, &attributes) == 0 { throw UninstallFailure.invalidBundle }
		if errno != ENOENT { throw UninstallFailure.invalidBundle }
		ancestor.deleteLastPathComponent()
	}
}

/// STOPPED precedes record retirement, so a clean driver exit may briefly race
/// the already-fenced worker's final unlink. Never delete its record ourselves.
func waitForUninstallLeaseRetirement(
	isEmpty: () throws -> Bool,
	now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
	pause: () -> Void = { usleep(10_000) },
	timeout: TimeInterval = 5
) throws -> Bool {
	let deadline = now() + timeout
	while try !isEmpty() {
		guard now() < deadline else { return false }
		pause()
	}
	return true
}

/// Orders all destructive work behind both authorization and exact clean exit.
func performConfirmedUninstall(
	validate: () throws -> Void,
	authorize: () throws -> Bool,
	waitForCleanExit: () -> Bool,
	unregister: () throws -> Void,
	trash: () throws -> Void
) throws {
	try validate()
	guard try authorize() else { throw UninstallFailure.invalidProtocol }
	guard waitForCleanExit() else { throw UninstallFailure.parentExit }
	try validate()
	try unregister()
	try validate()
	try trash()
}

/// Pins the callback result across the kernel monitor's background queue.
private final class UninstallExitObservation {
	private let lock = NSLock()
	private let semaphore = DispatchSemaphore(value: 0)
	private var result: EmbeddedProcessExit?

	func receive(_ result: EmbeddedProcessExit) {
		lock.lock()
		self.result = result
		lock.unlock()
		semaphore.signal()
	}

	func wait() -> Bool {
		guard semaphore.wait(timeout: .now() + 60) == .success else { return false }
		lock.lock()
		defer { lock.unlock() }
		return result == .exited(code: 0)
	}
}

/// Headless role of the signed launcher; no caller-selected deletion path exists.
enum UninstallWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.dropFirst().first == "--uninstall"
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 4 else { return 64 }
		let bundle = Bundle.main.bundleURL.standardizedFileURL
		let executable = bundle.appendingPathComponent("Contents/MacOS/ErgoptiPlus").path
		let environment = ProcessInfo.processInfo.environment
		let expectedIdentity = launcherExecutableFileIdentity(at: executable)
		let observation = UninstallExitObservation()
		guard getppid() > 1, let monitor = makeEmbeddedProcessExitMonitor(
			processIdentifier: getppid(), completion: observation.receive
		) else { return 70 }
		defer { monitor.cancel() }

		do {
			try performConfirmedUninstall(validate: {
				try validateUninstallBundle(bundle: bundle,
					bundleIdentifier: Bundle.main.bundleIdentifier,
					environment: environment, expectedIdentity: expectedIdentity)
			}, authorize: {
				try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
				var message = Data()
				let deadline = ProcessInfo.processInfo.systemUptime + 30
				while message.count < 7 {
					let remaining = deadline - ProcessInfo.processInfo.systemUptime
					guard remaining > 0 else { return false }
					var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
					let ready = Darwin.poll(&input, 1, Int32(remaining * 1000))
					if ready < 0 && errno == EINTR { continue }
					guard ready > 0 else { return false }
					var byte: UInt8 = 0
					guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return false }
					message.append(byte)
					if byte == 10 { break }
				}
				guard message == Data("COMMIT\n".utf8) else { return false }
				try FileHandle.standardOutput.write(contentsOf: Data("ACK\n".utf8))
				return true
			}, waitForCleanExit: observation.wait, unregister: {
				let records = LeaseGuardianPaths().records
				guard try waitForUninstallLeaseRetirement(isEmpty: {
					var attributes = stat()
					if Darwin.lstat(records, &attributes) != 0 {
						if errno == ENOENT { return true }
						throw UninstallFailure.activeLease
					}
					guard attributes.st_mode & S_IFMT == S_IFDIR,
						attributes.st_uid == getuid() else { throw UninstallFailure.activeLease }
					return try FileManager.default.contentsOfDirectory(atPath: records).isEmpty
				}) else { throw UninstallFailure.activeLease }
				guard removeLegacyRemapGuardian(executablePath: executable) else {
					throw UninstallFailure.guardian
				}
				if #available(macOS 13.0, *) {
					let login = SMAppService.mainApp
					if login.status == .enabled || login.status == .requiresApproval { try login.unregister() }
					let service = SMAppService.agent(plistName: kRemapGuardianPlistName)
					if service.status != .notRegistered { try service.unregister() }
				}
			}, trash: {
				try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
			})
			LauncherLog.write("Confirmed uninstall completed; personal data retained")
			return 0
		} catch {
			LauncherLog.write("Uninstall refused: \(error)")
			let app = NSApplication.shared
			app.setActivationPolicy(.accessory)
			app.activate(ignoringOtherApps: true)
			let alert = NSAlert()
			alert.messageText = arguments[2]
			alert.informativeText = arguments[3]
			alert.alertStyle = .critical
			alert.runModal()
			return 70
		}
	}
}

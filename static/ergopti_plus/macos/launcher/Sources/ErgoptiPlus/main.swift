// Sources/Ergopti/main.swift

// ==============================================================================
// MODULE: Ergopti macOS Launcher
// DESCRIPTION:
// Tiny Cocoa app that wraps the bundled Hammerspoon binary. The user sees and
// interacts with “Ergopti.app” — Hammerspoon never appears in the Dock, in
// /Applications, or in the menu bar. This launcher's only jobs are:
//
//   1. Point the embedded Hammerspoon at our bundled Lua config dir via the
//      MJConfigDir user-defaults key, isolated by our rebranded bundle id so
//      it never collides with a stock Hammerspoon install the user may run.
//   2. Spawn the embedded Hammerspoon binary as a child process; forward its
//      lifecycle so quitting Ergopti cleanly terminates Hammerspoon, and a
//      Hammerspoon crash terminates Ergopti.
//   3. Host Sparkle (SPUStandardUpdaterController) so the in-app updater can
//      ship new releases over the configured appcast.
//
// FEATURES & RATIONALE:
//  - Foreground LSUIElement=NO so notification badges work; we hide the
//    launcher's own Dock icon via NSApp.setActivationPolicy(.accessory)
//    so only Hammerspoon's menubar item is visible to the user.
//  - No NSMainNibFile / storyboard: this is a programmatic-only app to keep
//    the binary tiny (~2 MB before Sparkle) and Xcode-project-free.
//  - All paths are derived from Bundle.main so the launcher works correctly
//    whether the .app lives in /Applications or anywhere else.
// ==============================================================================

import Cocoa
import Darwin
import Dispatch
import Sparkle




// ==================================
// ==================================
// ======= 1/ App-Level State =======
// ==================================
// ==================================

// Bundle identifier the embedded Hammerspoon will run under. Picked so the
// embedded HS reads its preferences from ~/Library/Preferences/com.ergoptiplus.app.plist
// and cannot collide with a stock Hammerspoon install (org.hammerspoon.Hammerspoon).
let kErgoptiBundleId = "com.ergoptiplus.app"

// Key Hammerspoon reads to locate its Lua config dir. Default would be
// ~/.hammerspoon; we override to keep Ergopti's tree fully self-contained.
// Hammerspoon reads MJConfigFile (full path to init.lua), not MJConfigDir.
// MJConfigDir is a community myth — variables.m uses MJConfigFile exclusively.
let kHammerspoonConfigKey = "MJConfigFile"

/// Returns the inherited child environment with the exact live launcher
/// identity replacing any stale values inherited from an ancestor process.
/// - Parameters:
///   - base: Environment inherited by the Swift launcher.
///   - launcherPid: Current Swift launcher process identifier.
///   - launcherBundleId: Current launcher bundle identifier when observable.
/// - Returns: Environment safe to assign to the embedded Hammerspoon child.
func launcherChildEnvironment(
	base: [String: String],
	launcherPid: Int32,
	launcherBundleId: String?
) -> [String: String] {
	var environment = base
	environment["ERGOPTI_LAUNCHER_PID"] = String(launcherPid)
	environment.removeValue(forKey: "ERGOPTI_LAUNCHER_BUNDLE_ID")
	if let launcherBundleId, !launcherBundleId.isEmpty {
		environment["ERGOPTI_LAUNCHER_BUNDLE_ID"] = launcherBundleId
	}
	return environment
}

/// Captures the exact on-disk identity of the running launcher executable.
/// Hammerspoon rechecks these values before it may spawn a headless lease role,
/// so a same-named developer wrapper or replaced helper path fails closed.
/// - Parameter path: Current launcher executable path.
/// - Returns: Decimal device/inode strings, or nil when lstat fails.
func launcherExecutableFileIdentity(
	at path: String?
) -> (device: String, inode: String)? {
	guard let path, !path.isEmpty else { return nil }
	var attributes = stat()
	guard path.withCString({ Darwin.lstat($0, &attributes) }) == 0 else { return nil }
	return (String(attributes.st_dev), String(attributes.st_ino))
}




// =====================================
// =====================================
// ======= 1.1) Persistent Logging =====
// =====================================
// =====================================

// Before this (F-MED-30), the only diagnostic artifact on any launcher failure
// was a single NSLog call — invisible in any headless/automated launch (no
// Console.app session watching, no attached debugger). A user reporting "it
// just doesn't start" gave us nothing to go on. LauncherLog appends a
// timestamped line to a small on-disk file next to every NSAlert/failure path
// (and a few success milestones) so a post-mortem is always possible.
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
let kLauncherLogAppendTestFlag = "--launcher-log-append-test"
#endif

/// Writes every byte through one injectable POSIX operation. Retrying EINTR and
/// advancing after a short write prevents a diagnostic from becoming a torn
/// record merely because the kernel accepted only a prefix.
/// - Parameters:
///   - data: Complete UTF-8 log record.
///   - descriptor: Already-open append-only regular-file descriptor.
///   - writeOperation: POSIX write boundary, injectable for deterministic tests.
/// - Returns: Whether every byte reached the kernel.
func writeLauncherLogData(
	_ data: Data,
	descriptor: Int32,
	writeOperation: (
		Int32,
		UnsafeRawPointer?,
		Int
	) -> Int = { Darwin.write($0, $1, $2) }
) -> Bool {
	return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
		guard let base = bytes.baseAddress else { return data.isEmpty }
		var offset = 0
		while offset < bytes.count {
			let written = writeOperation(
				descriptor,
				base.advanced(by: offset),
				bytes.count - offset
			)
			if written > 0 {
				offset += written
				continue
			}
			if written == -1 && errno == EINTR { continue }
			return false
		}
		return true
	}
}

enum LauncherLog {
	// Standard macOS per-app log location; readable by the user without special
	// permissions and rotated by nothing — kept deliberately tiny (one line per
	// launch event) so unbounded growth is not a practical concern.
	private static let logDirectory = NSHomeDirectory() + "/Library/Logs/ErgoptiPlus"
	private static let logFileName = "launcher.log"
	private static let queue = DispatchQueue(label: "com.ergoptiplus.launcher-log")
	private static let lockTimeoutSeconds: TimeInterval = 0.25
	private static let lockRetryMicroseconds: useconds_t = 1_000

	private static let dateFormatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return f
	}()

	/// Appends one timestamped line to ~/Library/Logs/ErgoptiPlus/launcher.log.
	/// Best-effort: a logging failure must never prevent the launcher from
	/// proceeding, so every step here is wrapped defensively.
	static func write(_ message: String) {
		queue.sync {
			_ = writeUnlocked(message, directoryPath: logDirectory)
		}
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Exercises the production append path in a private SwiftPM subprocess.
	/// Release builds expose no caller-controlled logging destination.
	static func writeForTesting(
		_ message: String,
		directoryPath: String,
		beforeLock: (() -> Void)? = nil
	) -> Bool {
		guard isValidTestLogDirectory(directoryPath) else { return false }
		return queue.sync {
			writeUnlocked(
				message,
				directoryPath: directoryPath,
				beforeLock: beforeLock
			)
		}
	}

	/// Restricts the debug-only path override to one owned 0700 temp directory.
	static func isValidTestLogDirectory(_ directoryPath: String) -> Bool {
		guard directoryPath.hasPrefix("/") else { return false }
		let temporaryRoot = FileManager.default.temporaryDirectory
			.standardizedFileURL
			.resolvingSymlinksInPath()
		let candidate = URL(fileURLWithPath: directoryPath, isDirectory: true)
			.standardizedFileURL
		let resolvedCandidate = candidate.resolvingSymlinksInPath()
		let rootPrefix = temporaryRoot.path.hasSuffix("/")
			? temporaryRoot.path
			: temporaryRoot.path + "/"
		guard resolvedCandidate.path.hasPrefix(rootPrefix),
			candidate.lastPathComponent.hasPrefix("ergopti-launcher-log-")
		else { return false }

		var attributes = stat()
		return candidate.path.withCString({ Darwin.lstat($0, &attributes) }) == 0
			&& (attributes.st_mode & S_IFMT) == S_IFDIR
			&& (attributes.st_mode & 0o777) == 0o700
			&& attributes.st_uid == geteuid()
	}
	#endif

	/// Opens one exact user-owned directory without following its final component.
	private static func openLogDirectory(_ directoryPath: String) -> Int32 {
		// Another launcher role may win the create race. The descriptor-based
		// validation below is authoritative, so an EEXIST-style error is harmless.
		try? FileManager.default.createDirectory(
			atPath: directoryPath,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)

		let descriptor = Darwin.open(
			directoryPath,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
		)
		guard descriptor >= 0 else { return -1 }
		var attributes = stat()
		guard Darwin.fstat(descriptor, &attributes) == 0,
			(attributes.st_mode & S_IFMT) == S_IFDIR,
			attributes.st_uid == geteuid(),
			Darwin.fchmod(descriptor, S_IRWXU) == 0
		else {
			Darwin.close(descriptor)
			return -1
		}
		return descriptor
	}

	/// Opens only `launcher.log` relative to the already-validated directory.
	private static func openLogFile(directoryDescriptor: Int32) -> Int32 {
		let descriptor = logFileName.withCString { name in
			Darwin.openat(
				directoryDescriptor,
				name,
				O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
				S_IRUSR | S_IWUSR
			)
		}
		guard descriptor >= 0 else { return -1 }
		var attributes = stat()
		guard Darwin.fstat(descriptor, &attributes) == 0,
			(attributes.st_mode & S_IFMT) == S_IFREG,
			attributes.st_uid == geteuid(),
			attributes.st_nlink == 1,
			Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
		else {
			Darwin.close(descriptor)
			return -1
		}
		return descriptor
	}

	/// Takes a bounded advisory lock so partial writes from two processes cannot
	/// interleave. A stopped writer can delay diagnostics by at most 250 ms.
	private static func acquireLogLock(_ descriptor: Int32) -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + lockTimeoutSeconds
		while true {
			if Darwin.flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
			let lockError = errno
			guard lockError == EINTR || lockError == EAGAIN || lockError == EWOULDBLOCK,
				ProcessInfo.processInfo.systemUptime < deadline
			else { return false }
			if lockError != EINTR { usleep(lockRetryMicroseconds) }
		}
	}

	@discardableResult
	private static func writeUnlocked(
		_ message: String,
		directoryPath: String,
		beforeLock: (() -> Void)? = nil
	) -> Bool {
		let timestamp = dateFormatter.string(from: Date())
		let line = "[\(timestamp)] \(message)\n"
		guard let data = line.data(using: .utf8) else { return false }

		let directoryDescriptor = openLogDirectory(directoryPath)
		guard directoryDescriptor >= 0 else { return false }
		defer { Darwin.close(directoryDescriptor) }
		let logDescriptor = openLogFile(directoryDescriptor: directoryDescriptor)
		guard logDescriptor >= 0 else { return false }
		defer { Darwin.close(logDescriptor) }
		beforeLock?()
		guard acquireLogLock(logDescriptor) else { return false }
		defer { _ = Darwin.flock(logDescriptor, LOCK_UN) }
		return writeLauncherLogData(data, descriptor: logDescriptor)
	}
}




// =====================================
// =====================================
// ======= 2/ AppDelegate ==============
// =====================================
// =====================================

final class AppDelegate: NSObject, NSApplicationDelegate {

	private var hsProcess: Process?
	private var updaterController: SPUStandardUpdaterController?
	private let launcherIdentityReader: (String?) -> (device: String, inode: String)?
	private let processRunner: (Process) throws -> Void
	private let fatalReporter: ((String) -> Void)?
	private let guardianRegistrar: (String) -> RemapGuardianRegistrationStatus
	private let guardianRegistrationQueue = DispatchQueue(
		label: "com.ergoptiplus.remap-guardian.registration",
		qos: .userInitiated
	)
	private var applicationIsTerminating = false

	/// Creates the production delegate or an injected launcher boundary for tests.
	/// - Parameters:
	///   - launcherIdentityReader: Captures the running launcher's exact file identity.
	///   - processRunner: Performs the sole embedded-Hammerspoon child start.
	///   - fatalReporter: Test-only observer replacing the modal fatal UI.
	///   - guardianRegistrar: Resolves the independent service off the AppKit thread.
	init(
		launcherIdentityReader: @escaping (String?) -> (device: String, inode: String)? =
			launcherExecutableFileIdentity,
		processRunner: @escaping (Process) throws -> Void = { try $0.run() },
		fatalReporter: ((String) -> Void)? = nil,
		guardianRegistrar: @escaping (String) -> RemapGuardianRegistrationStatus =
			remapGuardianRegistrationStatus
	) {
		self.launcherIdentityReader = launcherIdentityReader
		self.processRunner = processRunner
		self.fatalReporter = fatalReporter
		self.guardianRegistrar = guardianRegistrar
		super.init()
	}




	// =====================================
	// ===== 2.1) NSApplicationDelegate ====
	// =====================================

	func applicationDidFinishLaunching(_ notification: Notification) {
		LauncherLog.write("applicationDidFinishLaunching — version \(bundleVersionString())")

		// Hide the launcher from the Dock — Hammerspoon's own menubar item
		// is the only UI affordance the user should see.
		NSApp.setActivationPolicy(.accessory)

		// Wire Sparkle. Standard controller starts checking automatically based
		// on Info.plist's SUEnableAutomaticChecks / SUScheduledCheckInterval.
		updaterController = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: nil,
			userDriverDelegate: nil
		)

		// Tell the embedded Hammerspoon where to read its Lua config from.
		seedConfigDirDefault()

		// Spawn the embedded Hammerspoon binary; if it cannot be located we
		// surface a hard error rather than silently degrading.
		guard let hsBinary = locateEmbeddedHammerspoonBinary() else {
			fail("Embedded Hammerspoon binary not found inside the .app bundle.")
			return
		}

		// Hammerspoon itself tolerates a missing/invalid MJConfigFile by starting
		// normally with no Lua loaded — no crash, exit code 0. Without this check
		// a partial unzip, a disk-full install, or a build-script regression that
		// silently drops the Lua tree would all produce an app that launches,
		// shows nothing wrong, and remaps nothing (F-HIGH-28). Fail loudly instead.
		guard FileManager.default.fileExists(atPath: bundledInitLuaPath()) else {
			fail("Bundled configuration (init.lua) not found inside the .app bundle.")
			return
		}

		// Service registration can execute bounded launchctl children on macOS
		// 11/12. Keep that work off AppKit's main thread, but do not launch
		// Hammerspoon until its result is known: remapping remains fail-closed.
		guard let launcherPath = Bundle.main.executablePath else {
			fail("Running launcher executable path is unavailable.")
			return
		}
		startManagedHammerspoon(at: hsBinary, launcherPath: launcherPath)
	}

	/// Starts Hammerspoon only after the independent guardian result is known.
	func startManagedHammerspoon(at hsBinary: String, launcherPath: String) {
		beginRemapGuardianRegistration(executablePath: launcherPath) { [weak self] status in
			guard let self, !self.applicationIsTerminating else { return }
			if status != .ready {
				LauncherLog.write(
					"remap guardian \(status.rawValue); ErgoptiPlus rules remain inert"
				)
			}
			self.launchHammerspoon(at: hsBinary, remapGuardianStatus: status)
		}
	}

	/// Resolves bounded service work away from AppKit and returns on the main queue.
	func beginRemapGuardianRegistration(
		executablePath: String,
		completion: @escaping (RemapGuardianRegistrationStatus) -> Void
	) {
		let registrar = guardianRegistrar
		guardianRegistrationQueue.async {
			let status = registrar(executablePath)
			DispatchQueue.main.async { completion(status) }
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		applicationIsTerminating = true
		// Forward the quit to the child so Hammerspoon shuts down cleanly.
		if let proc = hsProcess, proc.isRunning {
			proc.terminate()
		}
	}




	// =====================================
	// ===== 2.2) Hammerspoon Discovery ====
	// =====================================

	// Locate the embedded Hammerspoon binary inside our bundle. The build
	// script places Hammerspoon.app under Contents/Frameworks so it does not
	// pollute Contents/MacOS (which Apple reserves for the host executable).
	private func locateEmbeddedHammerspoonBinary() -> String? {
		let bundlePath = Bundle.main.bundlePath
		let candidate = "\(bundlePath)/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
		return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
	}

	// Full path to the bundled init.lua that Hammerspoon reads via MJConfigFile.
	// MJConfigFile is the actual preference key HS uses (see variables.m); the
	// directory is derived from the file path by HS internally, so every Lua
	// require() and hs.configdir resolve correctly from this single override.
	private func bundledConfigDir() -> String {
		return "\(Bundle.main.bundlePath)/Contents/Resources/static/ergopti_plus/macos"
	}

	private func bundledInitLuaPath() -> String {
		return bundledConfigDir() + "/init.lua"
	}

	// Path to the vendored Karabiner-Elements installer .app. The Lua driver
	// calls hs.open() on this path when KE is not yet installed so the user
	// steps through the system-extension approval without any download.
	private func bundledKarabinerInstallerPath() -> String {
		return "\(Bundle.main.bundlePath)/Contents/Resources/Tools/Karabiner/Karabiner-Elements.app"
	}

	// Path to the vendored Ollama server binary. The Lua driver sets
	// OLLAMA_MODELS and spawns this binary directly so local LLM inference
	// works without a separate Ollama install.
	private func bundledOllamaBinPath() -> String {
		return "\(Bundle.main.bundlePath)/Contents/Resources/Tools/Ollama/ollama"
	}




	// =====================================
	// ===== 2.3) Hammerspoon Lifecycle ====
	// =====================================

	// Write Hammerspoon preference overrides directly via CFPreferencesSetValue.
	// This writes into ~/Library/Preferences/<bundleId>.plist synchronously,
	// bypassing the cfprefsd async pipeline that `defaults write` goes through.
	// Hammerspoon reads its prefs via [NSUserDefaults standardUserDefaults] under
	// its own bundle ID (rewritten to kErgoptiBundleId at build time); the plist
	// is flushed before launchHammerspoon() so HS sees the correct path on the
	// very first read, even on first-ever launch.
	// Done at every startup so a user who moved the .app sees the new path.
	private func seedConfigDirDefault() {
		let appId = kErgoptiBundleId as CFString
		let user  = kCFPreferencesCurrentUser
		let host  = kCFPreferencesAnyHost

		// Point HS at our bundled init.lua — MJConfigFile takes the full file path.
		CFPreferencesSetValue(
			kHammerspoonConfigKey as CFString,
			bundledInitLuaPath() as CFString,
			appId, user, host)

		// Suppress the native Hammerspoon hammer menubar icon and Dock icon.
		// Ergopti provides its own menubar item via hs.menubar; the HS default
		// icons are redundant and reveal the underlying dependency.
		for key in ["MJShowMenuIconOnLaunch", "MJShowDockIconOnLaunch"] {
			CFPreferencesSetValue(
				key as CFString,
				false as CFBoolean,
				appId, user, host)
		}

		// Flush synchronously so the plist is on disk before we exec Hammerspoon.
		CFPreferencesSynchronize(appId, user, host)
	}

	// Launch the embedded Hammerspoon as a child Process. We use Process
	// rather than NSWorkspace.open so terminating the launcher also terminates
	// Hammerspoon — keeping the two visually fused for the user.
	func launchHammerspoon(
		at binaryPath: String,
		remapGuardianStatus: RemapGuardianRegistrationStatus = .ready
	) {
		guard let launcherPath = Bundle.main.executablePath,
			!launcherPath.isEmpty,
			let launcherIdentity = launcherIdentityReader(launcherPath)
		else {
			fail("Running launcher executable identity is unavailable.")
			return
		}

		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: binaryPath)

		// Inherit our environment and add a marker the bundled Lua config can
		// optionally read to know it is running under the Ergopti launcher.
		var env = launcherChildEnvironment(
			base: ProcessInfo.processInfo.environment,
			launcherPid: ProcessInfo.processInfo.processIdentifier,
			launcherBundleId: Bundle.main.bundleIdentifier
		)
		env["ERGOPTI_LAUNCHER_VERSION"]       = bundleVersionString()
		env["ERGOPTI_CONFIG_DIR"]             = bundledConfigDir()
		env["ERGOPTI_KARABINER_INSTALLER"]    = bundledKarabinerInstallerPath()
		env["ERGOPTI_OLLAMA_BIN"]             = bundledOllamaBinPath()
		env["ERGOPTI_LAUNCHER_EXECUTABLE"]     = launcherPath
		env["ERGOPTI_REMAP_GUARDIAN_STATUS"]  = remapGuardianStatus.rawValue
		env.removeValue(forKey: "ERGOPTI_LAUNCHER_DEVICE")
		env.removeValue(forKey: "ERGOPTI_LAUNCHER_INODE")
		env["ERGOPTI_LAUNCHER_DEVICE"] = launcherIdentity.device
		env["ERGOPTI_LAUNCHER_INODE"] = launcherIdentity.inode
		proc.environment = env

		proc.terminationHandler = { [weak self] terminated in
			// When Hammerspoon exits (crash or clean quit), the launcher quits
			// too so the user is never left with an orphaned process.
			let code = terminated.terminationStatus
			NSLog("[Ergopti] embedded Hammerspoon exited with code \(code)")
			LauncherLog.write("embedded Hammerspoon exited with code \(code)")
			DispatchQueue.main.async {
				NSApp.terminate(self)
			}
		}

		do {
			try processRunner(proc)
			hsProcess = proc
			LauncherLog.write("embedded Hammerspoon launched at \(binaryPath)")
		} catch {
			fail("Failed to launch embedded Hammerspoon: \(error.localizedDescription)")
		}
	}




	// ===================================
	// ===== 2.4) Failure handling =======
	// ===================================

	// Surface a fatal error to the user before quitting; running with no
	// Hammerspoon to spawn means the .app is broken and we must not pretend
	// otherwise (fail-fast principle from copilot-instructions.md).
	//
	// Also persisted to LauncherLog (F-MED-30) — the NSAlert is the only
	// diagnostic surface in an interactive session, but a headless/automated
	// launch (Sparkle's silent-update relaunch, a CI smoke test, a script
	// wrapping the app) never sees it. Without a durable artifact a failure in
	// that context left literally nothing to investigate after the fact.
	private func fail(_ message: String) {
		if let fatalReporter {
			fatalReporter(message)
			return
		}

		LauncherLog.write("FATAL: \(message)")

		let alert = NSAlert()
		alert.messageText = "Ergopti n'a pas pu démarrer"
		alert.informativeText = message
		alert.alertStyle = .critical
		alert.addButton(withTitle: "Quitter")
		alert.runModal()
		NSApp.terminate(nil)
	}

	private func bundleVersionString() -> String {
		let info = Bundle.main.infoDictionary
		let short  = info?["CFBundleShortVersionString"] as? String
		let build  = info?["CFBundleVersion"]            as? String
		return [short, build].compactMap { $0 }.joined(separator: "+")
	}
}




// =====================================
// =====================================
// ======= 3/ App Bootstrap ============
// =====================================
// =====================================

// The launcher binary also serves every headless native lease role.
// Branch before touching NSApplication, CFPreferences or Sparkle so a helper
// spawned by Hammerspoon owns no GUI/application lifecycle.
if KarabinerLeaseWorker.handles(arguments: CommandLine.arguments) {
	Darwin.exit(KarabinerLeaseWorker.run(arguments: CommandLine.arguments))
}

// Write MJConfigFile via CFPreferences before NSApplication.run() so Hammerspoon
// always sees the correct config path, even if applicationDidFinishLaunching is
// never reached (Gatekeeper first-run kill, Sparkle init exception, etc.).
// CFPreferencesSynchronize flushes synchronously to disk before app.run().
let _earlyInitLua = Bundle.main.bundlePath + "/Contents/Resources/static/ergopti_plus/macos/init.lua"
CFPreferencesSetValue(
    kHammerspoonConfigKey as CFString,
    _earlyInitLua as CFString,
    kErgoptiBundleId as CFString,
    kCFPreferencesCurrentUser,
    kCFPreferencesAnyHost)
CFPreferencesSynchronize(
    kErgoptiBundleId as CFString,
    kCFPreferencesCurrentUser,
    kCFPreferencesAnyHost)

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

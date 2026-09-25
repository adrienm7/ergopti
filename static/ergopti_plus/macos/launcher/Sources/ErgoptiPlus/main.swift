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
//   2. Launch the embedded Hammerspoon app through Launch Services; forward its
//      lifecycle so quitting Ergopti cleanly terminates Hammerspoon, and a
//      Hammerspoon shutdown terminates Ergopti.
//   3. Host Sparkle (SPUStandardUpdaterController) so the in-app updater can
//      ship new releases over the configured appcast.
//   4. Install a private inherited umask before Hammerspoon or a native helper
//      can create configuration-bearing transaction sidecars.
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

// Shared bootstrap constants live in LauncherConstants.swift so XCTest imports
// initialized storage instead of executable-entry-point globals.

/// Installs the process-wide private creation mask before any child is spawned.
/// - Parameter setter: Injectable Darwin boundary used by the launcher tests.
/// - Returns: The process mask that was active before the installation.
@discardableResult
func installPrivateProcessUmask(
	setter: (mode_t) -> mode_t = { Darwin.umask($0) }
) -> mode_t {
	return setter(kPrivateProcessUmask)
}

/// Stable user-writable bootstrap file used by the bundled Lua resolver.
/// The Lua source itself lives inside signed application resources, so deriving
/// paths.toml from MJConfigFile would make every first-run write target the app
/// bundle and lose the override across replacements.
/// - Parameter homeDirectory: Current user's Foundation home directory.
/// - Returns: Absolute path exported to the embedded Hammerspoon process.
func managedPathsFile(homeDirectory: String = NSHomeDirectory()) -> String {
	return homeDirectory + "/Library/Application Support/ErgoptiPlus/paths.toml"
}

/// Returns the inherited child environment with the exact live launcher
/// identity replacing any stale values inherited from an ancestor process.
/// - Parameters:
///   - base: Environment inherited by the Swift launcher.
///   - launcherPid: Current Swift launcher process identifier.
///   - launcherBundleId: Current launcher bundle identifier when observable.
///   - loggerEndpoint: Pre-bound native logger authority for this exact child.
/// - Returns: Environment safe to assign to the embedded Hammerspoon child.
func launcherChildEnvironment(
	base: [String: String],
	launcherPid: Int32,
	launcherBundleId: String?,
	loggerEndpoint: LoggerDatagramEndpoint? = nil
) -> [String: String] {
	var environment = base
	// Launch Services injects the outer app identity into its environment.
	// Process inherits it verbatim, but the child is a second GUI bundle: keeping
	// either marker makes AppKit/NSUserDefaults treat embedded Hammerspoon as the
	// launcher, so it misses the MJConfigFile stored under its own bundle ID and
	// can terminate cleanly before loading init.lua. Let the child derive its
	// identity from its own executable and Info.plist.
	environment.removeValue(forKey: "__CFBundleIdentifier")
	environment.removeValue(forKey: "XPC_SERVICE_NAME")
	environment["ERGOPTI_LAUNCHER_PID"] = String(launcherPid)
	environment.removeValue(forKey: "ERGOPTI_LAUNCHER_BUNDLE_ID")
	environment.removeValue(forKey: kLoggerDatagramPortEnvironment)
	environment.removeValue(forKey: kLoggerDatagramTokenEnvironment)
	if let launcherBundleId, !launcherBundleId.isEmpty {
		environment["ERGOPTI_LAUNCHER_BUNDLE_ID"] = launcherBundleId
	}
	if let loggerEndpoint {
		environment[kLoggerDatagramPortEnvironment] = String(loggerEndpoint.port)
		environment[kLoggerDatagramTokenEnvironment] = loggerEndpoint.token
	}
	return environment
}

/// Lists the launcher-owned keys of a child environment by name only, so the
/// startup trail shows what Hammerspoon received without logging a credential.
/// - Parameter environment: Environment assigned to the embedded child.
/// - Returns: Sorted comma-separated `ERGOPTI_*` names, or "none".
func launcherEnvironmentKeySummary(_ environment: [String: String]) -> String {
	let names = environment.keys.filter { $0.hasPrefix("ERGOPTI_") }.sorted()
	return names.isEmpty ? "none" : names.joined(separator: ", ")
}

/// Describes one embedded-process exit for logs and alerts.
/// - Parameter exit: Kernel exit observation.
/// - Returns: "with exit code N", "after signal N" or the unavailable errno.
func embeddedProcessExitDescription(_ exit: EmbeddedProcessExit) -> String {
	switch exit {
	case let .exited(code):
		return "with exit code \(code)"
	case let .signaled(signal):
		return "after signal \(signal)"
	case let .unavailable(errorCode):
		return "with unavailable exit status (errno \(errorCode))"
	}
}

/// Resolves the application bundle that owns an embedded GUI executable.
func embeddedApplicationBundleURL(binaryPath: String) -> URL? {
	let executableURL = URL(fileURLWithPath: binaryPath).standardizedFileURL
	let appURL = executableURL
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()
	guard appURL.pathExtension == "app" else { return nil }
	return appURL
}

/// Creates the Launch Services request used for the embedded GUI runtime.
func embeddedApplicationOpenConfiguration(
	environment: [String: String]
) -> NSWorkspace.OpenConfiguration {
	let configuration = NSWorkspace.OpenConfiguration()
	configuration.activates = false
	configuration.addsToRecentItems = false
	configuration.createsNewApplicationInstance = true
	configuration.environment = environment
	return configuration
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

	/// Absolute launcher.log path, exported so the Lua runtime can append its
	/// own fatal line and named in every fatal alert.
	static var filePath: String { return logDirectory + "/" + logFileName }

	/// Per-launch fatal report written by Lua before it exits (see
	/// EmbeddedFatalReport.swift); kept beside launcher.log for the user.
	static var fatalReportPath: String { return logDirectory + "/hammerspoon-fatal.txt" }

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
			// A lost launcher.log line must still reach the unified log, or a
			// refused directory or a lock timeout erases the only diagnostic.
			_ = writeUnlocked(message, directoryPath: logDirectory, onFailure: { step, errorCode in
				NSLog("ErgoptiPlus launcher.log %@ failed (errno %d): %@", step, errorCode, message)
			})
		}
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	/// Exercises the production append path in a private SwiftPM subprocess.
	/// Release builds expose no caller-controlled logging destination.
	static func writeForTesting(
		_ message: String,
		directoryPath: String,
		beforeLock: (() -> Void)? = nil,
		onFailure: ((String, Int32) -> Void)? = nil
	) -> Bool {
		guard isValidTestLogDirectory(directoryPath) else {
			onFailure?("validate-test-directory", EINVAL)
			return false
		}
		return queue.sync {
			writeUnlocked(
				message,
				directoryPath: directoryPath,
				beforeLock: beforeLock,
				onFailure: onFailure
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

	/// Opens the user-owned log directory through the same resolver as the Lua
	/// log sink, so a symlinked ~/Library/Logs layout is honoured identically.
	private static func openLogDirectory(
		_ directoryPath: String,
		onFailure: ((String, Int32) -> Void)?
	) -> Int32 {
		switch OwnedLogDirectoryResolver.open(directoryPath) {
		case let .success(directory):
			return directory.descriptor
		case let .failure(failure):
			switch failure.refusal {
			case .notDirectory, .notOwned:
				onFailure?("validate-directory", EINVAL)
			case let .cannotSetPermissions(errorCode):
				onFailure?("chmod-directory", errorCode)
			case let .accessDenied(errorCode), let .cannotCreate(errorCode), let .unavailable(errorCode):
				onFailure?("open-directory", errorCode)
			case .invalidPath, .danglingSymlink:
				onFailure?("open-directory", ENOENT)
			}
			return -1
		}
	}

	/// Opens only `launcher.log` relative to the already-validated directory.
	private static func openLogFile(
		directoryDescriptor: Int32,
		onFailure: ((String, Int32) -> Void)?
	) -> Int32 {
		let (descriptor, openError) = logFileName.withCString { name in
			let result = Darwin.openat(
				directoryDescriptor,
				name,
				O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
				S_IRUSR | S_IWUSR
			)
			return (result, result < 0 ? errno : 0)
		}
		guard descriptor >= 0 else {
			#if ERGOPTI_GUARDIAN_TEST_SUPPORT
			if onFailure != nil {
				var directoryAttributes = stat()
				let directoryStatus = Darwin.fstat(directoryDescriptor, &directoryAttributes)
				let diagnostic = "Logger open failure pid=\(getpid()) errno=\(openError) "
					+ "directoryStatus=\(directoryStatus) directoryInode=\(directoryAttributes.st_ino) "
					+ "directoryLinks=\(directoryAttributes.st_nlink).\n"
				_ = writeLauncherLogData(Data(diagnostic.utf8), descriptor: STDERR_FILENO)
			}
			#endif
			onFailure?("open-file", openError)
			return -1
		}
		var attributes = stat()
		guard Darwin.fstat(descriptor, &attributes) == 0 else {
			onFailure?("stat-file", errno)
			Darwin.close(descriptor)
			return -1
		}
		guard (attributes.st_mode & S_IFMT) == S_IFREG,
			attributes.st_uid == geteuid(),
			attributes.st_nlink == 1
		else {
			onFailure?("validate-file", EINVAL)
			Darwin.close(descriptor)
			return -1
		}
		guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
			onFailure?("chmod-file", errno)
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
			if ergoptiFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
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
		beforeLock: (() -> Void)? = nil,
		onFailure: ((String, Int32) -> Void)? = nil
	) -> Bool {
		let timestamp = dateFormatter.string(from: Date())
		let line = "[\(timestamp)] \(message)\n"
		guard let data = line.data(using: .utf8) else { return false }

		let directoryDescriptor = openLogDirectory(directoryPath, onFailure: onFailure)
		guard directoryDescriptor >= 0 else { return false }
		defer { Darwin.close(directoryDescriptor) }
		let logDescriptor = openLogFile(
			directoryDescriptor: directoryDescriptor,
			onFailure: onFailure
		)
		guard logDescriptor >= 0 else { return false }
		defer { Darwin.close(logDescriptor) }
		beforeLock?()
		guard acquireLogLock(logDescriptor) else {
			onFailure?("lock-file", errno)
			return false
		}
		defer { _ = ergoptiFlock(logDescriptor, LOCK_UN) }
		let written = writeLauncherLogData(data, descriptor: logDescriptor)
		if !written { onFailure?("write-file", errno) }
		return written
	}
}




// =====================================
// =====================================
// ======= 2/ AppDelegate ==============
// =====================================
// =====================================

final class AppDelegate: NSObject, NSApplicationDelegate {

	private var hsApplication: NSRunningApplication?
	private var hsExitMonitor: EmbeddedProcessExitMonitoring?
	private var hsExitMonitorGeneration: UInt64 = 0
	private var hsLaunchContext: (
		binaryPath: String,
		guardianStatus: RemapGuardianRegistrationStatus
	)?
	private var hsBootstrapReady = false
	private var hsBootstrapRecoveryUsed = false
	private var hsLogFolderRefusal: LogDirectoryFailure?
	private var loggerWorker: LoggerDatagramServing?
	private var updaterController: SPUStandardUpdaterController?
	private let updaterCommandRouter = UpdaterCommandRouter()
	private let launcherIdentityReader: (String?) -> (device: String, inode: String)?
	private let applicationLauncher: (
		URL,
		NSWorkspace.OpenConfiguration,
		@escaping (NSRunningApplication?, Error?) -> Void
	) -> Void
	private let fatalReporter: ((String) -> Void)?
	private let applicationTerminator: (Any?) -> Void
	private let guardianRegistrar: (String) -> RemapGuardianRegistrationStatus
	private let loggerWorkerFactory: () -> LoggerDatagramServing?
	private let processExitMonitorFactory: EmbeddedProcessExitMonitorFactory
	private let fatalReportStore: EmbeddedFatalReportStore
	private let guardianRegistrationQueue = DispatchQueue(
		label: "com.ergoptiplus.remap-guardian.registration",
		qos: .userInitiated
	)
	private var applicationIsTerminating = false
	// Monotonic origin of this launcher's startup trail.
	private let launcherStartUptime = ProcessInfo.processInfo.systemUptime

	/// Milliseconds since the launcher process started its delegate.
	private func elapsedMilliseconds() -> Int {
		return Int((ProcessInfo.processInfo.systemUptime - launcherStartUptime) * 1000)
	}

	/// Creates the production delegate or an injected launcher boundary for tests.
	/// - Parameters:
	///   - launcherIdentityReader: Captures the running launcher's exact file identity.
	///   - applicationLauncher: Starts embedded Hammerspoon through Launch Services.
	///   - fatalReporter: Test-only observer replacing the modal fatal UI.
	///   - applicationTerminator: Ends AppKit after a clean child shutdown.
	///   - guardianRegistrar: Resolves the independent service off the AppKit thread.
	///   - loggerWorkerFactory: Binds the native loopback logger before child start.
	///   - processExitMonitorFactory: Acquires the child's kernel exit-status owner.
	///   - fatalReportStore: Per-launch report the Lua runtime writes before a fatal exit.
	init(
		launcherIdentityReader: @escaping (String?) -> (device: String, inode: String)? =
			launcherExecutableFileIdentity,
		applicationLauncher: @escaping (
			URL,
			NSWorkspace.OpenConfiguration,
			@escaping (NSRunningApplication?, Error?) -> Void
		) -> Void = { url, configuration, completion in
			NSWorkspace.shared.openApplication(
				at: url,
				configuration: configuration,
				completionHandler: completion
			)
		},
		fatalReporter: ((String) -> Void)? = nil,
		applicationTerminator: @escaping (Any?) -> Void = { NSApp.terminate($0) },
		guardianRegistrar: @escaping (String) -> RemapGuardianRegistrationStatus =
			remapGuardianRegistrationStatus,
		loggerWorkerFactory: @escaping () -> LoggerDatagramServing? = {
			LoggerDatagramWorker()
		},
		processExitMonitorFactory: @escaping EmbeddedProcessExitMonitorFactory =
			makeEmbeddedProcessExitMonitor,
		fatalReportStore: EmbeddedFatalReportStore =
			EmbeddedFatalReportStore(path: LauncherLog.fatalReportPath)
	) {
		self.launcherIdentityReader = launcherIdentityReader
		self.applicationLauncher = applicationLauncher
		self.fatalReporter = fatalReporter
		self.applicationTerminator = applicationTerminator
		self.guardianRegistrar = guardianRegistrar
		self.loggerWorkerFactory = loggerWorkerFactory
		self.processExitMonitorFactory = processExitMonitorFactory
		self.fatalReportStore = fatalReportStore
		super.init()
	}




	// =====================================
	// ===== 2.1) NSApplicationDelegate ====
	// =====================================

	func applicationDidFinishLaunching(_ notification: Notification) {
		LauncherLog.write("launcher startup started — version \(bundleVersionString())")

		// Hide the launcher from the Dock — Hammerspoon's own menubar item
		// is the only UI affordance the user should see.
		NSApp.setActivationPolicy(.accessory)

		// Wire Sparkle. Automatic checks (Info.plist SUEnableAutomaticChecks /
		// SUScheduledCheckInterval) only fetch the appcast; a download must wait
		// for the user's install choice, which the consent policy proves on the
		// live updater before it may start. A refusal leaves updates off rather
		// than letting Sparkle download in the background.
		let controller = SPUStandardUpdaterController(
			startingUpdater: false,
			updaterDelegate: nil,
			userDriverDelegate: nil
		)
		if let refusal = UpdateConsentPolicy.refusal(for: controller.updater) {
			LauncherLog.write("ERROR: Sparkle updater not started: \(refusal)")
		} else {
			controller.startUpdater()
			updaterController = controller
			updaterCommandRouter.bind(controller)
			LauncherLog.write("launcher stage: Sparkle updater wired (+\(elapsedMilliseconds()) ms)")
		}

		// Tell the embedded Hammerspoon where to read its Lua config from.
		seedConfigDirDefault()
		LauncherLog.write("launcher stage: \(kHammerspoonConfigKey) seeded to \(bundledInitLuaPath())")

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
		LauncherLog.write("launcher stage: embedded Hammerspoon and bundled init.lua found at \(hsBinary)")

		// Service registration can execute bounded launchctl children on macOS
		// 11/12. Keep that work off AppKit's main thread, but do not launch
		// Hammerspoon until its result is known: remapping remains fail-closed.
		guard let launcherPath = Bundle.main.executablePath else {
			fail("Running launcher executable path is unavailable.")
			return
		}
		startManagedHammerspoon(at: hsBinary, launcherPath: launcherPath)
	}

	/// Routes the private menu command to the retained Sparkle controller.
	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls where updaterCommandRouter.route(url) {
			LauncherLog.write("accepted native updater check command")
		}
	}

	/// Starts Hammerspoon only after the independent guardian result is known.
	func startManagedHammerspoon(at hsBinary: String, launcherPath: String) {
		LauncherLog.write("launcher stage: remap guardian registration started")
		beginRemapGuardianRegistration(executablePath: launcherPath) { [weak self] status in
			guard let self, !self.applicationIsTerminating else { return }
			LauncherLog.write(
				"launcher stage: remap guardian registration finished: \(status.rawValue) "
					+ "(+\(self.elapsedMilliseconds()) ms)"
			)
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
		LauncherLog.write("applicationWillTerminate; stopping embedded Hammerspoon")
		cancelEmbeddedHammerspoonExitMonitoring()
		// Forward the quit to the child so Hammerspoon shuts down cleanly.
		if let application = hsApplication, !application.isTerminated {
			application.terminate()
		}
		// The DispatchSource cancel handler is asynchronous. Explicitly relinquish
		// the logger socket while AppKit is still alive instead of assuming process
		// teardown will eventually run the worker's deinitializer.
		loggerWorker?.stop()
		loggerWorker = nil
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
	// its own bundle ID (rewritten to kEmbeddedHammerspoonBundleId at build time);
	// the outer bundle prohibits duplicate instances, so the GUI child must keep
	// a distinct Launch Services identity. The plist
	// is flushed before launchHammerspoon() so HS sees the correct path on the
	// very first read, even on first-ever launch.
	// Done at every startup so a user who moved the .app sees the new path.
	private func seedConfigDirDefault() {
		let appId = kEmbeddedHammerspoonBundleId as CFString
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

	// Launch the embedded Hammerspoon through Launch Services. A nested AppKit
	// bundle cannot be bootstrapped reliably by executing its inner Mach-O: on
	// headless and fresh sessions it may receive a clean termination request
	// before setup.lua loads. NSWorkspace supplies the application launch context
	// while the returned NSRunningApplication preserves the fused lifecycle.
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
		// A report left by an earlier launch would be misattributed to this one.
		guard fatalReportStore.clear() else {
			fail("Stale embedded fatal report \(fatalReportStore.path) could not be removed.")
			return
		}
		guard let activeLoggerWorker = loggerWorker ?? loggerWorkerFactory() else {
			fail("Native Hammerspoon logger transport could not be started.")
			return
		}
		loggerWorker = activeLoggerWorker
		LauncherLog.write(
			"launcher stage: native logger worker bound on loopback port \(activeLoggerWorker.endpoint.port)"
		)
		hsLaunchContext = (binaryPath, remapGuardianStatus)
		hsLogFolderRefusal = nil
		activeLoggerWorker.setConfigureRefusalHandler { [weak self] failure in
			let record = {
				guard let self else { return }
				self.hsLogFolderRefusal = failure
				LauncherLog.write("embedded Hammerspoon log folder refused: \(failure.diagnostic)")
			}
			if Thread.isMainThread { record() }
			else { DispatchQueue.main.async(execute: record) }
		}
		activeLoggerWorker.setBootstrapReadyHandler { [weak self] in
			let markReady = {
				guard let self else { return }
				self.hsBootstrapReady = true
				LauncherLog.write(
					"embedded Hammerspoon bootstrap logger configured (+\(self.elapsedMilliseconds()) ms)"
				)
			}
			if Thread.isMainThread { markReady() }
			else { DispatchQueue.main.async(execute: markReady) }
		}

		// Inherit our environment and add a marker the bundled Lua config can
		// optionally read to know it is running under the Ergopti launcher.
		var env = launcherChildEnvironment(
			base: ProcessInfo.processInfo.environment,
			launcherPid: ProcessInfo.processInfo.processIdentifier,
			launcherBundleId: Bundle.main.bundleIdentifier,
			loggerEndpoint: activeLoggerWorker.endpoint
		)
		env["ERGOPTI_LAUNCHER_VERSION"]       = bundleVersionString()
		env["ERGOPTI_CONFIG_DIR"]             = bundledConfigDir()
		env["ERGOPTI_PATHS_FILE"]             = managedPathsFile()
		env["ERGOPTI_KARABINER_INSTALLER"]    = bundledKarabinerInstallerPath()
		env["ERGOPTI_OLLAMA_BIN"]             = bundledOllamaBinPath()
		env["ERGOPTI_LAUNCHER_EXECUTABLE"]     = launcherPath
		env["ERGOPTI_REMAP_GUARDIAN_STATUS"]  = remapGuardianStatus.rawValue
		env[kFatalReportEnvironment]          = fatalReportStore.path
		env[kLauncherLogEnvironment]          = LauncherLog.filePath
		env.removeValue(forKey: "ERGOPTI_LAUNCHER_DEVICE")
		env.removeValue(forKey: "ERGOPTI_LAUNCHER_INODE")
		env["ERGOPTI_LAUNCHER_DEVICE"] = launcherIdentity.device
		env["ERGOPTI_LAUNCHER_INODE"] = launcherIdentity.inode
		guard let applicationURL = embeddedApplicationBundleURL(binaryPath: binaryPath) else {
			loggerWorker?.stop()
			loggerWorker = nil
			fail("Embedded Hammerspoon application bundle path is invalid.")
			return
		}

		LauncherLog.write("launcher stage: child environment exports \(launcherEnvironmentKeySummary(env))")
		let configuration = embeddedApplicationOpenConfiguration(environment: env)
		LauncherLog.write("launcher stage: launch requested for \(applicationURL.path)")
		applicationLauncher(applicationURL, configuration) { [weak self] application, error in
			let finishLaunch = {
				guard let self else { return }
				guard let application else {
					self.loggerWorker?.stop()
					self.loggerWorker = nil
					self.fail(
						"Failed to launch embedded Hammerspoon: "
							+ (error?.localizedDescription ?? "Launch Services returned no application.")
					)
					return
				}
				self.trackEmbeddedHammerspoon(
					application,
					applicationURL: applicationURL,
					guardianStatus: remapGuardianStatus
				)
			}
			if Thread.isMainThread { finishLaunch() }
			else { DispatchQueue.main.async(execute: finishLaunch) }
		}
	}

	func trackEmbeddedHammerspoon(
		_ application: NSRunningApplication,
		applicationURL: URL,
		guardianStatus: RemapGuardianRegistrationStatus
	) {
		hsApplication = application
		LauncherLog.write(
			"embedded Hammerspoon launched at \(applicationURL.path) "
				+ "(pid \(application.processIdentifier), +\(elapsedMilliseconds()) ms)"
		)
		guard !application.isTerminated else {
			hsApplication = nil
			handleEmbeddedHammerspoonExit(
				.unavailable(errorCode: ESRCH),
				guardianStatus: guardianStatus
			)
			return
		}
		guard beginEmbeddedHammerspoonExitMonitoring(
			processIdentifier: application.processIdentifier,
			guardianStatus: guardianStatus
		) else { return }
		LauncherLog.write(
			"launcher startup complete: exit monitoring attached to pid \(application.processIdentifier) "
				+ "(+\(elapsedMilliseconds()) ms)"
		)
		// Close the launch-completion-to-kqueue race without fabricating success.
		// Once the monitor is attached, every later exit edge carries a real status.
		guard !application.isTerminated else {
			cancelEmbeddedHammerspoonExitMonitoring()
			hsApplication = nil
			handleEmbeddedHammerspoonExit(
				.unavailable(errorCode: ESRCH),
				guardianStatus: guardianStatus
			)
			return
		}
	}

	/// Acquires the authoritative kernel status stream for one embedded process.
	@discardableResult
	func beginEmbeddedHammerspoonExitMonitoring(
		processIdentifier: pid_t,
		guardianStatus: RemapGuardianRegistrationStatus
	) -> Bool {
		cancelEmbeddedHammerspoonExitMonitoring()
		hsExitMonitorGeneration &+= 1
		let generation = hsExitMonitorGeneration
		guard let monitor = processExitMonitorFactory(processIdentifier, { [weak self] exit in
			DispatchQueue.main.async {
				self?.finishEmbeddedHammerspoonExitMonitoring(
					exit,
					guardianStatus: guardianStatus,
					generation: generation
				)
			}
		}) else {
			fail(
				"Embedded Hammerspoon exit-status monitoring could not attach to process "
					+ "\(processIdentifier)."
			)
			return false
		}
		hsExitMonitor = monitor
		return true
	}

	private func finishEmbeddedHammerspoonExitMonitoring(
		_ exit: EmbeddedProcessExit,
		guardianStatus: RemapGuardianRegistrationStatus,
		generation: UInt64
	) {
		guard generation == hsExitMonitorGeneration, hsExitMonitor != nil else { return }
		let monitor = hsExitMonitor
		hsExitMonitor = nil
		monitor?.cancel()
		hsApplication = nil
		LauncherLog.write(
			"embedded Hammerspoon terminated \(embeddedProcessExitDescription(exit)) "
				+ "(bootstrap logger configured: \(hsBootstrapReady), +\(elapsedMilliseconds()) ms)"
		)
		handleEmbeddedHammerspoonExit(exit, guardianStatus: guardianStatus)
	}

	private func cancelEmbeddedHammerspoonExitMonitoring() {
		hsExitMonitorGeneration &+= 1
		let monitor = hsExitMonitor
		hsExitMonitor = nil
		monitor?.cancel()
	}

	/// Surfaces unexpected child death with the exact independent guardian state.
	func handleEmbeddedHammerspoonExit(
		_ exit: EmbeddedProcessExit,
		guardianStatus: RemapGuardianRegistrationStatus
	) {
		guard !applicationIsTerminating else {
			applicationTerminator(self)
			return
		}
		// A refused log folder is deterministic: a retry would fail identically,
		// and the child exit status cannot say why (Hammerspoon reports 0 even
		// after Lua calls os.exit(1)). Name the folder and the cause instead.
		if !hsBootstrapReady, let refusal = hsLogFolderRefusal {
			fail(
				"Log folder refused: \(refusal.diagnostic).",
				alertText: logFolderRefusalAlertText(refusal, localization: LauncherLocalization.load())
			)
			return
		}
		// Checked before the clean-exit branch: exit status 0 after the logger
		// handshake is also what a fatal Lua abort looks like, and treating it as
		// a Quit made v0.0.0-dev.128 vanish with no dialog and no log.
		if let report = fatalReportStore.read() {
			fail(
				report.diagnostic,
				alertText: embeddedFatalAlertText(
					report,
					logPath: LauncherLog.filePath,
					localization: LauncherLocalization.load()
				)
			)
			return
		}
		if case .exited(code: 0) = exit, hsBootstrapReady {
			applicationTerminator(self)
			return
		}
		if case .exited(code: 0) = exit,
			!hsBootstrapRecoveryUsed,
			let launchContext = hsLaunchContext
		{
			hsBootstrapRecoveryUsed = true
			hsBootstrapReady = false
			LauncherLog.write(
				"embedded Hammerspoon exited before bootstrap readiness; retrying once"
			)
			launchHammerspoon(
				at: launchContext.binaryPath,
				remapGuardianStatus: launchContext.guardianStatus
			)
			return
		}

		fail(
			"Embedded Hammerspoon stopped unexpectedly \(embeddedProcessExitDescription(exit)). "
				+ remapGuardianExitDiagnostic(guardianStatus)
		)
	}

	private func remapGuardianExitDiagnostic(
		_ status: RemapGuardianRegistrationStatus
	) -> String {
		switch status {
		case .ready:
			return "The independent remap guardian is enforcing ErgoptiPlus remap revocation."
		case .requiresApproval:
			return "The independent remap guardian requires user approval; ErgoptiPlus rules remain inert."
		case .unavailable:
			return "The independent remap guardian is unavailable; ErgoptiPlus rules remain inert."
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
	//
	// The alert chrome and any cause-specific text come from the bundled locale
	// catalog. When that catalog is itself unreadable (a damaged bundle), the
	// English developer diagnostic is shown instead: the documented pre-i18n
	// fatal-modal exception.
	private func fail(_ message: String, alertText: String? = nil) {
		if let fatalReporter {
			fatalReporter(message)
			return
		}

		LauncherLog.write("FATAL: \(message)")

		let localization = LauncherLocalization.load()
		let alert = NSAlert()
		alert.messageText = localization?.text("launcher.fatal.title") ?? "ErgoptiPlus could not start"
		alert.informativeText = alertText ?? message
		alert.alertStyle = .critical
		alert.addButton(withTitle: localization?.text("launcher.fatal.quit") ?? "Quit")
		// The launcher runs as an accessory app that was never activated after
		// launch; without this the modal can open behind the frontmost window,
		// which to the user is indistinguishable from no dialog at all.
		NSApp.activate(ignoringOtherApps: true)
		alert.window.level = .modalPanel
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
installPrivateProcessUmask()

if KeychainTokenWorker.handles(arguments: CommandLine.arguments) {
	Darwin.exit(KeychainTokenWorker.run(arguments: CommandLine.arguments))
}

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
    kEmbeddedHammerspoonBundleId as CFString,
    kCFPreferencesCurrentUser,
    kCFPreferencesAnyHost)
CFPreferencesSynchronize(
    kEmbeddedHammerspoonBundleId as CFString,
    kCFPreferencesCurrentUser,
    kCFPreferencesAnyHost)

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

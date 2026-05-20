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




// =====================================
// =====================================
// ======= 2/ AppDelegate ==============
// =====================================
// =====================================

final class AppDelegate: NSObject, NSApplicationDelegate {

	private var hsProcess: Process?
	private var updaterController: SPUStandardUpdaterController?




	// =====================================
	// ===== 2.1) NSApplicationDelegate ====
	// =====================================

	func applicationDidFinishLaunching(_ notification: Notification) {
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
		launchHammerspoon(at: hsBinary)
	}

	func applicationWillTerminate(_ notification: Notification) {
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
		return "\(Bundle.main.bundlePath)/Contents/Resources/static/drivers/hammerspoon"
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
	private func launchHammerspoon(at binaryPath: String) {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: binaryPath)

		// Inherit our environment and add a marker the bundled Lua config can
		// optionally read to know it is running under the Ergopti launcher.
		var env = ProcessInfo.processInfo.environment
		env["ERGOPTI_LAUNCHER_VERSION"]       = bundleVersionString()
		env["ERGOPTI_CONFIG_DIR"]             = bundledConfigDir()
		env["ERGOPTI_KARABINER_INSTALLER"]    = bundledKarabinerInstallerPath()
		env["ERGOPTI_OLLAMA_BIN"]             = bundledOllamaBinPath()
		proc.environment = env

		proc.terminationHandler = { [weak self] terminated in
			// When Hammerspoon exits (crash or clean quit), the launcher quits
			// too so the user is never left with an orphaned process.
			let code = terminated.terminationStatus
			NSLog("[Ergopti] embedded Hammerspoon exited with code \(code)")
			DispatchQueue.main.async {
				NSApp.terminate(self)
			}
		}

		do {
			try proc.run()
			hsProcess = proc
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
	private func fail(_ message: String) {
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

// Write MJConfigDir via CFPreferences before NSApplication.run() so Hammerspoon
// always sees the correct config path, even if applicationDidFinishLaunching is
// never reached (Gatekeeper first-run kill, Sparkle init exception, etc.).
// CFPreferencesSynchronize flushes synchronously to disk before app.run().
let _earlyInitLua = Bundle.main.bundlePath + "/Contents/Resources/static/drivers/hammerspoon/init.lua"
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

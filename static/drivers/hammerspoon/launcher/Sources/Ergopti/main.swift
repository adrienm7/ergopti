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
// embedded HS reads its preferences from ~/Library/Preferences/com.ergopti.app.plist
// and cannot collide with a stock Hammerspoon install (org.hammerspoon.Hammerspoon).
let kErgoptiBundleId = "com.ergopti.app"

// Key Hammerspoon reads to locate its Lua config dir. Default would be
// ~/.hammerspoon; we override to keep Ergopti's tree fully self-contained.
let kHammerspoonConfigKey = "MJConfigDir"




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

	// Path to the bundled Lua config dir that ends up in MJConfigDir. The
	// build script mirrors the dev tree under Contents/Resources/, so the
	// config dir sits at the same offset as <repo>/static/drivers/hammerspoon
	// from the static root. Every Lua path in the driver walks up from
	// hs.configdir using that exact layout, so a single MJConfigDir override
	// fixes every read site without touching the Lua sources.
	private func bundledConfigDir() -> String {
		return "\(Bundle.main.bundlePath)/Contents/Resources/static/drivers/hammerspoon"
	}




	// =====================================
	// ===== 2.3) Hammerspoon Lifecycle ====
	// =====================================

	// Write our config-dir override into the bundle-id-scoped defaults plist
	// the embedded Hammerspoon will read on launch. Done at every startup so
	// a user who has moved the .app sees the new path immediately.
	private func seedConfigDirDefault() {
		let defaults = UserDefaults(suiteName: kErgoptiBundleId)
		defaults?.set(bundledConfigDir(), forKey: kHammerspoonConfigKey)
		defaults?.synchronize()
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
		env["ERGOPTI_LAUNCHER_VERSION"] = bundleVersionString()
		env["ERGOPTI_CONFIG_DIR"]       = bundledConfigDir()
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

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

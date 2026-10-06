// tools/diagnostics/native_global_switcher/GlobalSwitcherFixture.swift
// Two separately bundled instances supply independent visible fixture applications.
import AppKit
import Darwin

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let value = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 280, height: 160),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        value.title = Bundle.main.bundleIdentifier ?? "Unidentified fixture"
        value.makeKeyAndOrderFront(nil)
        window = value
        // No activation here: the Hammerspoon precondition activates B then A once.
        print("READY \(getpid())")
        fflush(stdout)
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }

// tools/diagnostics/hs274-context-target.swift
// Own an external Cocoa input window; the consumer independently observes it through AX.
import Cocoa
import CoreFoundation

final class Target: NSObject, NSApplicationDelegate {
    let request: URL
    let response: URL
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let input = NSTextField(frame: NSRect(x: 20, y: 85, width: 380, height: 28))
    let secret = NSSecureTextField(frame: NSRect(x: 20, y: 35, width: 380, height: 28))
    var sequence = 0
    var timer: Timer?
    let started = ProcessInfo.processInfo.systemUptime

    init(request: URL, response: URL) {
        self.request = request
        self.response = response
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(input)
        window.contentView!.addSubview(secret)
        input.setAccessibilityLabel("HS274 physical input")
        secret.setAccessibilityLabel("HS274 empty protected fixture")
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
            do { try poll() } catch {
                FileHandle.standardError.write(Data("Native target failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    func poll() throws {
        guard ProcessInfo.processInfo.systemUptime - started < 120 else {
            throw NSError(domain: "HS274 target lifetime exceeded", code: 1)
        }
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let data = try Data(contentsOf: request)
        guard data.count <= 1024,
              let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(command.keys) == Set(["sequence", "phase"]),
              let number = command["sequence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              let phase = command["phase"] as? String else {
            throw NSError(domain: "Invalid HS274 target command", code: 1)
        }
        if number.intValue == sequence { return }
        guard number.intValue == sequence + 1,
              ["public", "private", "secure", "resumed", "close"].contains(phase) else {
            throw NSError(domain: "Invalid HS274 target transition", code: 1)
        }
        sequence = number.intValue
        if phase == "close" {
            timer?.invalidate()
            window.close()
            NSApplication.shared.terminate(nil)
            return
        }
        window.title = phase == "private" ? "Private Browsing" : "HS274 input fixture"
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let field: NSTextField = phase == "secure" ? secret : input
        guard window.makeFirstResponder(field) else {
            throw NSError(domain: "Native target refused first responder", code: 1)
        }
        let receipt: [String: Any] = ["sequence": sequence, "phase": phase,
                                     "pid": ProcessInfo.processInfo.processIdentifier,
                                     "window_id": window.windowNumber]
        try JSONSerialization.data(withJSONObject: receipt).write(to: response, options: .atomic)
    }
}

guard CommandLine.arguments.count == 3 else { exit(64) }
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let target = Target(request: URL(fileURLWithPath: CommandLine.arguments[1]),
                    response: URL(fileURLWithPath: CommandLine.arguments[2]))
application.delegate = target
application.run()

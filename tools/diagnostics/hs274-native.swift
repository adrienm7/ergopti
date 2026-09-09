// tools/diagnostics/hs274-native.swift
// Observe native Quartz capabilities on a disposable macOS runner.

import CoreGraphics
import Darwin
import Foundation

let marker: Int64 = 0x4552474F
var receivedMarker: Int64?
var receivedKeycode: Int64?
var traces: [[String: Any]] = []
var failures: [String] = []

func observe(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == marker {
        if type == .keyDown {
            receivedMarker = event.getIntegerValueField(.eventSourceUserData)
            receivedKeycode = event.getIntegerValueField(.keyboardEventKeycode)
        }
        // Consume only this probe's tagged event on the disposable runner.
        return nil
    }
    return Unmanaged.passUnretained(event)
}

func run() throws -> [String: Any] {
    let variants: [(String, CGEventSourceStateID?)] = [
        ("nil", nil), ("hid", .hidSystemState),
        ("combined", .combinedSessionState), ("private", .privateState)
    ]
    var deliveryEvent: CGEvent?
    var deliverySource: CGEventSource?
    var checks = 0
    for (name, state) in variants {
        var source: CGEventSource?
        if let state {
            guard let acquired = CGEventSource(stateID: state) else {
                throw NSError(domain: "HS274", code: 1, userInfo: [NSLocalizedDescriptionKey: "source construction failed: \(name)"])
            }
            source = acquired
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true) else {
            throw NSError(domain: "HS274", code: 2, userInfo: [NSLocalizedDescriptionKey: "event construction failed: \(name)"])
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        guard let copy = event.copy(), let data = event.data,
              let decoded = CGEvent(withDataAllocator: nil, data: data) else {
            throw NSError(domain: "HS274", code: 3, userInfo: [NSLocalizedDescriptionKey: "event copy or serialization failed: \(name)"])
        }
        for (stage, candidate) in [("original", event), ("copy", copy), ("decoded", decoded)] {
            let tag = candidate.getIntegerValueField(.eventSourceUserData)
            let keycode = candidate.getIntegerValueField(.keyboardEventKeycode)
            traces.append([
                "source": name, "stage": stage, "tag": tag, "keycode": keycode,
                "type": candidate.type.rawValue,
                "source_state": candidate.getIntegerValueField(.eventSourceStateID),
                "source_pid": candidate.getIntegerValueField(.eventSourceUnixProcessID)
            ])
            if tag != marker { failures.append("\(name)/\(stage): provenance marker") }
            if keycode != 49 { failures.append("\(name)/\(stage): keycode") }
            if candidate.type != .keyDown { failures.append("\(name)/\(stage): event type") }
            checks += 3
        }
        if name == "hid" {
            deliveryEvent = event
            deliverySource = source
        }
    }
    var result: [String: Any] = [
        "status": failures.isEmpty ? "capabilities_observed" : "native_assertions_failed",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "uid": getuid(),
        "native_roundtrip_assertions": checks,
        "assertion_failures": failures,
        "traces": traces,
        "physical_keyboard_validated": false,
        "karabiner_virtual_hid_validated": false,
        "hs274_fixed": false,
        "listen_access": CGPreflightListenEventAccess(),
        "post_access": CGPreflightPostEventAccess(),
        "native_delivery": "unavailable"
    ]
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: observe, userInfo: nil
    ) else {
        result["native_delivery"] = "event_tap_creation_refused"
        return result
    }
    defer { CFMachPortInvalidate(tap) }
    guard let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        throw NSError(domain: "HS274", code: 4, userInfo: [NSLocalizedDescriptionKey: "runloop source construction failed"])
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, .commonModes)
    defer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), loopSource, .commonModes) }
    CGEvent.tapEnable(tap: tap, enable: true)
    guard CGEvent.tapIsEnabled(tap: tap) else {
        result["native_delivery"] = "event_tap_activation_refused"
        return result
    }
    guard CGPreflightPostEventAccess() else {
        result["native_delivery"] = "post_permission_missing"
        return result
    }
    guard let event = deliveryEvent,
          let release = CGEvent(keyboardEventSource: deliverySource, virtualKey: 49, keyDown: false) else {
        throw NSError(domain: "HS274", code: 5, userInfo: [NSLocalizedDescriptionKey: "paired delivery construction failed"])
    }
    release.setIntegerValueField(.eventSourceUserData, value: marker)
    event.post(tap: .cgSessionEventTap)
    release.post(tap: .cgSessionEventTap)
    CFRunLoopRunInMode(.defaultMode, 1, false)
    result["native_delivery"] = receivedMarker == marker && receivedKeycode == 49
        ? "tagged_quartz_event_observed" : "tagged_event_not_observed"
    return result
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "HS274", code: 6, userInfo: [NSLocalizedDescriptionKey: "expected output JSON path"])
    }
    let result = try run()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
    if !failures.isEmpty { exit(1) }
} catch {
    let report: [String: Any] = [
        "status": "error", "error": String(describing: error), "traces": traces,
        "assertion_failures": failures, "hs274_fixed": false
    ]
    if CommandLine.arguments.count == 2 {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        } catch {
            fputs("HS274 failure receipt write failed: \(error)\n", stderr)
        }
    }
    fputs("HS274 native observation failed: \(error)\n", stderr)
    exit(1)
}

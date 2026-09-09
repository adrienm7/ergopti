// tools/diagnostics/hs274-native.swift
// Observe native Quartz capabilities on a disposable macOS runner.

import CoreGraphics
import Foundation

let marker: Int64 = 0x4552474F
var receivedMarker: Int64?
var receivedKeycode: Int64?

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
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true) else {
        throw NSError(domain: "HS274", code: 1, userInfo: [NSLocalizedDescriptionKey: "event construction failed"])
    }
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    guard let copy = event.copy(), let data = event.data,
          let decoded = CGEvent(withData: data) else {
        throw NSError(domain: "HS274", code: 2, userInfo: [NSLocalizedDescriptionKey: "event copy or serialization failed"])
    }
    var checks = 0
    for candidate in [event, copy, decoded] {
        guard candidate.getIntegerValueField(.eventSourceUserData) == marker,
              candidate.getIntegerValueField(.keyboardEventKeycode) == 49,
              candidate.type == .keyDown else {
            throw NSError(domain: "HS274", code: 3, userInfo: [NSLocalizedDescriptionKey: "native provenance roundtrip failed"])
        }
        checks += 3
    }
    var result: [String: Any] = [
        "status": "capabilities_observed",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "native_roundtrip_assertions": checks,
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
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        throw NSError(domain: "HS274", code: 4, userInfo: [NSLocalizedDescriptionKey: "runloop source construction failed"])
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    defer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
    CGEvent.tapEnable(tap: tap, enable: true)
    guard CGEvent.tapIsEnabled(tap: tap) else {
        result["native_delivery"] = "event_tap_activation_refused"
        return result
    }
    guard CGPreflightPostEventAccess() else {
        result["native_delivery"] = "post_permission_missing"
        return result
    }
    guard let release = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) else {
        throw NSError(domain: "HS274", code: 6, userInfo: [NSLocalizedDescriptionKey: "paired release construction failed"])
    }
    release.setIntegerValueField(.eventSourceUserData, value: marker)
    event.post(tap: .cgSessionEventTap)
    release.post(tap: .cgSessionEventTap)
    CFRunLoopRunInMode(.defaultMode, 1, false)
    guard receivedMarker == marker && receivedKeycode == 49 else {
        result["native_delivery"] = "tagged_event_not_observed"
        return result
    }
    result["native_delivery"] = "tagged_quartz_event_observed"
    return result
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "HS274", code: 5, userInfo: [NSLocalizedDescriptionKey: "expected output JSON path"])
    }
    let result = try run()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("HS274 native observation failed: \(error)\n", stderr)
    exit(1)
}

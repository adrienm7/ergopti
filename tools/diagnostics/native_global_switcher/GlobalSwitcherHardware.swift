// tools/diagnostics/native_global_switcher/GlobalSwitcherHardware.swift
// Read-only hardware snapshot for the isolated native switcher fixture.
// This trusted finite executable never posts input, creates children, or grants TCC.
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

guard CommandLine.arguments.count == 2,
      let request = Int(CommandLine.arguments[1]), request > 0, request < 10000 else {
    exit(64)
}
let keys: [CGKeyCode] = [54, 55, 56, 60, 58, 61, 59, 62, 48]
let held = keys.filter { CGEventSource.keyState(.hidSystemState, key: $0) }.map(Int.init)
let session: [String: Any] = [
    "version": 1, "request": request, "source": "combined_session",
    "held": keys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }.map(Int.init),
    "flags": CGEventSource.flagsState(.combinedSessionState).rawValue
]
let frame: [String: Any] = [
    "version": 1, "request": request, "source": "hid_system",
    "held": held, "flags": CGEventSource.flagsState(.hidSystemState).rawValue,
    "listen_access": CGPreflightListenEventAccess(), "post_access": CGPreflightPostEventAccess(),
    "ax_trusted": AXIsProcessTrusted(), "session": session
]
do {
    let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
    guard data.count < 512 else { exit(65) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch { exit(66) }

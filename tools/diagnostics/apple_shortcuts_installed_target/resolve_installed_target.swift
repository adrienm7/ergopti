// resolve_installed_target.swift
// Read-only LaunchServices metadata. No application or AppleEvent is opened.
import CoreServices
import Foundation

let target = "com.apple.shortcuts.events"
func refuse(_ reason: String) -> Never {
    let packet: [String: Any] = ["version": 1, "status": "refused", "reason": reason]
    let data = try! JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(1)
}
guard CommandLine.arguments.count == 1 else { refuse("arguments") }
guard let retained = LSCopyApplicationURLsForBundleIdentifier(target as CFString, nil) else {
    refuse("not_resolved")
}
// SDK Copy ownership: keep the returned array alive through all URL validation.
let urls = retained.takeRetainedValue() as NSArray
guard urls.count == 1, let url = urls[0] as? URL,
      url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
    refuse("ambiguous_or_nonlocal")
}
let path = url.path
// Do not normalize away traversal or substitute a directory found by scanning.
guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
      !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
    refuse("path")
}
let packet: [String: Any] = ["version": 1, "status": "resolved",
                           "target": target, "urls": [path]]
guard let data = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]),
      data.count <= 65536 else { refuse("packet") }
FileHandle.standardOutput.write(data)

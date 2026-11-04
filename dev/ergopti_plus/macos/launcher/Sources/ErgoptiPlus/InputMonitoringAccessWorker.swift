// Sources/ErgoptiPlus/InputMonitoringAccessWorker.swift

// ==============================================================================
// MODULE: Input Monitoring Access Reader
// DESCRIPTION:
// Reads whether this app holds the Input Monitoring grant, without prompting.
// Hammerspoon has no query that cannot prompt, so the field run and the
// diagnostics read "unknown" (ledger L32); IOHIDCheckAccess only reads the
// TCC state, while IOHIDRequestAccess is the call that asks, and is never made.
// ==============================================================================

import Foundation
import IOKit.hid

/// The closed answers of the reader, printed on one line.
enum InputMonitoringAccess: String {
	case granted, denied, unknown
}

/// Maps the IOKit verdict onto the closed answers; anything new is unknown.
func inputMonitoringAccess(from access: IOHIDAccessType) -> InputMonitoringAccess {
	if access == kIOHIDAccessTypeGranted { return .granted }
	if access == kIOHIDAccessTypeDenied { return .denied }
	return .unknown
}

/// Headless role, dispatched before the interactive application boots.
enum InputMonitoringAccessWorker {
	static let flag = "--input-monitoring"

	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == flag
	}

	/// Prints granted, denied or unknown; exit 64 on any other argument list.
	static func run(arguments: [String], check: (IOHIDRequestType) -> IOHIDAccessType = IOHIDCheckAccess) -> Int32 {
		guard arguments.count == 3, arguments[2] == "status" else { return 64 }
		print(inputMonitoringAccess(from: check(kIOHIDRequestTypeListenEvent)).rawValue)
		return 0
	}
}

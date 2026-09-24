// Sources/ErgoptiPlus/EmbeddedChildActivity.swift

/**
 ==============================================================================
 MODULE: Embedded child activity
 DESCRIPTION:
 Holds one ProcessInfo activity while embedded Hammerspoon runs, so macOS does
 not App Nap the launcher that hosts its native logger worker.

 FEATURES & RATIONALE:
 1. The launcher is an accessory app with no visible window, which is exactly
    what App Nap throttles. Its logger worker then answers late, and the Lua
    transport counts that silence against its stall budget.
 2. Idempotent hold/release: every exit path (child exit, failed launch, app
    termination) may release without tracking whether another one already did.
 3. Idle system sleep stays allowed: the activity keeps the launcher's own
    timers and I/O responsive, never the Mac awake.
 ==============================================================================
 */

import Foundation

/// Why the activity exists, as shown by `pmset -g assertions`.
let kEmbeddedChildActivityReason = "ErgoptiPlus keeps its embedded runtime and native logger responsive"

/// Owns the single activity token held while the embedded child runs.
final class EmbeddedChildActivity {
	private let begin: () -> NSObjectProtocol
	private let end: (NSObjectProtocol) -> Void
	private var token: NSObjectProtocol?

	/// - Parameters:
	///   - begin: Starts the activity; ProcessInfo in production.
	///   - end: Ends the activity token returned by `begin`.
	init(
		begin: @escaping () -> NSObjectProtocol = {
			ProcessInfo.processInfo.beginActivity(
				options: .userInitiatedAllowingIdleSystemSleep,
				reason: kEmbeddedChildActivityReason
			)
		},
		end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
	) {
		self.begin = begin
		self.end = end
	}

	deinit { release() }

	/// Whether an activity token is currently held.
	var isHeld: Bool { token != nil }

	/// Starts the activity once; a second hold while held is a no-op.
	func hold() {
		guard token == nil else { return }
		token = begin()
	}

	/// Ends the held activity; releasing when nothing is held is a no-op.
	func release() {
		guard let held = token else { return }
		token = nil
		end(held)
	}
}

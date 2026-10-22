// Sources/ErgoptiPlus/LauncherInstanceOwnership.swift

/**
 ==============================================================================
 MODULE: Launcher instance ownership
 DESCRIPTION:
 Makes the GUI launcher the single owner of the embedded Hammerspoon runtime:
 one launcher per user holds an exclusive lock, and only that launcher may
 replace a leftover embedded runtime.

 FEATURES & RATIONALE:
 1. LSMultipleInstancesProhibited only stops a launch from another user
    session; `open -n`, a direct exec or an update relaunch racing the old
    process can still start a second launcher, which would start a second
    embedded runtime. An flock(2) on a per-user file is released by the
    kernel when its holder exits, however it exits, so a crash never leaves a
    stale lock behind.
 2. The descriptor is close-on-exec: a helper the launcher spawns must not
    keep the lock alive after the launcher is gone.
 3. Replacement is limited to the embedded runtime's own bundle identifier.
    A Hammerspoon the user installed (org.hammerspoon.Hammerspoon, or any
    other identity) is never selected, so it is never terminated.
 ==============================================================================
 */

import Darwin
import Foundation

/// Per-user lock file; its folder already holds the launcher's paths.toml.
/// - Parameter homeDirectory: Current user's Foundation home directory.
/// - Returns: Absolute lock path.
func launcherInstanceLockPath(homeDirectory: String = NSHomeDirectory()) -> String {
	return homeDirectory + "/Library/Application Support/ErgoptiPlus/launcher.lock"
}

/// Result of one attempt to become the sole launcher.
enum LauncherInstanceLockOutcome: Equatable {
	case acquired
	case heldByAnotherLauncher
	case failed(errorCode: Int32)
}

/// Exclusive per-user launcher lock, held for the whole process lifetime.
final class LauncherInstanceLock {
	let path: String
	private var descriptor: Int32 = -1

	init(path: String) {
		self.path = path
	}

	deinit { release() }

	/// Whether this object currently holds the lock.
	var isHeld: Bool { descriptor >= 0 }

	/// The held descriptor, for tests that verify close-on-exec.
	var heldDescriptor: Int32? { descriptor >= 0 ? descriptor : nil }

	/// Takes the lock without waiting. A second acquire on a held object is a
	/// programming error and is refused rather than opening a second descriptor.
	func acquire() -> LauncherInstanceLockOutcome {
		guard descriptor < 0 else { return .failed(errorCode: EALREADY) }
		let directory = (path as NSString).deletingLastPathComponent
		if Darwin.mkdir(directory, 0o700) != 0 && errno != EEXIST {
			return .failed(errorCode: errno)
		}
		let opened = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
		guard opened >= 0 else { return .failed(errorCode: errno) }
		if ergoptiFlock(opened, LOCK_EX | LOCK_NB) != 0 {
			let failure = errno
			Darwin.close(opened)
			return failure == EWOULDBLOCK ? .heldByAnotherLauncher : .failed(errorCode: failure)
		}
		descriptor = opened
		return .acquired
	}

	/// Releases the lock; releasing when nothing is held is a no-op.
	func release() {
		guard descriptor >= 0 else { return }
		_ = ergoptiFlock(descriptor, LOCK_UN)
		Darwin.close(descriptor)
		descriptor = -1
	}
}

/// One running application as seen by the stale-runtime scan.
struct RunningRuntimeCandidate: Equatable {
	let processIdentifier: pid_t
	let bundleIdentifier: String?
}

/// Selects the leftover embedded runtimes the sole launcher replaces.
/// - Parameters:
///   - running: Every application the scan observed.
///   - trackedChild: The runtime this launcher started, which is never stale.
///   - embeddedBundleId: The embedded runtime's own bundle identifier.
/// - Returns: Process identifiers to terminate, in scan order.
func staleEmbeddedRuntimes(
	_ running: [RunningRuntimeCandidate],
	trackedChild: pid_t?,
	embeddedBundleId: String = kEmbeddedHammerspoonBundleId
) -> [pid_t] {
	return running
		.filter { candidate in
			candidate.bundleIdentifier == embeddedBundleId
				&& candidate.processIdentifier > 0
				&& candidate.processIdentifier != trackedChild
		}
		.map(\.processIdentifier)
}

/// A launcher being replaced by an update relaunch may still hold the lock for
/// a moment; a genuine second launcher keeps it. 50 tries of 100 ms tell them apart.
let kLauncherLockRetryAttempts = 50
let kLauncherLockRetryIntervalSeconds = 0.1
/// Time a leftover embedded runtime gets to run its own teardown after a
/// normal terminate request before it is force-terminated.
let kStaleRuntimeTerminateGraceSeconds = 3.0
let kStaleRuntimePollIntervalSeconds = 0.1

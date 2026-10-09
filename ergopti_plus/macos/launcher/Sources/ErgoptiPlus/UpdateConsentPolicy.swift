// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdateConsentPolicy.swift
//
// Refuses to start Sparkle when it could download an update before the user
// chose to install it. Scheduled checks may only fetch the appcast: Sparkle's
// automatic update driver downloads in the background and installs on quit
// whenever automaticallyDownloadsUpdates is true, which is
// SUAllowsAutomaticUpdates (read from Info.plist only) AND a stored
// SUAutomaticallyUpdate default that Sparkle's own update alert lets the user
// tick once. The bundle therefore declares SUAllowsAutomaticUpdates false, and
// this policy proves it on the live updater before starting it.

import Sparkle

/// Live Sparkle settings that could bypass Lua's cadence or install consent.
@MainActor
protocol AutomaticUpdateSettings: AnyObject {
	var allowsAutomaticUpdates: Bool { get }
	var automaticallyDownloadsUpdates: Bool { get }
	var automaticallyChecksForUpdates: Bool { get }
}

extension SPUUpdater: AutomaticUpdateSettings {}

enum UpdateConsentPolicy {
	/// Explains why the updater must not start, or returns nil when every
	/// download will wait for the user's explicit install choice.
	@MainActor
	static func refusal(for settings: AutomaticUpdateSettings) -> String? {
		if settings.automaticallyChecksForUpdates {
			return "automatic checks are enabled: Sparkle would bypass the driver's cadence and pause"
		}
		if settings.allowsAutomaticUpdates {
			return "SUAllowsAutomaticUpdates is true: Sparkle may download updates without asking"
		}
		if settings.automaticallyDownloadsUpdates {
			return "automatic update downloads are enabled: Sparkle may download updates without asking"
		}
		return nil
	}
}

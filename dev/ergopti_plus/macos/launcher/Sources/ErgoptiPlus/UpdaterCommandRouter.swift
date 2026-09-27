// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdaterCommandRouter.swift
//
// Routes the embedded Hammerspoon menu command to the one retained Sparkle
// updater. Strict URL matching keeps the external scheme from becoming a
// general command surface.

import Foundation
import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
	func checkForUpdates()
}

extension SPUUpdater: UpdateChecking {}

@MainActor
final class UpdaterCommandRouter {
	private weak var updateChecker: UpdateChecking?
	private var hasPendingCheck = false

	/// Creates inert state before AppKit enters its main-actor delegate callbacks.
	nonisolated init() {}

	/// Binds the single launcher-owned controller and drains one coalesced request.
	func bind(_ updateChecker: UpdateChecking) {
		self.updateChecker = updateChecker
		guard hasPendingCheck else { return }
		hasPendingCheck = false
		updateChecker.checkForUpdates()
	}

	/// Accepts only `ergoptiplus://updater/check`, with no authority modifiers.
	@discardableResult
	func route(_ url: URL) -> Bool {
		guard url.scheme == "ergoptiplus",
			url.host == "updater",
			url.path == "/check",
			url.user == nil,
			url.password == nil,
			url.port == nil,
			url.query == nil,
			url.fragment == nil else {
			return false
		}

		if let updateChecker {
			updateChecker.checkForUpdates()
		} else {
			hasPendingCheck = true
		}
		return true
	}
}

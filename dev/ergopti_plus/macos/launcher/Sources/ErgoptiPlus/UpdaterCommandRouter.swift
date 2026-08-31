// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdaterCommandRouter.swift
//
// Routes the embedded Hammerspoon menu command to the one retained Sparkle
// controller. Strict URL matching keeps the external scheme from becoming a
// general command surface.

import Foundation
import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
	func checkForUpdates(_ sender: Any?)
}

extension SPUStandardUpdaterController: UpdateChecking {}

@MainActor
final class UpdaterCommandRouter {
	private weak var updateChecker: UpdateChecking?
	private var hasPendingCheck = false

	/// Binds the single launcher-owned controller and drains one coalesced request.
	func bind(_ updateChecker: UpdateChecking) {
		self.updateChecker = updateChecker
		guard hasPendingCheck else { return }
		hasPendingCheck = false
		updateChecker.checkForUpdates(nil)
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
			updateChecker.checkForUpdates(nil)
		} else {
			hasPendingCheck = true
		}
		return true
	}
}

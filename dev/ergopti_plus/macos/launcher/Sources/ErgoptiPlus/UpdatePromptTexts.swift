// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdatePromptTexts.swift
//
// Every text of the in-app update flow, resolved from the shared 21-locale
// catalog in the user's chosen language. Sparkle's own interface ships its
// strings inside Sparkle.framework: English unless the host bundle declares
// localizations, and without Hindi or Norwegian (no) at all, so it can never
// follow the driver's language choice.

import Foundation
import Sparkle

/// One prompt: what the user reads, and one title per button.
struct UpdatePrompt: Equatable {
	let title: String
	let message: String
	let buttons: [String]
}

/// A prompt whose buttons each stand for one Sparkle choice, in order.
struct UpdateOffer {
	let prompt: UpdatePrompt
	let choices: [SPUUserUpdateChoice]

	/// Sparkle's answer for a pressed button index; nil (window closed) or an
	/// unknown index reminds the user later.
	func choice(at index: Int?) -> SPUUserUpdateChoice {
		guard let index, choices.indices.contains(index) else { return .dismiss }
		return choices[index]
	}
}

/// A progress window's texts.
struct UpdateProgressText: Equatable {
	let title: String
	let message: String
	let cancelTitle: String?
}

struct UpdatePromptTexts {
	/// Every catalog key the update flow shows; each locale must define them all.
	static let requiredKeys = [
		"updater.title_update",
		"updater.title_update_available",
		"updater.update_found_body",
		"updater.update_dialog_install",
		"updater.update_dialog_later",
		"updater.skip_version",
		"updater.ready_to_install_body",
		"updater.install_and_restart",
		"updater.install_on_quit",
		"updater.up_to_date",
		"updater.no_connection",
		"updater.install_error",
		"updater.move_to_applications",
		"updater.close",
		"menu.about.update_checking",
		"menu.about.update_downloading",
		"menu.about.update_installing",
		"button.cancel",
	]

	private let lookup: (String, [String]) -> String?

	/// Refuses a catalog missing any required key, so no prompt can ever fall
	/// back to Sparkle's English or show a raw key.
	init?(lookup: @escaping (String, [String]) -> String?) {
		for key in Self.requiredKeys where lookup(key, []) == nil {
			return nil
		}
		self.lookup = lookup
	}

	init?(localization: LauncherLocalization) {
		self.init(lookup: { key, arguments in localization.text(key, arguments) })
	}

	private func text(_ key: String, _ arguments: [String] = []) -> String {
		guard let value = lookup(key, arguments) else {
			// Every key used below is in requiredKeys, which the initializer proved.
			preconditionFailure("update catalog key \(key) is missing after validation")
		}
		return value
	}

	/// The offer of a found update, by Sparkle's stage of that update.
	func updateFound(version: String, stage: SPUUserUpdateStage, informationOnly: Bool) -> UpdateOffer {
		let title = text("updater.title_update_available")
		switch stage {
		case .installing:
			// Already staged: "later" still installs it when ErgoptiPlus quits.
			return UpdateOffer(
				prompt: UpdatePrompt(
					title: title,
					message: text("updater.ready_to_install_body"),
					buttons: [text("updater.install_and_restart"), text("updater.install_on_quit")]),
				choices: [.install, .dismiss])
		case .notDownloaded, .downloaded:
			break
		@unknown default:
			break
		}
		let message = text("updater.update_found_body", [version])
		if informationOnly {
			return UpdateOffer(
				prompt: UpdatePrompt(
					title: title,
					message: message,
					buttons: [text("updater.update_dialog_later"), text("updater.skip_version")]),
				choices: [.dismiss, .skip])
		}
		return UpdateOffer(
			prompt: UpdatePrompt(
				title: title,
				message: message,
				buttons: [
					text("updater.update_dialog_install"),
					text("updater.update_dialog_later"),
					text("updater.skip_version"),
				]),
			choices: [.install, .dismiss, .skip])
	}

	/// The downloaded update waits for a restart.
	func readyToInstall() -> UpdateOffer {
		return UpdateOffer(
			prompt: UpdatePrompt(
				title: text("updater.title_update"),
				message: text("updater.ready_to_install_body"),
				buttons: [text("updater.install_and_restart"), text("updater.install_on_quit")]),
			choices: [.install, .dismiss])
	}

	/// A user-initiated check found nothing newer.
	func upToDate(currentVersion: String) -> UpdatePrompt {
		return UpdatePrompt(
			title: text("updater.title_update"),
			message: text("updater.up_to_date", [currentVersion]),
			buttons: [text("updater.close")])
	}

	/// A failed check, download or installation. Sparkle's own description is
	/// never shown: it is English, and only the log needs its detail.
	func failure(domain: String, code: Int) -> UpdatePrompt {
		return UpdatePrompt(
			title: text("updater.title_update"),
			message: text(Self.failureKey(domain: domain, code: code)),
			buttons: [text("updater.close")])
	}

	static func failureKey(domain: String, code: Int) -> String {
		if domain == NSURLErrorDomain {
			return "updater.no_connection"
		}
		guard domain == SUSparkleErrorDomain else {
			return "updater.install_error"
		}
		switch code {
		case Int(SUError.appcastParseError.rawValue),
			Int(SUError.appcastError.rawValue),
			Int(SUError.resumeAppcastError.rawValue),
			Int(SUError.downloadError.rawValue):
			return "updater.no_connection"
		case Int(SUError.runningFromDiskImageError.rawValue),
			Int(SUError.runningTranslocated.rawValue):
			return "updater.move_to_applications"
		default:
			return "updater.install_error"
		}
	}

	func checking() -> UpdateProgressText {
		return UpdateProgressText(
			title: text("updater.title_update"),
			message: text("menu.about.update_checking"),
			cancelTitle: text("button.cancel"))
	}

	func downloading() -> UpdateProgressText {
		return UpdateProgressText(
			title: text("updater.title_update"),
			message: text("menu.about.update_downloading"),
			cancelTitle: text("button.cancel"))
	}

	func installing() -> UpdateProgressText {
		return UpdateProgressText(
			title: text("updater.title_update"),
			message: text("menu.about.update_installing"),
			cancelTitle: nil)
	}
}

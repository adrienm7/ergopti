// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/CatalogUpdateUserDriver.swift
//
// Sparkle user driver that speaks the shared locale catalog. It replaces
// Sparkle's standard interface, whose English windows cannot follow the
// driver's language, and whose modal alerts stall the launcher's main queue.
// A found update is only offered: Sparkle downloads it after the user picks
// Install, and every other answer (Later, Skip, closing the window) leaves it
// on the server. Each reply is answered once; dismissUpdateInstallation drops
// the pending ones without answering, as Sparkle requires.

import AppKit
import Sparkle

/// Presents the update flow's windows. Every call happens on the main actor.
@MainActor
protocol UpdatePromptPresenting: AnyObject {
	/// Shows a prompt; onChoice receives the pressed button's index, or nil
	/// when the user closed the window. Replaces any prompt or progress window.
	func present(_ prompt: UpdatePrompt, activate: Bool, onChoice: @escaping (Int?) -> Void)
	/// Shows or updates the progress window; a nil fraction is indeterminate.
	func showProgress(_ text: UpdateProgressText, fraction: Double?, onCancel: (() -> Void)?)
	/// Brings the current window to the front.
	func bringToFront()
	/// Closes every window without reporting a choice.
	func closeAll()
}

final class CatalogUpdateUserDriver: NSObject, SPUUserDriver {
	private let textsProvider: () -> UpdatePromptTexts?
	private let presenter: UpdatePromptPresenting
	private let currentVersion: () -> String
	private let log: (String) -> Void
	private var pendingUpdateReply: ((SPUUserUpdateChoice) -> Void)?
	private var pendingReadyReply: ((SPUUserUpdateChoice) -> Void)?
	private var pendingAcknowledgement: (() -> Void)?
	private var cancellation: (() -> Void)?
	private var expectedBytes: UInt64 = 0
	private var receivedBytes: UInt64 = 0

	/// - Parameters:
	///   - textsProvider: Resolves the catalog for each window, so a language
	///     change applies to the next prompt; nil when the catalog is unreadable.
	///   - presenter: Owns the windows.
	///   - currentVersion: Version shown by the up-to-date notice.
	///   - log: Launcher log sink.
	init(
		textsProvider: @escaping () -> UpdatePromptTexts?,
		presenter: UpdatePromptPresenting,
		currentVersion: @escaping () -> String,
		log: @escaping (String) -> Void
	) {
		self.textsProvider = textsProvider
		self.presenter = presenter
		self.currentVersion = currentVersion
		self.log = log
		super.init()
	}

	private func resolveTexts() -> UpdatePromptTexts? {
		guard let texts = textsProvider() else {
			log("ERROR: update prompt skipped: the locale catalog is unreadable or incomplete")
			return nil
		}
		return texts
	}

	private func answerUpdate(_ choice: SPUUserUpdateChoice) {
		let reply = pendingUpdateReply
		pendingUpdateReply = nil
		reply?(choice)
	}

	private func answerReady(_ choice: SPUUserUpdateChoice) {
		let reply = pendingReadyReply
		pendingReadyReply = nil
		reply?(choice)
	}

	private func acknowledge() {
		let acknowledgement = pendingAcknowledgement
		pendingAcknowledgement = nil
		acknowledgement?()
	}

	private func cancelOperation() {
		let cancel = cancellation
		cancellation = nil
		cancel?()
	}

	// MARK: - SPUUserDriver

	func show(_ request: SPUUpdatePermissionRequest,
			  reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
		// Unreachable while Info.plist defines SUEnableAutomaticChecks. Never
		// answer with automatic downloads: checks only fetch the appcast.
		reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
	}

	func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
		self.cancellation = cancellation
		guard let texts = resolveTexts() else { return }
		presenter.showProgress(texts.checking(), fraction: nil) { [weak self] in
			self?.cancelOperation()
		}
	}

	func showUpdateFound(with appcastItem: SUAppcastItem,
						 state: SPUUserUpdateState,
						 reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
		presentUpdateFound(
			version: appcastItem.displayVersionString,
			stage: state.stage,
			userInitiated: state.userInitiated,
			informationOnly: appcastItem.isInformationOnlyUpdate,
			reply: reply)
	}

	/// Value-typed core of showUpdateFound (SUAppcastItem and
	/// SPUUserUpdateState have no public initializer).
	func presentUpdateFound(
		version: String,
		stage: SPUUserUpdateStage,
		userInitiated: Bool,
		informationOnly: Bool,
		reply: @escaping (SPUUserUpdateChoice) -> Void
	) {
		cancellation = nil
		guard let texts = resolveTexts() else {
			reply(.dismiss)
			return
		}
		let offer = texts.updateFound(version: version, stage: stage, informationOnly: informationOnly)
		pendingUpdateReply = reply
		// A scheduled check must not steal focus; a check the user asked for may.
		presenter.present(offer.prompt, activate: userInitiated) { [weak self] index in
			self?.answerUpdate(offer.choice(at: index))
		}
	}

	func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
		// The appcast carries no release notes link: nothing to render.
	}

	func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
		let nsError = error as NSError
		log("update release notes unavailable: \(nsError.domain) \(nsError.code)")
	}

	func showUpdateNotFoundWithError(_ error: any Error,
									 acknowledgement: @escaping () -> Void) {
		cancellation = nil
		guard let texts = resolveTexts() else {
			acknowledgement()
			return
		}
		// Acknowledging ends Sparkle's session, which dismisses the installation
		// UI: answer only once the user closed the notice.
		pendingAcknowledgement = acknowledgement
		presenter.present(texts.upToDate(currentVersion: currentVersion()), activate: true) { [weak self] _ in
			self?.acknowledge()
		}
	}

	func showUpdaterError(_ error: any Error,
						  acknowledgement: @escaping () -> Void) {
		cancellation = nil
		let nsError = error as NSError
		log("ERROR: update failed: \(nsError.domain) \(nsError.code)")
		guard let texts = resolveTexts() else {
			acknowledgement()
			return
		}
		pendingAcknowledgement = acknowledgement
		presenter.present(texts.failure(domain: nsError.domain, code: nsError.code), activate: true) { [weak self] _ in
			self?.acknowledge()
		}
	}

	func showDownloadInitiated(cancellation: @escaping () -> Void) {
		self.cancellation = cancellation
		expectedBytes = 0
		receivedBytes = 0
		showDownloadProgress()
	}

	func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
		expectedBytes = expectedContentLength
		receivedBytes = 0
		showDownloadProgress()
	}

	func showDownloadDidReceiveData(ofLength length: UInt64) {
		receivedBytes += length
		showDownloadProgress()
	}

	private func showDownloadProgress() {
		guard let texts = resolveTexts() else { return }
		let fraction = expectedBytes > 0 ? min(1.0, Double(receivedBytes) / Double(expectedBytes)) : nil
		presenter.showProgress(texts.downloading(), fraction: fraction) { [weak self] in
			self?.cancelOperation()
		}
	}

	func showDownloadDidStartExtractingUpdate() {
		// Cancelling is only valid until extraction starts: replace the download
		// window, whose Cancel button and close box would no longer cancel.
		cancellation = nil
		presenter.closeAll()
		showInstallProgress(fraction: nil)
	}

	func showExtractionReceivedProgress(_ progress: Double) {
		showInstallProgress(fraction: progress)
	}

	private func showInstallProgress(fraction: Double?) {
		guard let texts = resolveTexts() else { return }
		presenter.showProgress(texts.installing(), fraction: fraction, onCancel: nil)
	}

	func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
		guard let texts = resolveTexts() else {
			// Dismiss keeps the staged update for the next quit.
			reply(.dismiss)
			return
		}
		let offer = texts.readyToInstall()
		pendingReadyReply = reply
		presenter.present(offer.prompt, activate: true) { [weak self] index in
			self?.answerReady(offer.choice(at: index))
		}
	}

	func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
							  retryTerminatingApplication: @escaping () -> Void) {
		showInstallProgress(fraction: nil)
	}

	func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
										  acknowledgement: @escaping () -> Void) {
		acknowledgement()
	}

	func showUpdateInFocus() {
		presenter.bringToFront()
	}

	func dismissUpdateInstallation() {
		pendingUpdateReply = nil
		pendingReadyReply = nil
		pendingAcknowledgement = nil
		cancellation = nil
		presenter.closeAll()
	}
}

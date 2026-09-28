// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdaterCommandRouter.swift
//
// Routes the embedded Hammerspoon menu commands to the one retained Sparkle
// updater and to the update-channel feed. Strict URL matching keeps the
// external scheme from becoming a general command surface: the only accepted
// paths are /check, /check/<channel> and /channel/<channel>, for a channel of
// the shared registry (kUpdateChannelFeeds, generated from channels.json).

import Foundation
import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
	func checkForUpdates()
}

/// Receives the channel the menu subscribed to, before any check it precedes.
protocol UpdateChannelSelecting: AnyObject {
	func selectChannel(_ channel: String)
}

extension SPUUpdater: UpdateChecking {}

@MainActor
final class UpdaterCommandRouter {
	private weak var updateChecker: UpdateChecking?
	private weak var channelSelector: UpdateChannelSelecting?
	private var hasPendingCheck = false
	private var pendingChannel: String?
	private let knownChannels: Set<String>

	/// Creates inert state before AppKit enters its main-actor delegate callbacks.
	/// - Parameter knownChannels: Channel ids a command may name.
	nonisolated init(knownChannels: Set<String> = Set(kUpdateChannelFeeds.keys)) {
		self.knownChannels = knownChannels
	}

	/// Binds the launcher-owned controller and feed, then drains one coalesced
	/// request: the channel first, so a check it preceded reads that channel.
	func bind(_ updateChecker: UpdateChecking, channelSelector: UpdateChannelSelecting) {
		self.updateChecker = updateChecker
		self.channelSelector = channelSelector
		if let channel = pendingChannel {
			pendingChannel = nil
			channelSelector.selectChannel(channel)
		}
		guard hasPendingCheck else { return }
		hasPendingCheck = false
		updateChecker.checkForUpdates()
	}

	/// Accepts only `ergoptiplus://updater/check`, `ergoptiplus://updater/check/<channel>`
	/// and `ergoptiplus://updater/channel/<channel>`, with no authority modifiers.
	@discardableResult
	func route(_ url: URL) -> Bool {
		guard url.scheme == "ergoptiplus",
			url.host == "updater",
			url.user == nil,
			url.password == nil,
			url.port == nil,
			url.query == nil,
			url.fragment == nil else {
			return false
		}
		// URL.path can remove a directory-style trailing slash. Commands require
		// the exact encoded path, including empty components and escaped bytes.
		guard let commandPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
			return false
		}
		let components = commandPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard components.first == "" else { return false }
		let command = Array(components.dropFirst())
		if command == ["check"] {
			requestCheck()
			return true
		}
		guard command.count == 2, knownChannels.contains(command[1]) else { return false }
		switch command[0] {
		case "check":
			select(command[1])
			requestCheck()
			return true
		case "channel":
			select(command[1])
			return true
		default:
			return false
		}
	}

	private func select(_ channel: String) {
		if let channelSelector {
			channelSelector.selectChannel(channel)
		} else {
			pendingChannel = channel
		}
	}

	private func requestCheck() {
		if let updateChecker {
			updateChecker.checkForUpdates()
		} else {
			hasPendingCheck = true
		}
	}
}

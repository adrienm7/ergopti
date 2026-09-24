// static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/UpdateChannelFeed.swift

/**
 ==============================================================================
 MODULE: Update channel feed
 DESCRIPTION:
 Serves Sparkle the appcast of the update channel the user subscribed to in the
 menu, instead of the one feed stamped into Info.plist at build time.

 FEATURES & RATIONALE:
 1. One source: the channel ids and appcast names come from the shared registry
    (kUpdateChannelFeeds, generated from _shared/modules/updater/channels.json).
 2. Same feed directory: a channel's appcast sits beside the bundle's SUFeedURL
    on the sparkle-appcasts branch, so only the file name changes.
 3. Survives relaunch: the selection is kept in the launcher's defaults, so
    Sparkle's scheduled checks follow the channel the menu shows.
 4. Nil keeps the bundle feed: an unknown or absent selection falls back to
    Info.plist exactly as Sparkle would without a delegate.
 ==============================================================================
 */

import Foundation
import Sparkle

final class UpdateChannelFeed: NSObject, SPUUpdaterDelegate, UpdateChannelSelecting {
	/// Launcher defaults key holding the subscribed channel id.
	static let defaultsKey = "ErgoptiUpdateChannel"

	private let defaults: UserDefaults
	private let bundleFeedURL: String?
	private let feeds: [String: String]

	/// - Parameters:
	///   - defaults: Store of the subscribed channel.
	///   - bundleFeedURL: The SUFeedURL stamped into Info.plist.
	///   - feeds: Appcast file name of every registry channel.
	init(
		defaults: UserDefaults = .standard,
		bundleFeedURL: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
		feeds: [String: String] = kUpdateChannelFeeds
	) {
		self.defaults = defaults
		self.bundleFeedURL = bundleFeedURL
		self.feeds = feeds
		super.init()
	}

	/// Records the subscribed channel; an id outside the registry is ignored.
	func selectChannel(_ channel: String) {
		guard feeds[channel] != nil else { return }
		defaults.set(channel, forKey: Self.defaultsKey)
	}

	/// Sparkle asks for the feed before every check, scheduled or manual.
	func feedURLString(for updater: SPUUpdater) -> String? {
		return selectedFeedURLString()
	}

	/// The subscribed channel's appcast beside the bundle feed, or nil for the
	/// bundle feed itself.
	func selectedFeedURLString() -> String? {
		guard let channel = defaults.string(forKey: Self.defaultsKey),
			let feed = feeds[channel],
			let base = bundleFeedURL,
			let url = URL(string: base) else {
			return nil
		}
		return url.deletingLastPathComponent().appendingPathComponent(feed).absoluteString
	}
}

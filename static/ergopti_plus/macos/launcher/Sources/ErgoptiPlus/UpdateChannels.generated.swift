// Sources/ErgoptiPlus/UpdateChannels.generated.swift
// AUTO-GENERATED from _shared/modules/updater/channels.json.
// DO NOT EDIT BY HAND -- run `npm run codegen:update-channels` to refresh.

// ==============================================================================
// MODULE: Update Channel Feeds
// DESCRIPTION:
// The Sparkle appcast of every channel of the shared update-channel registry.
// The launcher accepts a channel command only for these ids and serves Sparkle
// the subscribed channel's appcast, so a new channel is a data edit.
// ==============================================================================

let kUpdateChannelFeeds: [String: String] = [
	"main": "appcast-main.xml",
	"dev": "appcast-dev.xml",
]

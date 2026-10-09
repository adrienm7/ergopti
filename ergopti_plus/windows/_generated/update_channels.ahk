; _generated/update_channels.ahk
; AUTO-GENERATED from _shared/modules/updater/channels.json.
; DO NOT EDIT BY HAND — run `npm run codegen:update-channels` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Update Channel Registry Data (Windows)
; DESCRIPTION:
; The shared update-channel registry, in channel order (the stability rank),
; as the data modules/updater/channels.ahk interprets. A compiled build has no
; JSON reader at include time, and a hand-maintained copy would drift.
; ==============================================================================

; A function rather than a global initialiser so include ORDER cannot matter:
; the matcher reads it on first use, after every #Include has been processed.
UpdateChannelRegistryData() {
	return Map(
		"schema_version", 1,
		"unreleased_build_channel", "dev",
		"channels", [
			Map(
				"id", "main",
				"label_key", "updater.channel.main",
				"menu_label_key", "updater.channel.main_menu",
				"aliases", ["stable"],
				"github_prerelease", false,
				"tag_core", "semver",
				"tag_prerelease", 0,
				"sparkle_feed", "appcast-main.xml"),
			Map(
				"id", "dev",
				"label_key", "updater.channel.dev",
				"menu_label_key", "updater.channel.dev_menu",
				"aliases", [],
				"github_prerelease", true,
				"tag_core", "0.0.0",
				"tag_prerelease", Map("label", "dev", "counter", true),
				"sparkle_feed", "appcast-dev.xml")
		])
}

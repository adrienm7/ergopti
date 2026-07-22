--- vendor/karabiner-elements/manifest.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Vendor Manifest
--- DESCRIPTION:
--- Pins the exact Karabiner-Elements version shipped with Ergopti+. Read by
--- modules/karabiner/onboarding.lua to download, verify, and install the
--- correct DMG on first launch when KE is absent from the user's system.
---
--- FEATURES & RATIONALE:
--- 1. Reproducible installs: every Ergopti+ user runs the exact same KE build,
---    so bug reports are reproducible and version drift cannot mask issues.
--- 2. Integrity verification: the SHA-256 below is checked at runtime against
---    the downloaded DMG before the installer is launched, preventing a
---    corrupted or tampered binary from being silently installed.
--- 3. Download-on-demand instead of repo vendoring: the DMG is fetched from
---    the official pqrs-org GitHub release on first launch and cached under
---    ~/Library/Caches/Ergopti/karabiner-elements/. The repo stays light
---    forever, version bumps are 4-field text edits, and the cache makes
---    subsequent reinstalls offline-capable.
--- ==============================================================================
--- HOW TO UPDATE THE PINNED KE VERSION
---   1. Find the new release on https://github.com/pqrs-org/Karabiner-Elements/releases
---   2. Download the .dmg locally and compute its hash:
---        shasum -a 256 ~/Downloads/Karabiner-Elements-<VERSION>.dmg
---   3. Update the four fields below (version, file_name, sha256, source_url).
---   4. Commit. The DMG itself is NOT committed — users download it on demand.
--- ==============================================================================

return {
	-- Pinned KE version. Bump in lockstep with file_name, sha256 and source_url.
	version    = "16.0.0",

	-- Cached file name under ~/Library/Caches/Ergopti/karabiner-elements/.
	-- Convention: keep the upstream release's exact file name.
	file_name  = "Karabiner-Elements-16.0.0.dmg",

	-- SHA-256 of the DMG, verified after download before the installer is run.
	-- Lowercase hex, no spaces.
	sha256     = "b960f731890a74231c229e5453c4ee7109efb328c4fb63aed8974e347fd1f9c0",

	-- Stable GitHub release download URL. Pinning the version in the URL
	-- guarantees we always fetch the exact build whose hash is recorded above.
	source_url = "https://github.com/pqrs-org/Karabiner-Elements/releases/download/v16.0.0/Karabiner-Elements-16.0.0.dmg",
}

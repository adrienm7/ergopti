--- modules/updater/install_origin.lua

--- ==============================================================================
--- MODULE: Installation Origin Update Policy (Linux)
--- DESCRIPTION:
--- The one answer to « may this installation replace itself, and if not, what
--- does the user read? » for each installation kind
--- modules/updater/installer.resolve() returns. The About menu, the update
--- check window and the Versions window all show this reason.
---
--- FEATURES & RATIONALE:
--- 1. Only the self-update is refused. A system package, an AppImage and a
---    Flatpak each restart through their own launcher (installer.resolve names
---    it), so a Reload never asks this module.
--- 2. Each origin names its own updater: an AppImage greyed as « installé par
---    un paquet système » sent the user to a package manager that never
---    installed it (field report of 2026-11-25).
--- 3. An AppImage is still told of a new release. A package or a Flatpak has a
---    manager that announces it; an AppImage has none the daemon can count on
---    (AppImageUpdate is optional), so a dev-channel AppImage never learned of
---    a new version (field report of 2026-11-25). Its releases are announced
---    with the page to download the new AppImage from; installing stays
---    refused, so nothing replaces a file the user owns.
--- ==============================================================================

local M = {}

-- The locale key that names why each installation kind cannot replace itself.
-- A kind absent here (standalone, unmanaged) is not refused for its origin.
local UPDATE_BLOCKED_KEYS = {
	package  = "changelog_window.install_blocked_package",
	appimage = "changelog_window.install_blocked_appimage",
	flatpak  = "changelog_window.install_blocked_flatpak",
}

-- The refused kinds whose new releases are still announced (feature 3).
local ANNOUNCED_KINDS = {
	appimage = true,
}

--- Why an installation of this kind never replaces itself, as a locale key.
--- @param kind string|nil An installation kind installer.resolve() returned.
--- @return string|nil key nil when the kind's origin does not forbid it.
function M.update_blocked_key(kind)
	return UPDATE_BLOCKED_KEYS[kind]
end

--- Whether the background checks run for this kind: always for a kind that
--- may replace itself, and for an AppImage, which only announces.
--- @param kind string|nil An installation kind installer.resolve() returned.
--- @return boolean
function M.checks_for_releases(kind)
	return UPDATE_BLOCKED_KEYS[kind] == nil or ANNOUNCED_KINDS[kind] == true
end

--- The notification body announcing a release a background check found. An
--- installation that cannot replace itself adds its own way to update and the
--- release page to download it from.
--- @param release table { tag, check_only? } The updater's cached release.
--- @param kind string|nil The running installation's kind.
--- @param get function Locale lookup, key -> string.
--- @param releases_page string The repository's releases page URL.
--- @return string body
function M.release_notice(release, kind, get, releases_page)
	local body = require("updater.engine.check_notice").release_body(release, get)
	local key = UPDATE_BLOCKED_KEYS[kind]
	if key == nil then return body end
	if type(releases_page) ~= "string" or releases_page == "" then
		error("an announcement for a refused installation needs the releases page", 2)
	end
	return body .. " " .. get(key) .. " " .. releases_page .. "/tag/" .. release.tag
end

return M

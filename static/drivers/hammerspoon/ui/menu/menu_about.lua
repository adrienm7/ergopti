--- ui/menu/menu_about.lua

--- ==============================================================================
--- MODULE: Menu About / Update
--- DESCRIPTION:
--- Builds the "About / Update" sub-menu for the macOS menubar.
--- Exposes the current driver version, update-channel selector (main vs dev),
--- an on-demand update check against the GitHub Releases API, and a link to
--- the latest release changelog.
---
--- FEATURES & RATIONALE:
--- 1. No background polling: all network requests are user-initiated so the
---    driver never makes unexpected outbound calls at startup or on a timer.
--- 2. Channel-aware: the user can switch between "main" (stable releases) and
---    "dev" (pre-releases) and the choice is persisted in config.toml.
--- 3. Synchronous HTTP via hs.http: uses a callback-based request so the
---    macOS event loop stays unblocked while waiting for GitHub.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "menu_about"

M.DEFAULT_STATE = {
	update_channel = "main",
}




-- =====================================
-- =====================================
-- ======= 1/ Constants & helpers =======
-- =====================================
-- =====================================

local GH_OWNER = "adrienm7"
local GH_REPO  = "ergopti"

--- Returns the current app version string.
--- In the bundled Ergopti.app this is CFBundleShortVersionString from Info.plist.
--- When running from a bare Hammerspoon install it falls back to "dev".
--- @return string
local function current_version()
	local info = hs.processInfo
	if info and info.version and info.version ~= "" then
		return info.version
	end
	return "dev"
end

--- Builds the GitHub Releases API URL for the active channel.
--- @param channel string "main" or "dev"
--- @return string
local function api_url(channel)
	local base = string.format("https://api.github.com/repos/%s/%s/releases", GH_OWNER, GH_REPO)
	if channel == "dev" then
		return base .. "?per_page=1"
	end
	return base .. "/latest"
end

local function releases_page_url()
	return string.format("https://github.com/%s/%s/releases", GH_OWNER, GH_REPO)
end

--- Parses the tag_name from a GitHub release JSON string.
--- Handles both object (latest endpoint) and array (list endpoint) responses.
--- @param body string Raw JSON
--- @return string tag or ""
local function parse_tag(body)
	if not body or body == "" then return "" end
	local tag = body:match('"tag_name"%s*:%s*"([^"]+)"')
	return tag or ""
end

--- Parses the release notes body from a GitHub release JSON string.
--- @param body string Raw JSON
--- @return string notes or ""
local function parse_notes(body)
	if not body or body == "" then return "" end
	local raw = body:match('"body"%s*:%s*"(.-[^\\])"')
	if not raw then return "" end
	raw = raw:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
	return raw
end




-- ================================
-- ================================
-- ======= 2/ Network actions =======
-- ================================
-- ================================

--- Checks GitHub for a newer version and shows an alert with the result.
--- @param channel string "main" or "dev"
local function check_for_update(channel)
	local current = current_version()
	if current == "dev" then
		hs.dialog.alert(nil, "Running in dev mode — update checking is disabled.", "OK", "Informational")
		return
	end
	local url = api_url(channel)
	hs.http.asyncGet(url, { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body then
			hs.dialog.alert(nil, "Could not reach GitHub.\nCheck your internet connection and try again.", "OK", "Warning")
			return
		end
		local latest = parse_tag(body)
		if latest == "" then
			hs.dialog.alert(nil, "Could not parse the latest release tag from GitHub.", "OK", "Warning")
			return
		end
		if latest == current then
			hs.dialog.alert(nil, "ErgoptiPlus is up to date.\n\nCurrent version: " .. current, "OK", "Informational")
			return
		end
		local btn = hs.dialog.alert(nil,
			"A new version is available!\n\nCurrent: " .. current .. "\nLatest:  " .. latest
			.. "\n\nOpen the releases page to download?",
			"Open releases page",
			"Dismiss",
			"Informational")
		if btn == "Open releases page" then
			hs.urlevent.openURL(releases_page_url())
		end
	end)
end

--- Fetches and shows the release notes for the latest release on the active channel.
--- @param channel string "main" or "dev"
local function show_changelog(channel)
	local url = api_url(channel)
	hs.http.asyncGet(url, { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body then
			hs.dialog.alert(nil, "Could not reach GitHub.\nCheck your internet connection and try again.", "OK", "Warning")
			return
		end
		local tag   = parse_tag(body)
		local notes = parse_notes(body)
		if tag == "" then
			hs.dialog.alert(nil, "Could not retrieve release information from GitHub.", "OK", "Warning")
			return
		end
		if notes == "" then notes = "(No release notes available for this version.)" end
		if #notes > 2000 then notes = notes:sub(1, 2000) .. "\n…(truncated)" end
		local btn = hs.dialog.alert(nil,
			"Release notes for " .. tag .. ":\n\n" .. notes .. "\n\nOpen on GitHub?",
			"Open on GitHub",
			"Dismiss",
			"Informational")
		if btn == "Open on GitHub" then
			hs.urlevent.openURL(releases_page_url())
		end
	end)
end




-- ================================
-- ================================
-- ======= 3/ Menu builder =========
-- ================================
-- ================================

--- Builds the About / Update sub-menu item.
--- @param ctx table Menu context (must contain ctx.state.update_channel and ctx.save_prefs).
--- @return table Menu item table for insertion into the parent menu.
function M.build(ctx)
	local state   = ctx and ctx.state or {}
	local channel = (type(state.update_channel) == "string" and state.update_channel ~= "")
		and state.update_channel or "main"
	local ver     = current_version()
	local ver_label = "ErgoptiPlus " .. ver

	local function set_channel(c)
		state.update_channel = c
		if type(ctx.save_prefs) == "function" then ctx.save_prefs() end
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	return {
		title = ver_label,
		menu = {
			{ title = ver_label,                disabled = true },
			{ title = "-" },
			{
				title   = "Stable (main)",
				checked = (channel == "main") or nil,
				fn      = function() set_channel("main") end,
			},
			{
				title   = "Pre-release (dev)",
				checked = (channel == "dev") or nil,
				fn      = function() set_channel("dev") end,
			},
			{ title = "-" },
			{
				title = "Check for updates",
				fn    = function()
					Logger.info(LOG, "User triggered update check (channel: %s).", channel)
					check_for_update(channel)
				end,
			},
			{
				title = "Changelog",
				fn    = function()
					Logger.info(LOG, "User opened changelog (channel: %s).", channel)
					show_changelog(channel)
				end,
			},
			{
				title = "Open releases page",
				fn    = function() hs.urlevent.openURL(releases_page_url()) end,
			},
		},
	}
end

return M

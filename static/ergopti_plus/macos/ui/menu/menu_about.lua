--- ui/menu/menu_about.lua

--- ==============================================================================
--- MODULE: Menu About / Update
--- DESCRIPTION:
--- Builds the "About / Update" sub-menu for the macOS menubar. User-initiated
--- update checks cross the narrow launcher adapter so Sparkle alone verifies,
--- downloads, installs, and relaunches the outer application bundle.
---
--- FEATURES & RATIONALE:
--- 1. Native ownership: Sparkle's standard controller provides authenticated
---    download progress and replaces the actual outer bundle.
--- 2. Channel-aware: the user can switch between "main" (stable releases) and
---    "dev" (pre-releases) and the choice is persisted in config.toml.
--- ==============================================================================

local M = {}
local hs        = hs
local Logger    = require("infra.logger")
local i18n      = require("infra.i18n")
local changelog = require("ui.changelog")
local Updater   = require("modules.updater")
local ManifestMenu = require("infra.manifest_menu")
local UpdateLauncher = require("adapters.update_launcher")
local LOG       = "menu_about"

M.DEFAULT_STATE = {
	-- Source checkouts and packaged prereleases both follow the development feed.
	update_channel = Updater.default_channel(),
	update_check_interval_seconds = Updater.get_check_interval(),
}





-- ======================================
-- ======================================
-- ======= 1/ Constants & helpers =======
-- ======================================
-- ======================================

local function is_local_source()
	return Updater.is_local_source()
end

local function current_version()
	return Updater.current_version()
end

local function releases_page_url()
	return Updater.releases_page_url()
end




-- ================================
-- ================================
-- ======= 2/ Changelog ============
-- ================================
-- ================================


--- Opens the dedicated changelog window for the given channel.
--- Delegates to ui.changelog which shows a webview with the full release list
--- and markdown-rendered notes instead of a plain text dialog.
--- @param channel string "main" or "dev"
local function show_changelog(channel)
	Logger.info(LOG, "Opening changelog window (channel=%s).", channel)
	changelog.open({ channel = channel })
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
		and state.update_channel or M.DEFAULT_STATE.update_channel
	local ver     = current_version()
	local ver_label = i18n.get("menu.about.title")

	local interval_sec = tonumber(state.update_check_interval_seconds) or Updater.get_check_interval()

	-- Forward-declared because set_channel and set_check_interval both reference it,
	-- but the definition appears below them. Without this the name resolves to a global
	-- nil at the call site and restart_background_checks receives nil as its callback.
	local update_menu_fn

	local function set_channel(c)
		state.update_channel = c
		if type(ctx.save_prefs) == "function" and ctx.save_prefs() ~= true then return false end
		Updater.restart_background_checks(
			c,
			tonumber(state.update_check_interval_seconds) or Updater.get_check_interval(),
			update_menu_fn
		)
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	local function set_check_interval(seconds)
		interval_sec = tonumber(seconds) or 0
		state.update_check_interval_seconds = interval_sec
		if type(ctx.save_prefs) == "function" and ctx.save_prefs() ~= true then return false end
		Updater.restart_background_checks(
			state.update_channel or channel,
			interval_sec,
			update_menu_fn
		)
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	-- Callback passed to the update flow so it can trigger a menu rebuild when
	-- the state machine transitions (checking → available → installing → idle).
	function update_menu_fn()
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	local local_src = is_local_source()

	-- First disabled item mirrors AHK: "ErgoptiPlus <version>" with channel tag.
	-- e.g. "ErgoptiPlus v0.2.1-dev" or "ErgoptiPlus local"
	local ver_display
	if ver == "local" then
		ver_display = "ErgoptiPlus local"
	else
		local channel_tag = (channel == "dev") and "-dev" or ""
		ver_display = "ErgoptiPlus " .. ver .. channel_tag
	end

	-- Channel submenu — shown in both local and bundled modes.
	local channel_display = (channel == "dev")
		and i18n.get("menu.about.channel_dev")
		or  i18n.get("menu.about.channel_main")
	local channel_items = {
		{
			label   = i18n.get("menu.about.channel_main"),
			checked = (channel == "main") or nil,
			action      = function() set_channel("main") end,
		},
		{
			label   = i18n.get("menu.about.channel_dev"),
			checked = (channel == "dev") or nil,
			action      = function() set_channel("dev") end,
		},
	}

	local menu_items = {}

	-- Version header — always the first item, always disabled.
	--
	-- `label`, not `title`. This array is what the `about_updates` list provider
	-- returns, so the renderer reads it as provider DATA: a row keyed `title` has
	-- no label, and the renderer drops it with one warning. This row and the
	-- channel selector below were both invisible in the About submenu from the
	-- day the block became a provider until 2026-08-07.
	table.insert(menu_items, { label = ver_display, disabled = true })

	table.insert(menu_items, { separator = true })

	-- Channel selector submenu — always shown so the user can switch.
	local channel_title = i18n.get("menu.about.channel_menu") .. ": " .. channel_display
	table.insert(menu_items, { label = channel_title, items = channel_items })

	if not local_src then
		local freq_items = {}
		local current_freq_code = ""
		for _, preset in ipairs(Updater.INTERVAL_PRESETS) do
			local label = i18n.get("menu.about.frequency." .. preset.code)
			if preset.seconds == interval_sec then
				current_freq_code = preset.code
			end
			table.insert(freq_items, {
				label   = label,
				checked = (preset.seconds == interval_sec) or nil,
				action      = function() set_check_interval(preset.seconds) end,
			})
		end
		local freq_display = (current_freq_code ~= "") and current_freq_code or "?"
		table.insert(menu_items, {
			label = i18n.get("menu.about.frequency_menu") .. ": " .. freq_display,
			items  = freq_items,
		})

		-- Dynamic one-click update item — only meaningful for bundled builds.
		table.insert(menu_items, {
			label = i18n.get("menu.about.check_for_updates"),
			action = function()
				Logger.info(LOG, "User triggered one-click update (channel: %s).", channel)
				UpdateLauncher.request_check()
			end,
		})
	end

	-- The updater block above is the manifest's `about_updates` list; the two rows
	-- below it are `command` declarations. The separator between them is a `---`
	-- row. Until 2026-08-07 the whole submenu was assembled here and described
	-- nowhere, on all three drivers at once.
	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = {
		["about_changelog"] = function()
			Logger.info(LOG, "User opened changelog (channel: %s).", channel)
			show_changelog(channel)
		end,
		["about_releases_page"] = function() hs.urlevent.openURL(releases_page_url()) end,
	}

	local rendered = ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, {
		["about_updates"] = function() return menu_items end,
	})

	-- The submenu title uses the generic i18n label (e.g. "Version / Mise à jour")
	-- so the menubar entry stays compact; the version detail is inside the submenu.
	return { label = ver_label, submenu = rendered }
end

return M

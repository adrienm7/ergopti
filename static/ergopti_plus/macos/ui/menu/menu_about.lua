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
--- 2. One channel owner: the rows list every channel of the shared registry and
---    subscribe through the menu session's channel owner (ctx.channel_owner,
---    modules/updater/channel.lua), which persists the choice and
---    tells the launcher which feed Sparkle reads; the check names the same
---    channel, so the menu cannot diverge from Sparkle's feed.
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
--- and markdown-rendered notes instead of a plain text dialog. Its banner
--- subscribes through the same channel owner as the rows below.
--- @param channel string Registry channel shown first (the subscribed one).
--- @param owner table|nil The menu session's update-channel owner.
local function show_changelog(channel, owner)
	Logger.info(LOG, "Opening changelog window (channel=%s).", channel)
	changelog.open({ channel = channel, channel_owner = owner })
end




-- ================================
-- ================================
-- ======= 3/ Menu builder =========
-- ================================
-- ================================

--- Builds the About / Update sub-menu item.
--- @param ctx table Menu context.
--- @return table Menu item table for insertion into the parent menu.
function M.build(ctx)
	local owner = type(ctx) == "table" and ctx.channel_owner or nil
	if type(owner) ~= "table" then
		Logger.error(LOG, "No update channel owner in the menu context — the channel rows are left out.")
	end
	local channel = owner and owner.get() or Updater.installed_channel()
	local ver     = current_version()
	local ver_label = i18n.get("menu.about.title")

	local local_src = is_local_source()

	-- First disabled item mirrors AHK: "ErgoptiPlus <version>".
	-- e.g. "ErgoptiPlus v0.2.1-dev" or "ErgoptiPlus local"
	local ver_display
	if ver == "local" then
		ver_display = "ErgoptiPlus local"
	else
		ver_display = "ErgoptiPlus " .. ver
	end

	local menu_items = {}

	-- Version header — always the first item, always disabled.
	--
	-- `label`, not `title`. This array is what the `about_updates` list provider
	-- returns, so the renderer reads it as provider DATA: a row keyed `title` has
	-- no label, and the renderer drops it with one warning. This row was invisible
	-- in the About submenu until 2026-08-07.
	table.insert(menu_items, { label = ver_display, disabled = true })

	table.insert(menu_items, { separator = true })

	-- One row per registry channel, ticked on the subscribed one, right before the
	-- check row. The owner persists the choice and refreshes the menu.
	local registry = Updater.channels()
	for _, id in ipairs(owner and registry.ids() or {}) do
		table.insert(menu_items, {
			label = i18n.get(registry.channel(id).menu_label_key),
			checked = id == channel,
			action = function()
				Logger.info(LOG, "User chose the update channel '%s'.", id)
				owner.set(id)
			end,
		})
	end

	if not local_src then
		-- A packaged build delegates the entire transaction to Sparkle.
		table.insert(menu_items, {
			label = i18n.get("menu.about.check_for_updates"),
			action = function()
				Logger.info(LOG, "User triggered one-click update (channel: %s).", channel)
				UpdateLauncher.request_check(channel)
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
			show_changelog(channel, owner)
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

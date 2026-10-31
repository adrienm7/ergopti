--- ui/menu/menu_about.lua

--- ==============================================================================
--- MODULE: Linux Menu About Submenu
--- DESCRIPTION:
--- Builds the tray's About submenu from the shared manifest section: the
--- version, the update channel and frequency pickers, the update check and the
--- uninstall command with its confirmation and captions.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ParentSource = require("menu.frames.parent_source")
local Version = require("infra.version")
local Installation = require("infra.installation")
local VersionLabel = require("updater.version_label")
local Schedule = require("updater.schedule")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end
local separator_modules = package.loaded
local uninstall_caption_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_caption_receiver")
local uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")
local uninstall_caption_get = type(uninstall_caption_i18n) == "table" and rawget(uninstall_caption_i18n, "get")

local _fill = require("ui.menu.menu_dialogs")._fill
local shell_quote = require("ui.menu.menu_dialogs").shell_quote
local show_error = require("ui.menu.menu_dialogs").show_error
local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain
local ask_yes_no = require("ui.menu.menu_dialogs").ask_yes_no

local LOG = "ui.menu.menu_about"

--- Retains only the actual caption facade and translator used by removal options.
--- @return boolean current
local function uninstall_caption_facade_current()
	return type(ManifestMenu) == "table" and getmetatable(ManifestMenu) == nil
		and rawget(package, "loaded") == separator_modules
		and rawget(separator_modules, "infra.manifest_menu") == ManifestMenu
		and type(uninstall_caption_factory) == "function" and rawget(ManifestMenu, "command_caption_receiver") == uninstall_caption_factory
		and type(uninstall_caption_i18n) == "table" and getmetatable(uninstall_caption_i18n) == nil
		and rawget(separator_modules, "infra.i18n") == uninstall_caption_i18n
		and type(uninstall_caption_get) == "function" and rawget(uninstall_caption_i18n, "get") == uninstall_caption_get
end

--- The channel picker of the About submenu: one submenu titled with the
--- subscribed channel's registry name, one row per registry channel in registry
--- order, ticked on the subscribed one. A click subscribes through the updater,
--- which persists the choice; the redraw it asks for retitles the picker.
--- @param ctx table Menu context.
--- @param up table The updater module.
--- @return table row A provider row with its items.
local function _channel_picker(ctx, up)
	return ManifestMenu.choice_row("about_update_channel_menu", require("config_keys").COMMAND.UPDATE_CHANNEL, {
		update_channel = function(id)
			local ok, committed = pcall(up.set_channel, id)
			if not ok or committed ~= true then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			-- An open Versions page follows only an acknowledged subscription.
			local ok_bridge, Changelog = pcall(require, "ui.changelog.bridge")
			if ok_bridge then
				Changelog.push_subscribed_channel(id)
			else
				Logger.error(LOG, "The Versions page bridge is unavailable: %s.", tostring(Changelog))
			end
			return true
		end,
	}, {
		[require("config_keys").KEY.UPDATER_CHANNEL] = function() return up.get_channel() end,
		installed_build = function() return not Installation.is_source_run() end,
	})
end

--- Supplies the registered cadence choice to the existing updater owner.
--- @param ctx table Menu context.
--- @param up table Native updater owner.
--- @return table row Shared choice provider data.
local function _frequency_picker(ctx, up)
	return ManifestMenu.choice_row("about_update_frequency_menu", require("config_keys").COMMAND.UPDATE_CHECK_INTERVAL, {
		update_check_interval = function(seconds)
			if up.set_check_interval(seconds) ~= true then return false end
			if up.start_background_checks() ~= true then return false end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end,
	}, {
		[require("config_keys").KEY.UPDATER_CHECK_INTERVAL_SECONDS] = function()
			return Schedule.snap_interval(up.get_check_interval(), up.TIMING)
		end,
		installed_build = function() return not Installation.is_source_run() end,
	})
end

--- The updater block of the About submenu, as provider DATA: the version, the
--- channel picker right before the check row, then the check-frequency picker.
--- It used to be a Linux-only top-level "Updates" submenu with its own
--- 'stable'/'dev' rows.
--- @param ctx table Menu context.
--- @return table rows
local function _about_update_rows(ctx)
	local up = ctx.updater
	-- The build and the commit it was built from, in the shared wording:
	-- « Version 0.0.0-dev.144 (c3005e0b9) » for a release, « Version locale
	-- (c3005e0b9) » for a source run. The identity is resolved once per daemon
	-- by infra/version.lua, so a rebuild reads no file.
	local identity = Version.identity()
	local out = {
		{
			label = VersionLabel.format(identity.kind, identity.version, identity.commit, i18n_safe),
			disabled = true,
		},
	}
	local separator_rows = ManifestMenu.template_rows("about_version_separator")
	if not separator_rows then return {} end
	for _, row in ipairs(separator_rows) do out[#out + 1] = row end
	if not up then
		Logger.error(LOG, "No updater module — the About menu shows no channel or check row.")
		return out
	end

	out[#out + 1] = _channel_picker(ctx, up)

	-- A local version has no installation to update, so it checks for nothing
	-- (the updater starts no background check for it). Its channel, check and
	-- frequency rows are still drawn, greyed with the reason: left out, nobody
	-- could tell whether the automatic update exists. The manifest's
	-- `disabled_when = ["installed_build"]` greys the two choices.
	local source_run = Installation.is_source_run()
	-- A system package never self-updates either, so it gets the same greyed rows
	-- with its own reason (the key the Versions window already shows).
	local update_blocked_reason = source_run and "menu.about.source_run_reason" or nil
	if not source_run and type(up.installation_kind) == "function" and up.installation_kind() == "package" then
		update_blocked_reason = "changelog_window.install_blocked_package"
	end
	local frequency_row = _frequency_picker(ctx, up)

	-- A check discovers releases; installation needs the separately named row.
	if source_run then
		local source_row = ManifestMenu.command_row("about_source_menu", require("config_keys").COMMAND.ABOUT_SOURCE_CHECK, {
			[require("config_keys").COMMAND.ABOUT_SOURCE_CHECK] = function() return false end,
		}, { ["about_source_release_ready"] = function() return not source_run end })
		if source_row then out[#out + 1] = source_row end
	else
		out[#out + 1] = {
		label = up.get_menu_label(),
		disabled = up.get_state() == "checking" or up.get_state() == "downloading"
			or up.get_state() == "installing",
		action = function()
			-- The answer is shown in the shared update-check window, with Update
			-- and the other channels' newer releases
			local opened = require("ui.update_check.bridge").open({
				updater            = up,
				on_menu_changed    = ctx.on_menu_changed,
				on_update_finished = ctx.on_update_finished,
				on_open_today_log  = ctx.on_open_today_log,
			})
			if opened then return end
			-- Without a window (no WebKitGTK, no display) the answer is announced
			-- by a notification instead
			Logger.warn(LOG, "The update-check window could not open; the answer is notified instead.")
			up.check_for_updates(nil, function(available, release, err)
				if available and release then
					Logger.info(LOG, "Update available: %s.", release.tag)
				elseif err then
					Logger.warn(LOG, "Update check failed: %s.", tostring(err))
				else
					Logger.info(LOG, "No update available (current: %s).", up.current_version())
				end
				if type(ctx.on_update_checked) == "function" then
					ctx.on_update_checked(available, release, err)
				end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end)
		end,
	}
	end

	-- Only once there is something to install: a permanently visible
	-- "download" row that does nothing is indistinguishable from a broken one.
	if up.get_state() == "available" then
		local rel = up.get_cached_release()
		if rel and rel.check_only == true then
			-- Read from the public feed because the API was unreachable: announced, not installable.
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				disabled = true,
				disabled_reason_key = "update_check.check_only",
			}
		elseif rel and update_blocked_reason then
			-- A source run offers the latest release to look at, but has no
			-- installation to replace; a system package is updated by its
			-- package manager: the row stays, greyed, and the renderer names why
			-- as on every greyed row with a reason, with no action a click could
			-- start.
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				disabled = true,
				disabled_reason_key = update_blocked_reason,
			}
		elseif rel then
			out[#out + 1] = {
				label = _fill(i18n_safe("menu.about.update_now"), "{tag}", rel.tag),
				action = function()
					-- Consent names the release this row shows: the manager refuses
					-- it if a background check replaced the cached release since.
					require("ui.update_check.bridge").download_offered(up, rel, ctx)
				end,
			}
		end
	end


	-- A system package is an installed build, so only its own reason is applied here.
	if update_blocked_reason and not source_run then
		frequency_row.items = nil
		frequency_row.disabled = true
		frequency_row.disabled_reason_key = update_blocked_reason
	end

	out[#out + 1] = frequency_row
	return out
end


--- The action of the Uninstall row: the confirmed removal transaction of
--- ui/menu/uninstall.lua, which quits the daemon through ctx.on_quit once the
--- removal worker owns the files.
--- @param ctx table Menu context.
--- @return function
local function _uninstall_command(ctx)
	local receive, current
	if uninstall_caption_facade_current() then receive, current = uninstall_caption_factory("about_menu", "uninstall") end
	return function()
		if not uninstall_caption_facade_current() or type(receive) ~= "function" or type(current) ~= "function" or not current() then return false end
		local run = require("ui.menu.uninstall").run
		local title = receive()
		if title == nil or not uninstall_caption_facade_current() or not current() then return false end
		local confirmation = i18n_safe("dialog.uninstall.confirm")
		if not uninstall_caption_facade_current() or not current() then return false end
		local failure = i18n_safe("dialog.uninstall.failed")
		if not uninstall_caption_facade_current() or not current() then return false end
		local missing_program = i18n_safe("dialog.uninstall.missing_program")
		if not uninstall_caption_facade_current() or not current() then return false end
		local options = {
			title = title,
			confirmation = confirmation,
			failure = failure,
			missing_program = missing_program,
			confirm = function(title, text)
				return ask_yes_no(title, zenity_plain(text),
					i18n_safe("button.remove"), i18n_safe("button.cancel"))
			end,
			fail = function(text) show_error(zenity_plain(text), i18n_safe("menu.global.uninstall")) end,
			quit = function()
				if type(ctx.on_quit) ~= "function" then
					Logger.error(LOG, "Uninstall: ctx.on_quit is absent — the daemon cannot quit.")
					return
				end
				ctx.on_quit()
			end,
		}
		if not uninstall_caption_facade_current() or not current() then return false end
		run(options)
	end
end

--- Delegates the raw dense-array check to the shared section admission.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function about_dense(value, records)
	return ParentSource.dense(value, records)
end

--- Delegates the actual About source admission to the shared section admission.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function about_source(renderer, platform)
	return ParentSource.read(renderer, platform, "about")
end

--- Delegates the direct parent recheck to the shared section admission.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function about_parent_unchanged(parent, fields)
	return ParentSource.unchanged(parent, fields)
end

--- Builds the about item: the updater block, Versions and its GitHub page, then
--- startup and Uninstall after a separator. Uninstall sat at the bottom of
--- Configuration until 2026-09, where it read as one more setting.
local function _build_about(ctx)
	local root, top, section, parent, fields = about_source(ManifestMenu, "linux")
	if root == nil then return nil end
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		[require("config_keys").COMMAND.START_AT_LOGIN] = function()
			if not require("ui.menu.start_at_login").toggle() then
				show_error(i18n_safe("dialog.start_at_login.failed"), i18n_safe("menu.global.start_at_login"))
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		["uninstall"] = _uninstall_command(ctx),
		-- Opens the release notes. It used to log one line to a file the user
		-- never sees and call that an About box — while ui/changelog/ was written,
		-- registered in webview_manager's bridge table and given a window title,
		-- with no caller anywhere. The page existed and nothing could reach it.
		[require("config_keys").COMMAND.ABOUT_CHANGELOG] = function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager — the release notes cannot open.")
				return
			end
			ctx.webview.show("changelog")
		end,
		[require("config_keys").COMMAND.ABOUT_RELEASES_PAGE] = function()
			if type(ctx.updater) ~= "table" then
				Logger.error(LOG, "No updater module — the releases page URL is unknown.")
				return
			end
			local url = ctx.updater.releases_page_url()
			Logger.info(LOG, "Opening releases page: %s", url)
			pcall(function() os.execute("xdg-open " .. shell_quote(url) .. " 2>/dev/null &") end)
		end,
	}

	-- A local version run from source has nothing to uninstall: the row stays,
	-- greyed, and says why (the manifest's disabled_reason_key).
	local getters = {}
	for key, getter in pairs(type(render_ctx.state_getters) == "table" and render_ctx.state_getters or {}) do
		getters[key] = getter
	end
	getters["installed_build"] = function() return not Installation.is_source_run() end
	getters["startup_command_available"] = function()
		return require("ui.menu.start_at_login").command_available() ~= false
	end
	getters["start_at_login_enabled"] = function()
		return require("ui.menu.start_at_login").enabled() == true
	end
	render_ctx.state_getters = getters

	local rows = ManifestMenu
		and ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, {
			["about_updates"] = function() return _about_update_rows(ctx) end,
		})
		or {}
	if not about_dense(rows, true) then return nil end
	local current_root, current_top, current_section, current_parent = about_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not about_parent_unchanged(parent, fields) then return nil end
	return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)
end

M._about_update_rows = _about_update_rows
M.build = _build_about

return M

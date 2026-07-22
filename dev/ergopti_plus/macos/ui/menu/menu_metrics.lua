--- ui/menu/menu_metrics.lua

--- ==============================================================================
--- MODULE: Keylogger Menu UI
--- DESCRIPTION:
--- This module constructs and manages the "Metrics & Keylogger" submenu within
--- the global Hammerspoon menubar. It acts as the primary user interface for
--- toggling privacy settings, encryption, and real-time visualization widgets.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-Driven: Structure (order, separators, sections) is read from
---    ``_shared/menu_manifest.json`` via ``lib/manifest_menu``.  Dynamic blocks
---    (shortcut pickers, app exclusion, WPM controls, encryption) are supplied
---    as handlers so state-bearing logic stays in Lua.
--- 2. Orchestration: Bridges the isolated UI components (menubar, widget) and
---    starts/stops them cleanly upon user toggling.
--- 3. Standalone App Link: Provides a direct link to open the GUI of the Encryptor.
--- 4. Asynchronous GUI: Employs local native Lua loops for real-time UI tracking
---    during mass encryption routines handled by the core module.
--- ==============================================================================

local M = {}
local hs = hs
local fs = require("hs.fs")
local text_utils = require("lib.text_utils")

local AppPickerLib  = require("lib.app_picker")
local dialog        = require("lib.dialog_util")
local kl_mod        = require("modules.keylogger")
local i18n          = require("lib.i18n")
local ManifestMenu  = require("lib.manifest_menu")

local _prog_canvas = nil





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	keylogger_enabled                = kl_mod.DEFAULT_STATE.keylogger_enabled,
	keylogger_disabled_apps          = kl_mod.DEFAULT_STATE.keylogger_disabled_apps,
	keylogger_encrypt                = kl_mod.DEFAULT_STATE.keylogger_encrypt,
	keylogger_menubar_wpm            = kl_mod.DEFAULT_STATE.keylogger_menubar_wpm,
	keylogger_menubar_colors         = kl_mod.DEFAULT_STATE.keylogger_menubar_colors,
	keylogger_float_wpm              = kl_mod.DEFAULT_STATE.keylogger_float_wpm,
	keylogger_float_graph            = kl_mod.DEFAULT_STATE.keylogger_float_graph,
	keylogger_float_colors           = kl_mod.DEFAULT_STATE.keylogger_float_colors,
	keylogger_private_filter_enabled     = kl_mod.DEFAULT_STATE.keylogger_private_filter_enabled,
	keylogger_secure_filter_enabled      = kl_mod.DEFAULT_STATE.keylogger_secure_filter_enabled,
	keylogger_system_auth_filter_enabled = kl_mod.DEFAULT_STATE.keylogger_system_auth_filter_enabled,
	metrics_shortcut                 = false,
	apps_time_shortcut               = false,
}





-- ==================================
-- ==================================
-- ======= 2/ Local Utilities =======
-- ==================================
-- ==================================

--- Draws or updates the floating progress bar during mass encryption/decryption.
--- @param current_index number Current file count.
--- @param total_files number Total file count.
local function update_progress(current_index, total_files)
	if not _prog_canvas then
		local screen_frame = hs.screen.mainScreen():frame()
		local canvas_width, canvas_height = 400, 80
		_prog_canvas = hs.canvas.new({ x = (screen_frame.w - canvas_width) / 2, y = (screen_frame.h - canvas_height) / 2, w = canvas_width, h = canvas_height })
		_prog_canvas:behavior({ "canJoinAllSpaces", "stationary" }):level(hs.drawing.windowLevels.overlay)
	end

	local is_dark_mode = hs.host.interfaceStyle() == "Dark"
	local palette = {
		bg_color       = is_dark_mode and { white = 0, alpha = 0.8 } or { white = 0.95, alpha = 0.9 },
		text_color     = is_dark_mode and { white = 1 } or { white = 0 },
		track_color    = is_dark_mode and { white = 0.2, alpha = 1 } or { white = 0.85, alpha = 1 },
		progress_color = { hex = "#007aff", alpha = 1 }
	}

	local percentage = total_files > 0 and (current_index / total_files) or 0
	local ui_label = string.format(i18n.get("dialog.metrics.progress_label"), current_index, total_files)

	_prog_canvas:replaceElements({
		{ type = "rectangle", action = "fill", fillColor = palette.bg_color, roundedRectRadii = { xRadius = 10, yRadius = 10 } },
		{ type = "text", text = ui_label, frame = { x = 20, y = 15, w = 360, h = 25 }, textSize = 14, textColor = palette.text_color },
		{ type = "rectangle", action = "fill", frame = { x = 20, y = 45, w = 360, h = 10 }, fillColor = palette.track_color, roundedRectRadii = { xRadius = 5, yRadius = 5 } },
		{ type = "rectangle", action = "fill", frame = { x = 20, y = 45, w = 360 * percentage, h = 10 }, fillColor = palette.progress_color, roundedRectRadii = { xRadius = 5, yRadius = 5 } }
	})
	_prog_canvas:show()
end

--- Wraps the backend processing loop to provide UI feedback.
--- @param files_to_process table Array of absolute file paths.
--- @param is_encrypt boolean True to encrypt, false to decrypt.
--- @param password string The security key to provide to OpenSSL.
local function process_files_with_ui(files_to_process, is_encrypt, password)
	local total_files = #files_to_process
	update_progress(0, total_files)

	local function on_progress(current_index)
		update_progress(current_index, total_files)
	end
	
	local function on_complete(success_count, error_count, has_bad_password)
		if _prog_canvas then
			_prog_canvas:delete()
			_prog_canvas = nil
		end

		local alert_msg = string.format(i18n.get("dialog.metrics.complete_label"), success_count, error_count)
		if has_bad_password then
			alert_msg = alert_msg .. "\n\n" .. i18n.get("dialog.metrics.bad_password_warning")
		end

		dialog.block_alert("Encryptor", alert_msg, i18n.get("button.ok"))
	end

	local log_manager = require("modules.keylogger.log_manager")
	if type(log_manager.process_files_async) == "function" then
		log_manager.process_files_async(files_to_process, is_encrypt, password, on_progress, on_complete)
	end
end





-- ==============================
-- ==============================
-- ======= 3/ Factory API =======
-- ==============================
-- ==============================

--- Builds the Keylogger menu item and defines callbacks.
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table The menu definition table.
function M.build(ctx)
	local state          = ctx.state
	local save_prefs     = ctx.save_prefs
	local updateMenu     = ctx.updateMenu
	local script_control = ctx.script_control

	-- Sync widget visibility on every build so a reload restores the saved state.
	-- Keylogger start/stop is handled by sync_state_to_modules in init.lua.
	-- Gate the WPM UIs on pause too: pause_all() never tears them down, but the
	-- pause-change listener calls updateMenu() (this build), so honouring the pause
	-- state HERE is what stops the widget's 0.2 s timer + mouse eventtap and the
	-- menubar's 0.5 s timer while « tout est éteint », and restarts them on resume.
	-- Without it the WPM timers kept polling get_live_stats() and re-rendering the
	-- canvas under pause.
	local paused = script_control and type(script_control.is_paused) == "function"
		and script_control.is_paused() or false
	-- Live pause state for the interactive toggle handlers below. They run at CLICK
	-- time (later than this build), so re-derive pause then — toggling a WPM feature
	-- ON while paused must record the preference but NOT arm the 0.2s render timer +
	-- global mouse eventtap until resume (« pause = tout éteint », F-L10).
	local function paused_now()
		return script_control and type(script_control.is_paused) == "function"
			and script_control.is_paused() or false
	end
	if state.keylogger_enabled then
		local WpmMenubar = require("ui.wpm.wpm_menubar")
		if type(WpmMenubar.set_use_source_colors) == "function" then
			WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
		end
		if state.keylogger_menubar_wpm and not paused then WpmMenubar.start() else WpmMenubar.stop() end

		local WpmWidget = require("ui.wpm.wpm_widget")
		if type(WpmWidget.set_use_source_colors) == "function" then
			WpmWidget.set_use_source_colors(state.keylogger_float_colors)
		end
		if state.keylogger_float_wpm and not paused then
			WpmWidget.start(state.keylogger_float_graph)
		else
			WpmWidget.stop()
		end
	end


	-- =====================================================
	-- ===== 3.1) Dynamic Handlers for Manifest Items =====
	-- =====================================================

	-- Canonical state-key getters for the disabled_when resolver (MG-1) —
	-- maps the manifest's driver-neutral keys to the concrete Lua state reads
	-- they proxy. Shared by every dynamic handler below so the dependency
	-- graph (which item greys out on which toggle) lives once in
	-- menu_manifest.json instead of being re-derived per handler.
	local STATE_GETTERS = {
		keylogger_enabled   = function() return state.keylogger_enabled end,
		wpm_widget_visible  = function() return state.keylogger_float_wpm end,
		wpm_menubar_visible = function() return state.keylogger_menubar_wpm end,
	}

	local function dyn_show_typing(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.show_typing"),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "show_typing", STATE_GETTERS),
			fn       = function()
				local Keylogger = require("modules.keylogger")
				Keylogger.show_metrics()
			end,
		})
	end

	-- Coerce sc.mods to a table so that a disk-persisted scalar string (e.g.
	-- mods="ctrl") never crashes ipairs/table.concat (M-13).
	local function coerce_mods(mods)
		if type(mods) == "table" then return mods end
		if type(mods) == "string" and mods ~= "" then return { mods } end
		return {}
	end

	local function dyn_shortcut_typing(items, _ctx)
		local sc_label = i18n.get("menu.metrics.shortcut_none")
		if type(state.metrics_shortcut) == "table" then
			local mods_cap = {}
			for _, m in ipairs(coerce_mods(state.metrics_shortcut.mods)) do
				table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
			end
			local mods_str = table.concat(mods_cap, "+")
			sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.metrics_shortcut.key or "")
		end
		table.insert(items, {
			title    = string.format(i18n.get("menu.metrics.shortcut_item"), sc_label),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "shortcut_typing", STATE_GETTERS),
			fn       = function()
				local current_str = ""
				if type(state.metrics_shortcut) == "table" then
					current_str = table.concat(coerce_mods(state.metrics_shortcut.mods), "+") .. "+" .. (state.metrics_shortcut.key or "")
				end
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					i18n.get("menu.metrics.shortcut_typing_title"),
					i18n.get("menu.metrics.shortcut_prompt"),
					current_str, "OK", i18n.get("common.cancel"))
				if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
				raw = raw:match("^%s*(.-)%s*$"):lower()
				if raw == "" then
					if type(ctx.apply_metrics_shortcut) == "function" then ctx.apply_metrics_shortcut(nil, nil) end
					return
				end
				local parts = {}
				for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
				if #parts < 1 then return end
				local key  = parts[#parts]
				local mods = {}
				for i = 1, #parts - 1 do
					local m = parts[i]
					if m == "option" then m = "alt" end
					table.insert(mods, m)
				end
				if #mods == 0 then mods = { "ctrl" } end
				if type(ctx.apply_metrics_shortcut) == "function" then ctx.apply_metrics_shortcut(mods, key) end
			end,
		})
	end

	local function dyn_show_apps(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.show_apps"),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "show_apps", STATE_GETTERS),
			fn       = function()
				local ok, at = pcall(require, "ui.metrics_apps")
				if ok and type(at.show) == "function" then
					pcall(at.show, hs.configdir .. "/logs")
				end
			end,
		})
	end

	local function dyn_shortcut_apps(items, _ctx)
		local sc_label = i18n.get("menu.metrics.shortcut_none")
		if type(state.apps_time_shortcut) == "table" then
			local mods_cap = {}
			for _, m in ipairs(coerce_mods(state.apps_time_shortcut.mods)) do
				table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
			end
			local mods_str = table.concat(mods_cap, "+")
			sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.apps_time_shortcut.key or "")
		end
		table.insert(items, {
			title    = string.format(i18n.get("menu.metrics.shortcut_item"), sc_label),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "shortcut_apps", STATE_GETTERS),
			fn       = function()
				local current_str = ""
				if type(state.apps_time_shortcut) == "table" then
					current_str = table.concat(coerce_mods(state.apps_time_shortcut.mods), "+") .. "+" .. (state.apps_time_shortcut.key or "")
				end
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					i18n.get("menu.metrics.shortcut_apps_title"),
					i18n.get("menu.metrics.shortcut_prompt"),
					current_str, "OK", i18n.get("common.cancel"))
				if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
				raw = raw:match("^%s*(.-)%s*$"):lower()
				if raw == "" then
					if type(ctx.apply_apps_time_shortcut) == "function" then ctx.apply_apps_time_shortcut(nil, nil) end
					return
				end
				local parts = {}
				for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
				if #parts < 1 then return end
				local key  = parts[#parts]
				local mods = {}
				for i = 1, #parts - 1 do
					local m = parts[i]
					if m == "option" then m = "alt" end
					table.insert(mods, m)
				end
				if #mods == 0 then mods = { "ctrl" } end
				if type(ctx.apply_apps_time_shortcut) == "function" then ctx.apply_apps_time_shortcut(mods, key) end
			end,
		})
	end

	local function dyn_filter_private(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.filter_private"),
			checked  = state.keylogger_private_filter_enabled,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "filter_private", STATE_GETTERS),
			fn       = function()
				state.keylogger_private_filter_enabled = not state.keylogger_private_filter_enabled
				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_private_filter_enabled) == "function" then
					pcall(Keylogger.set_private_filter_enabled, state.keylogger_private_filter_enabled)
				end
				save_prefs(); updateMenu()
			end,
		})
	end

	local function dyn_filter_secure(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.filter_secure"),
			checked  = state.keylogger_secure_filter_enabled,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "filter_secure", STATE_GETTERS),
			fn       = function()
				state.keylogger_secure_filter_enabled = not state.keylogger_secure_filter_enabled
				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_secure_field_filter_enabled) == "function" then
					pcall(Keylogger.set_secure_field_filter_enabled, state.keylogger_secure_filter_enabled)
				end
				save_prefs(); updateMenu()
			end,
		})
	end

	local function dyn_filter_sysauth(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.filter_sysauth"),
			checked  = state.keylogger_system_auth_filter_enabled,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "filter_sysauth", STATE_GETTERS),
			fn       = function()
				state.keylogger_system_auth_filter_enabled = not state.keylogger_system_auth_filter_enabled
				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_system_auth_filter_enabled) == "function" then
					pcall(Keylogger.set_system_auth_filter_enabled, state.keylogger_system_auth_filter_enabled)
				end
				save_prefs(); updateMenu()
			end,
		})
	end

	local function dyn_exclude_apps(items, _ctx)
		local disabled_count = #(type(state.keylogger_disabled_apps) == "table" and state.keylogger_disabled_apps or {})
		local label = disabled_count > 0
			and string.format(i18n.get("menu.metrics.disabled_in_label"), disabled_count, disabled_count > 1 and "s" or "")
			or i18n.get("menu.metrics.exclude_apps")
		local exclusion_menu = AppPickerLib.build_menu(
			state.keylogger_disabled_apps,
			function(new_list)
				state.keylogger_disabled_apps = new_list
				local Keylogger = require("modules.keylogger")
				if type(Keylogger.set_disabled_apps) == "function" then
					pcall(Keylogger.set_disabled_apps, new_list)
				end
				pcall(save_prefs); pcall(updateMenu)
			end,
			i18n.get("menu.metrics.exclude_apps")
		)
		table.insert(items, {
			title    = label,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "exclude_apps", STATE_GETTERS),
			menu     = exclusion_menu,
		})
	end

	local function dyn_wpm_menubar(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.show_wpm_menubar"),
			checked  = state.keylogger_menubar_wpm,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "wpm_menubar", STATE_GETTERS),
			fn       = function()
				state.keylogger_menubar_wpm = not state.keylogger_menubar_wpm
				save_prefs()
				local WpmMenubar = require("ui.wpm.wpm_menubar")
				if type(WpmMenubar.set_use_source_colors) == "function" then
					WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
				end
				if state.keylogger_menubar_wpm and not paused_now() then WpmMenubar.start() else WpmMenubar.stop() end
				updateMenu()
			end,
		})
	end

	local function dyn_menubar_colors(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.colors_by_source"),
			checked  = state.keylogger_menubar_colors,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "menubar_colors", STATE_GETTERS),
			fn       = function()
				state.keylogger_menubar_colors = not state.keylogger_menubar_colors
				save_prefs()
				local WpmMenubar = require("ui.wpm.wpm_menubar")
				if type(WpmMenubar.set_use_source_colors) == "function" then
					WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
				end
				if state.keylogger_menubar_wpm and not paused_now() then WpmMenubar.start() end
				updateMenu()
			end,
		})
	end

	local function dyn_wpm_widget(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.show_wpm_widget"),
			checked  = state.keylogger_float_wpm,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "wpm_widget", STATE_GETTERS),
			fn       = function()
				state.keylogger_float_wpm = not state.keylogger_float_wpm
				save_prefs()
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				if state.keylogger_float_wpm and not paused_now() then WpmWidget.start(state.keylogger_float_graph) else WpmWidget.stop() end
				updateMenu()
			end,
		})
	end

	local function dyn_widget_colors(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.colors_by_source"),
			checked  = state.keylogger_float_colors,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "widget_colors", STATE_GETTERS),
			fn       = function()
				state.keylogger_float_colors = not state.keylogger_float_colors
				save_prefs()
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				if state.keylogger_float_wpm and not paused_now() then WpmWidget.start(state.keylogger_float_graph) end
				updateMenu()
			end,
		})
	end

	local function dyn_include_realtime(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.include_realtime"),
			checked  = state.keylogger_float_graph,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "include_realtime", STATE_GETTERS),
			fn       = function()
				state.keylogger_float_graph = not state.keylogger_float_graph
				save_prefs()
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				if state.keylogger_float_wpm and not paused_now() then WpmWidget.start(state.keylogger_float_graph) end
				updateMenu()
			end,
		})
	end

	local function dyn_reset_wpm_position(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.reset_wpm_position"),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "reset_wpm_position", STATE_GETTERS),
			fn       = function()
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.reset_position) == "function" then WpmWidget.reset_position() end
			end,
		})
	end

	local function dyn_encryption(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.encrypt_toggle"),
			checked  = state.keylogger_encrypt,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "encryption", STATE_GETTERS),
			fn       = function()
				local log_manager = require("modules.keylogger.log_manager")
				local log_dir     = hs.configdir .. "/logs"
				local default_pwd = "ERGOPTI_FALLBACK_KEY"
				if type(log_manager.get_mac_serial) == "function" then default_pwd = log_manager.get_mac_serial() end

				if not state.keylogger_encrypt then
					local res = dialog.block_alert(i18n.get("dialog.metrics.encrypt_confirm_title"),
						i18n.get("dialog.metrics.encrypt_confirm_body"),
						i18n.get("button.encrypt"), i18n.get("button.cancel"))
					if res ~= i18n.get("button.encrypt") then return end

					local ok_p, btn, pwd = pcall(dialog.text_prompt,
						i18n.get("dialog.metrics.encrypt_key_title"),
						i18n.get("dialog.metrics.encrypt_key_prompt"),
						default_pwd, i18n.get("button.ok"), i18n.get("button.cancel"))
					if not ok_p or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end

					if type(log_manager.register_encryptor_app) == "function" then
						pcall(log_manager.register_encryptor_app)
					end

					local files = {}
					local dir_iter = fs.dir(log_dir)
					if dir_iter then
						for file in dir_iter do
							if file:match("%.log%.gz$") and not file:match("%.enc$") then
								table.insert(files, log_dir .. "/" .. file)
							end
						end
					end
					state.keylogger_encrypt = true
					save_prefs()
					local Keylogger = require("modules.keylogger")
					if type(Keylogger.set_options) == "function" then
						Keylogger.set_options({ encrypt = true })
					end
					updateMenu()
					if #files > 0 then process_files_with_ui(files, true, pwd) end
				else
					local res = dialog.block_alert(i18n.get("dialog.metrics.decrypt_confirm_title"),
						i18n.get("dialog.metrics.decrypt_confirm_body"),
						i18n.get("button.decrypt"), i18n.get("button.cancel"))
					if res ~= i18n.get("button.decrypt") then return end

					local ok_p, btn, pwd = pcall(dialog.text_prompt,
						i18n.get("dialog.metrics.encrypt_key_title"),
						i18n.get("dialog.metrics.decrypt_key_prompt"),
						default_pwd, i18n.get("button.ok"), i18n.get("button.cancel"))
					if not ok_p or btn ~= "OK" or type(pwd) ~= "string" or pwd == "" then return end

					local files = {}
					local dir_iter2 = fs.dir(log_dir)
					if dir_iter2 then
						for file in dir_iter2 do
							if file:match("%.enc$") then
								table.insert(files, log_dir .. "/" .. file)
							end
						end
					end
					state.keylogger_encrypt = false
					save_prefs()
					local Keylogger = require("modules.keylogger")
					if type(Keylogger.set_options) == "function" then
						Keylogger.set_options({ encrypt = false })
					end
					updateMenu()
					if #files > 0 then process_files_with_ui(files, false, pwd) end
				end
			end,
		})
		table.insert(items, {
			title = i18n.get("menu.metrics.open_encryptor"),
			fn    = function()
				local app_path = hs.configdir .. "/utils/encryptor/Encryptor.app"
				if fs.attributes(app_path) then
					hs.execute("open " .. text_utils.shell_quote(app_path))
				else
					dialog.block_alert(
						i18n.get("dialog.metrics.encryptor_error_title"),
						i18n.get("dialog.metrics.encryptor_error_body"),
						i18n.get("button.ok"))
				end
			end,
		})
	end


	-- =============================================
	-- ===== 3.2) Manifest-Driven Menu Assembly =====
	-- =============================================

	local dyn_handlers = {
		show_typing      = dyn_show_typing,
		shortcut_typing  = dyn_shortcut_typing,
		show_apps        = dyn_show_apps,
		shortcut_apps    = dyn_shortcut_apps,
		filter_private   = dyn_filter_private,
		filter_secure    = dyn_filter_secure,
		filter_sysauth   = dyn_filter_sysauth,
		exclude_apps     = dyn_exclude_apps,
		wpm_menubar      = dyn_wpm_menubar,
		menubar_colors   = dyn_menubar_colors,
		wpm_widget       = dyn_wpm_widget,
		widget_colors    = dyn_widget_colors,
		include_realtime = dyn_include_realtime,
		reset_wpm_position = dyn_reset_wpm_position,
		encryption       = dyn_encryption,
	}

	local menu = ManifestMenu.build("metrics_menu", "Metrics", dyn_handlers, nil, ctx)

	return {
		title   = i18n.get("menu.metrics.title"),
		checked = state.keylogger_enabled,
		fn      = function()
			if not state.keylogger_enabled then
				local res = dialog.block_alert(
					i18n.get("dialog.metrics.security_warning_title"),
					i18n.get("dialog.metrics.security_warning_body"),
					i18n.get("button.activate"), i18n.get("button.cancel"), "warning")
				if res ~= i18n.get("button.activate") then return end
			end

			state.keylogger_enabled = not state.keylogger_enabled
			save_prefs()

			local ok_kl, Keylogger = pcall(require, "modules.keylogger")
			if not ok_kl then Keylogger = nil end
			local ok_wm, WpmMenubar = pcall(require, "ui.wpm.wpm_menubar")
			if not ok_wm then WpmMenubar = nil end
			local ok_ww, WpmWidget = pcall(require, "ui.wpm.wpm_widget")
			if not ok_ww then WpmWidget = nil end

			if state.keylogger_enabled then
				if Keylogger and type(Keylogger.set_options) == "function" then
					pcall(Keylogger.set_options, { encrypt = state.keylogger_encrypt })
				end
				if Keylogger and type(Keylogger.set_disabled_apps) == "function" then
					pcall(Keylogger.set_disabled_apps, state.keylogger_disabled_apps or {})
				end
				if Keylogger and type(Keylogger.start) == "function" then
					pcall(Keylogger.start, script_control)
				end
				if WpmMenubar and type(WpmMenubar.set_use_source_colors) == "function" then
					pcall(WpmMenubar.set_use_source_colors, state.keylogger_menubar_colors)
				end
				if WpmWidget and type(WpmWidget.set_use_source_colors) == "function" then
					pcall(WpmWidget.set_use_source_colors, state.keylogger_float_colors)
				end
				-- Gate on pause exactly like the 5 sibling per-feature toggles above
				-- (dyn_wpm_menubar, dyn_menubar_colors, dyn_wpm_widget, dyn_widget_colors,
				-- dyn_include_realtime): re-enabling the master switch while paused must
				-- record the preference but NOT arm the widget's 0.2s render timer +
				-- global mouse eventtap or the menubar's 0.5s timer until resume
				-- (« pause = tout éteint », F-L10) — this call site was the one place
				-- that still started both unconditionally on re-enable (F-LOW-13).
				if state.keylogger_menubar_wpm and not paused_now() and WpmMenubar and type(WpmMenubar.start) == "function" then pcall(WpmMenubar.start) end
				if state.keylogger_float_wpm and not paused_now() and WpmWidget and type(WpmWidget.start) == "function" then pcall(WpmWidget.start, state.keylogger_float_graph) end
			else
				if Keylogger and type(Keylogger.stop) == "function" then pcall(Keylogger.stop) end
				if WpmMenubar and type(WpmMenubar.stop) == "function" then pcall(WpmMenubar.stop) end
				if WpmWidget and type(WpmWidget.stop) == "function" then pcall(WpmWidget.stop) end
			end

			updateMenu()
		end,
		menu = menu,
	}
end

return M

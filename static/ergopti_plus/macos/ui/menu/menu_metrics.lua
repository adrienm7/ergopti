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
---    ``_shared/menu_manifest.json`` via ``infra/manifest_menu``.  Dynamic blocks
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
local text_utils = require("infra.text_utils")

local AppPickerLib  = require("infra.app_picker")
local dialog        = require("infra.dialog_util")
local kl_mod        = require("modules.keylogger")
local i18n          = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")
local Logger        = require("infra.logger")

local LOG = "menu_metrics"





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

	--- Persists one WPM state transition without letting a menu callback throw.
	--- @param label string Diagnostic operation label.
	--- @return boolean committed True only when persistence returned exact true.
	local function save_wpm_preferences(label)
		local ok, result = xpcall(save_prefs, debug.traceback)
		if ok and result == true then return true end
		Logger.error(LOG, "%s preference persistence failed: %s.", label,
			tostring(ok and result or result))
		return false
	end

	--- Invokes one WPM lifecycle method through its exact boolean contract.
	--- @param label string Diagnostic component label.
	--- @param module table WPM component module.
	--- @param method string `start` or `stop`.
	--- @param ... any Lifecycle arguments.
	--- @return boolean committed True only when the method returned exact true.
	local function call_wpm_lifecycle(label, module, method, ...)
		if type(module) ~= "table" or type(module[method]) ~= "function" then
			Logger.error(LOG, "%s %s is unavailable.", label, method)
			return false
		end
		local args = table.pack(...)
		local ok, result = xpcall(function()
			return module[method](table.unpack(args, 1, args.n))
		end, debug.traceback)
		if ok and result == true then return true end
		Logger.error(LOG, "%s %s did not commit: %s.", label, method,
			tostring(ok and result or result))
		return false
	end

	--- Removes a visibility preference after its runtime activation was rejected.
	--- @param state_key string Visibility preference key.
	--- @param label string Diagnostic component label.
	--- @return boolean Always false, for direct propagation to the caller.
	local function compensate_rejected_wpm_start(state_key, label)
		state[state_key] = false
		local persisted = save_wpm_preferences(label .. " activation rollback")
		Logger.error(LOG, "%s remains disabled after rejected activation; rollback persisted=%s.",
			label, tostring(persisted))
		return false
	end

	--- Reconciles a saved WPM visibility preference with the current pause state.
	--- A failed start is compensated immediately so the menu cannot advertise an
	--- active feature whose recurring producer was never committed.
	--- @param state_key string Visibility preference key.
	--- @param label string Diagnostic component label.
	--- @param module table WPM component module.
	--- @param ... any Start arguments.
	--- @return boolean settled Runtime commitment/cleanup result.
	local function sync_wpm_visibility(state_key, label, module, ...)
		if state[state_key] and not paused then
			if not call_wpm_lifecycle(label, module, "start", ...) then
				return compensate_rejected_wpm_start(state_key, label)
			end
			return true
		end
		return call_wpm_lifecycle(label, module, "stop")
	end

	--- Applies an interactive WPM visibility toggle transactionally.
	--- @param state_key string Visibility preference key.
	--- @param label string Diagnostic component label.
	--- @param module table WPM component module.
	--- @param ... any Start arguments.
	--- @return boolean committed True only when persistence and lifecycle settle.
	local function toggle_wpm_visibility(state_key, label, module, ...)
		local previous = state[state_key] == true
		local desired = not previous
		state[state_key] = desired
		if not save_wpm_preferences(label .. " toggle") then
			state[state_key] = previous
			updateMenu()
			return false
		end

		local settled
		if desired and not paused_now() then
			settled = call_wpm_lifecycle(label, module, "start", ...)
			if not settled then compensate_rejected_wpm_start(state_key, label) end
		else
			-- OFF and paused-ON both require a quiescent runtime. A refused native
			-- stop remains owned and fenced by the module, so retaining OFF is the
			-- truthful user-visible state while later builds retry the exact debt.
			settled = call_wpm_lifecycle(label, module, "stop")
		end
		updateMenu()
		return settled
	end

	--- Applies one metrics privacy-filter toggle across runtime, memory, and disk.
	--- Runtime changes first so an unavailable filter can never be persisted as
	--- active. Every later failure compensates the exact prior runtime value.
	--- @param state_key string Menu-state field.
	--- @param setter_name string Keylogger runtime setter.
	--- @param label string Diagnostic filter label.
	--- @return boolean committed True only when runtime and persistence agree.
	local function toggle_metrics_filter(state_key, setter_name, label)
		local previous = state[state_key] == true
		local desired = not previous
		local setter = kl_mod[setter_name]
		if type(setter) ~= "function" then
			Logger.error(LOG, "%s runtime setter is unavailable; state remains unchanged.", label)
			xpcall(updateMenu, debug.traceback)
			return false
		end

		local runtime_ok, runtime_detail = xpcall(setter, debug.traceback, desired)
		if not runtime_ok then
			local rollback_ok, rollback_detail = xpcall(setter, debug.traceback, previous)
			state[state_key] = previous
			Logger.error(LOG, "%s runtime update failed: %s; rollback committed=%s (%s).",
				label, tostring(runtime_detail), tostring(rollback_ok), tostring(rollback_detail))
			xpcall(updateMenu, debug.traceback)
			return false
		end

		state[state_key] = desired
		local save_ok, saved = xpcall(save_prefs, debug.traceback)
		if not save_ok or saved ~= true then
			state[state_key] = previous
			local rollback_ok, rollback_detail = xpcall(setter, debug.traceback, previous)
			Logger.error(LOG, "%s preference persistence failed: %s; runtime rollback committed=%s (%s).",
				label, tostring(saved), tostring(rollback_ok), tostring(rollback_detail))
			xpcall(updateMenu, debug.traceback)
			return false
		end

		local menu_ok, menu_detail = xpcall(updateMenu, debug.traceback)
		if not menu_ok then
			Logger.error(LOG, "%s menu refresh failed after a committed toggle: %s.",
				label, tostring(menu_detail))
		end
		return true
	end

	if state.keylogger_enabled then
		local WpmMenubar = require("ui.wpm.wpm_menubar")
		if type(WpmMenubar.set_use_source_colors) == "function" then
			WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
		end
		sync_wpm_visibility("keylogger_menubar_wpm", "WPM menubar", WpmMenubar)

		local WpmWidget = require("ui.wpm.wpm_widget")
		if type(WpmWidget.set_use_source_colors) == "function" then
			WpmWidget.set_use_source_colors(state.keylogger_float_colors)
		end
		sync_wpm_visibility("keylogger_float_wpm", "WPM widget", WpmWidget,
			state.keylogger_float_graph)
	end


	-- =====================================================
	-- ===== 3.1) Dynamic Handlers for Manifest Items =====
	-- =====================================================

	-- Canonical state-key getters for the disabled_when AND checked_when resolvers
	-- — the manifest's driver-neutral keys mapped to the concrete Lua state reads
	-- they proxy. Shared by every dynamic handler below so the dependency graph
	-- (which item greys out on which toggle) lives once in menu_manifest.json
	-- instead of being re-derived per handler.
	-- The three filter getters were missing until 2026-08-04: the manifest declared
	-- checked_when on those rows, macOS read `state.…` inline instead, and the two
	-- declarations were free to drift apart with nothing comparing them. Linux
	-- resolved the same three through the manifest, so the drivers already
	-- disagreed about where the truth lived.
	local STATE_GETTERS = {
		keylogger_enabled      = function() return state.keylogger_enabled end,
		wpm_widget_visible     = function() return state.keylogger_float_wpm end,
		wpm_menubar_visible    = function() return state.keylogger_menubar_wpm end,
		metrics_filter_private = function() return state.keylogger_private_filter_enabled end,
		metrics_filter_secure  = function() return state.keylogger_secure_filter_enabled end,
		metrics_filter_sysauth = function() return state.keylogger_system_auth_filter_enabled end,
		-- The two menubar rows became `check` on 2026-08-07: the renderer reads
		-- the tick through these instead of the handler setting it.
		metrics_menubar_wpm    = function() return state.keylogger_menubar_wpm end,
		metrics_menubar_colors = function() return state.keylogger_menubar_colors end,
		metrics_encrypt_enabled = function() return state.keylogger_encrypt end,
	}

	-- `command` rows since 2026-08-07: the label and the greying are the
	-- manifest's, so these supply only the click.
	local function cmd_show_typing()
		local Keylogger = require("modules.keylogger")
		Keylogger.show_metrics()
	end

	-- Coerce sc.mods to a table so that a disk-persisted scalar string (e.g.
	-- mods="ctrl") never crashes ipairs/table.concat (M-13).
	local function coerce_mods(mods)
		if type(mods) == "table" then return mods end
		if type(mods) == "string" and mods ~= "" then return { mods } end
		return {}
	end

	local function rows_shortcut_typing(_ctx)
		local sc_label = i18n.get("menu.metrics.shortcut_none")
		if type(state.metrics_shortcut) == "table" then
			local mods_cap = {}
			for _, m in ipairs(coerce_mods(state.metrics_shortcut.mods)) do
				table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
			end
			local mods_str = table.concat(mods_cap, "+")
			sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.metrics_shortcut.key or "")
		end
		return {{
			label    = string.format(i18n.get("menu.metrics.shortcut_item"), sc_label),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "shortcut_typing", STATE_GETTERS),
			action   = function()
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
		}}
	end

	local function cmd_show_apps()
		local ok, at = pcall(require, "ui.metrics_apps")
		if ok and type(at.show) == "function" then
		pcall(at.show, hs.configdir .. "/logs")
		end
	end

	local function rows_shortcut_apps(_ctx)
		local sc_label = i18n.get("menu.metrics.shortcut_none")
		if type(state.apps_time_shortcut) == "table" then
			local mods_cap = {}
			for _, m in ipairs(coerce_mods(state.apps_time_shortcut.mods)) do
				table.insert(mods_cap, m:sub(1, 1):upper() .. m:sub(2))
			end
			local mods_str = table.concat(mods_cap, "+")
			sc_label = (mods_str ~= "" and (mods_str .. " + ") or "") .. string.upper(state.apps_time_shortcut.key or "")
		end
		return {{
			label    = string.format(i18n.get("menu.metrics.shortcut_item"), sc_label),
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "shortcut_apps", STATE_GETTERS),
			action   = function()
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
		}}
	end

	--- Flips the private filter. The ROW is built by the shared renderer from
	--- the manifest (`type = "check"`); this is only what the row DOES.
	local function cmd_filter_private()
		return toggle_metrics_filter("keylogger_private_filter_enabled",
			"set_private_filter_enabled", "Private filter")
	end

	--- Flips the secure filter. The ROW is built by the shared renderer from
	--- the manifest (`type = "check"`); this is only what the row DOES.
	local function cmd_filter_secure()
		return toggle_metrics_filter("keylogger_secure_filter_enabled",
			"set_secure_field_filter_enabled", "Secure-field filter")
	end

	--- Flips the sysauth filter. The ROW is built by the shared renderer from
	--- the manifest (`type = "check"`); this is only what the row DOES.
	local function cmd_filter_sysauth()
		return toggle_metrics_filter("keylogger_system_auth_filter_enabled",
			"set_system_auth_filter_enabled", "System-auth filter")
	end

	local function rows_exclude_apps(_ctx)
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
				if save_prefs() ~= true then return false end
				pcall(updateMenu)
			end,
			i18n.get("menu.metrics.exclude_apps")
		)
		return {{
			label    = label,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "exclude_apps", STATE_GETTERS),
			-- AppPickerLib's rows, which the renderer materialises like any other.
			items    = exclusion_menu,
		}}
	end

	-- `check` rows since 2026-08-07: the label, the tick and the greying are the
	-- manifest's, so these supply only what the click does.
	local function cmd_wpm_menubar()
		local WpmMenubar = require("ui.wpm.wpm_menubar")
		if type(WpmMenubar.set_use_source_colors) == "function" then
			WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
		end
		return toggle_wpm_visibility("keylogger_menubar_wpm", "WPM menubar", WpmMenubar)
	end

	local function cmd_menubar_colors()
		state.keylogger_menubar_colors = not state.keylogger_menubar_colors
		if save_prefs() ~= true then return false end
		local WpmMenubar = require("ui.wpm.wpm_menubar")
		if type(WpmMenubar.set_use_source_colors) == "function" then
			WpmMenubar.set_use_source_colors(state.keylogger_menubar_colors)
		end
		-- Only restart when the readout is actually shown: colouring a menubar
		-- item that is not there would start it as a side effect.
		if state.keylogger_menubar_wpm and not paused_now()
			and not call_wpm_lifecycle("WPM menubar", WpmMenubar, "start") then
			compensate_rejected_wpm_start("keylogger_menubar_wpm", "WPM menubar")
		end
		updateMenu()
	end

	local function dyn_wpm_widget(items, _ctx)
		table.insert(items, {
			title    = i18n.get("menu.metrics.show_wpm_widget"),
			checked  = state.keylogger_float_wpm,
			disabled = ManifestMenu.resolve_disabled_when("metrics_menu", "wpm_widget", STATE_GETTERS),
			fn       = function()
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				return toggle_wpm_visibility("keylogger_float_wpm", "WPM widget", WpmWidget,
					state.keylogger_float_graph)
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
				if save_prefs() ~= true then return false end
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				if state.keylogger_float_wpm and not paused_now()
					and not call_wpm_lifecycle("WPM widget", WpmWidget, "start",
						state.keylogger_float_graph) then
					compensate_rejected_wpm_start("keylogger_float_wpm", "WPM widget")
				end
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
				if save_prefs() ~= true then return false end
				local WpmWidget = require("ui.wpm.wpm_widget")
				if type(WpmWidget.set_use_source_colors) == "function" then
					WpmWidget.set_use_source_colors(state.keylogger_float_colors)
				end
				if state.keylogger_float_wpm and not paused_now()
					and not call_wpm_lifecycle("WPM widget", WpmWidget, "start",
						state.keylogger_float_graph) then
					compensate_rejected_wpm_start("keylogger_float_wpm", "WPM widget")
				end
				updateMenu()
			end,
		})
	end

	local function cmd_reset_wpm_position()
		local WpmWidget = require("ui.wpm.wpm_widget")
		if type(WpmWidget.reset_position) == "function" then WpmWidget.reset_position() end
	end

	local function cmd_encryption()
		-- This entry used to call two empty stubs: it ticked its box, persisted
		-- the setting, and encrypted nothing, while docs/security told users to
		-- enable it. It also collected *.log.gz files — a storage format retired
		-- when persistence moved to SQLite. It is now a plain toggle over the
		-- real backend, and it refuses to tick when no key can be derived.
		local TextCipher = require("modules.keylogger.text_cipher")
		local want = not state.keylogger_encrypt
		if want and not TextCipher.is_available() then
			-- Existing keys, already translated in all 21 locales: the only
			-- way the key derivation fails on a Mac is a missing openssl,
			-- which is exactly what this message says.
			dialog.block_alert(
				i18n.get("dialog.metrics.encryptor_error_title"),
				i18n.get("apps.encryptor.err_openssl_missing"),
				i18n.get("button.ok"))
			return
		end
		TextCipher.set_enabled(want)
		state.keylogger_encrypt = want
		if save_prefs() ~= true then return false end
		local Keylogger = require("modules.keylogger")
		if type(Keylogger.set_options) == "function" then
			Keylogger.set_options({ encrypt = want })
		end
		-- The rows already stored predate this click, and the setting is
		-- worthless to a user with a year of logs unless they are converted
		-- too. The cipher is flipped FIRST: encrypt() returns the plaintext
		-- untouched while the toggle is off, so a pass started before it
		-- would convert nothing and report success.
		require("modules.keylogger.text_migration").start_for_posture(want)
		updateMenu()
	end


	-- =============================================
	-- ===== 3.2) Manifest-Driven Menu Assembly =====
	-- =============================================

	-- The two shortcut pickers and the app-exclusion row left dyn_handlers on
	-- 2026-08-07: their labels are computed, so no static declaration can carry
	-- them, but a provider that returns one row is still the renderer drawing it.
	-- The three WPM widget rows stay handlers — their callbacks repaint the OPEN
	-- menu rather than rebuilding the tray, which a declarative row cannot do.
	local dyn_handlers = {
		wpm_widget       = dyn_wpm_widget,
		widget_colors    = dyn_widget_colors,
		include_realtime = dyn_include_realtime,
	}

	local list_providers = {
		shortcut_typing = rows_shortcut_typing,
		shortcut_apps   = rows_shortcut_apps,
		exclude_apps    = rows_exclude_apps,
	}

	-- The declarative rows read their state and their behaviour off the
	-- context. A copy, so the caller's ctx is untouched.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.state_getters = STATE_GETTERS
	render_ctx.commands = {
		["filter_private"] = cmd_filter_private,
		["filter_secure"]  = cmd_filter_secure,
		["filter_sysauth"] = cmd_filter_sysauth,
		["encryption"]     = cmd_encryption,
		["reset_wpm_position"] = cmd_reset_wpm_position,
		["show_typing"]    = cmd_show_typing,
		["show_apps"]      = cmd_show_apps,
		["wpm_menubar"]    = cmd_wpm_menubar,
		["menubar_colors"] = cmd_menubar_colors,
	}

	local menu = ManifestMenu.build("metrics_menu", "Metrics", dyn_handlers, nil, render_ctx, list_providers)

	return {
		label   = i18n.get("menu.metrics.title"),
		checked = state.keylogger_enabled,
		action  = function()
			if not state.keylogger_enabled then
				local res = dialog.block_alert(
					i18n.get("dialog.metrics.security_warning_title"),
					i18n.get("dialog.metrics.security_warning_body"),
					i18n.get("button.activate"), i18n.get("button.cancel"), "warning")
				if res ~= i18n.get("button.activate") then return end
			end

			local desired_enabled = not state.keylogger_enabled
			local ok_kl, Keylogger = pcall(require, "modules.keylogger")
			if not ok_kl then Keylogger = nil end
			local lifecycle_method = desired_enabled and "start" or "stop"
			if type(Keylogger) ~= "table" or type(Keylogger[lifecycle_method]) ~= "function" then
				-- Validate the security lifecycle capability before publishing either
				-- memory or disk. In particular, OFF without a stop boundary would leave
				-- key capture active behind an unchecked menu item.
				Logger.error(LOG, "Metrics %s is unavailable; state remains unchanged.",
					lifecycle_method)
				updateMenu()
				return false
			end

			state.keylogger_enabled = desired_enabled
			if save_prefs() ~= true then return false end

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
				local start_ok, started = pcall(Keylogger.start, script_control)
				if not start_ok or started ~= true then
					-- The preference was published before runtime activation. Compensate
					-- transactionally so the checkmark cannot claim Metrics is active while
					-- its security-context watcher (and therefore the engine) is absent.
					state.keylogger_enabled = false
					local rollback_saved = save_prefs() == true
					state.keylogger_enabled = false
					Logger.error(LOG, "Metrics activation was rejected; disabled rollback persisted=%s.",
						tostring(rollback_saved))
					if WpmMenubar then
						call_wpm_lifecycle("WPM menubar", WpmMenubar, "stop")
					end
					if WpmWidget then call_wpm_lifecycle("WPM widget", WpmWidget, "stop") end
					updateMenu()
					return false
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
				local wpm_committed = true
				if state.keylogger_menubar_wpm and not paused_now() then
					if not call_wpm_lifecycle("WPM menubar", WpmMenubar, "start") then
						compensate_rejected_wpm_start("keylogger_menubar_wpm", "WPM menubar")
						wpm_committed = false
					end
				end
				if state.keylogger_float_wpm and not paused_now() then
					if not call_wpm_lifecycle("WPM widget", WpmWidget, "start",
						state.keylogger_float_graph) then
						compensate_rejected_wpm_start("keylogger_float_wpm", "WPM widget")
						wpm_committed = false
					end
				end
				if not wpm_committed then
					updateMenu()
					return false
				end
			else
				local runtime_settled = true
				local stop_ok, stopped = pcall(Keylogger.stop)
				if not stop_ok or stopped ~= true then
					Logger.error(LOG, "Metrics is disabled, but native keylogger cleanup remains pending.")
					runtime_settled = false
				end
				if not call_wpm_lifecycle("WPM menubar", WpmMenubar, "stop") then
					runtime_settled = false
				end
				if not call_wpm_lifecycle("WPM widget", WpmWidget, "stop") then
					runtime_settled = false
				end
				if not runtime_settled then
					updateMenu()
					return false
				end
			end

			updateMenu()
			return true
		end,
		menu = menu,
	}
end

return M

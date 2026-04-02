--- modules/keylogger/init.lua

--- ==============================================================================
--- MODULE: Core Keylogger Engine
--- DESCRIPTION:
--- This is the low-level event tap daemon responsible for intercepting, measuring,
--- and aggregating human keystrokes globally across the operating system.
---
--- FEATURES & RATIONALE:
--- 1. Precision Profiling: Captures the exact millisecond delay between keys.
--- 2. Zero-Lag Architecture: Lazy loads metrics UI using daily fragments.
--- 3. Accurate Synthetic Tracking: Synchronizes backspaces and text for net metrics.
--- ==============================================================================

local M = {}

local hs   = hs
local utf8 = utf8
local Logger = require("lib.logger")

local LogManager     = require("modules.keylogger.log_manager")
local ContextTracker = require("modules.keylogger.context_tracker")
local LOG = "keylogger"





-- ===================================
-- ===================================
-- ======= 1/ Default State ==========
-- ===================================
-- ===================================

M.DEFAULT_STATE = {
	keylogger_enabled       = false,
	keylogger_disabled_apps = {},
	keylogger_encrypt       = false,
	keylogger_menubar_wpm   = false,
	keylogger_menubar_colors = true,
	keylogger_float_wpm     = false,
	keylogger_float_graph   = false,
	keylogger_float_colors  = true,
}





-- ====================================
-- ====================================
-- ======= 2/ Constants And State =====
-- ====================================
-- ====================================

-- Central memory struct passed via reference to all sub-modules
local CoreState = {
	LOG_DIR                = hs.configdir .. "/logs",
	options                = { encrypt = false },
	is_enabled             = false,
	
	buffer_events          = {},
	buffer_text            = "",
	last_time              = 0,
	synth_queue            = {},
	pending_keyup          = {},
	rich_chunks            = {},
	
	last_flush_time        = hs.timer.absoluteTime() / 1000000,
	current_session_pause  = 0,
	session_chars          = 0,
	session_time_ms        = 0,
	session_start_time     = 0,
	session_last_active    = 0,
	
	recent_typing          = {},
	last_source_type       = "none",
	last_source_variant    = "none",
	last_source_time       = 0,
	
	session_app_name       = "Unknown",
	session_win_title      = "Unknown",
	session_url            = nil,
	session_field_role     = "Unknown",
	session_layout         = "Unknown",
	
	disabled_apps          = {},
	active_app_bundle      = nil,
	active_app_path        = nil,
	active_app_pid         = nil,
	is_private_window      = false,
	
	ax_observer            = nil,
	
	today_idx              = {},
	manifest               = {},
}

-- Hardware identifier cache
local _mac_serial = nil

CoreState.get_mac_serial = function()
	if _mac_serial then return _mac_serial end
	
	local serial = hs.execute("ioreg -l | grep IOPlatformSerialNumber | sed 's/.*= \"//;s/\"//'")
	if serial and serial ~= "" and not serial:find("UNKNOWN") then 
		_mac_serial = serial:gsub("%s+", "")
		return _mac_serial
	end
	
	local profiler = hs.execute("system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}'")
	if profiler and profiler ~= "" then
		_mac_serial = profiler:gsub("%s+", "")
		return _mac_serial
	end

	local uuid = hs.execute("ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformUUID' | sed 's/.*= \"//;s/\"//'")
	if uuid and uuid ~= "" then
		_mac_serial = uuid:gsub("%s+", "")
		return _mac_serial
	end

	return "ERGOPTI_FALLBACK_KEY"
end

-- Mount dependencies
LogManager.init(CoreState)
ContextTracker.init(CoreState, LogManager)

local _tap                = nil
local _script_control     = nil
local _idle_timer         = nil
local _maintenance_timer  = nil
local _app_watcher        = nil
local _win_filter         = nil
local _current_day        = os.date("%Y_%m_%d")

local MODIFIER_KEYCODES = {
	[54] = true,
	[55] = true,
	[56] = true,
	[57] = true,
	[58] = true,
	[59] = true,
	[60] = true,
	[61] = true,
	[62] = true,
	[63] = true,
}

local MODIFIER_ORDER = { "cmd", "ctrl", "alt", "shift", "fn" }
local MODIFIER_LABELS = { cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn" }
local KEY_LABELS = {
	[36] = "Enter",
	[48] = "Tab",
	[49] = "Space",
	[51] = "Backspace",
	[53] = "Escape",
	[123] = "Left",
	[124] = "Right",
	[125] = "Down",
	[126] = "Up",
}
local _keycode_to_name = nil

local function get_keycode_name_map()
	if _keycode_to_name then return _keycode_to_name end

	_keycode_to_name = {}
	for name, code in pairs(hs.keycodes.map or {}) do
		if type(name) == "string" and type(code) == "number" and not _keycode_to_name[code] then
			_keycode_to_name[code] = name
		end
	end

	return _keycode_to_name
end

local function normalize_key_name(name)
	if type(name) ~= "string" or name == "" then return nil end
	if #name == 1 then return string.upper(name) end
	return name:sub(1, 1):upper() .. name:sub(2)
end

local function is_shortcut_candidate(flags, keycode)
	if MODIFIER_KEYCODES[keycode] then return false end

	local has_cmd = flags.cmd or false
	local has_ctrl = flags.ctrl or false
	local has_alt = flags.alt or false
	local has_fn = flags.fn or false

	if not (has_cmd or has_ctrl or has_alt or has_fn) then return false end

	-- Option alone, or Shift+Option, are symbol layers and should not be counted as shortcuts
	if has_alt and not (has_cmd or has_ctrl or has_fn) then return false end

	return true
end

local function build_shortcut_key(event_obj, flags, keycode)
	local parts = {}
	for _, mod in ipairs(MODIFIER_ORDER) do
		if flags[mod] then table.insert(parts, MODIFIER_LABELS[mod]) end
	end

	local key_label = KEY_LABELS[keycode]
	if not key_label then
		local chars = event_obj:getCharacters(true) or event_obj:getCharacters(false) or ""
		if chars ~= "" and not chars:match("[%z\1-\31\127]") then
			key_label = normalize_key_name(chars)
		else
			key_label = normalize_key_name(get_keycode_name_map()[keycode]) or ("Keycode " .. tostring(keycode))
		end
	end

	table.insert(parts, key_label)
	return table.concat(parts, "+")
end





-- =====================================
-- =====================================
-- ======= 3/ Event Interception =======
-- =====================================
-- =====================================

--- Main eventtap listener callback.
--- @param event_obj table Event object.
--- @return boolean True to swallow, false to propagate.
local function handle_key(event_obj)
	local ok, err = pcall(function()
		if not CoreState.is_enabled then return end
		if CoreState.is_private_window then return end
		
		if CoreState.disabled_apps and #CoreState.disabled_apps > 0 then
			for _, d_app in ipairs(CoreState.disabled_apps) do
				if (d_app.bundleID and d_app.bundleID == CoreState.active_app_bundle) or 
				   (d_app.appPath and d_app.appPath == CoreState.active_app_path) then return end
			end
		end

		local evt_type = event_obj:getType()
		local now = hs.timer.absoluteTime() / 1000000

		if evt_type == hs.eventtap.event.types.leftMouseDown or 
		   evt_type == hs.eventtap.event.types.rightMouseDown or 
		   evt_type == hs.eventtap.event.types.scrollWheel or 
		   evt_type == hs.eventtap.event.types.mouseMoved then
			if #CoreState.buffer_events > 0 then
				LogManager.flush_buffer()
			end
			return false
		end
		
		if evt_type == hs.eventtap.event.types.keyUp then
			local keycode = event_obj:getKeyCode()
			if CoreState.pending_keyup[keycode] then
				CoreState.pending_keyup[keycode].event[3].h = math.floor(now - CoreState.pending_keyup[keycode].down_time)
				CoreState.pending_keyup[keycode] = nil
			end
			return
		end

		if evt_type ~= hs.eventtap.event.types.keyDown then return end

		if _script_control and type(_script_control.is_paused) == "function" and _script_control.is_paused() then
			LogManager.flush_buffer()
			return
		end

		local flags = event_obj:getFlags() or {}
		local keycode = event_obj:getKeyCode()

		-- Shortcut detection runs FIRST — before any early-exit that would silently
		-- drop candidates like Cmd+A (keycode 0). Shortcuts bypass the typing buffer
		-- entirely and are persisted immediately via a dedicated log entry.
		if is_shortcut_candidate(flags, keycode) then
			LogManager.flush_buffer()
			local app_sc = hs.application.frontmostApplication()
			LogManager.log_shortcut(build_shortcut_key(event_obj, flags, keycode), app_sc and app_sc:title() or "Unknown")
			return false
		end

		-- F1-F12 keys, Escape, Modifiers etc. flush the buffer to ensure continuous tracking across window switches
		if keycode >= 96 and keycode <= 122 then
			LogManager.flush_buffer()
			return false
		end

		if flags.cmd and keycode == 0 then LogManager.flush_buffer(); return end
		if flags.shift and (keycode >= 123 and keycode <= 126) then LogManager.flush_buffer(); return end

		local chars = event_obj:getCharacters(true)
		if keycode ~= 51 and keycode ~= 48 and keycode ~= 36 and keycode ~= 53 then
			if not chars or chars == "" then return end
			if chars:match("[%z\1-\31\127]") then return end
			for _, code in utf8.codes(chars) do if code >= 0xF700 and code <= 0xF8FF then return end end
		end

		local delay = CoreState.last_time > 0 and math.floor(now - CoreState.last_time) or 0
		CoreState.last_time = now

		if CoreState.session_start_time == 0 then
			CoreState.session_start_time = now
			LogManager.append_log({ type = "session_start" })
		end
		
		if #CoreState.buffer_events == 0 then
			CoreState.current_session_pause = math.floor(now - CoreState.last_flush_time)
			local app = hs.application.frontmostApplication()
			CoreState.session_app_name = app and app:title() or "Unknown"
			local win = app and app:mainWindow()
			CoreState.session_win_title = win and win:title() or "Unknown"
			CoreState.session_layout = hs.keycodes.currentLayout()
			CoreState.session_field_role = "Unknown"
			CoreState.session_url = nil
			local is_secure_field = false

			hs.timer.doAfter(0, function()
				local ok_sys, sys = pcall(hs.axuielement.systemWideElement)
				if ok_sys and sys then
					local focused = sys:attributeValue("AXFocusedUIElement")
					if focused then
						local role = focused:attributeValue("AXRole")
						local subrole = focused:attributeValue("AXSubrole")
						CoreState.session_field_role = (subrole and subrole ~= "") and subrole or role
						if role == "AXSecureTextField" or subrole == "AXSecureTextField" then
							is_secure_field = true
							CoreState.buffer_events = {}; CoreState.buffer_text = ""; CoreState.rich_chunks = {}
						end
					end
				end
				
				if not is_secure_field then
					local script = ""
					if CoreState.session_app_name == "Safari" then script = "tell application \"Safari\" to return URL of front document"
					elseif CoreState.session_app_name == "Google Chrome" or CoreState.session_app_name == "Brave Browser" or CoreState.session_app_name == "Microsoft Edge" or CoreState.session_app_name == "Arc" then
						script = "tell application \"" .. CoreState.session_app_name .. "\" to return URL of active tab of front window"
					end
					if script ~= "" then
						pcall(hs.osascript.applescript, script, function(succ, res) if succ and type(res) == "string" then CoreState.session_url = res end end)
					end
				end
			end)
		end

		if is_secure_field then return end

		local raw_chars = event_obj:getCharacters(false) or chars
		local is_synth = false
		local synth_type = "none"
		local is_dead_key = false
		local is_composed = false

		if keycode == 51 then
			if #CoreState.synth_queue > 0 and CoreState.synth_queue[1].char == "[BS]" then
				is_synth = true
				synth_type = CoreState.synth_queue[1].type
				table.remove(CoreState.synth_queue, 1)
			end
		else
			if #CoreState.synth_queue > 0 then
				local next_synth = CoreState.synth_queue[1]
				if raw_chars == next_synth.char then
					is_synth = true; synth_type = next_synth.type; table.remove(CoreState.synth_queue, 1)
				elseif delay < 3 then
					is_synth = true; synth_type = next_synth.type
				end
			end
		end

		-- Only count real (non-synthetic) non-BS chars: they represent effective net output
		if not is_synth and keycode ~= 51 then
			table.insert(CoreState.recent_typing, now)
		end
		CoreState.session_last_active = now
		
		if not is_synth then
			if keycode ~= 51 and keycode ~= 48 and keycode ~= 36 and keycode ~= 53 then
				local raw = event_obj:getCharacters(false) or ""
				local cooked = event_obj:getCharacters(true) or ""
				
				if cooked == "" and raw ~= "" then
					is_dead_key = true
					chars = raw
				elseif cooked ~= raw and #cooked > 0 then
					is_composed = true
				end
			end
		end

		local mods = {}
		for k, v in pairs(flags) do if v and k ~= "capslock" then table.insert(mods, k) end end
		table.sort(mods)

		local ok_km, keymap_mod = pcall(require, "modules.keymap")
		local shift_side = flags.capslock and "capslock" or ((ok_km and type(keymap_mod.get_shift_side) == "function") and keymap_mod.get_shift_side() or "none")
		local meta = { s = is_synth, st = synth_type, c = flags.capslock or false, ss = shift_side, r = raw_chars, m = table.concat(mods, ","), h = 0, d = delay, dk = is_dead_key, cp = is_composed }

		local ev_entry = nil

		if keycode == 51 then
			-- A real BS erases a char previously counted as effective output
			if not is_synth and #CoreState.recent_typing > 0 then table.remove(CoreState.recent_typing) end
			local deleted_char = ""
			if not is_synth and #CoreState.buffer_text > 0 then
				local last_char_pos = utf8.offset(CoreState.buffer_text, -1)
				if last_char_pos then
					deleted_char = string.sub(CoreState.buffer_text, last_char_pos)
					CoreState.buffer_text = string.sub(CoreState.buffer_text, 1, last_char_pos - 1)
				end
			end
			ev_entry = {"[BS]", delay, meta}
			table.insert(CoreState.buffer_events, ev_entry)
			if not is_synth and deleted_char ~= "" then table.insert(CoreState.rich_chunks, { type = "correction", text = deleted_char }) end
		elseif keycode == 48 or keycode == 53 then LogManager.flush_buffer()
		elseif keycode == 36 then
			CoreState.buffer_text = CoreState.buffer_text .. "\n"
			ev_entry = {"\n", delay, meta}; table.insert(CoreState.buffer_events, ev_entry)
			table.insert(CoreState.rich_chunks, { type = is_synth and synth_type or "text", text = "\n" })
			LogManager.flush_buffer()
		else
			local typed_char = chars or ""
			if not is_synth then CoreState.buffer_text = CoreState.buffer_text .. typed_char end
			ev_entry = {typed_char, delay, meta}; table.insert(CoreState.buffer_events, ev_entry)
			table.insert(CoreState.rich_chunks, { type = is_synth and synth_type or "text", text = typed_char })
			if typed_char:match("[.?!]") then LogManager.flush_buffer() end
		end

		if ev_entry then CoreState.pending_keyup[keycode] = { down_time = now, event = ev_entry } end

		-- Metrics webview requires near-real-time updates: flush each key so the
		-- table reflects typed characters immediately (including search field typing).
		local title = CoreState.session_win_title or ""
		if CoreState.session_app_name == "Hammerspoon" and (title:find("Métriques", 1, true) or title:find("Metrics", 1, true)) then
			LogManager.flush_buffer()
		end
	end)
	
	if not ok then Logger.warn(LOG, "Évitement verrouillage clavier: %s", tostring(err)) end
	return false
end





-- ==================================
-- ==================================
-- ======= 4/ Public Core API =======
-- ==================================
-- ==================================

--- Configures the keylogger global constraints.
--- @param opts table The options dictionary.
function M.set_options(opts)
	CoreState.options = opts or {}
end

--- Replaces the current disabled app list.
--- @param apps table The array of app bundles.
function M.set_disabled_apps(apps) CoreState.disabled_apps = type(apps) == "table" and apps or {} end

--- Injects simulated strings into the tracking buffer.
--- @param text string The payload.
function M.set_buffer(text) CoreState.buffer_text = type(text) == "string" and text or "" end

--- Queues synthetic characters to be marked distinctly in logs.
--- @param text string The synthetic text.
--- @param source_type string Origin identifier.
--- @param deletes number Quantity of backspaces issued before the text.
--- @param source_variant string|nil Optional source variant for UI coloring.
function M.notify_synthetic(text, source_type, deletes, source_variant)
	if deletes and deletes > 0 then
		for i = 1, deletes do
			table.insert(CoreState.synth_queue, { char = "[BS]", type = source_type })
		end
		-- Debit the trigger chars that were previously counted as effective output
		for i = 1, deletes do
			if #CoreState.recent_typing > 0 then table.remove(CoreState.recent_typing) end
		end
	end

	if text and text ~= "" then
		for _, code in utf8.codes(text) do
			table.insert(CoreState.synth_queue, { char = utf8.char(code), type = source_type })
		end
		-- Credit the output chars to the effective MPM counter
		local now_ms = hs.timer.absoluteTime() / 1000000
		local out_len = utf8.len(text) or 0
		for i = 1, out_len do
			table.insert(CoreState.recent_typing, now_ms)
		end
	end
	
	CoreState.last_source_type = source_type
	CoreState.last_source_variant = type(source_variant) == "string" and source_variant or source_type
	CoreState.last_source_time = hs.timer.absoluteTime() / 1000000000
end

--- Extracts the rolling array to compute current Words-Per-Minute immediately.
--- @return table Dictionary with `wpm` integer property.
function M.get_live_stats()
	local now = hs.timer.absoluteTime() / 1000000
	while #CoreState.recent_typing > 0 and (now - CoreState.recent_typing[1]) > 15000 do
		table.remove(CoreState.recent_typing, 1)
	end
	
	local is_idle = (CoreState.session_last_active == 0) or ((now - CoreState.session_last_active) > 5000)
	local display_wpm = 0
	
	if not is_idle and #CoreState.recent_typing > 1 then
		local duration_ms = now - CoreState.recent_typing[1]
		if duration_ms < 2000 then duration_ms = 2000 end
		display_wpm = math.floor(((#CoreState.recent_typing / 5) / (duration_ms / 60000)) + 0.5)
	end
	
	return { 
		wpm = display_wpm, 
		source = CoreState.last_source_type, 
		source_variant = CoreState.last_source_variant,
		source_time = CoreState.last_source_time 
	}
end

--- Cleans up sessions if typing is abandoned for a while.
local function check_idle()
	local now = hs.timer.absoluteTime() / 1000000
	if CoreState.session_last_active > 0 and (now - CoreState.session_last_active) > (5 * 60 * 1000) then
		if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end
		LogManager.append_log({ type = "session_end", duration_ms = CoreState.session_last_active - CoreState.session_start_time })
		CoreState.session_last_active = 0; CoreState.session_start_time = 0
	end
end

--- Routinely verifies log rotations to keep disk clean without blocking UI.
local function perform_maintenance()
	local today = os.date("%Y_%m_%d")
	if _current_day ~= today then
		LogManager.flush_buffer()
		LogManager.save_today_index()
		CoreState.today_idx = {}
		_current_day = today
		LogManager.ensure_dir_and_rotate()
	end
end

--- Boots up the engine and background daemons.
--- @param script_control table Module to allow pauses.
function M.start(script_control)
	_script_control = script_control
	if not CoreState.is_enabled then
		CoreState.is_enabled = true
		LogManager.rebuild_index_if_needed()
		LogManager.ensure_dir_and_rotate()
		CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000

		if not _app_watcher then _app_watcher = hs.application.watcher.new(ContextTracker.app_watcher_cb) end
		_app_watcher:start()

		if not _win_filter then
			local target_browsers = { "Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser", "Arc", "Opera", "Vivaldi" }
			_win_filter = hs.window.filter.new(target_browsers)
			_win_filter:subscribe({ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged }, ContextTracker.update_private_status)
		end
		ContextTracker.update_private_status()

		if not _tap then 
			_tap = hs.eventtap.new({ 
				hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp, 
				hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown,
				hs.eventtap.event.types.scrollWheel, hs.eventtap.event.types.mouseMoved
			}, handle_key) 
		end
		_tap:start()

		if not _idle_timer then _idle_timer = hs.timer.new(60, check_idle) end
		_idle_timer:start()

		if not _maintenance_timer then _maintenance_timer = hs.timer.new(1.0, perform_maintenance) end
		_maintenance_timer:start()
		
		local current_app = hs.application.frontmostApplication()
		if current_app then ContextTracker.update_ax_observer(current_app:pid()) end
	end
end

--- Halts tracking and clears all visual elements.
function M.stop()
	if CoreState.is_enabled then
		CoreState.is_enabled = false
		LogManager.flush_buffer()
		if _tap then _tap:stop() end
		if _app_watcher then _app_watcher:stop() end
		if _win_filter then _win_filter:unsubscribeAll() end
		if _idle_timer then _idle_timer:stop() end
		if _maintenance_timer then _maintenance_timer:stop() end
		if CoreState.ax_observer then CoreState.ax_observer:stop(); CoreState.ax_observer = nil end
	end
end

--- Captures shortcut expansion cleanly.
--- @param trigger string Sequence trigger.
--- @param replacement string Resulting string.
function M.log_hotstring(trigger, replacement)
	if not CoreState.is_enabled then return end
	LogManager.flush_buffer()
	LogManager.append_log({ type = "hotstring", app = CoreState.session_app_name, trigger = trigger, replacement = replacement, tag = "<hotstring>" .. replacement .. "</hotstring>" })
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Captures LLM generations.
--- @param context string Previous words.
--- @param results table Options generated.
function M.log_llm(context, results)
	if not CoreState.is_enabled then return end
	LogManager.flush_buffer()
	local preds = {}
	for _, r in ipairs(results or {}) do table.insert(preds, r.to_type) end
	LogManager.append_log({ type = "llm_generation", app = CoreState.session_app_name, context = context, predictions = preds, tag = "<llm_generated>" .. (preds[1] or "") .. "</llm_generated>" })
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Persists a shortcut trigger immediately (used by modules.shortcuts bindings).
--- @param shortcut_key string Canonical label (e.g. "Ctrl+S").
--- @param app_name string Frontmost application name.
function M.log_shortcut(shortcut_key, app_name)
	LogManager.log_shortcut(shortcut_key, app_name or CoreState.session_app_name)
end

--- Logs that a Hotstring was proposed to the user but not necessarily executed.
function M.log_hotstring_suggested()
	if not CoreState.is_enabled then return end
	LogManager.append_log({ type = "hotstring_suggested", app = CoreState.session_app_name })
	LogManager.increment_manifest_stat(CoreState.session_app_name, "hs_suggested")
end

--- Logs that an LLM string was proposed to the user.
function M.log_llm_suggested()
	if not CoreState.is_enabled then return end
	LogManager.increment_manifest_stat(CoreState.session_app_name, "llm_suggested")
end

--- Triggers the massive HTML interface metrics canvas.
function M.show_metrics()
	local ok, metrics_ui = pcall(require, "ui.metrics")
	if not ok or type(metrics_ui) ~= "table" or type(metrics_ui.show) ~= "function" then
		local ok2, explicit_ui = pcall(require, "ui.metrics.init")
		if ok2 and type(explicit_ui) == "table" and type(explicit_ui.show) == "function" then metrics_ui = explicit_ui; ok = true end
	end
	if ok and type(metrics_ui) == "table" and type(metrics_ui.show) == "function" then
		metrics_ui.show(CoreState.LOG_DIR)
	else
		local err_msg = tostring(metrics_ui)
		hs.dialog.blockAlert("Erreur Keylogger", "Impossible de charger l’interface des métriques.\n\nVérifiez ui/metrics/init.lua.\nDétails :\n" .. err_msg, "OK")
	end
end

return M

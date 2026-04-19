--- modules/keylogger/init.lua

--- ==============================================================================
--- MODULE: Core Keylogger Engine
--- DESCRIPTION:
--- Low-level event tap daemon responsible for intercepting, measuring, and
--- routing human keystroke events globally across the operating system.
--- Drives the context tracker and log manager sub-modules.
---
--- FEATURES & RATIONALE:
--- 1. Precision Profiling: Records the exact millisecond delay between keys.
--- 2. Secure Field Guard: Delegates secure-field detection to the AX observer
---    in context_tracker, then checks a persistent flag on every keystroke
---    instead of the previous broken async-local approach.
--- 3. Synthetic Typing: Differentiates keyboard-expander output from human
---    keystrokes so N-gram stats reflect actual typing patterns.
--- 4. Active Time Tracking: Records app focus, micro-idles, and sleep cycles.
--- 5. Hardware Context: Captures battery level, audio volume, mouse distance,
---    WiFi state, and system load alongside keystroke data.
--- ==============================================================================

local M = {}

local hs     = hs
local utf8   = utf8
local Logger = require("lib.logger")

local LogManager     = require("modules.keylogger.log_manager")
local ContextTracker = require("modules.keylogger.context_tracker")
local LOG            = "keylogger"




-- ================================
-- ================================
-- ======= 1/ Constants =======
-- ================================
-- ================================

-- Typing session idle threshold before a "micro-idle" event is logged (30 s)
local MICRO_IDLE_TIMEOUT_MS      = 30 * 1000
-- Typing session idle threshold before the session is considered fully ended (5 min)
local SESSION_TIMEOUT_MS         = 5 * 60 * 1000
-- Rolling window used to compute live WPM (15 s)
local WPM_WINDOW_MS              = 15 * 1000
-- Minimum time window for WPM calculation to avoid division by near-zero (2 s)
local WPM_MIN_DURATION_MS        = 2000
-- How often the idle check and mouse-distance poll run (seconds)
local IDLE_CHECK_INTERVAL_SEC    = 10
-- How often the maintenance timer fires for day-rotation and mouse polling (seconds)
local MAINTENANCE_INTERVAL_SEC   = 5
-- Minimum gap between system-load polls to avoid spawning top too often (5 min)
local SYSTEM_LOAD_POLL_INTERVAL_MS = 5 * 60 * 1000
-- Delay before synthetic input is considered a match (very fast = synthetic)
local SYNTH_MATCH_DELAY_MS       = 3
-- Flush the buffer after this many milliseconds of inactivity (2 min)
local AUTO_FLUSH_IDLE_MS         = 2 * 60 * 1000

-- Keycodes for all modifier keys (these should not be logged as characters)
local MODIFIER_KEYCODES = {
	[54] = true, [55] = true, [56] = true, [57] = true,
	[58] = true, [59] = true, [60] = true, [61] = true,
	[62] = true, [63] = true,
}

-- Canonical ordering of modifier labels in shortcut strings
local MODIFIER_ORDER  = { "cmd", "ctrl", "alt", "shift", "fn" }
local MODIFIER_LABELS = { cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn" }

-- Human-readable labels for special keycodes (used by build_shortcut_key)
local SPECIAL_KEY_LABELS = {
	[36]  = "Enter",     [48]  = "Tab",      [49]  = "Space",
	[51]  = "Backspace", [53]  = "Escape",
	[123] = "Left",      [124] = "Right",    [125] = "Down",     [126] = "Up",
	[117] = "Delete",    [115] = "Home",     [119] = "End",
	[116] = "PageUp",    [121] = "PageDown",
	[122] = "F1",  [120] = "F2",  [99]  = "F3",  [118] = "F4",
	[96]  = "F5",  [97]  = "F6",  [98]  = "F7",  [100] = "F8",
	[101] = "F9",  [109] = "F10", [103] = "F11", [111] = "F12",
}

-- Keycodes for F1–F12; excluded from the shortcut pipeline when no Cmd or Ctrl
-- modifier is held so that standalone F-key presses log as "[F1]" etc. in the
-- character dict instead of appearing as "Fn+F1" shortcut entries.
local F_KEY_CODES = {
	[122] = "F1",  [120] = "F2",  [99]  = "F3",  [118] = "F4",
	[96]  = "F5",  [97]  = "F6",  [98]  = "F7",  [100] = "F8",
	[101] = "F9",  [109] = "F10", [103] = "F11", [111] = "F12",
}

-- Keycodes for navigation keys (arrows + Delete, Home, End, PageUp, PageDown).
-- These produce no character string from getCharacters(), so they are excluded
-- from the early-return guard and logged explicitly as bracket markers so they
-- appear in the characters tab and participate in n-gram tracking.
local NAV_KEY_CODES = {
	[123] = "LEFT",  [124] = "RIGHT",  [125] = "DOWN",  [126] = "UP",
	[117] = "DELETE",  [115] = "HOME",  [119] = "END",
	[116] = "PAGEUP",  [121] = "PAGEDOWN",
}

-- System processes that handle OS-level authentication prompts.
-- Keystrokes in these processes must never be logged regardless of any other setting —
-- the secure_field filter is a belt-and-suspenders complement (AX observer may attach too
-- slowly to catch the very first keystrokes in a short-lived SecurityAgent window).
local SYSTEM_AUTH_BUNDLE_IDS = {
	["com.apple.SecurityAgent"] = true,  -- Admin/sudo password dialog
	["com.apple.CoreAuthUI"]    = true,  -- Touch ID and biometric auth UI
}




-- ================================
-- ================================
-- ======= 2/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	keylogger_enabled                = false,
	keylogger_disabled_apps          = {},
	keylogger_encrypt                = false,
	keylogger_menubar_wpm            = false,
	keylogger_menubar_colors         = true,
	keylogger_float_wpm              = false,
	keylogger_float_graph            = false,
	keylogger_float_colors           = true,
	keylogger_private_filter_enabled      = true,
	keylogger_secure_filter_enabled       = true,
	keylogger_system_auth_filter_enabled  = true,
}




-- ===========================================
-- ===========================================
-- ======= 3/ Core State And Lifecycle =======
-- ===========================================
-- ===========================================

--- Central shared-state table passed by reference to all sub-modules.
--- Fields are grouped by concern for readability.
local CoreState = {
	-- Paths
	LOG_DIR = hs.configdir .. "/logs",

	-- Enablement
	options    = { encrypt = false },
	is_enabled = false,

	-- Keystroke buffer (flushed at sentence boundaries / context switches)
	buffer_events         = {},
	buffer_text           = "",
	rich_chunks           = {},
	last_time             = 0,       -- ms timestamp of the previous keystroke
	synth_queue           = {},      -- queue of expected synthetic characters
	pending_keyup         = {},      -- maps keycode → {down_time, event_ref} for hold-time

	-- Session timing and productivity
	last_flush_time       = hs.timer.absoluteTime() / 1000000,
	current_session_pause = 0,
	session_start_time    = 0,
	session_last_active   = 0,
	is_micro_idle         = false,

	-- Mouse and environment
	session_mouse_clicks  = 0,
	session_mouse_scrolls = 0,
	mouse_distance_px     = 0,
	last_mouse_pos        = nil,
	in_meeting            = false,

	-- Rolling WPM buffers (timestamps of recent keystrokes)
	recent_typing_eff     = {},  -- includes synthetic characters
	recent_typing_phys    = {},  -- physical keystrokes only

	-- Last autocomplete source (for the WPM overlay)
	last_source_type      = "none",
	last_source_variant   = "none",
	last_source_time      = 0,

	-- Session context (captured at buffer-start)
	session_app_name      = "Unknown",
	session_win_title     = "Unknown",
	session_url           = nil,
	session_field_role    = "Unknown",
	session_layout        = "Unknown",
	session_document_path = nil,
	is_fullscreen         = false,

	-- App tracking (updated by context_tracker)
	disabled_apps                = {},
	active_app_name              = nil,
	active_app_start             = nil,
	active_app_bundle            = nil,
	active_app_path              = nil,
	active_app_pid               = nil,
	is_private_window            = false,
	-- Whether privacy context detection filters are active (user-configurable)
	private_filter_enabled            = true,
	secure_field_filter_enabled       = true,
	system_auth_filter_enabled        = true,

	-- Secure field flag: set by context_tracker's AX observer
	is_secure_field              = false,

	-- Hardware snapshots (updated by sensor pollers)
	current_battery_level = nil,
	current_audio_volume  = nil,

	-- Accessibility observer (managed by context_tracker)
	ax_observer           = nil,

	-- Aggregated data (shared with log_manager)
	today_idx             = {},
	manifest              = {},
	ngram_context         = nil,
}

-- Wire sub-modules to the shared state immediately at load time
LogManager.init(CoreState)
ContextTracker.init(CoreState, LogManager)

-- Watcher and timer handles
local _event_tap            = nil
local _script_control       = nil
local _idle_timer           = nil
local _maintenance_timer    = nil
local _app_watcher          = nil
local _win_filter           = nil
local _caffeinate_watcher   = nil
local _wifi_watcher         = nil
local _battery_watcher      = nil
local _spaces_watcher       = nil
local _audio_watcher_active = false
local _current_day          = os.date("%Y-%m-%d")

-- Cached module references to avoid pcall(require, ...) on every keystroke
local _keymap_mod = nil

-- Throttle for the expensive system-load poll
local _last_system_load_poll_ms = 0

-- Lazily built keycode → name mapping
local _keycode_to_name = nil




-- ==========================================
-- ==========================================
-- ======= 4/ Key Event Helper Utilities =======
-- ==========================================
-- ==========================================

--- Builds a keycode → name lookup table from hs.keycodes.map.
--- Lazy: only computed once on first use.
--- @return table The keycode → name mapping.
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

--- Normalizes a raw key name into a display-friendly format.
--- @param name string The raw key string from hs.keycodes.
--- @return string|nil The normalized name, or nil if input is invalid.
local function normalize_key_name(name)
	if type(name) ~= "string" or name == "" then return nil end
	if #name == 1 then return string.upper(name) end
	return name:sub(1, 1):upper() .. name:sub(2)
end

--- Returns true when the modifier+keycode combination represents a shortcut
--- that should be indexed separately rather than as a typed character.
--- AltGr (Ctrl+Alt) is intentionally excluded — it is a typing layer on
--- international keyboards and should flow through as a normal character.
--- F-keys without Cmd or Ctrl are also excluded: they are logged as bracket
--- markers ("[F1]" etc.) rather than as "Fn+F1" shortcut entries.
--- @param flags table The modifier flags from the key event.
--- @param keycode number The raw keycode.
--- @return boolean True when this event is a shortcut candidate.
local function is_shortcut_candidate(flags, keycode)
	if MODIFIER_KEYCODES[keycode] then return false end
	-- Nav keys (arrows, Home, End…) are never shortcuts — always recorded as bracket markers
	if NAV_KEY_CODES[keycode] then return false end
	-- F-keys pressed with only the fn modifier are character events, not shortcuts
	if F_KEY_CODES[keycode] and not flags.cmd and not flags.ctrl then return false end
	if flags.cmd then return true end
	-- Ctrl alone (not with Alt, to exclude AltGr)
	if flags.ctrl and not flags.alt then return true end
	if flags.fn then return true end
	return false
end

--- Builds a canonical string representation of a shortcut for indexing.
--- Example output: "Cmd+Shift+S", "Ctrl+Z".
--- @param event_obj table The raw hs.eventtap event object.
--- @param flags table The modifier flags.
--- @param keycode number The raw keycode.
--- @return string The formatted shortcut string.
local function build_shortcut_key(event_obj, flags, keycode)
	local parts = {}
	for _, mod in ipairs(MODIFIER_ORDER) do
		if flags[mod] then table.insert(parts, MODIFIER_LABELS[mod]) end
	end

	local key_label = SPECIAL_KEY_LABELS[keycode]
	if not key_label then
		local chars = event_obj:getCharacters(true) or event_obj:getCharacters(false) or ""
		if chars ~= "" and not chars:match("[%z\1-\31\127]") then
			key_label = normalize_key_name(chars)
		else
			key_label = normalize_key_name(get_keycode_name_map()[keycode])
				or ("Keycode " .. tostring(keycode))
		end
	end

	table.insert(parts, key_label)
	return table.concat(parts, "+")
end




-- =======================================
-- =======================================
-- ======= 5/ Event Tap Interceptor =======
-- =======================================
-- =======================================

--- Main eventtap callback. Processes all keyboard and mouse events.
--- Wrapped in pcall to prevent any Lua error from locking the OS keyboard.
--- @param event_obj table The raw hs.eventtap event object.
--- @return boolean False to propagate the event, true to consume it.
local function handle_key(event_obj)
	local ok, err = pcall(function()
		if not CoreState.is_enabled then return end

		-- Fast-path guards: skip private/secure contexts when the respective filter is enabled
		if CoreState.private_filter_enabled and CoreState.is_private_window then return end
		if CoreState.secure_field_filter_enabled and CoreState.is_secure_field then return end
		-- System auth dialogs: belt-and-suspenders guard in case the AX observer attaches too late
		if CoreState.system_auth_filter_enabled and CoreState.active_app_bundle
		and SYSTEM_AUTH_BUNDLE_IDS[CoreState.active_app_bundle] then return end

		-- Check the disabled-apps list
		if CoreState.disabled_apps and #CoreState.disabled_apps > 0 then
			for _, disabled in ipairs(CoreState.disabled_apps) do
				if (disabled.bundleID and disabled.bundleID == CoreState.active_app_bundle)
				or (disabled.appPath  and disabled.appPath  == CoreState.active_app_path) then
					return
				end
			end
		end

		local evt_type = event_obj:getType()
		local now      = hs.timer.absoluteTime() / 1000000

		-- Resume from micro-idle on any activity
		if CoreState.is_micro_idle then
			CoreState.is_micro_idle = false
			LogManager.append_log({
				type        = "idle_end",
				duration_ms = math.max(0, now - (CoreState.session_last_active + MICRO_IDLE_TIMEOUT_MS)),
			})
		end

		-- Mouse events: flush any pending typing context then propagate
		if evt_type == hs.eventtap.event.types.leftMouseDown
		or evt_type == hs.eventtap.event.types.rightMouseDown
		then
			CoreState.session_mouse_clicks = CoreState.session_mouse_clicks + 1
			if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end
			return
		end
		if evt_type == hs.eventtap.event.types.scrollWheel then
			CoreState.session_mouse_scrolls = CoreState.session_mouse_scrolls + 1
			if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end
			return
		end

		-- Key-up: record the hold duration for the corresponding key-down event
		if evt_type == hs.eventtap.event.types.keyUp then
			local keycode = event_obj:getKeyCode()
			local pending = CoreState.pending_keyup[keycode]
			if pending then
				pending.event[3].h = math.floor(now - pending.down_time)
				CoreState.pending_keyup[keycode] = nil
			end
			return
		end

		if evt_type ~= hs.eventtap.event.types.keyDown then return end

		-- If the script control module signals a pause (e.g. during hotstring expansion),
		-- flush and skip — we do not want to interleave expansion events with real typing
		if _script_control
		and type(_script_control.is_paused) == "function"
		and _script_control.is_paused()
		then
			LogManager.flush_buffer()
			return
		end

		local flags   = event_obj:getFlags() or {}
		local keycode = event_obj:getKeyCode()

		-- Shortcuts: flush then log immediately without entering the typing pipeline
		if is_shortcut_candidate(flags, keycode) then
			LogManager.flush_buffer()
			local front_app = hs.application.frontmostApplication()
			LogManager.log_shortcut(
				build_shortcut_key(event_obj, flags, keycode),
				front_app and front_app:title() or "Unknown"
			)
			return
		end

		-- getCharacters(false) returns the actual composed character for the current
		-- keyboard layout; nil/empty means a dead-key that needs another stroke to resolve.
		-- Capslock (57), F-keys, and navigation keys are exceptions: they produce no
		-- character string but are logged explicitly as bracket markers below.
		local chars = event_obj:getCharacters(false)
		if (not chars or chars == "") and keycode ~= 57
		   and not F_KEY_CODES[keycode] and not NAV_KEY_CODES[keycode]
		then return end
		chars = chars or ""

		local delay = CoreState.last_time > 0 and math.floor(now - CoreState.last_time) or 0
		CoreState.last_time = now

		-- Mark session start on the first keystroke after a long idle
		if CoreState.session_start_time == 0 then
			CoreState.session_start_time = now
			LogManager.append_log({ type = "session_start" })
		end

		-- Capture context on the first keystroke of a new buffer
		if #CoreState.buffer_events == 0 then
			CoreState.current_session_pause = math.floor(now - CoreState.last_flush_time)
			local front_app = hs.application.frontmostApplication()
			CoreState.session_app_name = front_app and front_app:title() or "Unknown"
			local main_win = front_app and front_app:mainWindow()
			CoreState.session_win_title = main_win and main_win:title() or "Unknown"
			CoreState.session_layout    = hs.keycodes.currentLayout()
			CoreState.session_field_role = "Unknown"
			CoreState.session_url        = nil
		end

		-- Determine if this keystroke was produced by a synthetic source
		-- (hotstring expansion or LLM completion) by matching against the queue
		local is_synthetic = false
		local synth_type   = "none"

		if keycode == 51 then
			-- Backspace: check if the next queued synthetic char is also a backspace
			if #CoreState.synth_queue > 0 and CoreState.synth_queue[1].char == "[BS]" then
				is_synthetic = true
				synth_type   = CoreState.synth_queue[1].type
				table.remove(CoreState.synth_queue, 1)
			end
		else
			if #CoreState.synth_queue > 0 then
				local next_synth = CoreState.synth_queue[1]
				if chars == next_synth.char then
					-- Exact character match
					is_synthetic = true
					synth_type   = next_synth.type
					table.remove(CoreState.synth_queue, 1)
				elseif delay < SYNTH_MATCH_DELAY_MS then
					-- Extremely fast keystroke — almost certainly synthetic even if char differs
					is_synthetic = true
					synth_type   = next_synth.type
				end
			end
		end

		-- Update rolling WPM buffers (physical typing keystrokes only).
		-- F-keys and navigation keys are excluded: they are not typing characters
		-- and would inflate WPM artificially if counted.
		if not is_synthetic and keycode ~= 51
		   and not F_KEY_CODES[keycode] and not NAV_KEY_CODES[keycode]
		then
			table.insert(CoreState.recent_typing_eff,  now)
			table.insert(CoreState.recent_typing_phys, now)
		end
		CoreState.session_last_active = now

		-- Build modifier and metadata record for this event
		local active_mods = {}
		for k, v in pairs(flags) do
			if v and k ~= "capslock" then table.insert(active_mods, k) end
		end
		table.sort(active_mods)

		local shift_side = flags.capslock and "capslock"
			or (_keymap_mod and type(_keymap_mod.get_shift_side) == "function"
				and _keymap_mod.get_shift_side()
				or "none")

		local meta = {
			s  = is_synthetic,
			st = synth_type,
			c  = flags.capslock or false,
			ss = shift_side,
			r  = chars,
			m  = table.concat(active_mods, ","),
			h  = 0,   -- hold duration — filled in on keyUp
			d  = delay,
			dk = false,
			cp = false,
			kc = keycode,  -- raw virtual keycode for physical-key frequency analysis
		}

		local ev_entry = nil

		if keycode == 51 then
			-- Backspace
			if not is_synthetic and #CoreState.recent_typing_eff > 0 then
				table.remove(CoreState.recent_typing_eff)
			end
			local deleted_char = ""
			if not is_synthetic and #CoreState.buffer_text > 0 then
				local ok_off, last_pos = pcall(utf8.offset, CoreState.buffer_text, -1)
				if ok_off and last_pos then
					deleted_char = string.sub(CoreState.buffer_text, last_pos)
					CoreState.buffer_text = string.sub(CoreState.buffer_text, 1, last_pos - 1)
				end
			end
			ev_entry = { "[BS]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			if not is_synthetic and deleted_char ~= "" then
				table.insert(CoreState.rich_chunks, { type = "correction", text = deleted_char })
			end

		elseif keycode == 48 then
			-- Tab: log as bracket marker and flush (cursor navigation — breaks N-gram context)
			ev_entry = { "[TAB]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			LogManager.flush_buffer()

		elseif keycode == 53 then
			-- Escape: log then flush (cancel/navigation action, breaks N-gram context)
			ev_entry = { "[ESC]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			LogManager.flush_buffer()

		elseif keycode == 57 then
			-- Capslock toggle: log the state change (does not flush — no context break)
			ev_entry = { "[CAPS]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)

		elseif keycode == 36 then
			-- Enter: use bracket marker for n-gram tracking; keep "\n" only in
			-- buffer_text and rich_chunks. The raw "\n" char (LF, code 10) is
			-- stripped by the JS control-character filter, so it must never be
			-- the event key — "[ENTER]" survives the filter and appears in the
			-- characters tab.
			CoreState.buffer_text = CoreState.buffer_text .. "\n"
			ev_entry = { "[ENTER]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			table.insert(CoreState.rich_chunks, {
				type = is_synthetic and synth_type or "text",
				text = "\n",
			})
			LogManager.flush_buffer()

		elseif F_KEY_CODES[keycode] then
			-- F1–F12: log as bracket marker and flush (context-breaking navigation)
			ev_entry = { "[" .. F_KEY_CODES[keycode] .. "]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			LogManager.flush_buffer()

		elseif NAV_KEY_CODES[keycode] then
			-- Arrow keys and extended nav (Delete, Home, End, PageUp, PageDown): log as
			-- bracket marker and flush — cursor moved, so N-gram context is broken
			ev_entry = { "[" .. NAV_KEY_CODES[keycode] .. "]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			LogManager.flush_buffer()

		else
			-- Normal character — a keylayout may map one physical key to a multi-codepoint
			-- string (e.g. Option+A → NNBSP + "?"). Storing the whole string as a single
			-- event key makes it unrecognisable in the chars tab (length ≠ 1) and breaks
			-- bigram token counts. Split into one event per codepoint so each character is
			-- recorded independently. Only the first codepoint carries the real delay; the
			-- rest get 0 because they all originate from the same physical keystroke.
			local ok_len, char_count = pcall(utf8.len, chars)
			if ok_len and char_count and char_count > 1 then
				local first = true
				for _, code in utf8.codes(chars) do
					local sub_char = utf8.char(code)
					local ev_delay = first and delay or 0
					if not is_synthetic then
						CoreState.buffer_text = CoreState.buffer_text .. sub_char
					end
					local sub_entry = { sub_char, ev_delay, meta }
					table.insert(CoreState.buffer_events, sub_entry)
					table.insert(CoreState.rich_chunks, {
						type = is_synthetic and synth_type or "text",
						text = sub_char,
					})
					if sub_char:match("[.?!]") or sub_char == " " then
						LogManager.flush_buffer()
					end
					-- Track only the first sub-char event for keyup matching
					if first then
						ev_entry = sub_entry
						first    = false
					end
				end
			else
				-- Standard single-codepoint path
				if not is_synthetic then
					CoreState.buffer_text = CoreState.buffer_text .. chars
				end
				ev_entry = { chars, delay, meta }
				table.insert(CoreState.buffer_events, ev_entry)
				table.insert(CoreState.rich_chunks, {
					type = is_synthetic and synth_type or "text",
					text = chars,
				})
				-- Flush on sentence-ending punctuation or space
				if chars:match("[.?!]") or keycode == 49 then
					LogManager.flush_buffer()
				end
			end
		end

		if ev_entry then
			CoreState.pending_keyup[keycode] = { down_time = now, event = ev_entry }
		end

		-- Push a live update to the typing metrics UI if its webview is open.
		-- Using package.loaded is a plain table lookup — no pcall overhead per keystroke.
		local metrics_typing = package.loaded["ui.metrics_typing.init"]
		if metrics_typing and metrics_typing._wv ~= nil then
			LogManager.flush_buffer()
		end

	end)

	if not ok then
		-- Log and swallow: we MUST return false to avoid locking the OS keyboard
		Logger.warn(LOG, "Keyboard lock avoidance triggered: %s.", tostring(err))
	end
	return false
end




-- =============================================
-- =============================================
-- ======= 6/ Hardware Watchers And Sensors =======
-- =============================================
-- =============================================

--- Polls mouse position and accumulates the physical travel distance.
--- Called every second via the maintenance timer.
local function poll_mouse_distance()
	local current_pos = hs.mouse.absolutePosition()
	if CoreState.last_mouse_pos then
		local dx   = current_pos.x - CoreState.last_mouse_pos.x
		local dy   = current_pos.y - CoreState.last_mouse_pos.y
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist > 0 then CoreState.mouse_distance_px = CoreState.mouse_distance_px + dist end
	end
	CoreState.last_mouse_pos = current_pos
end

--- Polls CPU usage via `top` and logs it as a system event.
--- Throttled to at most once per SYSTEM_LOAD_POLL_INTERVAL_MS to avoid spawning
--- a subprocess every 10 seconds.
local function poll_system_load()
	local now_ms = hs.timer.absoluteTime() / 1000000
	if (now_ms - _last_system_load_poll_ms) < SYSTEM_LOAD_POLL_INTERVAL_MS then return end
	_last_system_load_poll_ms = now_ms

	pcall(function()
		hs.task.new("/usr/bin/top", function(_, stdout, _)
			local cpu_user = stdout:match("CPU usage:%s*([%d%.]+)%%%s*user")
			local mem_used = stdout:match("PhysMem:%s*([%d%.A-Z]+)%s+used")
			LogManager.log_system_event("system_load", {
				cpu_user_percent = tonumber(cpu_user),
				mem_used         = mem_used,
			})
		end, { "-l", "1", "-n", "0" }):start()
	end)
end

--- Idle check: runs every IDLE_CHECK_INTERVAL_SEC seconds.
--- Logs micro-idle events and clears abandoned sessions.
local function check_idle()
	local now = hs.timer.absoluteTime() / 1000000

	if CoreState.session_last_active > 0 then
		local idle_ms = now - CoreState.session_last_active

		if not CoreState.is_micro_idle
		and idle_ms > MICRO_IDLE_TIMEOUT_MS
		and idle_ms <= SESSION_TIMEOUT_MS
		then
			CoreState.is_micro_idle = true
			LogManager.append_log({ type = "idle_start" })
			Logger.debug(LOG, "Micro-idle started (%.0f ms since last keystroke).", idle_ms)
		end

		if idle_ms > SESSION_TIMEOUT_MS then
			if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end
			LogManager.append_log({
				type        = "session_end",
				duration_ms = CoreState.session_last_active - CoreState.session_start_time,
			})
			Logger.debug(LOG, "Typing session ended after %.0f ms of inactivity.", idle_ms)
			CoreState.session_last_active = 0
			CoreState.session_start_time  = 0
			CoreState.is_micro_idle       = false
		end
	end

	poll_system_load()
end

--- Day-rotation check: runs every second via the maintenance timer.
--- When midnight passes, flushes and archives the previous day's data.
local function perform_maintenance()
	local today = os.date("%Y-%m-%d")
	if _current_day ~= today then
		Logger.start(LOG, "Midnight rotation: archiving %s…", _current_day)
		LogManager.flush_buffer()
		LogManager.save_today_index()
		LogManager.merge_day_to_db(_current_day, CoreState.today_idx, CoreState.manifest[_current_day])
		CoreState.today_idx    = {}
		CoreState.ngram_context = nil
		_current_day = today
		Logger.success(LOG, "Midnight rotation complete — now tracking %s.", today)
	end
	poll_mouse_distance()
end

--- Handles system sleep, wake, lock, and unlock events.
--- @param event number The caffeinate watcher event constant.
local function caffeinate_cb(event)
	local now = hs.timer.absoluteTime() / 1000000
	if event == hs.caffeinate.watcher.systemWillSleep
	or event == hs.caffeinate.watcher.screensDidSleep
	then
		LogManager.log_system_event("sleep", { battery_level = CoreState.current_battery_level })
		if CoreState.active_app_name then
			LogManager.log_app_switch(
				CoreState.active_app_name, "SYSTEM_SLEEP",
				now - (CoreState.active_app_start or now)
			)
			CoreState.active_app_name = nil
		end

	elseif event == hs.caffeinate.watcher.systemDidWake
	or     event == hs.caffeinate.watcher.screensDidWake
	then
		LogManager.log_system_event("wake")
		CoreState.active_app_start = now

	elseif event == hs.caffeinate.watcher.screensDidLock then
		LogManager.log_system_event("lock")
		if CoreState.active_app_name then
			LogManager.log_app_switch(
				CoreState.active_app_name, "SYSTEM_LOCK",
				now - (CoreState.active_app_start or now)
			)
			CoreState.active_app_name = nil
		end

	elseif event == hs.caffeinate.watcher.screensDidUnlock then
		LogManager.log_system_event("unlock")
		CoreState.active_app_start = now
	end
end

--- Starts WiFi, battery, spaces, and audio device watchers.
local function init_hardware_watchers()
	Logger.trace(LOG, "Starting hardware watchers…")

	if hs.wifi and hs.wifi.watcher then
		local ok, w = pcall(function()
			return hs.wifi.watcher.new(function()
				local ssid = hs.wifi.currentNetwork()
				LogManager.log_system_event("wifi_change", { ssid = ssid or "Disconnected" })
				Logger.debug(LOG, "Wi-Fi changed: %s.", ssid or "Disconnected")
			end)
		end)
		if ok and w then _wifi_watcher = w; _wifi_watcher:start() end
	end

	if hs.battery and hs.battery.watcher then
		local ok, w = pcall(function()
			return hs.battery.watcher.new(function()
				local level      = hs.battery.percentage()
				local is_charging = hs.battery.isCharging()
				local source     = hs.battery.powerSource()
				CoreState.current_battery_level = level
				LogManager.log_system_event("power_change", {
					source      = source,
					level       = level,
					is_charging = is_charging,
				})
				Logger.debug(LOG, "Battery: %s%% (%s, charging=%s).",
					tostring(level), tostring(source), tostring(is_charging))
			end)
		end)
		if ok and w then
			_battery_watcher = w
			_battery_watcher:start()
			-- Snapshot current battery level immediately on start
			CoreState.current_battery_level = hs.battery.percentage()
		end
	end

	if hs.spaces and hs.spaces.watcher then
		pcall(function()
			_spaces_watcher = hs.spaces.watcher.new(function(space_id)
				LogManager.log_system_event("space_change", { space_id = space_id })
			end)
			_spaces_watcher:start()
		end)
	end

	-- Audio device watcher: logs volume and mute changes
	if hs.audiodevice and hs.audiodevice.watcher then
		local ok = pcall(function()
			hs.audiodevice.watcher.setCallback(function(event_code)
				-- "vOut " = output volume changed, "mOut " = output mute toggled
				if event_code == "vOut " or event_code == "mOut " then
					local device = hs.audiodevice.defaultOutputDevice()
					if device then
						local vol   = device:volume()
						local muted = device:muted()
						CoreState.current_audio_volume = vol
						LogManager.log_system_event("audio_change", {
							volume     = vol,
							muted      = muted,
							event_code = event_code,
						})
						Logger.debug(LOG, "Audio: volume=%.0f%%, muted=%s.", vol or 0, tostring(muted))
					end
				end
			end)
			hs.audiodevice.watcher.start()
			_audio_watcher_active = true
			-- Snapshot current volume immediately
			local device = hs.audiodevice.defaultOutputDevice()
			if device then CoreState.current_audio_volume = device:volume() end
		end)
		if not ok then Logger.warn(LOG, "Failed to start audio device watcher.") end
	end

	Logger.done(LOG, "Hardware watchers started.")
end

--- Stops all hardware watchers cleanly.
local function stop_hardware_watchers()
	Logger.trace(LOG, "Stopping hardware watchers…")
	if _wifi_watcher    then _wifi_watcher:stop();    _wifi_watcher    = nil end
	if _battery_watcher then _battery_watcher:stop(); _battery_watcher = nil end
	if _spaces_watcher  then pcall(function() _spaces_watcher:stop() end); _spaces_watcher = nil end
	if _audio_watcher_active then
		pcall(function() hs.audiodevice.watcher.stop() end)
		_audio_watcher_active = false
	end
	Logger.done(LOG, "Hardware watchers stopped.")
end




-- ==================================
-- ==================================
-- ======= 7/ Public Core API =======
-- ==================================
-- ==================================

--- Configures encryption and other global options.
--- @param opts table The options dictionary.
function M.set_options(opts)
	CoreState.options = type(opts) == "table" and opts or {}
	Logger.debug(LOG, "Options updated.")
end

--- Replaces the disabled-app list.
--- @param apps table An array of {bundleID=…} or {appPath=…} entries.
function M.set_disabled_apps(apps)
	CoreState.disabled_apps = type(apps) == "table" and apps or {}
	Logger.debug(LOG, "Disabled apps updated (%d entry(ies)).", #CoreState.disabled_apps)
end

--- Enables or disables the private-browsing keystroke filter.
--- When disabled, keystrokes in private windows are recorded.
--- @param v boolean
function M.set_private_filter_enabled(v)
	CoreState.private_filter_enabled = (v ~= false)
	Logger.debug(LOG, "Private window filter: %s.", CoreState.private_filter_enabled and "on" or "off")
end

--- Enables or disables the secure/password-field keystroke filter.
--- When disabled, keystrokes in password fields are recorded.
--- @param v boolean
function M.set_secure_field_filter_enabled(v)
	CoreState.secure_field_filter_enabled = (v ~= false)
	Logger.debug(LOG, "Secure field filter: %s.", CoreState.secure_field_filter_enabled and "on" or "off")
end

--- Enables or disables the system authentication dialog keystroke filter.
--- When disabled, keystrokes typed into macOS admin/sudo prompts are recorded.
--- @param v boolean
function M.set_system_auth_filter_enabled(v)
	CoreState.system_auth_filter_enabled = (v ~= false)
	Logger.debug(LOG, "System auth filter: %s.", CoreState.system_auth_filter_enabled and "on" or "off")
end

--- Injects a string directly into the tracking buffer (used for testing).
--- @param text string The string to inject.
function M.set_buffer(text)
	CoreState.buffer_text = type(text) == "string" and text or ""
end

--- Queues synthetic characters so they can be tagged distinctly in the logs.
--- Called by hotstring expander and LLM modules before they type their output.
--- @param text string The text about to be typed synthetically.
--- @param source_type string Origin identifier ("hotstring", "llm", …).
--- @param deletes number Backspaces issued before the synthetic text.
--- @param source_variant string|nil Optional sub-type for UI rendering.
--- @param deleted_text string|nil The text that will be erased by the backspaces.
function M.notify_synthetic(text, source_type, deletes, source_variant, deleted_text)
	Logger.debug(LOG, "Queuing synthetic text from '%s' (%d delete(s), %d char(s))…",
		source_type, deletes or 0, text and (utf8.len(text) or #text) or 0)

	if deletes and deletes > 0 then
		for _ = 1, deletes do
			table.insert(CoreState.synth_queue, { char = "[BS]", type = source_type })
		end
		-- Mirror the backspaces in the effective WPM window
		for _ = 1, deletes do
			if #CoreState.recent_typing_eff > 0 then table.remove(CoreState.recent_typing_eff) end
		end
	end

	if text and text ~= "" then
		for _, code in utf8.codes(text) do
			table.insert(CoreState.synth_queue, { char = utf8.char(code), type = source_type })
		end
		-- Add timestamps for all synthetic chars so the WPM window reflects them
		local now_ms   = hs.timer.absoluteTime() / 1000000
		local char_count = utf8.len(text) or 0
		for _ = 1, char_count do
			table.insert(CoreState.recent_typing_eff, now_ms)
		end
		CoreState.session_last_active = now_ms
		if CoreState.session_start_time == 0 then CoreState.session_start_time = now_ms end
	end

	CoreState.last_source_type    = source_type
	CoreState.last_source_variant = type(source_variant) == "string" and source_variant or source_type
	CoreState.last_source_time    = hs.timer.absoluteTime() / 1000000000
	Logger.debug(LOG, "Synthetic queue size: %d.", #CoreState.synth_queue)
end

--- Computes the current live WPM from the rolling timestamp buffers.
--- @return table {wpm, wpm_physical, source, source_variant, source_time}.
function M.get_live_stats()
	local now = hs.timer.absoluteTime() / 1000000

	-- Evict entries older than WPM_WINDOW_MS
	while #CoreState.recent_typing_eff > 0
	and (now - CoreState.recent_typing_eff[1]) > WPM_WINDOW_MS do
		table.remove(CoreState.recent_typing_eff, 1)
	end
	while #CoreState.recent_typing_phys > 0
	and (now - CoreState.recent_typing_phys[1]) > WPM_WINDOW_MS do
		table.remove(CoreState.recent_typing_phys, 1)
	end

	local is_idle = (CoreState.session_last_active == 0)
		or ((now - CoreState.session_last_active) > 5000)

	local wpm_eff, wpm_phys = 0, 0
	if not is_idle then
		if #CoreState.recent_typing_eff > 1 then
			local window = math.max(now - CoreState.recent_typing_eff[1], WPM_MIN_DURATION_MS)
			wpm_eff = math.floor(((#CoreState.recent_typing_eff / 5) / (window / 60000)) + 0.5)
		end
		if #CoreState.recent_typing_phys > 1 then
			local window = math.max(now - CoreState.recent_typing_phys[1], WPM_MIN_DURATION_MS)
			wpm_phys = math.floor(((#CoreState.recent_typing_phys / 5) / (window / 60000)) + 0.5)
		end
	end

	return {
		wpm            = wpm_eff,
		wpm_physical   = wpm_phys,
		source         = CoreState.last_source_type,
		source_variant = CoreState.last_source_variant,
		source_time    = CoreState.last_source_time,
	}
end

--- Exposes the in-memory today N-gram index for read-only access.
--- Consumers (e.g. the LLM prediction engine) can use word-bigram data
--- to surface instant local predictions without waiting for the LLM.
--- The returned table is a live reference — callers must not mutate it.
--- @return table The today_idx map keyed by app name.
function M.get_ngram_index()
	return CoreState.today_idx
end

--- Logs a hotstring expansion event.
--- @param trigger string The typed trigger sequence.
--- @param replacement string The expanded replacement text.
--- @param h_type string Hotstring category ("star", "autocorrect", "personal", …).
function M.log_hotstring(trigger, replacement, h_type)
	if not CoreState.is_enabled then return end
	LogManager.flush_buffer()
	local net_saved = (utf8.len(replacement) or 0) - (utf8.len(trigger) or 0)
	LogManager.append_log({
		type           = "hotstring",
		app            = CoreState.session_app_name,
		trigger        = trigger,
		replacement    = replacement,
		h_type         = h_type or "unknown",
		net_saved_chars = net_saved,
		tag            = "<hotstring>" .. replacement .. "</hotstring>",
	})
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Logs an LLM prediction generation event.
--- @param context string The text context fed to the model.
--- @param results table Array of prediction result objects.
--- @param app_name string The frontmost application at time of generation.
function M.log_llm(context, results, app_name)
	if not CoreState.is_enabled then return end
	LogManager.flush_buffer()
	local preds = {}
	for _, r in ipairs(results or {}) do table.insert(preds, r.to_type) end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	LogManager.append_log({
		type        = "llm_generation",
		app         = target_app,
		context     = context,
		predictions = preds,
		tag         = "<llm_generated>" .. (preds[1] or "") .. "</llm_generated>",
	})
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Logs a keyboard shortcut. Delegates to the log manager.
--- @param shortcut_key string The canonical shortcut label (e.g. "Cmd+C").
--- @param app_name string The frontmost application.
function M.log_shortcut(shortcut_key, app_name)
	LogManager.log_shortcut(shortcut_key, app_name or CoreState.session_app_name)
end

--- Logs that a hotstring tooltip was shown to the user.
--- @param app_name string Focus app.
--- @param trigger string The typed trigger.
--- @param replacement string The offered replacement.
--- @param h_type string Hotstring category.
function M.log_hotstring_suggested(app_name, trigger, replacement, h_type)
	if not CoreState.is_enabled then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	LogManager.append_log({
		type        = "hotstring_suggested",
		app         = target_app,
		trigger     = trigger,
		replacement = replacement,
		h_type      = h_type,
	})
	LogManager.increment_manifest_stat(target_app, "hs_suggested")
end

--- Logs that a hotstring tooltip was dismissed.
--- @param app_name string Focus app.
--- @param trigger string The typed trigger.
--- @param replacement string The offered replacement.
--- @param h_type string Hotstring category.
function M.log_hotstring_dismissed(app_name, trigger, replacement, h_type)
	if not CoreState.is_enabled then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	LogManager.append_log({
		type        = "hotstring_dismissed",
		app         = target_app,
		trigger     = trigger,
		replacement = replacement,
		h_type      = h_type,
	})
end

--- Logs that an LLM suggestion was shown to the user.
--- @param app_name string Focus app.
--- @param count number Number of predictions shown.
function M.log_llm_suggested(app_name, count)
	if not CoreState.is_enabled then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	local c = tonumber(count) or 1
	LogManager.append_log({ type = "llm_suggested", app = target_app, count = c })
	LogManager.increment_manifest_stat(target_app, "llm_suggested", c)
end

--- Logs that an LLM suggestion was dismissed without being accepted.
--- @param app_name string Focus app.
--- @param all_predictions table All predictions that were shown.
function M.log_llm_dismissed(app_name, all_predictions)
	if not CoreState.is_enabled then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	LogManager.append_log({
		type            = "llm_dismissed",
		app             = target_app,
		all_predictions = all_predictions or {},
	})
end

--- Logs that the user accepted an LLM prediction.
--- @param prediction_text string The accepted prediction.
--- @param app_name string Focus app.
--- @param all_predictions table All predictions that were shown.
--- @param chosen_index number Which prediction the user picked (1-based).
--- @param deletes number Backspaces issued before typing the prediction.
--- @param deleted_text string The text that was deleted by those backspaces.
function M.log_llm_accepted(prediction_text, app_name, all_predictions, chosen_index, deletes, deleted_text)
	if not CoreState.is_enabled then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	LogManager.increment_manifest_stat(target_app, "llm_triggers")
	local net_saved = (utf8.len(prediction_text or "") or 0) - (deletes or 0)
	LogManager.append_log({
		type            = "llm_accepted",
		app             = target_app,
		prediction      = prediction_text or "",
		all_predictions = all_predictions or {},
		chosen_index    = chosen_index or 1,
		deletes         = deletes or 0,
		deleted_text    = deleted_text or "",
		net_saved_chars = net_saved,
	})
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Opens the typing metrics UI.
function M.show_metrics()
	Logger.debug(LOG, "Loading metrics UI…")
	-- Try both the package-level and the explicit init require path
	local metrics_ui = package.loaded["ui.metrics_typing.init"]
		or package.loaded["ui.metrics_typing"]
	if not metrics_ui then
		local ok, m = pcall(require, "ui.metrics_typing.init")
		if ok and type(m) == "table" then metrics_ui = m end
	end
	if metrics_ui and type(metrics_ui.show) == "function" then
		metrics_ui.show(CoreState.LOG_DIR)
		Logger.info(LOG, "Metrics UI opened.")
	else
		Logger.error(LOG, "Failed to load metrics UI — ui.metrics_typing.init not found.")
		hs.dialog.alert("Erreur Keylogger",
			"Impossible de charger l'interface des métriques.\n\nVérifiez ui/metrics_typing/init.lua.",
			"OK")
	end
end

--- Starts the keylogger engine and all background daemons.
--- Idempotent: calling it a second time while running is a no-op.
--- @param script_control table The module used to check expansion pauses.
function M.start(script_control)
	if CoreState.is_enabled then
		Logger.warn(LOG, "M.start() called while already running — ignoring.")
		return
	end
	Logger.start(LOG, "Starting keylogger engine…")
	_script_control = script_control

	-- Cache the keymap module reference once to avoid pcall(require, ...) per keystroke
	local ok_km, km = pcall(require, "modules.keymap")
	if ok_km and type(km) == "table" then
		_keymap_mod = km
		Logger.debug(LOG, "Keymap module cached for shift-side detection.")
	else
		Logger.debug(LOG, "Keymap module not available — shift side will be 'none'.")
	end

	CoreState.is_enabled    = true
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000

	-- Application watcher
	if not _app_watcher then
		_app_watcher = hs.application.watcher.new(ContextTracker.app_watcher_cb)
	end
	_app_watcher:start()

	-- Browser window filter for private-mode detection
	hs.timer.doAfter(0, function()
		if not _win_filter then
			local browsers = {
				"Safari", "Google Chrome", "Firefox", "Microsoft Edge",
				"Brave Browser", "Arc", "Opera", "Vivaldi",
			}
			_win_filter = hs.window.filter.new(browsers)
			_win_filter:subscribe(
				{ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged },
				ContextTracker.update_private_status
			)
		end
		ContextTracker.update_private_status()
	end)

	-- System sleep/wake/lock watcher
	if not _caffeinate_watcher then
		_caffeinate_watcher = hs.caffeinate.watcher.new(caffeinate_cb)
	end
	_caffeinate_watcher:start()

	init_hardware_watchers()

	-- Main event tap
	if not _event_tap then
		_event_tap = hs.eventtap.new({
			hs.eventtap.event.types.keyDown,
			hs.eventtap.event.types.keyUp,
			hs.eventtap.event.types.leftMouseDown,
			hs.eventtap.event.types.rightMouseDown,
			hs.eventtap.event.types.scrollWheel,
		}, handle_key)
	end
	_event_tap:start()

	-- Idle detection timer
	if not _idle_timer then _idle_timer = hs.timer.new(IDLE_CHECK_INTERVAL_SEC, check_idle) end
	_idle_timer:start()

	-- Maintenance timer (day rotation + mouse distance)
	if not _maintenance_timer then
		_maintenance_timer = hs.timer.new(MAINTENANCE_INTERVAL_SEC, perform_maintenance)
	end
	_maintenance_timer:start()

	-- Bootstrap: capture the current app context and load/rebuild today's index
	hs.timer.doAfter(0, function()
		local current_app = hs.application.frontmostApplication()
		if current_app then
			CoreState.active_app_name  = current_app:title()
			CoreState.active_app_start = hs.timer.absoluteTime() / 1000000
			pcall(ContextTracker.update_ax_observer, current_app:pid())
		end
		Logger.success(LOG, "Keylogger engine started.")
	end)

	-- Run the index evaluation asynchronously so the openssl PBKDF2 passes
	-- (decrypt/re-encrypt, potentially several seconds each) and the raw-log
	-- replay never block the HID event tap. Without this, reactivating the
	-- keylogger on a machine with pending past-day .idx files froze keyboard
	-- input and the Hammerspoon menu for tens of seconds.
	hs.timer.doAfter(2, function()
		local ok, err = pcall(LogManager.rebuild_index_if_needed_async)
		if not ok then
			Logger.error(LOG, "Index rebuild on startup failed: %s.", tostring(err))
		end
	end)
end

--- Halts all tracking, stops all timers and watchers, and flushes the buffer.
--- Idempotent: calling it while not running is a no-op.
function M.stop()
	if not CoreState.is_enabled then
		Logger.warn(LOG, "M.stop() called while not running — ignoring.")
		return
	end
	Logger.start(LOG, "Stopping keylogger engine…")

	CoreState.is_enabled = false
	LogManager.flush_buffer()

	if _event_tap          then _event_tap:stop() end
	if _app_watcher        then _app_watcher:stop() end
	if _caffeinate_watcher then _caffeinate_watcher:stop() end
	if _win_filter         then _win_filter:unsubscribeAll() end
	if _idle_timer         then _idle_timer:stop() end
	if _maintenance_timer  then _maintenance_timer:stop() end

	if CoreState.ax_observer then
		pcall(function() CoreState.ax_observer:stop() end)
		CoreState.ax_observer = nil
	end

	stop_hardware_watchers()
	Logger.success(LOG, "Keylogger engine stopped.")
end

return M

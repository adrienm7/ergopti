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

local hs       = hs
local utf8     = utf8
local Logger   = require("lib.logger")
local Timings  = require("lib.timings")
local Manifest = require("lib.manifest_reader")
local i18n     = require("lib.i18n")
local dialog   = require("lib.dialog_util")

local LogManager     = require("modules.keylogger.log_manager")
local ContextTracker = require("modules.keylogger.context_tracker")
local KcBridge       = require("modules.keylogger.kc_bridge")
local Watchers       = require("modules.keylogger.watchers")
local ProcessLifecycle = require("adapters.process_lifecycle")
local KeyboardHook   = require("adapters.keyboard_hook")
local LOG            = "keylogger"





-- ================================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ================================

-- Timing thresholds come from the shared cross-driver registry
-- (_shared/modules/timings/constants.toml [keylogger]) so the AHK and macOS keyloggers
-- stay in sync; the comment after each names the canonical value for reference.
-- Typing session idle threshold before a "micro-idle" event is logged (30 s)
local MICRO_IDLE_TIMEOUT_MS      = Timings.ms("keylogger", "micro_idle_timeout_ms")
-- Typing session idle threshold before the session is considered fully ended (5 min)
local SESSION_TIMEOUT_MS         = Timings.ms("keylogger", "session_timeout_ms")
-- Rolling window used to compute live WPM (15 s)
local WPM_WINDOW_MS              = Timings.ms("keylogger", "wpm_window_ms")
-- Minimum time window for WPM calculation to avoid division by near-zero (2 s)
local WPM_MIN_DURATION_MS        = Timings.ms("keylogger", "wpm_min_duration_ms")
-- How often the idle check and mouse-distance poll run (seconds)
local IDLE_CHECK_INTERVAL_SEC    = Timings.sec("keylogger", "idle_check_interval_ms")
-- How often the maintenance timer fires for day-rotation and mouse polling (seconds)
local MAINTENANCE_INTERVAL_SEC   = Timings.sec("keylogger", "maintenance_interval_ms")
-- Delay before synthetic input is considered a match (very fast = synthetic)
local SYNTH_MATCH_DELAY_MS       = Timings.ms("keylogger", "synth_match_delay_ms")
-- Flush the buffer after this many milliseconds of inactivity (2 min)
local AUTO_FLUSH_IDLE_MS         = Timings.ms("keylogger", "auto_flush_idle_ms")

-- How often the tap watchdog checks that the event tap is still running (seconds).
-- Mirrors the keymap module's watchdog cadence (script_control TAP_WATCHDOG_INTERVAL_SEC = 2).
local TAP_WATCHDOG_INTERVAL_SEC = 5

-- Inter-keystroke delay (ms) beyond which any remaining synth_queue entries are
-- considered stale and drained. An unmatched entry from a dropped synthetic
-- keyDown would otherwise permanently tag the next real keystroke as synthetic.
-- 500 ms is safely above any realistic expansion round-trip (C5 audit fix).
local SYNTH_IDLE_DRAIN_MS = 500

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

-- Synthetic OS-signal keys that must never appear in keystroke logs or metrics.
-- F18 (79) is tapped by the keep-awake jiggler as a secondary wakeup signal;
-- logging it would pollute character counts and WPM windows.
local SILENT_KEYCODES = {
	[79] = true,   -- F18: keep-awake OS signal
	[80] = true,   -- F19: reserved synthetic channel
	[90] = true,   -- F20: synthetic "typing complete" signal (KE bridge)
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

-- The privacy filter toggles and the encrypt flag are cross-driver metrics
-- settings sourced from the shared features manifest (single source, same as the
-- AHK driver) via Manifest.default_for. keylogger_enabled stays false here: the
-- macOS keylogger is opt-in by design (privacy), deliberately diverging from the
-- AHK metrics.enabled default; the remaining keys are HS-only UI toggles with no
-- manifest entry.
M.DEFAULT_STATE = {
	keylogger_enabled                = false,
	keylogger_disabled_apps          = {},
	keylogger_encrypt                = Manifest.default_for("metrics.encrypt"),
	keylogger_menubar_wpm            = false,
	keylogger_menubar_colors         = true,
	keylogger_float_wpm              = true,
	keylogger_float_graph            = true,
	keylogger_float_colors           = true,
	keylogger_private_filter_enabled      = Manifest.default_for("metrics.private_filter_enabled"),
	keylogger_secure_filter_enabled       = Manifest.default_for("metrics.secure_filter_enabled"),
	keylogger_system_auth_filter_enabled  = Manifest.default_for("metrics.system_auth_filter_enabled"),
}





-- ===========================================
-- ===========================================
-- ======= 3/ Core State And Lifecycle =======
-- ===========================================
-- ===========================================

--- Central shared-state table passed by reference to all sub-modules.
--- Fields are grouped by concern for readability.
local CoreState = {
	-- Paths — keystroke / metrics data goes under <config_dir>/metrics/.
	-- Resolved at module-load time via the central menu_paths module
	LOG_DIR = (function()
		local mp = require("ui.menu.menu_paths")
		local d  = mp.get_config_dir()
		if not d:match("[/\\]$") then d = d .. "/" end
		return d .. "metrics"
	end)(),

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

	-- Previous modifier flags — used to detect key-down vs key-up for flagsChanged events
	prev_flags            = {},

	-- Focus-latency tracking: armed by context_tracker on every app activation,
	-- consumed by the first non-synthetic keystroke that follows
	focus_pending_at      = nil,
	focus_pending_app     = nil,

	-- Per-keycode modifier-down timestamps. Populated on flagsChanged-press,
	-- consumed (and cleared) on flagsChanged-release to compute hold duration
	modifier_down_at      = {},

	-- Passive-time accounting: timestamp at which the screen was locked or
	-- the system went to sleep. Closed on the matching unlock/wake to credit
	-- the day's passive_*_ms manifest fields with the precise duration
	passive_started_at    = nil,
	passive_kind          = nil,

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

-- Wire KcBridge at load time so the file watcher and poll timer run
-- regardless of whether the keylogger is currently enabled — KE emits
-- physical kc events unconditionally and the bridge must always be
-- ready to drain them.
-- LogManager and ContextTracker are deferred to M.start() so that
-- metrics directories are not created when the feature is off.
KcBridge.init(CoreState, nil, nil, nil)

-- Tracks whether LogManager/ContextTracker have been initialized
local _state                = nil

-- Watcher and timer handles
local _event_tap            = nil
local _script_control       = nil
local _idle_timer           = nil
local _maintenance_timer    = nil
local _tap_watchdog_timer   = nil
local _win_filter           = nil
local _process_lifecycle_registered = false

-- Browser apps whose intra-window focus/title changes warrant a private-mode
-- re-check. The array feeds hs.window.filter.new(); the set gives O(1) lookup in
-- the app-activation hook that lazily creates the filter.
local BROWSER_APPS = {
	"Safari", "Google Chrome", "Firefox", "Microsoft Edge",
	"Brave Browser", "Arc", "Opera", "Vivaldi",
}
local BROWSER_APP_SET = {}
for _, _name in ipairs(BROWSER_APPS) do BROWSER_APP_SET[_name] = true end

--- Lazily creates the browser window-filter on the FIRST browser activation.
--- hs.window.filter's first instantiation makes Hammerspoon enumerate every window
--- of every app — multi-second on machines with many apps or a VPN — so creating
--- it eagerly at keylogger start delayed the whole engine becoming ready. Per
--- app-switch private/incognito detection runs immediately via
--- ContextTracker.update_private_status (called from app_watcher_cb) and does NOT
--- need this filter; the filter only adds intra-app (tab/title-change) re-checks,
--- which only matter once the user is actually inside a browser
--- (keylogger-winfilter-lazy).
local function ensure_browser_window_filter()
	if _win_filter then return end
	local t0 = hs.timer.absoluteTime()
	_win_filter = hs.window.filter.new(BROWSER_APPS)
	_win_filter:subscribe(
		{ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged },
		ContextTracker.update_private_status
	)
	Logger.debug(LOG, "Browser window filter created lazily on first browser activation (%.1f ms).",
		(hs.timer.absoluteTime() - t0) / 1e6)
end
-- Sleep/wake/lock watcher handle; its callback lives in the watchers module
local _caffeinate_watcher   = nil

-- Cached module references to avoid pcall(require, ...) on every keystroke
local _keymap_mod = nil

-- Lazily built keycode → name mapping
local _keycode_to_name = nil





-- ==========================================
-- =============================================
-- ======= 4/ Key Event Helper Utilities =======
-- =============================================
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

--- Returns true when the script-control module signals that the script is paused.
--- Used as a fast guard in all timer/watcher callbacks so no data is written
--- to the log while the user has explicitly suspended the keylogger.
local function _is_paused()
	return _script_control
		and type(_script_control.is_paused) == "function"
		and _script_control.is_paused()
end


--- Reports whether the CURRENT context may be recorded at all.
---
--- Four independent user-facing filters answer this question — private window,
--- secure field, system-auth dialog, and the disabled-apps list — and they used
--- to be spelled out inline in handle_key only. Every other route into the same
--- sink applied none of them: notify_synthetic and log_hotstring gated solely on
--- is_enabled, so an expansion fired inside a password manager, a system-auth
--- prompt or an app the user had explicitly excluded was persisted in full, and
--- was additionally mis-attributed, because the app name is only assigned on the
--- handle_key path that never ran there.
---
--- Exported rather than local so every writer consults ONE implementation. A
--- second copy is how these four answers drift apart again.
--- @return boolean True when the context is loggable.
function M.context_allows_logging()
	if CoreState.private_filter_enabled and CoreState.is_private_window then return false end
	if CoreState.secure_field_filter_enabled and CoreState.is_secure_field then return false end
	-- System auth dialogs: belt-and-suspenders in case the AX observer attaches late.
	if CoreState.system_auth_filter_enabled and CoreState.active_app_bundle
		and SYSTEM_AUTH_BUNDLE_IDS[CoreState.active_app_bundle] then
		return false
	end
	if CoreState.disabled_apps and #CoreState.disabled_apps > 0 then
		for _, disabled in ipairs(CoreState.disabled_apps) do
			if (disabled.bundleID and disabled.bundleID == CoreState.active_app_bundle)
				or (disabled.appPath and disabled.appPath == CoreState.active_app_path) then
				return false
			end
		end
	end
	return true
end





-- =======================================
-- ========================================
-- ======= 5/ Event Tap Interceptor =======
-- ========================================
-- =======================================

--- Main eventtap callback. Processes all keyboard and mouse events.
--- Wrapped in pcall to prevent any Lua error from locking the OS keyboard.
--- @param event_obj table The raw hs.eventtap event object.
--- @return boolean False to propagate the event, true to consume it.
local function handle_key(event_obj)
	local ok, err = pcall(function()
		if not CoreState.is_enabled then return end

		-- If the script control module signals a pause (e.g. during hotstring expansion),
		-- flush and skip — we do not want to interleave expansion events with real typing
		if _script_control
		and type(_script_control.is_paused) == "function"
		and _script_control.is_paused()
		then
			LogManager.flush_buffer()
			return
		end

		-- Private/secure/system-auth/disabled-app context. Delegated to the shared
		-- predicate so the physical path and the SYNTHETIC path cannot answer this
		-- question differently — they used to, and notify_synthetic persisted
		-- expansions this branch would have refused.
		if not M.context_allows_logging() then return end

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

		-- flagsChanged: track modifier press AND release per physical keycode.
		-- We can't rely on the flag bits alone because shared flags (cmd is set
		-- by both left_cmd 55 and right_cmd 54) prevent us from disambiguating
		-- consecutive presses. Instead, we toggle a per-keycode down-timestamp:
		-- absent → press (record now); present → release (compute hold, clear).
		-- During a hotstring expansion the script is paused; skip modifier logging
		-- so synthetic Shift/Ctrl/Alt held by the expander don't pollute the log.
		if evt_type == hs.eventtap.event.types.flagsChanged then
			local keycode = event_obj:getKeyCode()
			local flags   = event_obj:getFlags() or {}
			if MODIFIER_KEYCODES[keycode] then
				local down_at = CoreState.modifier_down_at[keycode]
				if not down_at then
					-- Press — record timestamp and credit the kc dict
					CoreState.modifier_down_at[keycode] = now
					local front_app = hs.application.frontmostApplication()
					local app_name  = front_app and front_app:title() or "Unknown"
					LogManager.log_modifier_press(keycode, app_name)
				else
					-- Release — compute hold duration and feed the manifest
					local hold_ms = math.floor(now - down_at)
					CoreState.modifier_down_at[keycode] = nil
					local front_app = hs.application.frontmostApplication()
					local app_name  = front_app and front_app:title() or "Unknown"
					LogManager.log_modifier_hold(keycode, app_name, hold_ms)
				end
			end
			-- Keep the flag snapshot up to date for any code path that reads it
			CoreState.prev_flags = flags
			return
		end

		if evt_type ~= hs.eventtap.event.types.keyDown then return end

		local flags   = event_obj:getFlags() or {}
		local keycode = event_obj:getKeyCode()

		-- Shortcuts: flush then log immediately without entering the typing pipeline.
		-- Gate on the keymap's own pending-synthetic-paste peek FIRST: any hotstring/
		-- personal-info/LLM expansion whose replacement exceeds the paste threshold
		-- synthesizes a Cmd+V, which is a genuine cmd+key combo and would otherwise
		-- match is_shortcut_candidate unconditionally, inflating the user's logged
		-- Cmd+V shortcut count with synthetic paste echoes (F-HIGH-17 fix).
		if is_shortcut_candidate(flags, keycode) then
			local is_synth_paste = _keymap_mod
				and type(_keymap_mod.is_pending_synthetic_paste) == "function"
				and _keymap_mod.is_pending_synthetic_paste(flags, keycode)
			if not is_synth_paste then
				LogManager.flush_buffer()
				local front_app = hs.application.frontmostApplication()
				LogManager.log_shortcut(
					build_shortcut_key(event_obj, flags, keycode),
					front_app and front_app:title() or "Unknown"
				)
			end
			return
		end

		-- Drop synthetic OS-signal keys before any logging or metric update
		if SILENT_KEYCODES[keycode] then return end

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

		-- flush_buffer() resets CoreState.last_time to 0, so the NEXT keystroke would
		-- compute a delay of 0 and the entire inter-word gap would vanish from the
		-- timing data. Every keystroke-driven flush below therefore re-seeds the
		-- baseline to `now`. The metrics-webview flush at the end of this function
		-- already did exactly this, with the same reasoning in its comment; the
		-- Tab/Escape/Enter/F-key/nav/space/punctuation sites did not. Declared here,
		-- above every call site, so no closure binds a nil global.
		local function flush_keeping_baseline()
			LogManager.flush_buffer()
			CoreState.last_time = now
		end

		-- Self-heal: drain stale synthetic queue entries after a long idle.
		-- An unmatched entry (from a suppressed expansion or a dropped keyDown)
		-- would permanently tag the next real keystroke as synthetic (C5 audit fix).
		if delay > SYNTH_IDLE_DRAIN_MS and #CoreState.synth_queue > 0 then
			Logger.warn(LOG, "Stale synth_queue drained after %d ms idle (%d entry(ies)).",
				delay, #CoreState.synth_queue)
			CoreState.synth_queue = {}
		end

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
				local next_synth = CoreState.synth_queue[1]
				table.remove(CoreState.synth_queue, 1)
				-- notify_synthetic has already written the logical replacement.
				-- Drop the later OS echo so it cannot be counted twice.
				if next_synth.discard then return end
				is_synthetic = true
				synth_type   = next_synth.type
			end
		else
			if #CoreState.synth_queue > 0 then
				local next_synth = CoreState.synth_queue[1]
				if chars == next_synth.char then
					-- Exact character match
					table.remove(CoreState.synth_queue, 1)
					if next_synth.discard then return end
					is_synthetic = true
					synth_type   = next_synth.type
				elseif delay < SYNTH_MATCH_DELAY_MS then
					-- Extremely fast keystroke — almost certainly synthetic even if char differs
					-- Pop the queue even on a char-mismatch fast-path: without this pop the
					-- head entry stays and re-matches every subsequent fast keystroke,
					-- tagging all rapid typing as synthetic until a >500 ms gap clears it.
					table.remove(CoreState.synth_queue, 1)
					if next_synth.discard then return end
					is_synthetic = true
					synth_type   = next_synth.type
				end
			end
		end

		-- Time-to-first-key after focus: triggered once per app activation,
		-- only for genuine human keystrokes (synthetic expansion is excluded —
		-- a hotstring firing 1 ms after focus is not a "user reaction time")
		if not is_synthetic
		   and CoreState.focus_pending_at
		   and not MODIFIER_KEYCODES[keycode]
		then
			local latency_ms = math.floor(now - CoreState.focus_pending_at)
			LogManager.log_focus_first_key(
				CoreState.focus_pending_app or CoreState.session_app_name or "Unknown",
				latency_ms
			)
			CoreState.focus_pending_at  = nil
			CoreState.focus_pending_app = nil
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
			-- Suppress the output kc when Karabiner is logging the physical key for
			-- this keycode — the bridge will credit the physical key instead, so we
			-- must not also count the remapped output or the heatmap is double-counted.
			kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or keycode,
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
			flush_keeping_baseline()

		elseif keycode == 53 then
			-- Escape: log then flush (cancel/navigation action, breaks N-gram context)
			ev_entry = { "[ESC]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			flush_keeping_baseline()

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
			flush_keeping_baseline()

		elseif F_KEY_CODES[keycode] then
			-- F1–F12: log as bracket marker and flush (context-breaking navigation)
			ev_entry = { "[" .. F_KEY_CODES[keycode] .. "]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			flush_keeping_baseline()

		elseif NAV_KEY_CODES[keycode] then
			-- Arrow keys and extended nav (Delete, Home, End, PageUp, PageDown): log as
			-- bracket marker and flush — cursor moved, so N-gram context is broken
			ev_entry = { "[" .. NAV_KEY_CODES[keycode] .. "]", delay, meta }
			table.insert(CoreState.buffer_events, ev_entry)
			flush_keeping_baseline()

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
						flush_keeping_baseline()
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
					flush_keeping_baseline()
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
			-- flush_buffer resets CoreState.last_time to 0; re-seed it so the
			-- next keystroke computes a correct inter-key delay instead of 0.
			CoreState.last_time = now
		end

	end)

	if not ok then
		-- Log and swallow: we MUST return false to avoid locking the OS keyboard
		Logger.warn(LOG, "Keyboard lock avoidance triggered: %s.", tostring(err))
	end
	return false
end





-- =============================================
-- ================================================
-- ======= 6/ Hardware Watchers And Sensors =======
-- ================================================
-- =============================================

-- The background sensor layer (idle/maintenance timers, sleep/wake caffeinate
-- callback, and the Wi-Fi/battery/spaces/audio hardware watchers) lives in the
-- self-contained keylogger/watchers.lua module so this file stays focused on the
-- event-tap engine. It is wired with the shared CoreState and the _is_paused
-- predicate in M.start(); the lifecycle below references Watchers.* directly.





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
--- @param physical_echo string|nil Text whose delayed physical key echoes must
---   be discarded. Clipboard output intentionally passes an empty string.
--- Stand-in recorded in place of each character of a PRIVATE expansion. One
--- placeholder per real character, so every count, WPM sample and timing
--- derived from these events stays accurate while the content itself is
--- unrecoverable from the metrics database or from a cross-device export.
local PRIVATE_PLACEHOLDER_CHAR = string.char(0xE2, 0x80, 0xA2) -- U+2022 BULLET

--- What is actually PERSISTED for one synthetic character.
---
--- Pure and exported so the privacy invariant can be asserted directly: the
--- alternative is reloading the whole keylogger to reach its private CoreState,
--- which drags the event tap, watchers and context tracker into the test run.
---
--- Backspace markers are never redacted — they carry no content, and rewriting
--- them would desynchronise the deletion count the buffer replays.
--- @param char string       The character about to be recorded.
--- @param is_private boolean|nil  True for a private mapping's replacement.
--- @return string           The value to persist.
function M.recorded_char(char, is_private)
	if is_private and char ~= "[BS]" then
		return PRIVATE_PLACEHOLDER_CHAR
	end
	return char
end

--- @param is_private boolean|nil  When true, the CONTENT is replaced by a
---        redacted placeholder in everything that is persisted, while the
---        physical-echo discard markers below still use the real text.
---        Skipping this call outright for a private expansion would be WORSE
---        than the leak it fixes: the physical echoes would then fall through
---        handle_key unclaimed and be recorded as ordinary human keystrokes in
---        buffer_text, so the secret would land in the metrics anyway - just in
---        a different column.
function M.notify_synthetic(text, source_type, deletes, source_variant, physical_echo, is_private)
	-- When the keylogger is OFF there is no consumer for synth_queue (handle_key
	-- returns at the is_enabled guard, so the idle-drain self-heal never runs).
	-- Queuing here while disabled is pure leak/poison: the queue and the WPM window
	-- grow unbounded across a session of hotstring use, and the FIRST real
	-- keystrokes after the user later enables the keylogger get mis-tagged
	-- synthetic against the stale head. Gate on is_enabled like the sibling
	-- log_hotstring / log_llm. Expander notifies unconditionally on every expansion.
	if not CoreState.is_enabled then return end

	-- A clipboard paste does not emit one keyDown per inserted character. Record
	-- the logical replacement immediately, then discard only the later physical
	-- echoes of direct key injection. This keeps clipboard hotstrings and LLM
	-- completions in the same raw event format as typed synthetic output.
	-- What gets PERSISTED for one synthetic character. For a private expansion
	-- the SHAPE is preserved (one entry per character, so counts, WPM and
	-- timings stay correct) while the character itself is replaced. The
	-- .text-based privacy tests never caught this because buffer_text stays
	-- clean either way: the secret travelled in the per-character `r` field of
	-- buffer_events and in rich_chunks, which become events_json and rich_text
	-- in the database and are replicated by cross-device export.
	local function append_virtual(char)
		-- The four context filters apply to the SYNTHETIC route exactly as they do
		-- to the physical one. Gating here — at the persistence step — rather than
		-- at the top of notify_synthetic is deliberate: the synth_queue discard
		-- markers below MUST still be queued, because dropping them would leave the
		-- physical echoes unclaimed and handle_key would record the very same
		-- secret as ordinary human keystrokes. The same text, in a worse place.
		if not M.context_allows_logging() then return end
		local recorded = M.recorded_char(char, is_private)
		table.insert(CoreState.buffer_events, {
			recorded, 0,
			{ s = true, st = source_type, c = false, ss = "none", r = recorded,
				m = "", h = 0, d = 0, dk = false, cp = false, kc = nil },
		})
		if char ~= "[BS]" then
			table.insert(CoreState.rich_chunks, { type = source_type, text = recorded })
		end
	end

	Logger.debug(LOG, "Queuing synthetic text from '%s' (%d delete(s), %d char(s))…",
		source_type, deletes or 0, text and (utf8.len(text) or #text) or 0)

	if deletes and deletes > 0 then
		for _ = 1, deletes do
			append_virtual("[BS]")
			table.insert(CoreState.synth_queue, { char = "[BS]", type = source_type, discard = true })
		end
		-- Mirror the backspaces in the effective WPM window
		for _ = 1, deletes do
			if #CoreState.recent_typing_eff > 0 then table.remove(CoreState.recent_typing_eff) end
		end
	end

	if text and text ~= "" then
		-- Validate BEFORE iterating: utf8.codes raises immediately on a malformed
		-- sequence (e.g. a truncated LLM completion cut mid-codepoint — French
		-- accents, curly quotes, em-dashes are all multi-byte), whereas utf8.len
		-- fails closed with nil instead of throwing. Mirrors the same
		-- validate-then-iterate pattern used for the physical-keystroke split at
		-- handle_key's normal-character branch (F-HIGH-16 fix).
		local ok_len, char_count = pcall(utf8.len, text)
		if ok_len and char_count then
			for _, code in utf8.codes(text) do
				append_virtual(utf8.char(code))
			end
		else
			-- Malformed UTF-8 — queue one opaque, non-validated entry rather than
			-- raising and aborting the expansion mid-flight (which would leave the
			-- synthetic-injection trackers desynced for every subsequent keystroke).
			Logger.warn(LOG, "notify_synthetic: malformed UTF-8 in synthetic text — queuing an opaque fallback entry.")
			append_virtual(text)
			char_count = 1
		end
		-- Add timestamps for all synthetic chars so the WPM window reflects them
		local now_ms = hs.timer.absoluteTime() / 1000000
		for _ = 1, char_count do
			table.insert(CoreState.recent_typing_eff, now_ms)
		end
		CoreState.session_last_active = now_ms
		if CoreState.session_start_time == 0 then CoreState.session_start_time = now_ms end
	end

	-- Paste has no per-character echo. Direct injection does, so queue just its
	-- physical echo events as discard markers; their logical counterparts above
	-- have already been persisted once.
	local echo_text = type(physical_echo) == "string" and physical_echo or text
	if echo_text and echo_text ~= "" then
		local ok_echo, echo_count = pcall(utf8.len, echo_text)
		if ok_echo and echo_count then
			for _, code in utf8.codes(echo_text) do
				table.insert(CoreState.synth_queue, {
					char = utf8.char(code), type = source_type, discard = true,
				})
			end
		else
			table.insert(CoreState.synth_queue, { char = echo_text, type = source_type, discard = true })
		end
	end

	-- A pure Cmd+V insertion would otherwise remain buffered indefinitely: the
	-- Cmd+V event is a shortcut, not a typing event, and its pasted characters
	-- never reach handle_key. Flush before the expander re-seeds buffer_text.
	if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end

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
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
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

--- Logs an LLM prediction generation event with optional provenance metadata.
--- @param context string The text context fed to the model.
--- @param results table Array of prediction result objects.
--- @param app_name string|nil The frontmost application at time of generation.
--- @param extras table|nil { backend = string?, model = string?, system_prompt = string?, user_prompt = string? }
---
--- The ``extras`` table records which backend (ollama / mlx / api), which
--- model and which exact prompts produced the predictions. Without this,
--- replaying a session log makes it impossible to tell after the fact whether
--- a given prediction came from a local model or a remote API, or which
--- precise system+user prompt the model saw — both essential when debugging
--- a prompt regression or comparing providers.
function M.log_llm(context, results, app_name, extras)
	if not CoreState.is_enabled then return end
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
	LogManager.flush_buffer()
	local preds = {}
	for _, r in ipairs(results or {}) do table.insert(preds, r.to_type) end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	local entry = {
		type        = "llm_generation",
		app         = target_app,
		context     = context,
		predictions = preds,
		tag         = "<llm_generated>" .. (preds[1] or "") .. "</llm_generated>",
	}
	if type(extras) == "table" then
		if type(extras.backend)       == "string" then entry.backend       = extras.backend end
		if type(extras.model)         == "string" then entry.model         = extras.model end
		if type(extras.system_prompt) == "string" then entry.system_prompt = extras.system_prompt end
		if type(extras.user_prompt)   == "string" then entry.user_prompt   = extras.user_prompt end
		-- Token usage + cost tracking. The provider's response normally
		-- carries ``usage.prompt_tokens`` / ``usage.completion_tokens``
		-- (OpenAI shape) or equivalent fields. The backend wrapper
		-- extracts them and forwards through extras so a tail of the
		-- log answers "how much did I burn this hour?".
		if type(extras.prompt_tokens)     == "number" then entry.prompt_tokens     = extras.prompt_tokens end
		if type(extras.completion_tokens) == "number" then entry.completion_tokens = extras.completion_tokens end
		if type(extras.total_tokens)      == "number" then entry.total_tokens      = extras.total_tokens end
		if type(extras.est_cost_usd)      == "number" then entry.est_cost_usd      = extras.est_cost_usd end
		if type(extras.elapsed_ms)        == "number" then entry.elapsed_ms        = extras.elapsed_ms end
	end
	LogManager.append_log(entry)
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Logs a FAILED LLM prediction attempt. Same envelope as ``log_llm`` but the
--- predictions array is empty and ``failure_reason`` captures what went wrong
--- (HTTP status, parse miss, timeout, …). Without this event a tail of the
--- log shows only successes, and "are predictions silently dropping?" becomes
--- impossible to answer.
--- @param context string Full text up to the caret at request time.
--- @param app_name string Frontmost app at request time.
--- @param extras table Optional fields: backend, model, system_prompt,
---     user_prompt, failure_reason, elapsed_ms.
function M.log_llm_failed(context, app_name, extras)
	if not CoreState.is_enabled then return end
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
	LogManager.flush_buffer()
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	local entry = {
		type        = "llm_generation_failed",
		app         = target_app,
		context     = context,
		predictions = {},
		tag         = "<llm_failed/>",
	}
	if type(extras) == "table" then
		if type(extras.backend)         == "string" then entry.backend         = extras.backend end
		if type(extras.model)           == "string" then entry.model           = extras.model end
		if type(extras.system_prompt)   == "string" then entry.system_prompt   = extras.system_prompt end
		if type(extras.user_prompt)     == "string" then entry.user_prompt     = extras.user_prompt end
		if type(extras.failure_reason)  == "string" then entry.failure_reason  = extras.failure_reason end
		if type(extras.elapsed_ms)      == "number" then entry.elapsed_ms      = extras.elapsed_ms end
	end
	LogManager.append_log(entry)
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Logs a keyboard shortcut. Delegates to the log manager.
--- @param shortcut_key string The canonical shortcut label (e.g. "Cmd+C").
--- @param app_name string The frontmost application.
function M.log_shortcut(shortcut_key, app_name)
	if not CoreState.is_enabled then return end
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
	LogManager.log_shortcut(shortcut_key, app_name or CoreState.session_app_name)
end

--- Logs that a hotstring tooltip was shown to the user.
--- @param app_name string Focus app.
--- @param trigger string The typed trigger.
--- @param replacement string The offered replacement.
--- @param h_type string Hotstring category.
function M.log_hotstring_suggested(app_name, trigger, replacement, h_type)
	if not CoreState.is_enabled then return end
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
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
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
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
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
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
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
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
	-- Same four context filters the physical path applies. These writers record
	-- triggers, replacements and LLM prompts verbatim, so a private window, a
	-- secure field, a system-auth dialog or a user-disabled app must silence them
	-- exactly as it silences a keystroke.
	if not M.context_allows_logging() then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	-- The synthetic typing burst is the canonical trigger counter. A manifest
	-- increment here used to be ignored by the whitelist and would double-count
	-- now that clipboard output is represented in the synthetic raw event stream.
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
		dialog.alert(i18n.get("keylogger.error_title"),
			i18n.get("keylogger.error_body"),
			i18n.get("button.ok"))
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

	-- Initialise sub-modules on first start (deferred from require-time
	-- so metrics directories are only created when the feature is on)
	if not _state then
		_state = true
		LogManager.init(CoreState)
		-- The context tracker owns three OS watchers that pause does NOT tear down,
		-- so it needs the same pause predicate as the watcher layer below.
		ContextTracker.init(CoreState, LogManager, _is_paused)
		-- The watcher layer needs the shared state and the pause predicate; both
		-- are stable for the process lifetime, so a one-shot init is sufficient.
		Watchers.init(CoreState, _is_paused)
	end
	-- Re-wire and re-arm on every start so stop/start cycles keep the bridge
	-- and ingest loop alive. Both calls are idempotent when already running.
	KcBridge.set_log_manager(LogManager)
	KcBridge.start()
	LogManager.ensure_ingest_running()

	CoreState.is_enabled    = true
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000

	-- Clear any synthetic-tracking state so a queue accumulated before this enable
	-- (or left over from a prior session) cannot mis-tag the FIRST real keystrokes
	-- as synthetic. notify_synthetic now gates on is_enabled, but the clear also
	-- guards the stop→start cycle. Mirrors the teardown in M.stop.
	CoreState.synth_queue        = {}
	CoreState.recent_typing_eff  = {}
	CoreState.recent_typing_phys = {}

	-- Application lifecycle. The browser window-filter is created LAZILY on the first
	-- browser activation (see ensure_browser_window_filter) so the keylogger never
	-- pays hs.window.filter's whole-window-tree enumeration at start.
	if not _process_lifecycle_registered then
		ProcessLifecycle.onAppActivate(function(app_name, app_object)
			if BROWSER_APP_SET[app_name] then ensure_browser_window_filter() end
			ContextTracker.app_watcher_cb(app_name, hs.application.watcher.activated, app_object)
		end)
		_process_lifecycle_registered = true
	end
	ProcessLifecycle.start()

	-- Evaluate the current window's private status on the next tick (independent of
	-- the lazy browser filter), keeping it off the synchronous start path.
	hs.timer.doAfter(0, ContextTracker.update_private_status)

	-- System sleep/wake/lock watcher
	if not _caffeinate_watcher then
		_caffeinate_watcher = hs.caffeinate.watcher.new(Watchers.caffeinate_cb)
	end
	_caffeinate_watcher:start()

	Watchers.init_hardware_watchers()

	-- Main event tap
	KeyboardHook.start({
		eventTypes = {
			hs.eventtap.event.types.keyDown,
			hs.eventtap.event.types.keyUp,
			hs.eventtap.event.types.flagsChanged,
			hs.eventtap.event.types.leftMouseDown,
			hs.eventtap.event.types.rightMouseDown,
			hs.eventtap.event.types.scrollWheel,
		},
		onEvent = handle_key,
	})
	_event_tap = true

	-- Tap watchdog: restarts the event tap if Hammerspoon silently disabled it
	-- (can happen after a system wake, screen-saver unlock, or security prompt).
	if not _tap_watchdog_timer then
		_tap_watchdog_timer = hs.timer.new(TAP_WATCHDOG_INTERVAL_SEC, function()
			if not CoreState.is_enabled then return end
			if not KeyboardHook.isRunning() then
				Logger.warn(LOG, "Keylogger event tap found disabled — restarting.")
				KeyboardHook.start()
			end
		end)
	end
	_tap_watchdog_timer:start()

	-- Idle detection timer
	if not _idle_timer then _idle_timer = hs.timer.new(IDLE_CHECK_INTERVAL_SEC, Watchers.check_idle) end
	_idle_timer:start()

	-- Maintenance timer (day rotation + mouse distance)
	if not _maintenance_timer then
		_maintenance_timer = hs.timer.new(MAINTENANCE_INTERVAL_SEC, Watchers.perform_maintenance)
	end
	_maintenance_timer:start()

	-- Bootstrap: capture the current app context and load/rebuild today's index
	hs.timer.doAfter(0, function()
		pcall(ContextTracker.capture_frontmost_app)
		Logger.success(LOG, "Keylogger engine started.")
	end)

	-- New persistence model: data.sql is the canonical source of truth and
	-- the SQLite cache in tmpdir is reconstructed by log_manager.M.init().
	-- No deferred rebuild dance is needed at boot — the ingest tick will
	-- catch up on any today.log entries written by a previous keylogger
	-- session that did not get flushed before exit.
end

--- Re-synchronises the cached app/secure-field context with reality.
--- Called by script_control on resume: the context tracker's pause guard correctly
--- suppresses everything while paused, which also means an app switch made DURING
--- a pause never updated the cached context — and nothing else re-syncs it.
--- @return boolean True when the context was re-synchronised.
function M.resync_context()
	-- A modifier held across the pause never received its release: handle_key returns
	-- at the pause guard, so the keyUp that would clear modifier_down_at never ran.
	-- The stale down-timestamp would then be misread as a fresh press on the next
	-- flagsChanged, inverting press/release and logging a hold that never happened.
	-- An unmatched down carries no usable duration, so discard it — the same
	-- reasoning the synth_queue clear applies at the other suppression sites.
	CoreState.modifier_down_at = {}
	local ok, res = pcall(ContextTracker.resync_context)
	if not ok then
		Logger.error(LOG, "resync_context() failed: %s.", tostring(res))
		return false
	end
	return res == true
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
	-- App-switch rows are normally created only on focus changes. Close the
	-- currently open interval before shutdown so reloads do not erase it.
	pcall(ContextTracker.close_active_app)
	LogManager.flush_buffer()
	ProcessLifecycle.stop()

	KeyboardHook.stop()
	_event_tap = nil
	if _caffeinate_watcher   then _caffeinate_watcher:stop();   _caffeinate_watcher = nil end
	if _win_filter           then _win_filter:unsubscribeAll(); _win_filter         = nil end
	if _idle_timer           then _idle_timer:stop();           _idle_timer         = nil end
	if _maintenance_timer    then _maintenance_timer:stop();     _maintenance_timer  = nil end
	if _tap_watchdog_timer   then _tap_watchdog_timer:stop();   _tap_watchdog_timer = nil end

	if CoreState.ax_observer then
		pcall(function() CoreState.ax_observer:stop() end)
		CoreState.ax_observer = nil
	end

	Watchers.stop_hardware_watchers()
	KcBridge.stop()

	-- Close the SQLite cache cleanly (drains any pending today.log entries
	-- one last time before stopping). Safe to call even if init never ran.
	pcall(LogManager.stop)

	-- Discard any unmatched synthetic queue entries so a restart does not
	-- inherit stale entries that would poison the first real keystroke (C5 fix).
	CoreState.synth_queue = {}

	Logger.success(LOG, "Keylogger engine stopped.")
end

return M

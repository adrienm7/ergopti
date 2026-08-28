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
local Logger   = require("infra.logger")
local Timings  = require("infra.timings")
local Manifest = require("infra.manifest_reader")
local i18n     = require("infra.i18n")
local dialog   = require("infra.dialog_util")
local TeardownTransaction = require("infra.teardown_transaction")
local InputSourceBroker = require("adapters.input_source_broker")

local LogManager     = require("modules.keylogger.log_manager")
local ContextTracker = require("modules.keylogger.context_tracker")
local KcBridge       = require("modules.keylogger.kc_bridge")
-- The WPM formula lives once, in the shared metrics module. This file used to
-- divide by a literal 5 in two places while _shared/lua/keylogger/metrics.lua
-- already defined DEFAULT_CHARS_PER_WORD and the exact batch formula its own
-- docstring says macOS uses — the shared copy existed only to be shadowed.
local Metrics        = require("keylogger.metrics")
local Watchers       = require("modules.keylogger.watchers")
local ProcessLifecycle = require("adapters.process_lifecycle")
local KeyboardHook   = require("adapters.keyboard_hook")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local LOG            = "keylogger"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

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

-- Bound one detached typing row so a mechanically stuck key cannot retain an
-- ever-growing event table until a separator finally arrives.
local BUFFER_EVENT_CAP = 1024

-- How often the tap watchdog checks that the event tap is still running (seconds).
-- Mirrors the keymap module's watchdog cadence (script_control TAP_WATCHDOG_INTERVAL_SEC = 2).
local TAP_WATCHDOG_INTERVAL_SEC = 5
local INPUT_SOURCE_SUBSCRIBER_ID = "modules.keylogger"

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
	[79]  = "F18",
}

-- Keycodes for F1–F12; excluded from the shortcut pipeline when no Cmd or Ctrl
-- modifier is held so that standalone F-key presses log as "[F1]" etc. in the
-- character dict instead of appearing as "Fn+F1" shortcut entries.
local F_KEY_CODES = {
	[122] = "F1",  [120] = "F2",  [99]  = "F3",  [118] = "F4",
	[96]  = "F5",  [97]  = "F6",  [98]  = "F7",  [100] = "F8",
	[101] = "F9",  [109] = "F10", [103] = "F11", [111] = "F12",
	[79]  = "F18",
}

-- Untagged reserved OS-signal keys that must never appear in keystroke logs or
-- metrics. F18 is deliberately absent: exact provenance now suppresses the
-- keep-awake echo, while a physical/programmable F18 remains real user input.
local SILENT_KEYCODES = {
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
		local mp = require("infra.config_paths")
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

--- Appends one event and detaches the run at either a semantic boundary or
--- the hard memory watermark. All event-producing branches use this owner so
--- a non-character repeat storm cannot bypass the same cap.
--- @param entry table Raw keylogger event tuple.
--- @param rich_chunk table|nil Rich-text fragment paired with the event.
--- @param is_boundary boolean Whether the event terminates the typing run.
--- @param now number Current monotonic timestamp in milliseconds.
local function append_buffer_event(entry, rich_chunk, is_boundary, now)
	table.insert(CoreState.buffer_events, entry)
	if rich_chunk then table.insert(CoreState.rich_chunks, rich_chunk) end
	if is_boundary or #CoreState.buffer_events >= BUFFER_EVENT_CAP then
		LogManager.flush_buffer()
		CoreState.last_time = now
	end
end

-- Wire KcBridge at load time so the file watcher and poll timer run
-- regardless of whether the keylogger is currently enabled — KE emits
-- physical kc events unconditionally and the bridge must always be
-- ready to drain them.
-- LogManager and ContextTracker are deferred to M.start() so that
-- metrics directories are not created when the feature is off.

-- Forward-declared here so the closure handed to KcBridge.init below captures
-- the real upvalue rather than a nil global.
local _is_paused

-- Passed as a closure because M.may_persist is published later in this module.
-- A filesystem callback delivered during module construction must fail closed;
-- after construction, the bridge reaches the same enable/pause/privacy gate as
-- every other persistence sink instead of reconstructing only part of it.
local kc_bridge_initialized = KcBridge.init(
	CoreState, nil, nil, nil, function()
		if type(M.may_persist) ~= "function" then return false end
		return M.may_persist()
	end)
if kc_bridge_initialized ~= true then
	error("KC bridge failed to acquire its always-on drain producers")
end

-- Tracks whether LogManager/ContextTracker have been initialized
local _state                = nil

-- Watcher and timer handles
local _event_tap            = nil
local _script_control       = nil
local _idle_timer           = nil
local _maintenance_timer    = nil
local _tap_watchdog_timer   = nil
local _foreground_bootstrap_timer = nil
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
-- Active keyboard layout, cached. hs.keycodes.currentLayout() is a Carbon/TIS
-- query and the per-word context snapshot called it on every new buffer. The
-- layout only changes when the OS says so, so it is read once and refreshed from
-- the notification below.
local _cached_layout        = nil
-- Cleanup obligation for the named input-source broker subscriber. This is
-- published before subscribe(): the setter may replace the native callback and
-- only then throw or return a refusal.
local _layout_listener      = nil

-- Cached module references to avoid pcall(require, ...) on every keystroke
local _keymap_mod = nil

local ACTION_EPOCH_LISTENER_ID = "modules.keylogger.action_epoch"
local _action_listener_registered = false
local _last_action_epoch = SyntheticInput.current_action_epoch()
local _teardown_state = TeardownTransaction.new_state()
local _process_lifecycle_cleanup_required = false
local _keyboard_hook_cleanup_required = false
local _log_manager_cleanup_required = false
local _runtime_generation = 0
local _kc_bridge_shutdown_complete = false


--- Splits human typing from one logical automation action.
--- The eventtap path reaches only LogManager.defer_flush_buffer(), whose O(1)
--- detach cannot serialize or persist. Once the LogManager outbox accepts the
--- snapshot, timer scheduling belongs to that outbox and cannot veto the epoch;
--- only a rejection before acceptance propagates to the adapter for retry.
--- @param epoch table Opaque SyntheticInput action token.
--- @param handoff_time_ms number|nil Monotonic action handoff timestamp.
local function reconcile_action_epoch(epoch, handoff_time_ms)
	if epoch == _last_action_epoch then return end
	if CoreState.is_enabled then
		local previous_time_ms = CoreState.last_time
		if not LogManager.defer_flush_buffer() then
			error("keylogger action buffer was not accepted for deferred flush")
		end
		local action_time_ms = handoff_time_ms
		if type(action_time_ms) ~= "number" then
			local clock_ok, ticks = pcall(hs.timer.absoluteTime)
			action_time_ms = clock_ok and type(ticks) == "number"
				and (ticks / 1000000)
				or previous_time_ms
		end
		CoreState.last_time = action_time_ms
	end
	_last_action_epoch = epoch
end

-- Lazily built keycode → name mapping
local _keycode_to_name = nil





-- =============================================
-- =============================================
-- ======= 4/ Key Event Helper Utilities =======
-- =============================================
-- =============================================

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

--- Returns the foreground application name already maintained by ContextTracker.
--- Native application queries can cross process boundaries and therefore cannot
--- run in the eventtap callback.
--- @return string app_name
local function current_cached_app_name()
	local active_name = CoreState.active_app_name
	if type(active_name) == "string" and active_name ~= "" then return active_name end
	local session_name = CoreState.session_app_name
	if type(session_name) == "string" and session_name ~= "" then return session_name end
	return "Unknown"
end

--- Returns true when the script-control module signals that the script is paused.
--- Used as a fast guard in all timer/watcher callbacks so no data is written
--- to the log while the user has explicitly suspended the keylogger.
_is_paused = function()
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

--- Reports whether any public keylogger sink may persist data right now.
---
--- Enablement, the live script pause, and privacy context are one indivisible
--- gate. Keeping this at the sink boundary matters because shortcut, hotstring,
--- LLM, and synthetic-output writers can all run from timers after the physical
--- eventtap has already returned.
--- @return boolean True when persistence is currently allowed.
function M.may_persist()
	if not CoreState.is_enabled then return false end
	local ok_paused, paused = pcall(_is_paused)
	if not ok_paused then
		Logger.error(LOG, "Pause predicate raised at keylogger sink — persistence denied: %s.", tostring(paused))
		return false
	end
	if paused == true then return false end
	return M.context_allows_logging()
end





-- ========================================
-- ========================================
-- ======= 5/ Event Tap Interceptor =======
-- ========================================
-- ========================================

--- Main eventtap callback. Processes all keyboard and mouse events.
--- Wrapped in pcall to prevent any Lua error from locking the OS keyboard.
--- @param event_obj table The raw hs.eventtap event object.
--- @return boolean False to propagate the event, true to consume it.
--- @return table|nil Older deferred synthetic events ordered before the original.
local function handle_key(event_obj)
	local returned_events = nil
	local consume_original = false
	local ok, err = pcall(function()
		local evt_type = event_obj:getType()

		-- Only an immutable Ergopti user-data tag is synthetic identity. Source PID,
		-- character equality and arrival time cannot distinguish another Spoon, a
		-- sibling action or an older generation. Run this before pause/privacy/state
		-- gates so tagged output can never be persisted during a transition.
		-- Physical mouse/scroll events can be copied and globally replayed behind a
		-- paced keyboard suffix. Those copies carry the same immutable physical-
		-- replay tag as a delayed key and must pass through EventProvenance before
		-- any fence claim; treating every non-keyboard event as foreign re-adopted
		-- the replay forever and the user click/scroll never reached the app.
		local provenance, provenance_status, fence = EventProvenance.classify_with_fence(
			event_obj, "keylogger")
		if fence then
			returned_events = fence.events
			consume_original = fence.consume_original == true
		end
		if consume_original then return end
		-- This tap may be upstream or downstream of keymap. Whichever non-owned
		-- consumer runs first claims every older deferred action in
		-- classify_with_fence(), making the returned payload order independent of
		-- Quartz tap insertion order.

		-- A physical event may beat the timer-zero listener. Re-read after the
		-- synchronous fence claim so both tap orders observe the same boundary.
		local action_epoch, handoff_time_ms = SyntheticInput.current_action_epoch()
		if CoreState.is_enabled and action_epoch ~= _last_action_epoch then
			reconcile_action_epoch(action_epoch, handoff_time_ms)
		end

		if provenance then
			-- Logical action boundaries are process-wide epochs, never whichever
			-- consumer happens to see a transaction's first tagged event. Replacement
			-- text was already recorded logically by notify_synthetic().
			return
		end

		if provenance_status == EventProvenance.STATUS_UNREADABLE then
			-- Preserve the already-observed run through the deferred O(1) outbox, but
			-- do not let an event whose tag could not be read enter human telemetry.
			LogManager.defer_flush_buffer()
			CoreState.modifier_down_at = {}
			CoreState.prev_flags = {}
			return
		end

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
			-- Re-seed the delay baseline. flush_buffer() zeroes CoreState.last_time,
			-- and these three branches RETURN before the keystroke path assigns it —
			-- so the next real keystroke measured its delay against 0, recorded a
			-- zero-millisecond gap, and could be mistaken for synthetic output.
			CoreState.last_time = now
			return
		end
		if evt_type == hs.eventtap.event.types.scrollWheel then
			CoreState.session_mouse_scrolls = CoreState.session_mouse_scrolls + 1
			if #CoreState.buffer_events > 0 then LogManager.flush_buffer() end
			-- Re-seed the delay baseline. flush_buffer() zeroes CoreState.last_time,
			-- and these three branches RETURN before the keystroke path assigns it —
			-- so the next real keystroke measured its delay against 0, recorded a
			-- zero-millisecond gap, and could be mistaken for synthetic output.
			CoreState.last_time = now
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
					LogManager.log_modifier_press(keycode, current_cached_app_name())
				else
					-- Release — compute hold duration and feed the manifest
					local hold_ms = math.floor(now - down_at)
					CoreState.modifier_down_at[keycode] = nil
					LogManager.log_modifier_hold(keycode, current_cached_app_name(), hold_ms)
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
		-- Current-process shortcuts (including paste-backed replacements) already
		-- returned through the provenance guard above, independent of eventtap order.
		if is_shortcut_candidate(flags, keycode) then
			LogManager.flush_buffer()
			-- Same re-seed as the mouse branches: this one returns below without
			-- ever reaching the keystroke path's assignment.
			CoreState.last_time = now
			LogManager.log_shortcut(
				build_shortcut_key(event_obj, flags, keycode),
				current_cached_app_name()
			)
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

		-- Mark session start on the first keystroke after a long idle
		if CoreState.session_start_time == 0 then
			CoreState.session_start_time = now
			LogManager.append_log({ type = "session_start" })
		end

		-- Capture context on the first keystroke of a new buffer
		if #CoreState.buffer_events == 0 then
			CoreState.current_session_pause = math.floor(now - CoreState.last_flush_time)
			-- Read from state the context tracker already maintains, not queried here.
			-- frontmostApplication():title() and mainWindow():title() are cross-process
			-- accessibility calls, and this block runs on the FIRST KEYSTROKE OF EVERY
			-- WORD inside the eventtap callback — the one callback whose overrun makes
			-- macOS disable the tap. The tracker's app watcher sets active_app_name on
			-- every activation and its window handler publishes active_win_title on
			-- every window change, so both are already current.
			CoreState.session_app_name  = CoreState.active_app_name  or "Unknown"
			CoreState.session_win_title = CoreState.active_win_title or "Unknown"
			CoreState.session_layout    = _cached_layout or "Unknown"
			CoreState.session_field_role = "Unknown"
			CoreState.session_url        = nil
		end

		-- Every current-process key event returned through the provenance guard.
		-- The remaining path is therefore physical input; logical synthetic text was
		-- already recorded by notify_synthetic() before its OS echoes were emitted.
		local is_synthetic = false
		local synth_type   = "none"

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
			local correction = not is_synthetic and deleted_char ~= ""
				and { type = "correction", text = deleted_char } or nil
			append_buffer_event(ev_entry, correction, false, now)

		elseif keycode == 48 then
			-- Tab: log as bracket marker and flush (cursor navigation — breaks N-gram context)
			ev_entry = { "[TAB]", delay, meta }
			append_buffer_event(ev_entry, nil, true, now)

		elseif keycode == 53 then
			-- Escape: log then flush (cancel/navigation action, breaks N-gram context)
			ev_entry = { "[ESC]", delay, meta }
			append_buffer_event(ev_entry, nil, true, now)

		elseif keycode == 57 then
			-- Capslock toggle: log the state change (does not flush — no context break)
			ev_entry = { "[CAPS]", delay, meta }
			append_buffer_event(ev_entry, nil, false, now)

		elseif keycode == 36 then
			-- Enter: use bracket marker for n-gram tracking; keep "\n" only in
			-- buffer_text and rich_chunks. The raw "\n" char (LF, code 10) is
			-- stripped by the JS control-character filter, so it must never be
			-- the event key — "[ENTER]" survives the filter and appears in the
			-- characters tab.
			CoreState.buffer_text = CoreState.buffer_text .. "\n"
			ev_entry = { "[ENTER]", delay, meta }
			append_buffer_event(ev_entry, {
				type = is_synthetic and synth_type or "text",
				text = "\n",
			}, true, now)

		elseif F_KEY_CODES[keycode] then
			-- F1–F12: log as bracket marker and flush (context-breaking navigation)
			ev_entry = { "[" .. F_KEY_CODES[keycode] .. "]", delay, meta }
			append_buffer_event(ev_entry, nil, true, now)

		elseif NAV_KEY_CODES[keycode] then
			-- Arrow keys and extended nav (Delete, Home, End, PageUp, PageDown): log as
			-- bracket marker and flush — cursor moved, so N-gram context is broken
			ev_entry = { "[" .. NAV_KEY_CODES[keycode] .. "]", delay, meta }
			append_buffer_event(ev_entry, nil, true, now)

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
					append_buffer_event(sub_entry, {
						type = is_synthetic and synth_type or "text",
						text = sub_char,
					}, sub_char:match("[.?!]") ~= nil or sub_char == " ", now)
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
				append_buffer_event(ev_entry, {
					type = is_synthetic and synth_type or "text",
					text = chars,
				}, chars:match("[.?!]") ~= nil or keycode == 49, now)
			end
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
		pcall(Logger.warn, LOG, "Keyboard lock avoidance triggered: %s.", tostring(err))
	end
	-- A failure after the fence claim may not veto the older user action. Returning
	-- the captured table still places it before the physical original at Quartz.
	return consume_original, returned_events
end





-- ================================================
-- ================================================
-- ======= 6/ Hardware Watchers And Sensors =======
-- ================================================
-- ================================================

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
--- This is the single funnel both the boot sync and the menu toggle go through,
--- which is why the encrypt flag is APPLIED here and not merely recorded: the
--- persisted preference used to be stored in CoreState and nothing else, so a Mac
--- that had encryption turned on came back from a restart with the box ticked and
--- the cipher off — the exact "it says encrypted and nothing is" defect this
--- feature was written to remove.
--- @param opts table The options dictionary.
function M.set_options(opts)
	CoreState.options = type(opts) == "table" and opts or {}

	local TextCipher = require("modules.keylogger.text_cipher")
	local want = CoreState.options.encrypt == true
	if want and not TextCipher.is_available() then
		Logger.error(LOG, "At-rest encryption is configured on but no key can be derived — staying off.")
		want = false
	end
	TextCipher.set_enabled(want)

	-- Pick up a conversion a previous session left unfinished. A RESUME only:
	-- starting one unconditionally would re-read every stored row at every boot,
	-- on Macs that may never have enabled the setting at all.
	require("modules.keylogger.text_migration").resume_for_posture(want)

	Logger.debug(LOG, "Options updated (at-rest encryption: %s).", tostring(want))
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

--- Removes one effective-typing timestamp that existed at an action boundary.
--- A physical key may overtake the timer-zero drain, so timestamps newer than
--- the synthetic action must not be deleted by that older action's backspaces.
--- @param timestamp_ms number Synthetic action timestamp.
local function remove_effective_timestamp_at_or_before(timestamp_ms)
	for index = #CoreState.recent_typing_eff, 1, -1 do
		if CoreState.recent_typing_eff[index] <= timestamp_ms then
			table.remove(CoreState.recent_typing_eff, index)
			return
		end
	end
end

--- Inserts synthetic timestamps without moving them after overtaking keys.
--- @param timestamp_ms number Synthetic action timestamp.
--- @param count number Number of logical characters inserted.
local function insert_effective_timestamps(timestamp_ms, count)
	local insert_at = #CoreState.recent_typing_eff + 1
	for index, recorded_at in ipairs(CoreState.recent_typing_eff) do
		if recorded_at > timestamp_ms then
			insert_at = index
			break
		end
	end
	for _ = 1, count do
		table.insert(CoreState.recent_typing_eff, insert_at, timestamp_ms)
		insert_at = insert_at + 1
	end
end

--- Builds one immutable synthetic typing snapshot after the eventtap returns.
--- @param operation table Captured synthetic action fields.
--- @return table snapshot Deferred typing payload.
local function build_deferred_synthetic_snapshot(operation)
	local buffer_events = {}
	local rich_chunks = {}
	local char_count = 0

	--- Appends one logical synthetic event to the detached snapshot.
	--- @param char string Logical character or backspace marker.
	local function append_virtual(char)
		local recorded = M.recorded_char(char, operation.is_private)
		table.insert(buffer_events, {
			recorded, 0,
			{ s = true, st = operation.source_type, c = false, ss = "none", r = recorded,
				m = "", d = 0, dk = false, cp = false, kc = nil },
		})
		if char ~= "[BS]" then
			table.insert(rich_chunks, { type = operation.source_type, text = recorded })
		end
	end

	Logger.debug(LOG, "Recording synthetic text from '%s' (%d delete(s), %d byte(s))…",
		operation.source_type, operation.deletes, #operation.text)

	for _ = 1, operation.deletes do append_virtual("[BS]") end
	if operation.text ~= "" then
		local ok_len, validated_count = pcall(utf8.len, operation.text)
		if ok_len and validated_count then
			for _, code in utf8.codes(operation.text) do
				append_virtual(utf8.char(code))
			end
			char_count = validated_count
		else
			Logger.warn(LOG, "notify_synthetic: malformed UTF-8 in synthetic text — queuing an opaque fallback entry.")
			append_virtual(operation.text)
			char_count = 1
		end
	end

	for _ = 1, operation.deletes do
		remove_effective_timestamp_at_or_before(operation.timestamp_ms)
	end
	insert_effective_timestamps(operation.timestamp_ms, char_count)
	if char_count > 0 then
		CoreState.session_last_active = math.max(
			CoreState.session_last_active or 0, operation.timestamp_ms)
		if CoreState.session_start_time == 0
			or CoreState.session_start_time > operation.timestamp_ms then
			CoreState.session_start_time = operation.timestamp_ms
		end
	end

	return {
		buffer_events = buffer_events,
		buffer_text = "",
		rich_chunks = rich_chunks,
	}
end

--- @param is_private boolean|nil When true, the content is replaced by a
---        redacted placeholder in every persisted field. Physical echoes are
---        excluded independently by immutable event provenance; this function
---        records only the logical replacement.
function M.notify_synthetic(text, source_type, deletes, source_variant, physical_echo, is_private)
	-- Expander notifies unconditionally, but an opt-in keylogger that is currently
	-- disabled or paused must not accumulate logical events or WPM samples for later.
	if not M.may_persist() then return end
	if text ~= nil and type(text) ~= "string" then
		Logger.error(LOG, "notify_synthetic(): text must be a string or nil.")
		return false
	end
	if deletes ~= nil and type(deletes) ~= "number" then
		Logger.error(LOG, "notify_synthetic(): deletes must be a number or nil.")
		return false
	end

	local timestamp_ms = hs.timer.absoluteTime() / 1000000
	local operation = {
		text = text or "",
		source_type = source_type,
		deletes = deletes and math.max(0, math.floor(deletes)) or 0,
		is_private = is_private == true,
		timestamp_ms = timestamp_ms,
	}

	-- `physical_echo` remains in the public signature for compatibility; immutable
	-- provenance tags, not that payload, identify the later OS echoes.
	if not LogManager.defer_flush_buffer() then
		Logger.error(LOG, "notify_synthetic(): prior typing was not accepted by the outbox.")
		return false
	end
	if operation.deletes > 0 or operation.text ~= "" then
		local accepted = LogManager.defer_typing_builder(function()
			return build_deferred_synthetic_snapshot(operation)
		end)
		if not accepted then
			Logger.error(LOG, "notify_synthetic(): synthetic typing was not accepted by the outbox.")
			return false
		end
	end

	CoreState.last_source_type    = source_type
	CoreState.last_source_variant = type(source_variant) == "string" and source_variant or source_type
	CoreState.last_source_time    = timestamp_ms / 1000
	return true
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
			wpm_eff = math.floor(Metrics.compute_wpm_from_events(#CoreState.recent_typing_eff, window) + 0.5)
		end
		if #CoreState.recent_typing_phys > 1 then
			local window = math.max(now - CoreState.recent_typing_phys[1], WPM_MIN_DURATION_MS)
			wpm_phys = math.floor(Metrics.compute_wpm_from_events(#CoreState.recent_typing_phys, window) + 0.5)
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
	if not M.may_persist() then return end
	if not LogManager.defer_flush_buffer() then
		Logger.error(LOG, "log_hotstring(): prior typing was not accepted by the outbox.")
		return false
	end
	local app_name = CoreState.session_app_name
	local accepted = LogManager.defer_entry_builder(function()
		local net_saved = (utf8.len(replacement) or 0) - (utf8.len(trigger) or 0)
		return {
			type            = "hotstring",
			app             = app_name,
			trigger         = trigger,
			replacement     = replacement,
			h_type          = h_type or "unknown",
			net_saved_chars = net_saved,
			tag             = "<hotstring>" .. replacement .. "</hotstring>",
		}
	end)
	if not accepted then
		Logger.error(LOG, "log_hotstring(): event was not accepted by the outbox.")
		return false
	end
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
	return true
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
	if not M.may_persist() then return end
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
	if not M.may_persist() then return end
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
	if not M.may_persist() then return end
	LogManager.log_shortcut(shortcut_key, app_name or CoreState.session_app_name)
end

--- Logs that a hotstring tooltip was shown to the user.
--- @param app_name string Focus app.
--- @param trigger string The typed trigger.
--- @param replacement string The offered replacement.
--- @param h_type string Hotstring category.
function M.log_hotstring_suggested(app_name, trigger, replacement, h_type)
	if not M.may_persist() then return end
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
	if not M.may_persist() then return end
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
	if not M.may_persist() then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	local c = tonumber(count) or 1
	LogManager.append_log({ type = "llm_suggested", app = target_app, count = c })
	LogManager.increment_manifest_stat(target_app, "llm_suggested", c)
end

--- Logs that an LLM suggestion was dismissed without being accepted.
--- @param app_name string Focus app.
--- @param all_predictions table All predictions that were shown.
function M.log_llm_dismissed(app_name, all_predictions)
	if not M.may_persist() then return end
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
	if not M.may_persist() then return end
	local target_app = (type(app_name) == "string" and app_name ~= "") and app_name or CoreState.session_app_name
	-- The synthetic typing burst is the canonical trigger counter. A manifest
	-- increment here used to be ignored by the whitelist and would double-count
	-- now that clipboard output is represented in the synthetic raw event stream.
	local accepted = LogManager.defer_entry_builder(function()
		local net_saved = (utf8.len(prediction_text or "") or 0) - (deletes or 0)
		return {
			type            = "llm_accepted",
			app             = target_app,
			prediction      = prediction_text or "",
			all_predictions = all_predictions or {},
			chosen_index    = chosen_index or 1,
			deletes         = deletes or 0,
			deleted_text    = deleted_text or "",
			net_saved_chars = net_saved,
		}
	end)
	if not accepted then
		Logger.error(LOG, "log_llm_accepted(): event was not accepted by the outbox.")
		return false
	end
	CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
	return true
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

--- Probes the documented native running state of one timer.
--- @param handle table|userdata Native timer.
--- @param expected boolean Required running state.
--- @return boolean matches True only when the exact state is observable and matches.
local function timer_running_matches(handle, expected)
	local readable, method_or_state = pcall(function() return handle.running end)
	if not readable then return false end
	if type(method_or_state) == "function" then
		local ok, running = xpcall(function() return method_or_state(handle) end,
			debug.traceback)
		return ok and type(running) == "boolean" and running == expected
	end
	-- Narrow table doubles historically exposed the state as a boolean field.
	-- Real Hammerspoon timers take the documented method branch above.
	return type(handle) == "table"
		and type(method_or_state) == "boolean"
		and method_or_state == expected
end

--- Stops one retained timer and clears it only after exact inactive-state proof.
--- @param handle table|userdata|nil Native timer.
--- @param clear function Clears the owning module field after commitment.
--- @return boolean stopped True when no retry debt remains.
local function stop_retained_timer(handle, clear)
	if not handle then return true end
	if type(handle.stop) ~= "function" then return false end
	local stopped, result = xpcall(function() return handle:stop() end, debug.traceback)
	if not stopped or not result or not timer_running_matches(handle, false) then return false end
	clear()
	return true
end

--- Stops the retained caffeinate watcher through its documented object result.
--- The watcher API exposes no running-state method, so exact-handle identity is
--- the strongest state contract available after a non-throwing stop.
--- @return boolean stopped True when no retry debt remains.
local function stop_caffeinate_watcher()
	local watcher = _caffeinate_watcher
	if not watcher then return true end
	if type(watcher.stop) ~= "function" then return false end
	local stopped, result = xpcall(function() return watcher:stop() end, debug.traceback)
	if not stopped or result ~= watcher then return false end
	if _caffeinate_watcher == watcher then _caffeinate_watcher = nil end
	return true
end

--- Constructs, publishes, and commits one repeating native timer.
--- @param interval number Repeat interval in seconds.
--- @param callback function Generation-fenced callback.
--- @param publish function Publishes the exact candidate before start.
--- @return boolean committed True only when running() proves activation.
local function acquire_recurring_timer(interval, callback, publish)
	local created, candidate = xpcall(function()
		return hs.timer.new(interval, callback)
	end, debug.traceback)
	if not created or not candidate then return false end
	publish(candidate)
	local started, result = xpcall(function()
		if type(candidate.start) ~= "function" then error("timer has no start method") end
		return candidate:start()
	end, debug.traceback)
	return started and result ~= nil and result ~= false
		and timer_running_matches(candidate, true)
end

--- Invokes a native callback only for the currently committed runtime generation.
--- @param generation integer Generation captured before native construction.
--- @param label string Callback label for diagnostics.
--- @param callback function Callback body.
--- @param ... any Native callback arguments.
local function invoke_runtime_callback(generation, label, callback, ...)
	if generation ~= _runtime_generation or not CoreState.is_enabled then return end
	local args = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback raised: %s.", label, tostring(err))
	end
end

--- Runs every keylogger cleanup owner independently and retains failed steps.
--- @return boolean complete True only when every runtime owner is released.
local function teardown_runtime()
	_runtime_generation = _runtime_generation + 1
	CoreState.is_enabled = false
	CoreState.is_secure_field = true
	local steps = {
		{
			name = "input-source-subscription",
			run = function()
				if not _layout_listener then return true end
				if InputSourceBroker.unsubscribe(INPUT_SOURCE_SUBSCRIBER_ID) ~= true then
					return false
				end
				_layout_listener = nil
				return true
			end,
		},
		{
			name = "action-listener",
			run = function()
				if not _action_listener_registered then return true end
				if SyntheticInput.unregister_action_listener(ACTION_EPOCH_LISTENER_ID) == false then
					return false
				end
				_action_listener_registered = false
				return true
			end,
		},
		{
			name = "active-app-interval",
			run = function()
				if not _state or type(ContextTracker.close_active_app) ~= "function" then return true end
				return ContextTracker.close_active_app() ~= false
			end,
		},
		{
			name = "buffer-flush",
			run = function()
				if not _state or type(LogManager.flush_buffer) ~= "function" then return true end
				return LogManager.flush_buffer() ~= false
			end,
		},
		{
			name = "process-lifecycle",
			run = function()
				if not _process_lifecycle_cleanup_required then return true end
				if ProcessLifecycle.stop() ~= true then return false end
				_process_lifecycle_cleanup_required = false
				return true
			end,
		},
		{
			name = "keyboard-hook",
			run = function()
				if not _keyboard_hook_cleanup_required then return true end
				if KeyboardHook.stop() ~= true then return false end
				_keyboard_hook_cleanup_required = false
				_event_tap = nil
				return true
			end,
		},
		{
			name = "foreground-bootstrap",
			run = function()
				return stop_retained_timer(_foreground_bootstrap_timer, function()
					_foreground_bootstrap_timer = nil
				end)
			end,
		},
		{
			name = "browser-window-filter",
			run = function()
				if not _win_filter then return true end
				if type(_win_filter.unsubscribeAll) ~= "function" then return false end
				if _win_filter:unsubscribeAll() == false then return false end
				_win_filter = nil
				return true
			end,
		},
		{
			name = "maintenance-timer",
			run = function()
				return stop_retained_timer(_maintenance_timer, function()
					_maintenance_timer = nil
				end)
			end,
		},
		{
			name = "idle-timer",
			run = function()
				return stop_retained_timer(_idle_timer, function() _idle_timer = nil end)
			end,
		},
		{
			name = "tap-watchdog",
			run = function()
				return stop_retained_timer(_tap_watchdog_timer, function()
					_tap_watchdog_timer = nil
				end)
			end,
		},
		{
			name = "caffeinate-watcher",
			run = stop_caffeinate_watcher,
		},
		{
			name = "ax-observer",
			run = function()
				local observer = CoreState.ax_observer
				if not observer then return true end
				if type(observer.stop) ~= "function" then return false end
				if observer:stop() == false then return false end
				if CoreState.ax_observer == observer then CoreState.ax_observer = nil end
				return true
			end,
		},
		{
			name = "hardware-watchers",
			run = function()
				if not _state then return true end
				return Watchers.stop_hardware_watchers() == true
			end,
		},
		{
			name = "log-manager",
			run = function()
				if not _log_manager_cleanup_required then return true end
				if type(LogManager.stop) ~= "function" or LogManager.stop() ~= true then
					return false
				end
				_log_manager_cleanup_required = false
				return true
			end,
		},
	}
	return TeardownTransaction.run(_teardown_state, steps)
end

--- Starts the keylogger engine and all background daemons.
--- Idempotent: calling it a second time while running is a no-op.
--- @param script_control table The module used to check expansion pauses.
function M.start(script_control)
	if CoreState.is_enabled then
		Logger.warn(LOG, "M.start() called while already running — ignoring.")
		return true
	end
	if not teardown_runtime() then
		Logger.error(LOG, "Keylogger start refused: prior cleanup remains pending.")
		return false
	end
	_teardown_state = TeardownTransaction.new_state()
	Logger.start(LOG, "Starting keylogger engine…")
	_script_control = script_control

	-- Seed the layout cache and keep it current from the OS notification. The
	-- per-word context snapshot used to call hs.keycodes.currentLayout() itself,
	-- inside the eventtap callback; the layout only changes when the system says so,
	-- so one read plus a listener replaces one read per word.
	local ok_layout, layout = pcall(hs.keycodes.currentLayout)
	_cached_layout = (ok_layout and type(layout) == "string") and layout or "Unknown"
	local startup_prepared, startup_prepare_err = xpcall(function()
	if type(InputSourceBroker.subscribe) ~= "function" then
		error("input-source broker is unavailable")
	end
	_layout_listener = true
	local subscribed = InputSourceBroker.subscribe(INPUT_SOURCE_SUBSCRIBER_ID,
		function()
			local ok_new, new_layout = pcall(hs.keycodes.currentLayout)
			if ok_new and type(new_layout) == "string" then
				_cached_layout = new_layout
				Logger.debug(LOG, "Layout cache refreshed: %s.", new_layout)
			end
		end)
	if subscribed ~= true then error("input-source subscription failed") end

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
		_log_manager_cleanup_required = true
		if LogManager.init(CoreState) ~= true then
			error("log manager refused initialization")
		end
		-- The context tracker owns three OS watchers that pause does NOT tear down,
		-- so it needs the same pause predicate as the watcher layer below.
		if ContextTracker.init(CoreState, LogManager, _is_paused) ~= true then
			error("keylogger context tracker initialization failed")
		end
		-- The watcher layer needs the shared state and the pause predicate; both
		-- are stable for the process lifetime, so a one-shot init is sufficient.
		if Watchers.init(CoreState, _is_paused) ~= true then
			error("keylogger watcher initialization failed")
		end
		_state = true
	end

	-- Security-critical application lifecycle must commit before any keyboard
	-- hook or persistence producer is enabled. A missing app watcher would leave
	-- the secure-field context stale while the keylogger continued recording.
	if not _process_lifecycle_registered then
		ProcessLifecycle.onAppActivate(function(app_name, app_object)
			local context_ok, context_err = xpcall(function()
				ContextTracker.app_watcher_cb(app_name,
					hs.application.watcher.activated, app_object)
			end, debug.traceback)
			if not context_ok then
				CoreState.is_secure_field = true
				Logger.error(LOG, "Application context refresh failed — logging disabled: %s.",
					tostring(context_err))
				return
			end
			if BROWSER_APP_SET[app_name] then
				local filter_ok, filter_err = xpcall(ensure_browser_window_filter,
					debug.traceback)
				if not filter_ok then
					Logger.error(LOG, "Optional browser window-filter setup failed: %s.",
						tostring(filter_err))
				end
			end
		end)
		_process_lifecycle_registered = true
	end
	end, debug.traceback)
	if not startup_prepared then
		CoreState.is_secure_field = true
		Logger.error(LOG, "Keylogger preparation failed: %s", tostring(startup_prepare_err))
		if not teardown_runtime() then
			Logger.error(LOG, "Keylogger preparation rollback remains incomplete.")
		end
		return false
	end
	local acquired, acquire_err = xpcall(function()
		_runtime_generation = _runtime_generation + 1
		local runtime_generation = _runtime_generation
		_process_lifecycle_cleanup_required = true
		if ProcessLifecycle.start() ~= true then
			error("application lifecycle watcher is unavailable")
		end
		KcBridge.set_log_manager(LogManager)
		if KcBridge.start() ~= true then error("KC bridge refused startup") end
		_kc_bridge_shutdown_complete = false
		-- A normal OFF stops LogManager but deliberately preserves its initialized
		-- state. ensure_ingest_running() then reacquires the timer/database on ON;
		-- publish that cleanup obligation before the call so a partial throw and the
		-- next OFF both release the exact rearmed owner.
		_log_manager_cleanup_required = true
		if LogManager.ensure_ingest_running() ~= true then
			error("log ingest refused startup")
		end
		if not _action_listener_registered then
			reconcile_action_epoch(SyntheticInput.current_action_epoch())
			if SyntheticInput.register_action_listener(ACTION_EPOCH_LISTENER_ID,
				reconcile_action_epoch) == false then
				error("action listener refused startup")
			end
			_action_listener_registered = true
		end

		CoreState.is_secure_field = true
		CoreState.last_flush_time = hs.timer.absoluteTime() / 1000000
		CoreState.recent_typing_eff = {}
		CoreState.recent_typing_phys = {}

		local caffeinate_created, caffeinate_candidate = xpcall(function()
			return hs.caffeinate.watcher.new(function(...)
				invoke_runtime_callback(runtime_generation, "Caffeinate watcher",
					Watchers.caffeinate_cb, ...)
			end)
		end, debug.traceback)
		if not caffeinate_created or not caffeinate_candidate then
			error("caffeinate watcher construction failed")
		end
		_caffeinate_watcher = caffeinate_candidate
		local caffeinate_started, caffeinate_result = xpcall(function()
			if type(caffeinate_candidate.start) ~= "function" then
				error("caffeinate watcher has no start method")
			end
			return caffeinate_candidate:start()
		end, debug.traceback)
		if not caffeinate_started or caffeinate_result ~= caffeinate_candidate then
			error("caffeinate watcher refused startup")
		end
		if Watchers.init_hardware_watchers() ~= true then
			error("hardware watchers refused startup")
		end

		local keyboard_hook_options = {
			eventTypes = {
				hs.eventtap.event.types.keyDown,
				hs.eventtap.event.types.flagsChanged,
				hs.eventtap.event.types.leftMouseDown,
				hs.eventtap.event.types.rightMouseDown,
				hs.eventtap.event.types.scrollWheel,
			},
			onEvent = handle_key,
		}
		_keyboard_hook_cleanup_required = true
		if KeyboardHook.start(keyboard_hook_options) ~= true
			or KeyboardHook.isRunning() ~= true then
			error("keyboard event tap is unavailable")
		end
		_event_tap = true

		local watchdog_committed = acquire_recurring_timer(TAP_WATCHDOG_INTERVAL_SEC,
			function()
				invoke_runtime_callback(runtime_generation, "Event tap watchdog", function()
				if not KeyboardHook.isRunning() then
					CoreState.is_secure_field = true
					Logger.warn(LOG, "Keylogger event tap found disabled — restarting.")
					local restart_ok, restarted = Logger.pcall(LOG, KeyboardHook.start)
					local state_ok, running = Logger.pcall(LOG, KeyboardHook.isRunning)
					if restart_ok and restarted == true and state_ok and running == true then
						local capture_ok, captured = Logger.pcall(LOG,
							ContextTracker.capture_frontmost_app)
						if not capture_ok or captured ~= true then
							CoreState.is_secure_field = true
							Logger.error(LOG,
								"Keylogger event tap recovered without a trusted context.")
						end
					else
						Logger.error(LOG,
							"Keylogger event tap restart failed — persistence disabled until recovery.")
					end
				end
				end)
			end, function(candidate) _tap_watchdog_timer = candidate end)
		if not watchdog_committed then
			error("event tap watchdog refused startup")
		end

		local idle_committed = acquire_recurring_timer(IDLE_CHECK_INTERVAL_SEC,
			function()
				invoke_runtime_callback(runtime_generation, "Idle timer", Watchers.check_idle)
			end, function(candidate) _idle_timer = candidate end)
		if not idle_committed then
			error("idle timer refused startup")
		end
		local maintenance_committed = acquire_recurring_timer(MAINTENANCE_INTERVAL_SEC,
			function()
				invoke_runtime_callback(runtime_generation, "Maintenance timer",
					Watchers.perform_maintenance)
			end, function(candidate) _maintenance_timer = candidate end)
		if not maintenance_committed then
			error("maintenance timer refused startup")
		end

		local bootstrap_candidate
		local bootstrap_activation_in_progress = true
		local bootstrap_delivered_before_commit = false
		local bootstrap_delivered = false
		local bootstrap_committed = acquire_recurring_timer(0, function()
			if bootstrap_activation_in_progress then
				bootstrap_delivered_before_commit = true
				return
			end
			invoke_runtime_callback(runtime_generation, "Foreground-context bootstrap", function()
				if bootstrap_delivered then
					if _foreground_bootstrap_timer == bootstrap_candidate then
						stop_retained_timer(bootstrap_candidate, function()
							_foreground_bootstrap_timer = nil
						end)
					end
					return
				end
				bootstrap_delivered = true
				if not stop_retained_timer(bootstrap_candidate, function()
					_foreground_bootstrap_timer = nil
				end) then
					Logger.error(LOG,
						"Foreground-context bootstrap cleanup remains pending.")
				end
				local ok_capture, captured = Logger.pcall(LOG,
					ContextTracker.capture_frontmost_app)
				if not ok_capture or captured ~= true then
					CoreState.is_secure_field = true
					Logger.error(LOG,
						"Initial application context was unavailable — logging remains disabled.")
				end
			end)
		end, function(candidate)
			bootstrap_candidate = candidate
			_foreground_bootstrap_timer = candidate
		end)
		bootstrap_activation_in_progress = false
		if not bootstrap_committed or bootstrap_delivered_before_commit then
			error("foreground-context bootstrap timer refused startup")
		end

		CoreState.is_enabled = true
		Logger.success(LOG, "Keylogger engine started.")
	end, debug.traceback)
	if not acquired then
		CoreState.is_secure_field = true
		Logger.error(LOG, "Keylogger start aborted: %s", tostring(acquire_err))
		if not teardown_runtime() then
			Logger.error(LOG, "Keylogger startup rollback remains incomplete.")
		end
		return false
	end

	-- New persistence model: data.sql is the canonical source of truth and
	-- the SQLite cache in tmpdir is reconstructed by log_manager.M.init().
	-- No deferred rebuild dance is needed at boot — the ingest tick will
	-- catch up on any today.log entries written by a previous keylogger
	-- session that did not get flushed before exit.
	return true
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
	-- An unmatched down carries no usable duration, so discard it.
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
	local was_enabled = CoreState.is_enabled
	if was_enabled then Logger.start(LOG, "Stopping keylogger engine…") end
	local complete = teardown_runtime()
	if complete then
		if was_enabled then
			Logger.success(LOG, "Keylogger engine stopped.")
		else
			Logger.warn(LOG, "M.stop() called while not running — cleanup verified.")
		end
	else
		Logger.error(LOG, "Keylogger stopped fail-closed; cleanup remains pending.")
	end
	return complete
end

--- Terminates feature resources and the always-on physical-key ledger drain.
--- Feature OFF intentionally calls M.stop() so the bridge keeps advancing its
--- file cursor; only process teardown may call this terminal lifecycle method.
--- @return boolean complete True only when feature and bridge cleanup both commit.
function M.shutdown()
	local feature_complete = teardown_runtime()
	if not _kc_bridge_shutdown_complete then
		local stopped, result = xpcall(KcBridge.stop, debug.traceback)
		if stopped and result == true then
			_kc_bridge_shutdown_complete = true
		else
			Logger.error(LOG, "KC bridge terminal cleanup remains pending: %s.",
				tostring(result))
		end
	end
	return feature_complete and _kc_bridge_shutdown_complete
end

return M

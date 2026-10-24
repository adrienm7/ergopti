--- modules/keystats/keystats.lua

--- ==============================================================================
--- MODULE: Full Keystats (Linux)
--- DESCRIPTION:
--- Extends metrics_collector with app-level grouping, password-field detection,
--- JSON export, and SQLite-based persistence. Wraps the existing metrics_collector
--- so the daemon has a single keystats surface. Equivalent to the macOS/Windows
--- keystats modules (keystats.lua / keystats.ahk).
---
--- FEATURES & RATIONALE:
--- 1. App-level grouping: tracks keystroke counts and WPM per application
---    (identified by the window_info adapter's appId). Enables per-app metrics
---    dashboards and app-specific typing profiles.
--- 2. Password detection: when the focused app is a known password manager or
---    secure field, keystroke logging is suppressed (counts excluded from stats).
--- 3. JSON export: export_session() returns a JSON-serializable snapshot of
---    all accumulated metrics — suitable for the shared healthcheck or WPM widget.
--- 4. SQLite persistence: flush() writes the current session into the
---    canonical SQLite schema (_shared/data/db/schema.sql) via the sqlite_writer
---    module (sqlite3 CLI wrapper). The shared metrics dashboard reads the same
---    schema across macOS, Windows, and Linux.
--- 5. Graceful degradation: when the sqlite3 binary is absent, flush() writes a
---    JSON log file instead (~/.config/ergopti/logs/keystrokes_YYYY-MM-DD.json).
--- ==============================================================================

local M = {}

local Logger   = require("logger.shim")
local Monotonic = require("infra.monotonic")
local Perf = require("infra.perf_counters")
local Timings   = require("infra.timings")
local EvdevCodes = require("infra.evdev_codes")
-- Hard requires: the privacy posture must come from the shared manifest, and a
-- missing filter must fail loudly rather than degrade into "record everything".
local Manifest      = require("infra.manifest_reader")
local PrivateWindow = require("keystats.private_window")
-- WPM ring cap single-sourced from the shared keystats metrics module so the
-- per-app rings below never drift from the collector's global ring cap.
local SharedMetrics    = require("keystats.metrics")
local Utils            = require("keystats.utils")
local WPM_RING_CAPACITY = SharedMetrics.DEFAULT_WPM_RING_CAPACITY
local MAX_TYPING_INTERVAL_MS = Timings.ms("keystats", "max_keystroke_delay_ms")
-- The WPM readouts' live speed and last source, the same tracker macOS reads.
-- Counted here because every character that reaches the page passes here —
-- typed, expanded or generated — and only here is it known which it was.
local LiveWpm = require("keystats.live_wpm")
local PointerMetrics = require("modules.keystats.pointer_metrics")
local function new_live_tracker()
	return LiveWpm.new({
		window_ms = Timings.ms("keystats", "wpm_window_ms"),
		min_duration_ms = Timings.ms("keystats", "wpm_min_duration_ms"),
		idle_reset_ms = Timings.ms("keystats", "wpm_idle_reset_ms"),
	})
end
local _live = new_live_tracker()

-- The typing session's start and end and its idle spans (events_session), the
-- state machine macOS and Windows run, ticked by the periodic flush.
local SessionEvents = require("keystats.session_events")
local function new_session_tracker()
	return SessionEvents.new({
		micro_idle_ms = Timings.ms("keystats", "micro_idle_timeout_ms"),
		session_timeout_ms = Timings.ms("keystats", "session_timeout_ms"),
	})
end
local _session = new_session_tracker()

-- For converting os.time()'s seconds to the millisecond scale the monotonic
-- clock reports in, so the two can be subtracted.
local MS_PER_SECOND = 1000

-- Past this, a press was a HOLD rather than a tap. Read from the tap-hold
-- configuration this daemon runs, so the metrics call something a hold exactly
-- when the engine does — a number of its own here would let the dashboard call
-- a tap what the keyboard treated as a hold. Asked each time: a change from the
-- tray reloads the engine live.
--
-- nil when the keys disagree or nothing is configured, and the split is then
-- declined rather than made on a number nobody chose. The duration, the count
-- and the maximum are still recorded: those need no threshold.
local TapHold = require("platform.remap.tap_hold_manager")

--- @return number|nil
local function tap_hold_threshold_ms()
	return TapHold.threshold_ms()
end
-- Metrics collector is optional — keystats falls back gracefully without it.
local Metrics  = nil
local ok_mc, mc_mod = pcall(require, "modules.keystats.metrics_collector")
if ok_mc then Metrics = mc_mod end

-- SQLite writer — optional (falls back to JSON when sqlite3 CLI is absent).
local SqliteWriter = nil
local ok_sw, sw_mod = pcall(require, "modules.keystats.sqlite_writer")
if ok_sw then SqliteWriter = sw_mod end

local SqliteReader = nil
local ok_sr, sr_mod = pcall(require, "modules.keystats.sqlite_reader")
if ok_sr then SqliteReader = sr_mod end

-- At-rest encryption of the typed-text columns. Hard require: the setting must
-- never silently degrade into "stored in clear".
local TextCipher = require("modules.keystats.text_cipher")
-- Bulk conversion of rows written BEFORE the setting changed. Without it the
-- toggle only ever protects the future, which is not what a user with a year of
-- logs is asking for when they tick it.
local TextMigration = require("modules.keystats.text_migration")
local MigrationPlan = require("keystats.text_migration")
-- Battery, network, lock and suspend. Optional: a machine with none of the
-- tools it reads simply reports nothing, and the typing path must not care.
local SystemMetrics = nil
local ok_sysmetrics, sysmetrics_mod = pcall(require, "modules.keystats.system_metrics")
if ok_sysmetrics then SystemMetrics = sysmetrics_mod end

-- The nine n-gram families, over the shared driver-agnostic accumulators.
local AggregateWalker = require("modules.keystats.aggregate_walker")

local LOG = "modules.keystats.keystats"

-- What a private expansion's characters are persisted as. U+2022 BULLET, the
-- same character macOS substitutes (keystats/init.lua), so a database merged
-- across a user's two machines redacts identically on both.
local PRIVATE_PLACEHOLDER_CHAR = "\226\128\162"

-- The token one deletion travels as in the portable events_json stream, the
-- same bracket marker the Windows hook and the macOS event tap write.
local BACKSPACE_MARKER = "[BS]"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Per-app accumulators: { [appId] = { keystroke_count, wpm_ring, char_window, ngrams } }
local _app_stats = {}

-- Foreground application accounting is independent of keystroke collection so
-- the apps dashboard can represent focused reading, video calls, and coding
-- pauses as well as text entry.
local _focused_app_id         = nil
local _focused_app_started_at = nil

-- Last persisted cumulative values by app. SQLite app-day rows are additive;
-- flushing cumulative counters again would duplicate every earlier keypress.
local _flushed_app_totals = {}

-- Raw events remain the audit source of truth. They are buffered per app until
-- flush, then written in the exact events_* tables used by macOS and Windows.
local _pending_typing_events = {}
local _pending_hotstring_events = {}
-- Shortcut firings, buffered like their hotstring siblings. macOS has recorded
-- these since its keystats existed; this driver recorded nothing, so every
-- action that types no text — CapsWord, the selection transforms, the wrapping
-- pairs, everything an extension registers — was absent from the metrics.
local _pending_shortcut_events = {}
-- LLM prediction events (generation, suggested, dismissed, accepted), buffered like their
-- siblings and written to events_llm so the dashboard's AI tab has rows on this driver too.
local _pending_llm_events = {}
local _pending_app_switch_events = {}
-- Window title changes, written to events_window_switch as Windows and macOS do:
-- the dashboard's per-application context shifts read them.
local _pending_window_switch_events = {}
-- events_session rows produced by _session.
local _pending_session_events = {}
-- events_system rows: the machine's transitions system_metrics observed.
local _pending_system_events = {}

--- Buffers the session events the tracker produced, stamped now.
--- @param events table { kind, duration_ms? } in order.
local function queue_session_events(events)
	for _, event in ipairs(events) do
		_pending_session_events[#_pending_session_events + 1] = {
			ts = os.date("!%Y-%m-%d %H:%M:%S"), date = os.date("%Y-%m-%d"),
			kind = event.kind, duration_ms = event.duration_ms,
		}
	end
end
-- The observed pointers' stream, measured into the mouse columns of the
-- focused application's next typing row (pending.mouse), as on macOS.
local _pointer = PointerMetrics.new()
local _flush_state, _flush_stopping, _flush_pumping = nil, false, false
local _flush_generation, _stop_final_dispatched, _stop_fallback_attempted = 0, false, false
local _flush_listeners = {}
local _last_flush_committed = false
local _flush_unavailable_warned = false
-- The window title currently focused, and when it became so. Held rather than
-- asked for at flush, because a flush lands between keystrokes and the title by
-- then may already be the next one.
--
-- Declared HERE, in the state section, and not beside the setter three hundred
-- lines below: a `local` written after a function that reads it is not captured
-- — the function binds the nil GLOBAL instead, and the read silently does
-- nothing. record_app_key reads this, and the first version of it declared the
-- variable next to its setter. Three bugs of exactly that shape have already
-- been fixed in this driver.
local _current_title = nil
local _title_since = nil
-- When _current_title came to the front. _title_since restarts at every report
-- of the same title; a window switch lasts from the change to the next change.
local _title_entered_at = nil
-- Which application owned _current_title when it was reported. The title is
-- global while applications are not: closing the interval against the
-- incoming application credits nothing (its titles table has no such row)
-- and every later keystroke misses its count the same way. Declared here in
-- the state section, beside the two locals it belongs with.

local _flushed_app_titles = {}
local _flushed_app_holds = {}
local _flushed_app_ngrams = {}
local _flushed_app_scancodes = {}
local _flushed_app_sources = {}
-- Each application's aggregate-walk context as of the last COMMIT: the word,
-- sequence, correction, burst and session still open when that flush was cut.
-- A flush adopts its successor only on COMMIT, so a refused one re-walks its
-- restored events from exactly this state.
local _walker_contexts = {}
-- The sessions and bursts a previous process left open, read back from the
-- open-walk record its last COMMIT wrote. A crash ends them where they were:
-- the next flush credits them once, and its COMMIT clears this.
local _recovered_walks = nil
-- The open-walk record as the last COMMIT left it, so a flush rewrites it only
-- when it changed: an idle daemon must not open a transaction every interval.
local _persisted_open_walk = nil
-- Assigned beside the flush capture; declared here so init() binds the local.
local decode_open_walk
-- The monotonic stamp of each application's last manual keystroke. Kept
-- across flushes: a fresh pending buffer has none, and its first keystroke
-- then read as zero milliseconds after the previous one, however long ago
-- that was, and every expansion typed first in a flush had no stamp at all.
local _typing_last_key_at = {}

-- Persisted manifest cache keyed by SQLite's monotonic revision. The live
-- delta is layered on a shallow copy, so an open dashboard avoids a CLI query
-- every two seconds without ever serving stale keystrokes.
local _manifest_cache = { revision = nil, manifest = nil }

-- Whether password-field suppression is active.
local _suppressed = false

-- Whether the user paused metrics collection from the Metrics menu. A state of
-- its own: the password flag above is driven by the focused application and is
-- cleared whenever focus moves, which would silently end a pause the user set.
-- Never persisted, so every launch starts recording as its settings say.
local _suspended = false

-- Cross-driver privacy posture, read from the shared features manifest so the
-- three drivers cannot drift. Linux had none of these: it recorded
-- unconditionally, because the metrics section of the manifest did not list
-- "linux" and the codegen emitted no manifest for this driver to read.
--
-- Where each toggle's user choice is kept, and the shape of that keeping: only a
-- CHANGE from the shipped default is stored. Persisting the default too would
-- freeze today's default for anyone who had already run the driver, which is the
-- same reasoning the dynamic-hotstring families are stored under.
--
-- Until 2026-08-06 nothing was stored at all. Every one of these reverted to the
-- manifest default at the next start, so a user who switched metrics off found
-- them back on after a reboot — and the two filters they had deliberately
-- relaxed silently tightened again, which is the harmless direction. The master
-- switch is the other direction: off means off, and it did not stay off.
local Preferences = require("infra.metrics_preferences")
local KEY  = require("config_keys").KEY
local LEAF = require("config_keys").LEAF

--- Persists a boolean, or clears it when it matches the shipped default.
--- @param key string A config_keys.KEY value.
--- @param value boolean
--- @return boolean
local function store_bool(key, value)
	return Preferences.set(key, value)
end

local _DEFAULTS = {
	enabled                    = Manifest.default_for(KEY.METRICS_ENABLED),
	private_filter_enabled     = Manifest.default_for(KEY.METRICS_PRIVATE_FILTER_ENABLED),
	secure_filter_enabled      = Manifest.default_for(KEY.METRICS_SECURE_FILTER_ENABLED),
	system_auth_filter_enabled = Manifest.default_for(KEY.METRICS_SYSTEM_AUTH_FILTER_ENABLED),
	encrypt                    = Manifest.default_for(KEY.METRICS_ENCRYPT),
}

-- Seeded from the manifest at LOAD, and re-seeded from config.toml inside M.init().
--
-- Reading the store here was the first version and it was wrong twice over. It
-- gave this module a file-system dependency at require time that it never had —
-- so requiring it began touching $HOME, and any consumer that had only ever
-- needed the type suddenly needed a working config directory. And it made the
-- module's state depend on load ORDER, which differs between the machine this is
-- developed on and the one it is gated on: `dir /b /s` and `find` do not return
-- the suite in the same sequence, and four password-suppression tests failed on
-- one and not the other for reasons that had nothing to do with passwords.
--
-- init() is where a driver decides what it is; that is where the user's stored
-- choice belongs. Anything that reads a flag before init gets the shipped
-- default, which is exactly what it got before any of this existed.
local _enabled                    = _DEFAULTS.enabled
local _private_filter_enabled     = _DEFAULTS.private_filter_enabled
local _secure_filter_enabled      = _DEFAULTS.secure_filter_enabled
local _system_auth_filter_enabled = _DEFAULTS.system_auth_filter_enabled
local _encrypt_enabled            = _DEFAULTS.encrypt

-- Applications the user excluded from recording, as a lower-cased set; the
-- configured list is `metrics.disabled_apps`.
local _disabled_apps = {}
-- The same list in its configured order, for the menu and the scope snapshot.
local _disabled_list = {}

--- Builds the lower-cased exclusion set of a configured list.
--- @param list table Application identifiers.
--- @return table set
local function exclusion_set(list)
	local set = {}
	for _, app in ipairs(list) do set[app:lower()] = true end
	return set
end

-- Whether the focused window is a private/incognito browser session. Set from
-- the focus-change callback, never computed on the keystroke path.
local _private_window = false

-- Whether the AT-SPI adapter reported a secure field on the focused window.
-- Also set from the focus-change callback: the probe spawns a subprocess and
-- has no business running once per keystroke.
local _secure_field = false

-- Password managers and credential UIs (case-insensitive substring match on
-- appId). Gated by metrics.secure_filter_enabled.
--
-- NOTE: intentionally distinct from the AT-SPI adapter's
-- secure_field_detector.SECURE_APP_IDS (exact WM_CLASS match, smaller list e.g.
-- keepassxc). The adapter is consulted IN ADDITION to this list, never instead
-- of it: it matches exactly, so delegating would NARROW coverage and leak
-- keystrokes. The broad coverage is locked by the "coverage must never narrow"
-- guard in tests/unit/modules/keystats/core/test_keystats.lua.
local _SECURE_APPS = {
	"1password", "bitwarden", "keepass", "lastpass",
}

-- OS-level authentication prompts. Gated by metrics.system_auth_filter_enabled,
-- matching the "system_auth" category of the shared no-persist corpus.
local _SYSTEM_AUTH_APPS = {
	"gpg", "ssh-agent", "polkit", "sudo",
}

-- The union both flags cover when enabled — which is the default, so the eight
-- entries that were previously one flat list still all match.
local _DEFAULT_PASSWORD_APPS = {}
for _, app in ipairs(_SECURE_APPS) do _DEFAULT_PASSWORD_APPS[#_DEFAULT_PASSWORD_APPS + 1] = app end
for _, app in ipairs(_SYSTEM_AUTH_APPS) do _DEFAULT_PASSWORD_APPS[#_DEFAULT_PASSWORD_APPS + 1] = app end

-- Returns a fresh shallow copy so per-init appends never mutate the base list.
local function _default_password_apps()
	local out = {}
	for i = 1, #_DEFAULT_PASSWORD_APPS do out[i] = _DEFAULT_PASSWORD_APPS[i] end
	return out
end

-- Returns a fresh shallow copy of the secure-app base list.
local function _default_secure_apps()
	local out = {}
	for i = 1, #_SECURE_APPS do out[i] = _SECURE_APPS[i] end
	return out
end

-- Active secure-app list (base + any custom apps supplied to init). Custom
-- entries join this list rather than the system-auth one: a user-supplied app is
-- a credential UI, not an OS authentication prompt.
local _secure_apps = _default_secure_apps()

-- Active full list, kept for diagnostics and the stats snapshot.
local _password_apps = _default_password_apps()

--- The single decision point for "may this keystroke be recorded?".
--- Every recording entry point asks this and nothing else, so a new filter is
--- added in one place and cannot be forgotten on one of the five paths.
--- @return boolean
local function may_record()
	if _flush_stopping then return false end
	if not _enabled then return false end
	if _suppressed or _suspended then return false end
	if _secure_filter_enabled and _secure_field then return false end
	if _private_filter_enabled and _private_window then return false end
	return true
end

-- Opaque producer authority: excluded time can never be reconstructed on release.
local _hold_token = {}
local _hold_focus_app = nil
local settle_hold_policy

-- Base directory for log file persistence (JSON fallback).
local _log_dir = nil

-- SQLite database path (primary persistence).
local _sqlite_path = nil

-- Device identifier for SQLite registration (derived from hostname).
local _device_id = "linux-unknown"

-- Session start timestamp for export.
local _session_started_at = nil

-- Forward-declaration: _to_json is defined in section 8 but called from section 6.
local _to_json

local function char_count(text)
	if type(text) ~= "string" then return 0 end
	local ok, count = pcall(utf8.len, text)
	return ok and count or #text
end

--- Returns the per-app accumulator, creating an empty one when required.
--- @param app_id string Focused application identifier.
--- @param timestamp_ms number Timestamp used to seed the first-seen value.
--- @return table Mutable per-app accumulator.
local function ensure_app_stats(app_id, timestamp_ms)
	local app = _app_stats[app_id]
	if app then return app end
	app = {
		keystroke_count = 0,
		wpm_ring         = {},
		char_window      = {},
		ngrams           = {},
		first_seen       = timestamp_ms,
		typing_time_ms   = 0,
		last_key_at      = nil,
		focus_time_ms    = 0,
		hs_chars         = 0,
		hs_triggers      = 0,
		hs_input_chars   = 0,
		hs_suggested     = 0,
		llm_suggested    = 0,
		llm_chars        = 0,
		llm_triggers     = 0,
		llm_input_chars  = 0,
		physical_scancodes = {},
		ngram_sources      = {},
		-- evdev code → { sum_ms, count, max_ms, tap_count, hold_count }. On a
		-- keyboard whose whole design is tap-hold, how long a key was held is the
		-- difference between the two things it can mean.
		kc_hold            = {},
		-- title → { c, ms }. The dashboard's apps panel groups a day's work by
		-- window, which is the difference between "four hours in the editor" and
		-- "four hours in three files"; this driver had nothing to group by.
		titles             = {},
	}
	_app_stats[app_id] = app
	return app
end

--- Returns a stable display name without collapsing dotted desktop identifiers.
--- @param app_id string Application identifier reported by the focus adapter.
--- @return string Application name suitable for the shared metrics manifest.
local function dashboard_app_name(app_id)
	return tostring(app_id)
end


-- =========================================
-- =========================================
-- ======= 2/ Initialisation ===============
-- =========================================
-- =========================================

--- Initialises the keystats.
--- @param opts table { log_dir?, password_apps? }
function M.init(opts)
	if _flush_state or _flush_stopping then return false end
	if not Preferences.admit() then return false end
	_flush_generation = _flush_generation + 1
	_flush_listeners = {}
	local options = type(opts) == "table" and opts or {}
	-- Validate canonical consent before initializing collectors or persistent data.
	local preferences = Preferences.snapshot()

	-- Initialise the underlying metrics collector if available.
	if Metrics then Metrics.init({}) end

	-- Set up log / SQLite directories for persistence.
	-- Through the resolver. The old "~" fallback was not expanded by io.open —
	-- Lua does no tilde expansion — so with HOME unset the keystats wrote its
	-- database into a literal directory named "~" beside the process.
	local ConfigPaths = require("infra.config_paths")
	_log_dir = options.log_dir or ConfigPaths.config("logs")
	_sqlite_path = options.sqlite_path or ConfigPaths.metrics_path()

	-- Derive device ID from hostname.
	local hostname = "linux"
	-- The kernel's nodename, read in this process (what `hostname` prints, without
	-- a fork on every start).
	local fh_host = io.open("/proc/sys/kernel/hostname", "rb")
	if fh_host then
		hostname = fh_host:read("*l") or "linux"
		fh_host:close()
	end
	hostname = hostname:gsub("%s+", "")
	_device_id = "linux-" .. hostname

	-- Open the SQLite database (bootstraps schema on first run).
	if SqliteWriter and SqliteWriter.open_db(_sqlite_path) then
		SqliteWriter.register_device(_device_id, hostname, "linux", "", hostname)
		-- A live walk owns the record; only a fresh process reads back what the
		-- previous one left open when it stopped without its final flush.
		if next(_walker_contexts) == nil then
			local recorded, read_ok = SqliteWriter.read_open_walk(_device_id)
			-- No record states what an empty one would: nothing is open.
			_persisted_open_walk, _recovered_walks = recorded or (read_ok and "[]" or nil), nil
			if recorded then
				_recovered_walks = decode_open_walk(recorded)
				if not _recovered_walks then
					Logger.warn(LOG, "Open session record is malformed; its sessions are not credited.")
				end
			elseif not read_ok then
				Logger.warn(LOG, "Open session record could not be read; sessions left open by a crash are not credited.")
			end
		end
		if SystemMetrics then
			local database, device = _sqlite_path, _device_id
			SystemMetrics.bind(database, device, function(date)
				if SqliteWriter.get_db_path() ~= database then return nil, false end
				return SqliteWriter.read_system_day(device, date)
			end)
		end
		Logger.info(LOG, "SQLite persistence active: %s", _sqlite_path)
	else
		Logger.info(LOG, "SQLite unavailable — JSON fallback active.")
	end

	-- The stored encryption choice, read before the cipher is configured below:
	-- the migration this block launches depends on which posture is in force, so
	-- reading it afterwards would resume the wrong direction on the first start
	-- after the user changed it.
	_encrypt_enabled = preferences[KEY.METRICS_ENCRYPT]

	-- Push the configured posture into the cipher. Without this the cipher stayed
	-- off while get_privacy_state() reported the manifest's value, which is the
	-- "the box is ticked and nothing is encrypted" defect this feature replaced.
	if _encrypt_enabled and not TextCipher.is_available() then
		Logger.error(LOG, "At-rest encryption is configured on but unavailable — retaining ON and refusing plaintext persistence.")
	end
	TextCipher.set_enabled(_encrypt_enabled)
	-- Resume only a pass a previous run left unfinished. Starting one
	-- unconditionally would re-read every stored row at every daemon start, on
	-- machines that may never have enabled the setting at all.
	TextMigration.resume(
		_encrypt_enabled and MigrationPlan.MODE_ENCRYPT or MigrationPlan.MODE_DECRYPT,
		_device_id)

	-- The user's stored choices, applied over the manifest defaults. Here rather
	-- than at module load: see the note beside the declarations.
	_enabled                    = preferences[KEY.METRICS_ENABLED]
	_private_filter_enabled     = preferences[KEY.METRICS_PRIVATE_FILTER_ENABLED]
	_secure_filter_enabled      = preferences[KEY.METRICS_SECURE_FILTER_ENABLED]
	_system_auth_filter_enabled = preferences[KEY.METRICS_SYSTEM_AUTH_FILTER_ENABLED]
	_disabled_list              = preferences[KEY.METRICS_DISABLED_APPS]
	_disabled_apps              = exclusion_set(_disabled_list)

	_hold_token = {}
	_hold_focus_app = nil
	_suspended = false

	-- Custom password apps (reset then rebuild to avoid duplicates on re-init).
	if type(options.password_apps) == "table" then
		_secure_apps   = _default_secure_apps()
		_password_apps = _default_password_apps()
		for _, app in ipairs(options.password_apps) do
			_secure_apps[#_secure_apps + 1]     = app:lower()
			_password_apps[#_password_apps + 1] = app:lower()
		end
	end

	-- Track session start in milliseconds for unit consistency.
	_session_started_at = os.time() * 1000

	Logger.success(LOG, "Keystats initialised (log_dir=%s, password_apps=%d).",
		_log_dir, #_password_apps)
end


-- =========================================
-- =========================================
-- ======= 3/ Keystroke Recording ==========
-- =========================================
-- =========================================

--- Records a single keypress event with app context.
--- @param ch           string  The character typed.
--- @param timestamp_ms number  Wall-clock timestamp in ms.
--- @param app_id       string|nil  The focused app identifier (from window_info).
--- @param scancode     number|nil  Physical evdev code captured at keydown.
local function ingest_keydown(ch, timestamp_ms, app_id, scancode)
	if not may_record() then return end

	-- A correction is an input event but types nothing, so neither speed readout
	-- counts it: the Windows widget is pushed for characters only and macOS
	-- leaves Backspace out of its typing rings. Counting it would make every
	-- held Backspace read as a burst of fast typing.
	local is_correction = ch == BACKSPACE_MARKER
	if type(timestamp_ms) == "number" then queue_session_events(_session.input(timestamp_ms, true)) end
	-- Forward to the base metrics collector if available.
	if Metrics and not is_correction then
		Metrics.on_keydown(ch, timestamp_ms)
	end
	if not is_correction and type(ch) == "string" and ch ~= "" and type(timestamp_ms) == "number" then
		LiveWpm.record(_live, 1, timestamp_ms)
	end

	-- Per-app tracking. Focus polling is asynchronous; use an explicit Unknown
	-- bucket for the small startup/focus race rather than silently dropping a
	-- real physical character and breaking the raw-event audit trail.
	local resolved_app = (type(app_id) == "string" and app_id ~= "") and app_id or "Unknown"
	if type(ch) == "string" and ch ~= "" then
		M.record_app_key(resolved_app, ch, timestamp_ms)
		local pending = _pending_typing_events[resolved_app]
		if not pending then
			pending = { text = {}, events = {}, times = {} }
			_pending_typing_events[resolved_app] = pending
		end
		local delay = 0
		local previous_at = _typing_last_key_at[resolved_app]
		if type(previous_at) == "number" and type(timestamp_ms) == "number" then
			delay = math.max(0, math.min(timestamp_ms - previous_at, MAX_TYPING_INTERVAL_MS))
		end
		_typing_last_key_at[resolved_app] = timestamp_ms
		pending.text[#pending.text + 1] = ch
		-- [text, inter-key delay, metadata] is the portable events_json shape
		-- consumed by the macOS/Windows projectors. `sk` deliberately identifies
		-- the physical source key; synthetic output never receives one.
		-- Omit `s` for manual input. Lua treats numeric 0 as truthy, so emitting
		-- { s = 0 } would be read as synthetic by the macOS portable-event walker.
		-- This matches Windows/macOS: only synthetic entries carry s=1/true.
		local meta = {}
		if type(scancode) == "number" and scancode > 0 then meta.sk = math.floor(scancode) end
		pending.events[#pending.events + 1] = { ch, delay, meta }
		-- Kept alongside the event rather than inside it: the three-element shape
		-- is the portable events_json contract the macOS and Windows projectors
		-- parse, and a fourth element would have to be understood by both. The
		-- hour a keystroke belongs to is only derivable from an absolute stamp —
		-- the delays are capped, so summing them drifts across every real pause.
		pending.times[#pending.events] = timestamp_ms
	end
end

--- Records one typed character (or the Backspace marker) for the metrics.
--- Counted and, at DEBUG, timed: this runs once per keystroke.
function M.on_keydown(ch, timestamp_ms, app_id, scancode)
	local started = Perf.clock()
	Perf.count("keystats.ingests")
	ingest_keydown(ch, timestamp_ms, app_id, scancode)
	Perf.span("keystats.ingest", started)
end

--- Records one physical Backspace press as a manual correction.
---
--- The hook reports Backspace through its control callback, never as text, so
--- before this entry point the daemon fed nothing for it: the walker's error
--- counts, hourly corrections and backspace n-grams only ever saw the deletions
--- a hotstring made. Every press counts, auto-repeat and Ctrl+Backspace
--- included, as on Windows and macOS: each is one deletion the user asked for.
--- @param app_id       string|nil Focused application identifier.
--- @param timestamp_ms number     Monotonic wall-clock timestamp in ms.
function M.record_correction(app_id, timestamp_ms)
	M.on_keydown(BACKSPACE_MARKER, timestamp_ms, app_id, EvdevCodes.KEY_BACKSPACE)
end


-- =========================================
-- =========================================
-- ======= 4/ Per-App Tracking =============
-- =========================================
-- =========================================

--- Records a keystroke for a specific application.
--- @param app_id       string  Application identifier.
--- @param ch           string  Character typed.
--- @param timestamp_ms number  Wall-clock timestamp.
function M.record_app_key(app_id, ch, timestamp_ms)
	if not may_record() then return end

	local app = ensure_app_stats(app_id, timestamp_ms)
	if type(app.last_key_at) == "number" then
		local elapsed = timestamp_ms - app.last_key_at
		if elapsed > 0 then
			app.typing_time_ms = app.typing_time_ms + math.min(elapsed, MAX_TYPING_INTERVAL_MS)
		end
	end
	app.last_key_at = timestamp_ms

	-- A correction remains an input event, but contributes no typed character.
	if ch ~= BACKSPACE_MARKER then app.keystroke_count = app.keystroke_count + 1 end
	-- Against the window it was typed into, not the application. Both are useful
	-- and only one of them was recorded.
	if _current_title then
		local title_row = app.titles[_current_title]
		if title_row then title_row.c = title_row.c + 1 end
	end
	if type(ch) == "string" and ch ~= "" then
		app.ngrams[ch] = (app.ngrams[ch] or 0) + 1
	end
	app.wpm_ring[#app.wpm_ring + 1] = timestamp_ms

	-- Prune ring (keep last WPM_RING_CAPACITY entries).
	while #app.wpm_ring > WPM_RING_CAPACITY do
		table.remove(app.wpm_ring, 1)
	end
end

--- Records one physical evdev keydown for the layout-independent heatmap.
--- This is intentionally separate from on_keydown(): control/modifier keys do
--- not produce text output but are still genuine user presses. Callers must
--- invoke it exactly once per device keydown, before printable output handling.
--- @param app_id string|nil Focused application identifier.
--- @param scancode number Linux evdev key code.
--- @param timestamp_ms number Event time in ms.
function M.record_physical_key(app_id, scancode, timestamp_ms)
	if not may_record() then return end
	if type(scancode) ~= "number" or scancode <= 0 then return end
	local resolved_app = (type(app_id) == "string" and app_id ~= "") and app_id or "Unknown"
	local app = ensure_app_stats(resolved_app, timestamp_ms)
	local code = math.floor(scancode)
	app.physical_scancodes[code] = (app.physical_scancodes[code] or 0) + 1
end

local function ensure_pending(app_id)
	local pending = _pending_typing_events[app_id]
	if pending then return pending end
	pending = { text = {}, events = {}, times = {} }
	_pending_typing_events[app_id] = pending
	return pending
end

local function add_synthetic_ngram(app, char, source)
	app.ngrams[char] = (app.ngrams[char] or 0) + 1
	app.ngram_sources[char] = app.ngram_sources[char] or {}
	app.ngram_sources[char][source] = (app.ngram_sources[char][source] or 0) + 1
end

--- What actually gets persisted for one synthetic character.
---
--- For a private expansion the SHAPE is preserved — one entry per character, so
--- counts, timings and the net-gain arithmetic stay correct — while the
--- character itself is replaced. Dropping the entries instead would be worse
--- than the leak: the per-character record is what tells the daemon these
--- characters were synthetic, and without it the physical echoes fall through as
--- ordinary human keystrokes and the secret lands in the metrics anyway, in a
--- different column. macOS reached the same conclusion; the comment above its
--- `notify_synthetic` says so at length.
---
--- Backspace markers are never redacted: they carry no content, and rewriting
--- them would desynchronise the deletion count.
--- @param char string
--- @param is_private boolean|nil
--- @return string
local function recorded_char(char, is_private)
	if is_private and char ~= BACKSPACE_MARKER then return PRIVATE_PLACEHOLDER_CHAR end
	return char
end

--- @param is_private boolean|nil True when `text` is PII and must be redacted.
local function append_synthetic_events(app_id, text, source, deletes, is_private)
	local pending = ensure_pending(app_id)
	-- An expansion fires within a keystroke of its trigger, so it belongs in the
	-- same minute. Taking the trigger's stamp keeps the two together without
	-- reading a clock from a function that has never needed one.
	local at = _typing_last_key_at[app_id]
	for _ = 1, math.max(0, math.floor(tonumber(deletes) or 0)) do
		pending.events[#pending.events + 1] = { BACKSPACE_MARKER, 0, { s = 1, st = source } }
		pending.times[#pending.events] = at
		add_synthetic_ngram(_app_stats[app_id], BACKSPACE_MARKER, source)
	end
	if type(text) ~= "string" or text == "" then return end
	local ok, len = pcall(utf8.len, text)
	if not ok or not len then
		-- A malformed sequence has no codepoints to walk, so the whole string is
		-- recorded as one entry. Redacting it to a single placeholder loses the
		-- length, which is the price of not being able to count the characters —
		-- and losing the length is the right way round.
		local blob = recorded_char(text, is_private)
		pending.events[#pending.events + 1] = { blob, 0, { s = 1, st = source } }
		pending.times[#pending.events] = at
		add_synthetic_ngram(_app_stats[app_id], blob, source)
		return
	end
	for _, codepoint in utf8.codes(text) do
		local char = recorded_char(utf8.char(codepoint), is_private)
		pending.events[#pending.events + 1] = { char, 0, { s = 1, st = source } }
		pending.times[#pending.events] = at
		add_synthetic_ngram(_app_stats[app_id], char, source)
	end
end

--- Records a completed static-hotstring expansion for metrics parity.
--- The physical trigger remains part of manual input; the dashboard subtracts
--- hs_input_chars from the generated output to calculate the net gain.
--- @param app_id string Focused application identifier.
--- @param trigger string Typed hotstring trigger.
--- @param replacement string Generated replacement text.
--- @param timestamp_ms number Event timestamp.
--- @param h_type string|nil Expansion kind, as the dashboard groups them.
--- @param deletes number|nil Characters erased before the replacement was typed.
--- @param is_private boolean|nil True when the payload is PII.
---   Two sinks are affected, and only one of them is skipped. The per-character
---   synthetic record is REDACTED, never dropped — see `recorded_char`. The
---   events_hotstring row is dropped outright, because BOTH its columns are
---   secret: the replacement is the IBAN, and the trigger is its first six
---   characters. Redacting only the replacement would still leak. macOS makes
---   the same split — `expander.lua` skips `log_hotstring` and forwards the flag
---   to `notify_synthetic`.
--- Records that a suggestion was OFFERED to the user.
---
--- The counterpart of the trigger counters, which record the ones TAKEN. The
--- acceptance rate is the ratio of the two, so with this never recorded the
--- dashboard divided by nothing and reported 0% on a driver whose suggestions
--- were being accepted all day — indistinguishable from a feature nobody uses,
--- which is exactly the conclusion it invites.
---
--- Only the count is kept. What was offered is not: a suggestion the user did
--- not take is the strongest signal in the database about what they were about
--- to type, and it has none of the justification the accepted ones have.
--- @param app_id string Application identifier.
--- @param kind string "hotstring" or "llm".
--- @param timestamp_ms number|nil
function M.record_suggestion(app_id, kind, timestamp_ms)
	if not may_record() or type(app_id) ~= "string" or app_id == "" then return end
	local field = (kind == "llm") and "llm_suggested" or "hs_suggested"
	local app = ensure_app_stats(app_id, timestamp_ms)
	app[field] = (app[field] or 0) + 1
	Logger.debug(LOG, "Suggestion offered (%s).", field)
end

function M.record_hotstring(app_id, trigger, replacement, timestamp_ms, h_type, deletes, is_private)
	if not may_record() or type(app_id) ~= "string" or app_id == "" then return end
	if type(replacement) ~= "string" or replacement == "" then return end
	local app = ensure_app_stats(app_id, timestamp_ms)
	app.hs_chars       = app.hs_chars + char_count(replacement)
	app.hs_triggers    = app.hs_triggers + 1
	app.hs_input_chars = app.hs_input_chars + char_count(type(trigger) == "string" and trigger or "")
	append_synthetic_events(app_id, replacement, "hotstring",
		deletes ~= nil and deletes or char_count(type(trigger) == "string" and trigger or ""),
		is_private)
	if type(timestamp_ms) == "number" then
		-- The group names the colour the readouts take; a private expansion
		-- still colours them — the colour says a hotstring fired, not what it typed.
		LiveWpm.record(_live, char_count(replacement), timestamp_ms)
		LiveWpm.mark_source(_live, "hotstring", h_type, timestamp_ms)
	end
	if is_private then
		Logger.debug(LOG, "Private expansion fired (content withheld).")
		return
	end
	_pending_hotstring_events[#_pending_hotstring_events + 1] = {
		ts = os.date("!%Y-%m-%d %H:%M:%S"),
		date = os.date("%Y-%m-%d"),
		app = dashboard_app_name(app_id),
		kind = "fired",
		trigger = trigger or "",
		replacement = replacement,
		h_type = h_type or "static",
		net_saved_chars = char_count(replacement) - char_count(trigger),
	}
end

--- Records a shortcut firing — an action the user triggered that types no text.
---
--- CapsWord, the selection transforms, the wrapping pairs and every action an
--- extension registers all end here. They produced nothing measurable before, so
--- "what did I actually use" — the question the dashboard exists to answer —
--- could only be answered about hotstrings on this driver.
---
--- Deliberately NOT counted as synthetic output: these actions type nothing of
--- their own. Adding them to the character totals would inflate the saved-
--- keystrokes figure with keystrokes nobody saved.
--- @param app_id string Focused application identifier.
--- @param key string What fired, e.g. "caps_word" or "wrap_selection".
--- @param timestamp_ms number|nil Event timestamp; unused today, taken for
---   symmetry with its siblings and so a caller need not know which of them
---   stamps its own time.
function M.record_shortcut(app_id, key, timestamp_ms)  -- luacheck: ignore 212
	if not may_record() then return end
	if type(key) ~= "string" or key == "" then
		Logger.warn(LOG, "record_shortcut(): no key name — the event would say only that "
			.. "something fired, so it is dropped.")
		return
	end
	_pending_shortcut_events[#_pending_shortcut_events + 1] = {
		ts   = os.date("!%Y-%m-%d %H:%M:%S"),
		date = os.date("%Y-%m-%d"),
		app  = dashboard_app_name(type(app_id) == "string" and app_id or "unknown"),
		key  = key,
	}
end

--- Records one report of an observed pointer for the mouse columns of
--- events_typing. The clicks, wheel turns and distance accumulate under the
--- focused application and are written with its next typing row, as macOS
--- carries them to the next flushed run. Gated like every recording entry
--- point, and never for an application whose input stays out of the metrics.
--- @param kind string "press", "motion" or "frame" (pointer_metrics).
--- @param code integer evdev code.
--- @param value integer evdev value.
function M.record_pointer(kind, code, value)
	local delta = _pointer.observe(kind, code, value)
	if not delta or not may_record() then return end
	queue_session_events(_session.input(math.floor(Monotonic.now_ms()), false))
	local app_id = _focused_app_id
	if type(app_id) ~= "string" or M.is_unrecorded_app(app_id) then return end
	local pending = ensure_pending(app_id)
	local mouse = pending.mouse or { clicks = 0, scrolls = 0, distance = 0 }
	mouse.clicks = mouse.clicks + delta.clicks
	mouse.scrolls = mouse.scrolls + delta.scrolls
	mouse.distance = mouse.distance + delta.distance
	pending.mouse = mouse
end

-- The events_llm kinds, with the fields each may carry. The table's CHECK constraint
-- knows only these four; anything else would be dropped silently by INSERT OR IGNORE.
local LLM_EVENT_FIELDS = {
	generation = { "count", "prompt_tokens", "completion_tokens", "total_tokens", "est_cost_usd" },
	suggested = { "count" },
	dismissed = { "all_predictions" },
	accepted = { "prediction", "all_predictions", "chosen_index", "deletes", "deleted_text", "net_saved_chars" },
}

--- Records one LLM prediction event in the canonical events_llm shape macOS and Windows write.
---
--- generation: a request answered (how many predictions, and the tokens the backend
--- reported). suggested: predictions were offered. dismissed: the offer went unused.
--- accepted: the user took one. The dashboard's AI tab reads exactly these rows; before
--- this existed only the per-application counters were kept, so the tab stayed empty.
--- @param app_id string Application identifier.
--- @param kind string "generation", "suggested", "dismissed" or "accepted".
--- @param fields table|nil The fields of that kind (LLM_EVENT_FIELDS).
function M.record_llm_event(app_id, kind, fields)
	if not may_record() or type(app_id) ~= "string" or app_id == "" then return end
	local allowed = LLM_EVENT_FIELDS[kind]
	if not allowed then
		Logger.error(LOG, "record_llm_event(): '%s' is not an events_llm kind; the event is dropped.", tostring(kind))
		return
	end
	fields = type(fields) == "table" and fields or {}
	local row = {
		ts = os.date("!%Y-%m-%d %H:%M:%S"), date = os.date("%Y-%m-%d"),
		app = dashboard_app_name(app_id), kind = kind,
	}
	for _, name in ipairs(allowed) do row[name] = fields[name] end
	if kind == "accepted" and row.net_saved_chars == nil and type(row.prediction) == "string" then
		row.net_saved_chars = char_count(row.prediction) - math.max(0, tonumber(row.deletes) or 0)
	end
	_pending_llm_events[#_pending_llm_events + 1] = row
end

--- Records successful automated output that is not a static hotstring (LLM,
--- clipboard expansion, etc.) in the same portable event format. It is called
--- only after the producer confirms success, so cancelled streamed output never
--- appears as a false logical keystroke.
function M.record_synthetic_output(app_id, text, source, timestamp_ms, deletes, input_chars)
	if not may_record() or type(app_id) ~= "string" or app_id == "" then return end
	if type(text) ~= "string" or text == "" then return end
	local kind = type(source) == "string" and source or "other"
	local app = ensure_app_stats(app_id, timestamp_ms)
	if kind == "llm" then
		app.llm_chars = app.llm_chars + char_count(text)
		app.llm_triggers = app.llm_triggers + 1
		app.llm_input_chars = app.llm_input_chars + math.max(0, math.floor(tonumber(input_chars) or 0))
	end
	append_synthetic_events(app_id, text, kind, deletes)
	if type(timestamp_ms) == "number" then
		LiveWpm.record(_live, char_count(text), timestamp_ms)
		LiveWpm.mark_source(_live, kind, kind, timestamp_ms)
	end
end

--- Records a foreground application transition from the process lifecycle port.
--- @param app_id string|nil New focused application identifier.
--- @param timestamp_ms number|nil Monotonic transition timestamp in milliseconds.
function M.on_app_focus(app_id, timestamp_ms)
	if type(app_id) ~= "string" or app_id == "" then return end
	M.observe_hold_focus(app_id)
	-- Gated like every other recording entry point: focus time and app
	-- switches are records too, and tracking them while recording is
	-- forbidden would persist them on the next flush. The in-flight interval
	-- is forgotten rather than closed — time that must not be recorded
	-- cannot be credited later without backfilling the forbidden gap.
	if not may_record() then
		_focused_app_id, _focused_app_started_at = nil, nil
		_current_title, _title_since, _current_title_app = nil, nil, nil
		return
	end
	local now = type(timestamp_ms) == "number" and timestamp_ms or math.floor(Monotonic.now_ms())
	if _focused_app_id == app_id then return end
	-- A switch orphans the previous window: close its interval under the
	-- application that owned it. Left open, the next title change would
	-- close it against the incoming application and credit nothing — and
	-- every keystroke until then would miss its count the same way. Kept
	-- when the title was just reported for this same application: the daemon
	-- always sends title-then-focus together, and clearing there would
	-- orphan the window it just named.
	if _current_title and type(_title_since) == "number"
		and _current_title_app ~= nil and _current_title_app ~= app_id then
		local owner = _app_stats[_current_title_app]
		if owner then
			local row = owner.titles[_current_title]
			if row then row.ms = row.ms + math.max(0, now - _title_since) end
		end
		_current_title, _title_since, _current_title_app = nil, nil, nil
	end
	if _focused_app_id and type(_focused_app_started_at) == "number" then
		local elapsed = math.max(0, now - _focused_app_started_at)
		local previous = ensure_app_stats(_focused_app_id, _focused_app_started_at)
		previous.focus_time_ms = previous.focus_time_ms + elapsed
		_pending_app_switch_events[#_pending_app_switch_events + 1] = {
			-- The instant is UTC and the day is local, which is the convention every
			-- other table here follows: a timestamp has to be comparable across
			-- machines, and a "day" is the user's day. Both were UTC until
			-- 2026-08-06, so for anyone east of Greenwich an evening application
			-- switch was filed under tomorrow while the keystrokes either side of it
			-- were filed under today.
			ts = os.date("!%Y-%m-%d %H:%M:%S"),
			date = os.date("%Y-%m-%d"),
			prev_app = dashboard_app_name(_focused_app_id),
			next_app = dashboard_app_name(app_id),
			duration_ms = elapsed,
		}
	end
	ensure_app_stats(app_id, now)
	_focused_app_id         = app_id
	_focused_app_started_at = now
	Logger.debug(LOG, "Foreground application: %s.", app_id)
end

--- Returns per-app statistics.
--- @return table { [appId] = { keystrokes, first_seen } }
function M.get_app_stats()
	local result = {}
	local now = math.floor(Monotonic.now_ms())
	for app_id, stats in pairs(_app_stats) do
		local focus_time_ms = stats.focus_time_ms or 0
		local physical_scancodes = {}
		for code, count in pairs(stats.physical_scancodes or {}) do physical_scancodes[code] = count end
		if app_id == _focused_app_id and type(_focused_app_started_at) == "number" then
			focus_time_ms = focus_time_ms + math.max(0, now - _focused_app_started_at)
		end
		result[app_id] = {
			keystrokes = stats.keystroke_count,
			first_seen = stats.first_seen,
			typing_time_ms = stats.typing_time_ms or 0,
			focus_time_ms  = focus_time_ms,
			hs_chars       = stats.hs_chars or 0,
			hs_triggers    = stats.hs_triggers or 0,
			hs_input_chars = stats.hs_input_chars or 0,
			llm_chars = stats.llm_chars or 0,
			llm_triggers = stats.llm_triggers or 0,
			llm_input_chars = stats.llm_input_chars or 0,
			-- Named here as well as in the accumulator and the flush. This
			-- projection is the boundary the flush reads, and a field the
			-- accumulator increments but this does not copy is lost between the
			-- two with nothing to show for it — which is precisely how the three
			-- LLM counters above spent their existence.
			hs_suggested = stats.hs_suggested or 0,
			llm_suggested = stats.llm_suggested or 0,
			physical_scancodes = physical_scancodes,
		}
	end
	return result
end

--- Adds current, not-yet-flushed counters to a persisted manifest entry.
local function shallow_copy(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

local function add_live_manifest_delta(manifest)
	local today = os.date("%Y-%m-%d")
	local result = shallow_copy(manifest)
	result[today] = shallow_copy(manifest[today])
	for app_id, stats in pairs(M.get_app_stats()) do
		local previous = _flushed_app_totals[app_id] or {}
		local app_name = dashboard_app_name(app_id)
		local entry = shallow_copy(result[today][app_name] or { category = "Unknown" })
		local current = {
			chars = stats.keystrokes or 0,
			time = stats.typing_time_ms or 0,
			app_time_ms = stats.focus_time_ms or 0,
			hs_chars = stats.hs_chars or 0,
			hs_triggers = stats.hs_triggers or 0,
			hs_input_chars = stats.hs_input_chars or 0,
			llm_chars = stats.llm_chars or 0,
			llm_triggers = stats.llm_triggers or 0,
			llm_input_chars = stats.llm_input_chars or 0,
		}
		for field, value in pairs(current) do
			local persisted_field = field == "time" and "time_ms" or field
			entry[field] = (entry[field] or 0) + math.max(0, value - (previous[persisted_field] or 0))
		end
		entry.category = entry.category or "Unknown"
		result[today][app_name] = entry
	end
	return result
end

--- @return table manifest Persisted manifest, partial when a query failed.
--- @return boolean complete Whether every native query was accepted.
local function persisted_manifest()
	if not (SqliteWriter and SqliteWriter.is_available() and SqliteReader) then return {}, true end
	local revision = SqliteWriter.get_revision and SqliteWriter.get_revision() or nil
	if _manifest_cache.manifest and revision ~= nil and _manifest_cache.revision == revision then
		return _manifest_cache.manifest, true
	end
	local fresh, complete = SqliteReader.read_manifest(_sqlite_path)
	-- A partial manifest is shown but never cached, so the next read retries
	if complete then
		_manifest_cache = { revision = revision, manifest = fresh }
	end
	return fresh, complete == true
end

--- Drops the cached projection so the next read rebuilds from the database.
---
--- The dashboard's reset control asks for exactly this: it clears the filters
--- and expects the next payload to be a clean rebuild. Linux answered nothing
--- at all, so the button reset the page and left the backend serving the same
--- cached manifest it had before — the one visible symptom being that a reset
--- changed nothing.
function M.clear_cache()
	if M.has_flush_debt() or _flush_stopping then return false end
	_manifest_cache = { revision = nil, manifest = nil }
	Logger.info(LOG, "Dashboard cache cleared at the user's request.")
	return true
end

--- Records the category and score a user assigned to an application.
---
--- The category is a column on agg_app_day and the dashboard groups by it, so
--- an unhandled edit is a control that appears to work and silently discards
--- what the user typed into it.
--- @param app_name string
--- @param category string
--- @param score number|nil Productivity score, as the shared page defines it.
--- @return boolean Whether it was persisted.
function M.set_app_category(app_name, category, score)
	if M.has_flush_debt() or _flush_stopping then return false end
	if type(app_name) ~= "string" or app_name == "" then
		Logger.error(LOG, "set_app_category(): an application name is required.")
		return false
	end
	if type(category) ~= "string" or category == "" then
		Logger.error(LOG, "set_app_category(): a category is required for '%s'.", app_name)
		return false
	end
	if not (SqliteWriter and SqliteWriter.is_available()) then
		Logger.warn(LOG, "set_app_category(): no database — '%s' stays uncategorised.", app_name)
		return false
	end
	local ok = SqliteWriter.set_app_category(_device_id, app_name, category, tonumber(score) or 0)
	-- The cached manifest still holds the old category, and the page re-reads
	-- immediately after the edit. Without this the user sees their change
	-- reverted and tries again.
	if ok then M.clear_cache() end
	Logger.debug(LOG, "Category for '%s': %s (score %s).", app_name, category, tostring(score))
	return ok == true
end

local function empty_ngrams()
	return { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {}, sc_kb = {} }
end

--- Adds only unflushed character n-grams to the per-app today projection.
local function add_live_ngram_delta(today_payload, apps)
	-- Match the SQL reader: no valid application name means an unrestricted
	-- projection. A selected range must not regain excluded apps from RAM.
	local selected = {}
	if type(apps) == "table" then
		for _, app in ipairs(apps) do
			if type(app) == "string" and app ~= "" then selected[app] = true end
		end
	end
	local unrestricted = next(selected) == nil
	for app_id, stats in pairs(_app_stats) do
		if unrestricted or selected[dashboard_app_name(app_id)] then
			local previous = _flushed_app_ngrams[app_id] or {}
			local app_name = dashboard_app_name(app_id)
			local target = today_payload[app_name] or empty_ngrams()
			for token, count in pairs(stats.ngrams or {}) do
				local delta = math.max(0, count - (previous[token] or 0))
				if delta > 0 then
					local item = target.c[token] or { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
					item.c = item.c + delta
					local source_delta = math.max(0,
						((stats.ngram_sources[token] or {}).hotstring or 0)
						- (((_flushed_app_sources[app_id] or {})[token] or {}).hotstring or 0))
					local llm_delta = math.max(0,
						((stats.ngram_sources[token] or {}).llm or 0)
						- (((_flushed_app_sources[app_id] or {})[token] or {}).llm or 0))
					local other_delta = 0
					local flushed_sources = (_flushed_app_sources[app_id] or {})[token] or {}
					for label, source_count in pairs(stats.ngram_sources[token] or {}) do
						if Utils.is_other_synthetic_source(label) then
							other_delta = other_delta + math.max(0, source_count - (flushed_sources[label] or 0))
						end
					end
					item.hs = (item.hs or 0) + source_delta
					item.llm = (item.llm or 0) + llm_delta
					item.o = (item.o or 0) + other_delta
					target.c[token] = item
				end
			end
			local flushed_scancodes = _flushed_app_scancodes[app_id] or {}
			for scancode, count in pairs(stats.physical_scancodes or {}) do
				local delta = math.max(0, count - (flushed_scancodes[scancode] or 0))
				if delta > 0 then
					local item = target.sc_kb[tostring(scancode)] or { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
					item.c = item.c + delta
					target.sc_kb[tostring(scancode)] = item
				end
			end
			today_payload[app_name] = target
		end
	end
	return today_payload
end

--- Builds the shared manifest/prefetch contract consumed by both metrics UIs.
--- Historical rows come from SQLite; only the unflushed in-memory delta is
--- layered on top, so refreshing a dashboard never double-counts a session.
--- A failed SQLite query still yields the rows that were read, flagged with
--- `metrics_manifest_incomplete` or `_prefetch_data.incomplete`.
--- @return table Metrics prefetch payload matching the macOS/Windows schema.
function M.get_dashboard_payload(opts)
	if M.is_flush_pending() then return nil, "SQLite flush pending" end
	if not SqliteReader then return nil, "SQLite projection unavailable" end
	local options = type(opts) == "table" and opts or {}
	local categories = {}
	if SqliteWriter and SqliteWriter.is_available() then
		categories = SqliteReader.read_user_categories(_sqlite_path, _device_id)
		if categories == nil then return nil, "SQLite projection unavailable" end
	end
	local persisted, manifest_complete = persisted_manifest()
	local manifest = add_live_manifest_delta(persisted)
	local prefetch = nil
	if options.include_prefetch ~= false then
		prefetch = M.get_range_payload(nil, nil, nil)
	end
	return {
		metrics_manifest = manifest,
		user_categories  = categories,
		app_icons        = {},
		_prefetch_data   = prefetch,
		metrics_manifest_incomplete = not manifest_complete or nil,
		driver_meta      = { os = "linux", heatmap_id = "sc_kb" },
	}
end

--- Returns n-grams for one UI-selected range without rebuilding the manifest.
--- @param start_date string|nil Inclusive range start.
--- @param end_date string|nil Inclusive range end.
--- @param apps table|nil Selected application IDs.
function M.get_range_payload(start_date, end_date, apps)
	if M.is_flush_pending() then return nil, "SQLite flush pending" end
	if not SqliteReader then return nil, "SQLite projection unavailable" end
	local bounds = SqliteReader.split_bounds(start_date, end_date)
	local payload, complete = { historical = empty_ngrams(), today = {} }, true
	if SqliteWriter and SqliteWriter.is_available() then
		payload, complete = SqliteReader.read_range_split_today(_sqlite_path, start_date, end_date, apps, bounds.today)
	end
	-- The page shows the partial counts and says the history is incomplete
	payload.incomplete = not complete or nil
	payload.historical = payload.historical or empty_ngrams()
	payload.today = payload.today or {}
	if bounds.includes_today then payload.today = add_live_ngram_delta(payload.today, apps) end
	return payload
end


-- =========================================
-- =========================================
-- ======= 5/ Password Detection ===========
-- =========================================
-- =========================================

--- Checks whether an app ID indicates a password/secure field.
--- @param app_id string|nil
--- @return boolean
function M.is_password_app(app_id)
	if type(app_id) ~= "string" then return false end
	local lower = app_id:lower()

	-- Two lists, two flags, matching the "secure_field" and "system_auth"
	-- categories of the shared no-persist corpus. With both flags at their
	-- manifest default (true) the union is exactly the flat list this replaced,
	-- so coverage is unchanged unless the user deliberately turns a filter off.
	if _secure_filter_enabled then
		for _, pattern in ipairs(_secure_apps) do
			if lower:find(pattern, 1, true) then return true end
		end
	end
	if _system_auth_filter_enabled then
		for _, pattern in ipairs(_SYSTEM_AUTH_APPS) do
			if lower:find(pattern, 1, true) then return true end
		end
	end
	return false
end

--- Whether the user excluded this application from recording. Unlike a password
--- application this blocks the metrics only: hotstrings and predictions work there.
--- @param app_id string|nil Application identifier.
--- @return boolean
function M.is_app_excluded(app_id)
	return type(app_id) == "string" and _disabled_apps[app_id:lower()] == true
end

--- Whether anything typed in this application must stay out of the metrics.
--- @param app_id string|nil Application identifier.
--- @return boolean
function M.is_unrecorded_app(app_id)
	return M.is_password_app(app_id) or M.is_app_excluded(app_id)
end

--- Applies the live application/window privacy filters to a joined context.
--- Reads only in-memory policy; native metadata must already belong to its field.
--- @param app_id string Exact current application's identifier.
--- @param title string Exact current native frame title.
--- @return boolean protected
function M.is_context_protected(app_id, title)
	return M.is_password_app(app_id) or (_private_filter_enabled and PrivateWindow.matches(title))
end

local hold_password_app = M.is_unrecorded_app
settle_hold_policy = function()
	if not may_record() or hold_password_app(_hold_focus_app) then
		_hold_token = {}
		return false
	end
	return true
end

--- Publishes focus to the hold producer before reentrant UI callbacks.
--- @param app_id string|nil Current foreground application, retained only in memory.
function M.observe_hold_focus(app_id)
	_hold_focus_app = type(app_id) == "string" and app_id ~= "" and app_id or nil
	settle_hold_policy()
end

--- Returns the current admission identity for physical hold measurements.
--- @return table|nil token Opaque authority, never a duration or input payload.
function M.hold_accounting_token()
	if not settle_hold_policy() then return nil end
	return _hold_token
end

--- Retires in-flight measurements when the daemon owner excludes input.
function M.cancel_hold_intervals()
	_hold_token = {}
end

--- Records how long one key was held.
---
--- The threshold between a tap and a hold is the shared tap-hold activation
--- time, so this driver's idea of the difference is the same one the tap-hold
--- engine acts on. A second number here would let the dashboard call something a tap that
--- the keyboard treated as a hold.
--- @param app_id string|nil
--- @param scancode number evdev code.
--- @param held_ms number
function M.record_hold(app_id, scancode, held_ms)
	if not may_record() then return end
	if type(app_id) ~= "string" or app_id == "" then return end
	local code = tonumber(scancode)
	local duration = tonumber(held_ms)
	if not code or not duration or code <= 0 or duration < 0 then return end

	local app = ensure_app_stats(app_id, nil)
	local row = app.kc_hold[code]
	if not row then
		row = { sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }
		app.kc_hold[code] = row
	end
	row.sum_ms = row.sum_ms + duration
	row.count = row.count + 1
	if duration > row.max_ms then row.max_ms = duration end
	local threshold = tap_hold_threshold_ms()
	if threshold then
		if duration >= threshold then
			row.hold_count = row.hold_count + 1
		else
			row.tap_count = row.tap_count + 1
		end
	end
end

--- Records that the focused window's title changed.
---
--- Gated by exactly the filters a keystroke is: a private window, a secure
--- field, a disabled application or metrics being off all mean this title is
--- not recorded. A title is often MORE revealing than the keystrokes — a browser
--- tab names the page — so a weaker gate here would leak past every filter the
--- user set on the text itself.
--- @param app_id string|nil
--- @param title string|nil
--- @param timestamp_ms number|nil
function M.set_window_title(app_id, title, timestamp_ms)
	local now = type(timestamp_ms) == "number" and timestamp_ms or math.floor(Monotonic.now_ms())

	if not may_record() or type(app_id) ~= "string" or app_id == "" then
		_current_title, _title_since, _current_title_app = nil, nil, nil
		return
	end

	-- The title change itself, attributed to the application that owned the
	-- outgoing title (Windows' rule), with the time that title was in front.
	-- Neither title is recorded for an application kept out of the metrics.
	local owner_app = _current_title_app or app_id
	if _current_title and type(_title_entered_at) == "number" and type(title) == "string" and title ~= ""
		and title ~= _current_title and not M.is_unrecorded_app(owner_app) and not M.is_unrecorded_app(app_id) then
		_pending_window_switch_events[#_pending_window_switch_events + 1] = {
			ts = os.date("!%Y-%m-%d %H:%M:%S"), date = os.date("%Y-%m-%d"),
			app = dashboard_app_name(owner_app), prev_title = _current_title, next_title = title,
			duration_ms = math.max(0, now - _title_entered_at),
		}
	end

	-- Close the previous title's interval under the application that owned
	-- it, never the incoming one: the time already spent under it was earned
	-- while recording was allowed, and the incoming application's titles
	-- table has no such row, so closing there credits nothing. It used to
	-- run before the gate above, crediting forbidden time on flush.
	if _current_title and type(_title_since) == "number" then
		local owner = _app_stats[_current_title_app or app_id]
		if owner then
			local row = owner.titles[_current_title]
			if row then row.ms = row.ms + math.max(0, now - _title_since) end
		end
	end

	if type(title) ~= "string" or title == "" then
		_current_title, _title_since, _current_title_app = nil, nil, nil
		return
	end

	local app = ensure_app_stats(app_id, now)
	app.titles[title] = app.titles[title] or { c = 0, ms = 0 }
	if title ~= _current_title then _title_entered_at = now end
	_current_title = title
	_title_since = now
	_current_title_app = app_id
end

--- Reports whether a window title marks a private/incognito browser session.
--- @param title string|nil Focused window title.
--- @return boolean
function M.is_private_window(title)
	return PrivateWindow.matches(title)
end

--- Enables password suppression for the current focused app.
--- Call this when the window_info adapter detects a secure field.
function M.suppress()
	if not _suppressed then
		_suppressed = true
		settle_hold_policy()
		Logger.debug(LOG, "Keystroke logging suppressed (password field detected).")
	end
end

--- Disables password suppression.
function M.unsuppress()
	if _suppressed then
		_suppressed = false
		Logger.debug(LOG, "Keystroke logging resumed.")
	end
end

--- Returns whether logging is currently suppressed.
--- @return boolean
function M.is_suppressed()
	return _suppressed
end

--- Pauses metrics collection at the user's request. Idempotent. The pause is
--- independent of the password flag: leaving a secure field does not end it.
function M.suspend_collection()
	if not _suspended then
		_suspended = true
		settle_hold_policy()
		Logger.info(LOG, "Metrics collection suspended by the user.")
	end
end

--- Ends the user's pause. Nothing typed meanwhile is recovered.
function M.resume_collection()
	if _suspended then
		_suspended = false
		Logger.info(LOG, "Metrics collection resumed by the user.")
	end
end

--- Returns whether the user paused metrics collection.
--- @return boolean
function M.is_collection_suspended()
	return _suspended
end

--- Turns keystroke collection on or off. The Linux driver had no off switch at
--- all; the other two drivers have had one since they shipped.
--- @param enabled boolean
function M.set_enabled(enabled)
	if not Preferences.admit() then return false end
	local wanted = (enabled == true)
	if not store_bool(KEY.METRICS_ENABLED, wanted) then
		Logger.error(LOG, "Metrics collection state was not persisted — it was not changed.")
		return false
	end
	_enabled = wanted
	settle_hold_policy()
	Logger.debug(LOG, "Metrics collection: %s.", tostring(_enabled))
	return true
end

--- Returns whether keystroke collection is enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Records whether the focused window is a private/incognito browser session.
--- @param is_private boolean
function M.set_private_window(is_private)
	_private_window = (is_private == true)
	settle_hold_policy()
	Logger.debug(LOG, "Private browsing window: %s.", tostring(_private_window))
end

--- Records the AT-SPI adapter's secure-field verdict for the focused window.
--- Consulted IN ADDITION to the app-name list, never instead of it.
--- @param is_secure boolean
function M.set_secure_field(is_secure)
	_secure_field = (is_secure == true)
	settle_hold_policy()
	Logger.debug(LOG, "Secure field focused: %s.", tostring(_secure_field))
end

--- Admits one privacy-filter change, or says why it was refused. A metrics
--- scope that still owes a rollback holds the preferences; the click then
--- changes nothing, and it must not do so silently.
--- @param label string Filter name for the log.
--- @return boolean
local function admit_filter_change(label)
	if Preferences.admit() then return true end
	Logger.error(LOG, "%s filter change refused: a metrics configuration transaction still owns the preferences. Nothing was changed.", label)
	return false
end

--- Toggles the private-browsing filter.
--- @param enabled boolean
function M.set_private_filter_enabled(enabled)
	if not admit_filter_change("Private-browsing") then return false end
	local wanted = (enabled == true)
	if not store_bool(KEY.METRICS_PRIVATE_FILTER_ENABLED, wanted) then
		Logger.error(LOG, "Private-browsing filter state was not persisted — it was not changed.")
		return false
	end
	_private_filter_enabled = wanted
	settle_hold_policy()
	Logger.debug(LOG, "Private-browsing filter: %s.", tostring(_private_filter_enabled))
	return true
end

--- The application last reported in the foreground, for the exclusion menu.
--- @return string|nil app_id
function M.last_app()
	return _hold_focus_app
end

--- Returns the configured exclusion list, in its stored order.
--- @return table apps A detached list.
function M.get_disabled_apps()
	local copy = {}
	for index, app in ipairs(_disabled_list) do copy[index] = app end
	return copy
end

--- Replaces the list of applications excluded from recording.
--- @param apps table Application identifiers.
--- @return boolean persisted
function M.set_disabled_apps(apps)
	if not admit_filter_change("Excluded-applications") then return false end
	if type(apps) ~= "table" then return false end
	for _, app in ipairs(apps) do
		if type(app) ~= "string" or app == "" then return false end
	end
	if not Preferences.set(KEY.METRICS_DISABLED_APPS, apps) then
		Logger.error(LOG, "The excluded applications were not persisted — the list was not changed.")
		return false
	end
	_disabled_list = {}
	for index, app in ipairs(apps) do _disabled_list[index] = app end
	_disabled_apps = exclusion_set(_disabled_list)
	settle_hold_policy()
	Logger.debug(LOG, "Excluded applications: %d.", #apps)
	return true
end

--- Toggles the secure-field / password-manager filter.
--- @param enabled boolean
function M.set_secure_filter_enabled(enabled)
	if not admit_filter_change("Secure-field") then return false end
	local wanted = (enabled == true)
	if not store_bool(KEY.METRICS_SECURE_FILTER_ENABLED, wanted) then
		Logger.error(LOG, "Secure-field filter state was not persisted — it was not changed.")
		return false
	end
	_secure_filter_enabled = wanted
	settle_hold_policy()
	Logger.debug(LOG, "Secure-field filter: %s.", tostring(_secure_filter_enabled))
	return true
end

--- Toggles the OS authentication-prompt filter.
--- @param enabled boolean
function M.set_system_auth_filter_enabled(enabled)
	if not admit_filter_change("System-auth") then return false end
	local wanted = (enabled == true)
	if not store_bool(KEY.METRICS_SYSTEM_AUTH_FILTER_ENABLED, wanted) then
		Logger.error(LOG, "System-auth filter state was not persisted — it was not changed.")
		return false
	end
	_system_auth_filter_enabled = wanted
	settle_hold_policy()
	Logger.debug(LOG, "System-auth filter: %s.", tostring(_system_auth_filter_enabled))
	return true
end

--- Toggles at-rest encryption of the typed-text columns.
--- Refuses to report success when no key can be derived on this machine: a
--- setting that claims to encrypt and does not is the defect this replaced.
--- @param enabled boolean
--- @return boolean The posture actually in force after the call.
function M.set_encrypt_enabled(enabled)
	if M.has_flush_debt() or _flush_stopping then return false end
	if not Preferences.admit() then return false end
	local want = (enabled == true)
	if want and not TextCipher.is_available() then
		Logger.error(LOG, "At-rest encryption requested but no key can be derived — keeping the current posture.")
		return false
	end
	if not store_bool(KEY.METRICS_ENCRYPT, want) then
		Logger.error(LOG, "At-rest encryption state was not persisted — it was not changed.")
		return false
	end
	local changed = (want ~= _encrypt_enabled)
	_encrypt_enabled = want
	-- The cipher is flipped BEFORE the migration starts: encrypt() returns the
	-- plaintext untouched while the toggle is off, so an encrypting pass launched
	-- first would convert nothing and report success.
	TextCipher.set_enabled(want)
	-- Persisted like its siblings. This one matters most of the three: a user who
	-- turned encryption ON and found it off after a reboot would have a database
	-- half encrypted and half not, with nothing saying when the posture changed.
	Logger.debug(LOG, "At-rest encryption: %s.", tostring(_encrypt_enabled))
	if changed then M.migrate_stored_text() end
	return _encrypt_enabled
end

--- Starts (or resumes) the conversion of rows written before the current
--- posture. Idempotent: a pass over an already-converted table skips every row.
--- @return boolean True when a pass is in flight.
function M.migrate_stored_text()
	if M.has_flush_debt() or _flush_stopping then return false end
	if not Preferences.admit() then return false end
	TextMigration.cancel()
	return TextMigration.start(
		_encrypt_enabled and MigrationPlan.MODE_ENCRYPT or MigrationPlan.MODE_DECRYPT,
		_device_id)
end

--- Advances the at-rest migration by one bounded batch.
--- Driven from the daemon's periodic tick rather than from flush(): the work is
--- one openssl spawn per value, and the flush path runs on the keystroke side of
--- the daemon where that cost would be felt as input lag.
function M.pump_migration()
	if M.has_flush_debt() then return end
	TextMigration.pump()
end

--- Snapshot of the at-rest migration, for the menu and for diagnostics.
--- @return table
function M.get_migration_progress()
	return TextMigration.get_progress()
end

--- Stops the at-rest migration. Converted rows stay converted and the stored
--- cursor lets a later run pick up from there, so this is a pause, not a revert.
function M.cancel_migration()
	TextMigration.cancel()
end

--- Returns whether at-rest encryption is active.
--- @return boolean
function M.is_encrypt_enabled()
	return _encrypt_enabled
end

--- Captures configuration without transient focus state or historical data.
--- @return table|nil Detached posture; nil during conversion, owned flush or shutdown.
function M.configuration_snapshot()
	if M.has_flush_debt() or _flush_stopping then return nil end
	if TextMigration.is_running() then
		Logger.error(LOG, "Collector configuration is owned by an active historical conversion.")
		return nil
	end
	return {
		enabled = _enabled,
		private_filter_enabled = _private_filter_enabled,
		secure_filter_enabled = _secure_filter_enabled,
		system_auth_filter_enabled = _system_auth_filter_enabled,
		encrypt = _encrypt_enabled,
		cipher_enabled = TextCipher.is_enabled(),
		disabled_apps = M.get_disabled_apps(),
	}
end

--- Applies future capture policy without persistence or historical conversion.
--- The scope owner retains the inverse if a cipher call mutates before refusal.
--- @param candidate table Configuration snapshot to apply or restore.
--- @return boolean acknowledged
function M.apply_configuration(candidate)
	if M.has_flush_debt() or _flush_stopping then return false end
	if type(candidate) ~= "table" or TextMigration.is_running() then return false end
	for _, key in ipairs({ LEAF.ENABLED, LEAF.PRIVATE_FILTER_ENABLED, LEAF.SECURE_FILTER_ENABLED,
		LEAF.SYSTEM_AUTH_FILTER_ENABLED, LEAF.ENCRYPT, "cipher_enabled" }) do
		if type(candidate[key]) ~= "boolean" then return false end
	end
	if type(candidate.disabled_apps) ~= "table" then return false end
	for _, app in ipairs(candidate.disabled_apps) do
		if type(app) ~= "string" then return false end
	end
	if TextCipher.is_enabled() ~= candidate.cipher_enabled then
		if candidate.cipher_enabled and not TextCipher.is_available() then
			Logger.error(LOG, "Collector configuration requires an unavailable cipher.")
			return false
		end
		local called, acknowledged = pcall(TextCipher.set_enabled, candidate.cipher_enabled)
		if not called or acknowledged ~= true or TextCipher.is_enabled() ~= candidate.cipher_enabled then
			Logger.error(LOG, "Collector configuration cipher transition was not acknowledged.")
			return false
		end
	end
	_enabled = candidate.enabled
	_private_filter_enabled = candidate.private_filter_enabled
	_secure_filter_enabled = candidate.secure_filter_enabled
	_system_auth_filter_enabled = candidate.system_auth_filter_enabled
	_encrypt_enabled = candidate.encrypt
	_disabled_list = {}
	for index, app in ipairs(candidate.disabled_apps) do _disabled_list[index] = app end
	_disabled_apps = exclusion_set(_disabled_list)
	settle_hold_policy()
	Logger.debug(LOG, "Collector configuration applied without historical conversion.")
	return true
end

--- Snapshot of the active privacy posture, for the menu and for diagnostics.
--- @return table
function M.get_privacy_state()
	return {
		enabled                    = _enabled,
		private_filter_enabled     = _private_filter_enabled,
		secure_filter_enabled      = _secure_filter_enabled,
		system_auth_filter_enabled = _system_auth_filter_enabled,
		encrypt                    = _encrypt_enabled,
		private_window             = _private_window,
		secure_field               = _secure_field,
		suppressed                 = _suppressed,
		suspended                  = _suspended,
	}
end


-- =========================================
-- =========================================
-- ======= 6/ JSON Export ==================
-- =========================================
-- =========================================

--- Exports the current session as a JSON-serializable table.
--- All timestamps in milliseconds for unit consistency.
--- @return table
function M.export_session()
	local stats = { keystrokes = 0, words = 0, start_time = 0, duration_ms = 0 }
	local wpm = 0.0
	if Metrics then
		stats = Metrics.get_session_stats()
		wpm   = Metrics.get_wpm()
	end
	local apps  = M.get_app_stats()

	return {
		session_started_ms = _session_started_at,
		exported_at_ms     = os.time() * 1000,
		keystrokes         = stats.keystrokes,
		words              = stats.words,
		duration_ms        = stats.duration_ms,
		wpm                = wpm,
		apps               = apps,
		suppressed         = _suppressed,
		suspended          = _suspended,
	}
end

--- Serialises the session to a JSON string.
--- @return string
function M.export_json()
	local data = M.export_session()
	return _to_json(data)
end

--- Copies only caller-owned RAM data; no I/O or persistence is implied.
local function copy_flush_value(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy_flush_value(item) end
	return result
end

-- The numeric cursor fields an open-walk record keeps, in their fixed order.
-- No typed text: the open word and sequence are not persisted.
local OPEN_SESSION_FIELDS = { "char_count", "total_ms" }
local OPEN_BURST_FIELDS = { "char_count", "sum_delays", "sum_delays_sq", "max_delay" }

--- Encodes the sessions and bursts the walk contexts hold open, canonically, so
--- an unchanged state encodes to the same text and causes no write.
--- @param contexts table Walk contexts by application id.
--- @return string encoded JSON array without raw NUL or newline.
local function encode_open_walk(contexts)
	local Json = require("json")
	local function cursor(value, fields)
		if type(value) ~= "table" then return "null" end
		local parts = {}
		for index, field in ipairs(fields) do parts[index] = Json.encode(value[field] or 0) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local records = {}
	for _, ctx in pairs(contexts) do
		-- The shared walk context names its cursors current_session and
		-- current_burst; the persisted record keeps its own field names.
		local session, burst = ctx.current_session, ctx.current_burst
		if type(ctx.date) == "string" and type(ctx.app) == "string" and (session or burst) then
			records[#records + 1] = { date = ctx.date, app = ctx.app, text = "{\"date\":" .. Json.encode(ctx.date)
				.. ",\"app\":" .. Json.encode(ctx.app) .. ",\"session\":" .. cursor(session, OPEN_SESSION_FIELDS)
				.. ",\"burst\":" .. cursor(burst, OPEN_BURST_FIELDS) .. "}" }
		end
	end
	table.sort(records, function(a, b) return a.date < b.date or (a.date == b.date and a.app < b.app) end)
	local texts = {}
	for index, record in ipairs(records) do texts[index] = record.text end
	return "[" .. table.concat(texts, ",") .. "]"
end

--- Decodes an open-walk record into settle-ready contexts.
--- @param encoded string Record text read from the database.
--- @return table|nil contexts { date, app, current_session?, current_burst? } list; nil when malformed.
decode_open_walk = function(encoded)
	local Json = require("json")
	local ok, records = pcall(Json.decode, encoded)
	if not ok or type(records) ~= "table" or (next(records) ~= nil and #records == 0) then return nil end
	local function cursor(value, fields)
		-- The decoder reads JSON null as an empty table.
		if value == nil or (type(value) == "table" and next(value) == nil) then return true, nil end
		if type(value) ~= "table" or #value ~= #fields then return false end
		local result = {}
		for index, field in ipairs(fields) do
			if type(value[index]) ~= "number" or value[index] ~= value[index] or value[index] < 0 then return false end
			result[field] = value[index]
		end
		return true, result
	end
	local contexts = {}
	for index, record in ipairs(records) do
		if type(record) ~= "table" or type(record.date) ~= "string"
			or not record.date:match("^%d%d%d%d%-%d%d%-%d%d$") or type(record.app) ~= "string" then return nil end
		local session_ok, session = cursor(record.session, OPEN_SESSION_FIELDS)
		local burst_ok, burst = cursor(record.burst, OPEN_BURST_FIELDS)
		if not session_ok or not burst_ok then return nil end
		contexts[index] = { date = record.date, app = record.app, current_session = session, current_burst = burst }
	end
	return contexts
end

--- Composes one immutable snapshot without advancing public watermarks.
local function capture_flush()
	local date, now_iso = os.date("%Y-%m-%d"), os.date("!%Y-%m-%d %H:%M:%S")
	local payload = { raw = { typing = {}, hotstrings = {}, shortcuts = {}, switches = {}, llm = {}, windows = {},
		sessions = {}, system = {} }, upserts = {} }
	local add = setmetatable({}, { __index = function(_, kind)
		return function(_, ...)
			payload.upserts[#payload.upserts + 1] = { kind = kind, args = copy_flush_value({ ... }) }
		end
	end })
	local buffers = {
		typing = _pending_typing_events, hotstrings = _pending_hotstring_events,
		shortcuts = _pending_shortcut_events, switches = _pending_app_switch_events,
		llm = _pending_llm_events, windows = _pending_window_switch_events, sessions = _pending_session_events,
		system = _pending_system_events,
	}
	local _pending_typing_events, _pending_hotstring_events = buffers.typing, buffers.hotstrings
	local _pending_shortcut_events, _pending_app_switch_events = buffers.shortcuts, buffers.switches
	local _pending_llm_events = buffers.llm
	local _pending_window_switch_events = buffers.windows
	local _pending_session_events = buffers.sessions
	local _pending_system_events = buffers.system
	local _flushed_app_totals = copy_flush_value(_flushed_app_totals)
	local _flushed_app_titles = copy_flush_value(_flushed_app_titles)
	local _flushed_app_holds = copy_flush_value(_flushed_app_holds)
	local _flushed_app_ngrams = copy_flush_value(_flushed_app_ngrams)
	local _flushed_app_scancodes = copy_flush_value(_flushed_app_scancodes)
	local _flushed_app_sources = copy_flush_value(_flushed_app_sources)
	local walker_contexts = copy_flush_value(_walker_contexts)
	-- 1. Compose buffered physical key events and their matching aggregates. This is
	-- the canonical, replayable source shared with the macOS/AHK drivers.
	local typing_batch = {}
	-- The nine n-gram families, walked from the SAME buffered stream the raw
	-- events are built from. Built here rather than accumulated per keystroke
	-- because a sequence is only knowable in context — a bigram needs the
	-- character before it, and a long pause has to be able to un-make one.
	local ngram_batch = nil
	-- Keystrokes are stamped on the monotonic clock, which says nothing about
	-- the time of day; the activity histogram is entirely about the time of
	-- day. Taking both readings at the same instant gives the offset between
	-- them, and the offset is what makes an uptime figure into an hour.
	local wall_offset_ms = os.time() * MS_PER_SECOND - math.floor(Monotonic.now_ms())
	for app_id, pending in pairs(_pending_typing_events) do
		-- Pointer activity alone is a row too, with no text, as macOS flushes it.
		local mouse = pending.mouse
		if #pending.events > 0 or mouse then
			local total_time_ms = 0
			for _, event in ipairs(pending.events) do total_time_ms = total_time_ms + (event[2] or 0) end
			typing_batch[#typing_batch + 1] = {
				ts = now_iso, date = date, app = dashboard_app_name(app_id),
				text = table.concat(pending.text),
				wpm = SharedMetrics.compute_wpm_from_events(#pending.events, total_time_ms),
				events_json = _to_json(pending.events),
				mouse_clicks = mouse and mouse.clicks or 0,
				mouse_scrolls = mouse and mouse.scrolls or 0,
				mouse_distance_px = mouse and math.floor(mouse.distance) or 0,
			}
		end
		if #pending.events > 0 then
			walker_contexts[app_id] = walker_contexts[app_id] or {}
			local ok_walk, walked = pcall(AggregateWalker.walk,
				pending.events, date, dashboard_app_name(app_id), ngram_batch,
				{ times = pending.times, wall_offset_ms = wall_offset_ms }, walker_contexts[app_id])
			if ok_walk then
				ngram_batch = walked
			else
				-- Loudly, and without taking the raw events down with it: the
				-- replayable stream is the source of truth and the aggregates are
				-- derived from it, so losing the derivation must never lose the source.
				return nil, "Typing aggregate derivation failed; pending source remains unacknowledged"
			end
		end
	end
	-- What each context still holds is credited once its own gap has passed,
	-- and all of it on a new day or at shutdown, so a session ends where the
	-- user stopped rather than where a flush happened to land.
	local now_ms = math.floor(Monotonic.now_ms())
	for _, context in pairs(walker_contexts) do
		local ok_settle, settled = pcall(AggregateWalker.settle, context, now_ms, ngram_batch,
			_flush_stopping or (context.date ~= nil and context.date ~= date))
		if not ok_settle then
			return nil, "Typing aggregate settlement failed; pending source remains unacknowledged"
		end
		ngram_batch = settled
	end
	-- The sessions and bursts a crashed process left open ended with it: each is
	-- credited once, to its own day, and this flush's COMMIT clears the record.
	local recovered = _recovered_walks
	for _, context in ipairs(recovered or {}) do
		local ok_recover, credited = pcall(AggregateWalker.settle, copy_flush_value(context), nil, ngram_batch, true)
		if not ok_recover then
			return nil, "Recovered open session settlement failed; its record remains retained"
		end
		ngram_batch = credited
	end
	-- What stays open after this flush is recorded in the same transaction, so a
	-- crash before the next one no longer loses the session in progress.
	local open_walk = encode_open_walk(walker_contexts)
	if open_walk ~= _persisted_open_walk then add.open_walk(_device_id, open_walk) end
	payload.raw.typing = typing_batch
	if ngram_batch then
		for _, group in ipairs(AggregateWalker.batches_for_writer(ngram_batch)) do
			add.ngrams(_device_id, group.date, group.app, group.ngrams, group.table_name)
		end
		local methods = {
			chars_class = "chars_class", errors = "errors", hourly = "hourly", hourly_min5 = "hourly_min5",
			app_buckets = "app_bucket", bursts = "burst", sessions = "session", ergo = "ergo", layouts = "layout",
		}
		for family, rows in pairs(AggregateWalker.daily_rows(ngram_batch)) do
			for _, row in ipairs(rows) do add[assert(methods[family])](_device_id, row) end
		end
	end
	if #_pending_hotstring_events > 0 then
		payload.raw.hotstrings = _pending_hotstring_events
		_pending_hotstring_events = {}
	end
	if #_pending_shortcut_events > 0 then
		payload.raw.shortcuts = _pending_shortcut_events
		_pending_shortcut_events = {}
	end
	if #_pending_llm_events > 0 then
		payload.raw.llm = _pending_llm_events
		_pending_llm_events = {}
	end
	if #_pending_window_switch_events > 0 then
		payload.raw.windows = _pending_window_switch_events
		_pending_window_switch_events = {}
	end
	if #_pending_session_events > 0 then
		payload.raw.sessions = _pending_session_events
		_pending_session_events = {}
	end
	if #_pending_system_events > 0 then
		payload.raw.system = _pending_system_events
		_pending_system_events = {}
	end
	-- The machine's own state, which the dashboard puts beside the typing to
	-- explain a quiet afternoon. Sampled on the daemon's tick, written here.
	if SystemMetrics then
		local day = SystemMetrics.current()
		if day then add.system_day(_device_id, day) end
	end

	if #_pending_app_switch_events > 0 then
		-- Count the transitions from this exact immutable raw snapshot. Its
		-- source remains retained until the whole transaction is acknowledged.
		local transitions = {}
		for _, event in ipairs(_pending_app_switch_events) do
			local key = event.date .. "\1" .. event.prev_app .. "\1" .. event.next_app
			local row = transitions[key]
			if not row then
				row = { date = event.date, app_from = event.prev_app, app_to = event.next_app, count = 0 }
				transitions[key] = row
			end
			row.count = row.count + 1
		end
		payload.raw.switches = _pending_app_switch_events
		_pending_app_switch_events = {}
		for _, row in pairs(transitions) do add.switch_to(_device_id, row) end
	end

	-- 2. Upsert only new per-app daily aggregate values.
	local apps = M.get_app_stats()
	for app_id, app_stats in pairs(apps) do
		-- The dashboard and both other drivers retain the complete desktop
		-- identifier (for example org.mozilla.firefox). Truncating at the first
		-- dot silently merged unrelated applications in the persisted database.
		local app_name = dashboard_app_name(app_id)
		local current = {
			chars       = app_stats.keystrokes or 0,
			time_ms     = app_stats.typing_time_ms or 0,
			app_time_ms = app_stats.focus_time_ms or 0,
			hs_chars    = app_stats.hs_chars or 0,
			hs_triggers = app_stats.hs_triggers or 0,
			hs_input_chars = app_stats.hs_input_chars or 0,
			-- The three LLM counters, missing from this table until 2026-08-06.
			-- record_synthetic_output has always incremented them in memory and
			-- upsert_app_day has always accepted them — they were simply never
			-- named here, so every accepted completion was counted for the life of
			-- the process and forgotten at the next start. The dashboard's
			-- LLM-gain figure read zero on a machine that had been using it all
			-- day, which looks exactly like a feature nobody uses.
			llm_chars       = app_stats.llm_chars or 0,
			llm_triggers    = app_stats.llm_triggers or 0,
			llm_input_chars = app_stats.llm_input_chars or 0,
			-- The denominators of the acceptance rate. Recorded in memory since
			-- record_suggestion existed and never persisted, which is the same
			-- shape the three LLM counters above had: a number the process knew
			-- and forgot at every restart.
			hs_suggested    = app_stats.hs_suggested or 0,
			llm_suggested   = app_stats.llm_suggested or 0,
		}
		local previous = _flushed_app_totals[app_id] or {}
		local delta = {}
		local changed = false
		for field, value in pairs(current) do
			local increment = math.max(0, value - (previous[field] or 0))
			delta[field] = increment
			changed = changed or increment > 0
		end
		if changed then add.app_day(_device_id, date, app_name, delta) end
		_flushed_app_totals[app_id] = current

		-- Hold durations, as deltas: the row sums on conflict.
		local flushed_holds = _flushed_app_holds[app_id] or {}
		for code, row in pairs((_app_stats[app_id] or {}).kc_hold or {}) do
			local before = flushed_holds[code]
				or { sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }
			local delta_count = math.max(0, row.count - before.count)
			if delta_count > 0 then
				add.kc_hold(_device_id, {
					date = date, app = app_name, keycode = code,
					sum_ms = math.max(0, row.sum_ms - before.sum_ms),
					count = delta_count,
					-- The longest hold is a record, not a delta: sending the running
					-- maximum is right because the column takes a MAX on conflict.
					max_ms = row.max_ms,
					tap_count = math.max(0, row.tap_count - before.tap_count),
					hold_count = math.max(0, row.hold_count - before.hold_count),
				})
			end
			flushed_holds[code] = {
				sum_ms = row.sum_ms, count = row.count, max_ms = row.max_ms,
				tap_count = row.tap_count, hold_count = row.hold_count,
			}
		end
		_flushed_app_holds[app_id] = flushed_holds

		-- Window titles, as deltas like everything else on this table: the rows
		-- add on conflict, so writing the cumulative counters again would count
		-- every earlier keystroke once more per flush.
		local flushed_titles = _flushed_app_titles[app_id] or {}
		for title, row in pairs((_app_stats[app_id] or {}).titles or {}) do
			local before = flushed_titles[title] or { c = 0, ms = 0 }
			local delta_c = math.max(0, (row.c or 0) - before.c)
			local delta_ms = math.max(0, (row.ms or 0) - before.ms)
			if delta_c > 0 or delta_ms > 0 then
				add.title(_device_id, {
					date = date, app = app_name, title = title,
					c = delta_c, ms = delta_ms,
				})
			end
			flushed_titles[title] = { c = row.c or 0, ms = row.ms or 0 }
		end
		_flushed_app_titles[app_id] = flushed_titles
	end

	-- 3. Record which per-app character counts are now persisted, so the
	-- live view adds only what came after. They were also written here, as a
	-- delta, on top of the aggregate walker's rows for the same characters:
	-- both upserts add, so every stored character count was doubled. The
	-- walker's rows, which carry the sources too, are the only write.
	for app_id, app_stats in pairs(_app_stats) do
		_flushed_app_ngrams[app_id] = {}
		for token, count in pairs(app_stats.ngrams or {}) do _flushed_app_ngrams[app_id][token] = count end
		_flushed_app_sources[app_id] = {}
		for token, sources in pairs(app_stats.ngram_sources or {}) do
			_flushed_app_sources[app_id][token] = {}
			for source, count in pairs(sources) do _flushed_app_sources[app_id][token][source] = count end
		end

		local previous_scancodes = _flushed_app_scancodes[app_id] or {}
		local scancode_delta = {}
		for scancode, count in pairs(app_stats.physical_scancodes or {}) do
			local increment = math.max(0, count - (previous_scancodes[scancode] or 0))
			if increment > 0 then scancode_delta[scancode] = increment end
		end
		if next(scancode_delta) ~= nil then
			add.scancodes(_device_id, date, dashboard_app_name(app_id), scancode_delta)
		end
		_flushed_app_scancodes[app_id] = {}
		for scancode, count in pairs(app_stats.physical_scancodes or {}) do
			_flushed_app_scancodes[app_id][scancode] = count
		end
	end

	return {
		payload = payload, buffers = buffers,
		watermarks = {
			totals = _flushed_app_totals, titles = _flushed_app_titles, holds = _flushed_app_holds,
			ngrams = _flushed_app_ngrams, scancodes = _flushed_app_scancodes, sources = _flushed_app_sources,
			walker = walker_contexts, open_walk = open_walk, recovered = recovered ~= nil,
		},
	}
end

--- Returns a RAM-only description of native ownership and logical flush debt.
--- Known rollback permits coherent last-COMMIT + complete RAM projections;
--- unresolved COMMIT and running writes must defer such merged projections.
--- @return table
function M.get_flush_status()
	local state = _flush_state
	local safe = state == nil or (state.operation ~= nil and state.operation:is_read_safe() == true)
	return {
		phase = state and (state.operation and state.operation:phase() or "uncertain") or "idle",
		pending = not safe, has_debt = state ~= nil, read_safe = safe,
		committed = state == nil and _last_flush_committed == true,
		stopping = _flush_stopping, generation = _flush_generation,
		retryable = state ~= nil and state.operation ~= nil and state.operation:is_retryable() == true,
		error = state and state.operation and state.operation.result and state.operation.result.error or nil,
	}
end

--- Returns whether a merged persisted/live projection must wait for a verdict.
--- @return boolean
function M.is_flush_pending() return M.get_flush_status().pending end

--- Returns whether a captured snapshot is still unacknowledged.
--- @return boolean
function M.has_flush_debt() return _flush_state ~= nil end

--- Subscribes to the next conclusive commit/rollback observation from pump().
--- @param callback function Receives the RAM-only status; may run inline if safe.
--- @return boolean
function M.when_flush_settled(callback)
	if type(callback) ~= "function" or _flush_stopping then return false end
	local status = M.get_flush_status()
	if status.read_safe then pcall(callback, status) else _flush_listeners[#_flush_listeners + 1] = callback end
	return true
end

local function publish_flush_observation()
	if _flush_stopping or not M.get_flush_status().read_safe then return end
	local listeners = _flush_listeners
	_flush_listeners = {}
	local status = M.get_flush_status()
	for _, callback in ipairs(listeners) do pcall(callback, status) end
end

--- Consumes staged native receipts off the input callback, without running luv.
--- @return boolean Whether no captured snapshot remains.
function M.pump_flush()
	if _flush_pumping then return _flush_state == nil end
	local state = _flush_state
	if not state then publish_flush_observation(); return true end
	if not state.operation then return false end
	_flush_pumping = true
	local called, settled = pcall(state.operation.pump, state.operation)
	if not called then
		Logger.error(LOG, "SQLite flush observation failed; exact ownership remains retained.")
		_flush_pumping = false
		return false
	end
	if settled == true then
		local result = state.operation.result
		if type(result) == "table" and result.committed == true then
			local marks = state.snapshot.watermarks
			_flushed_app_totals, _flushed_app_titles, _flushed_app_holds = marks.totals, marks.titles, marks.holds
			_flushed_app_ngrams, _flushed_app_scancodes, _flushed_app_sources = marks.ngrams, marks.scancodes, marks.sources
			_walker_contexts = marks.walker
			_persisted_open_walk = marks.open_walk
			if marks.recovered then _recovered_walks = nil end
			_manifest_cache = { revision = nil, manifest = nil }
			_last_flush_committed, _flush_state = true, nil
			Logger.info(LOG, "Session flush received its SQLite COMMIT and native cleanup acknowledgement.")
		elseif not state.failure_reported then
			state.failure_reported = true
			Logger.error(LOG, "SQLite persistence did not receive a conclusive successful COMMIT; pending source remains retained.")
		end
	end
	_flush_pumping = false
	publish_flush_observation()
	return _flush_state == nil
end

local function restore_flush_buffers(buffers)
	local function prepend(older, newer)
		local values = {}
		for _, value in ipairs(older) do values[#values + 1] = value end
		for _, value in ipairs(newer) do values[#values + 1] = value end
		return values
	end
	for app, older in pairs(buffers.typing) do
		local newer = _pending_typing_events[app]
		if newer then
			for _, field in ipairs({ "text", "events", "times" }) do older[field] = prepend(older[field], newer[field]) end
			if newer.mouse then
				local mouse = older.mouse or { clicks = 0, scrolls = 0, distance = 0 }
				for _, field in ipairs({ "clicks", "scrolls", "distance" }) do mouse[field] = mouse[field] + newer.mouse[field] end
				older.mouse = mouse
			end
		end
		_pending_typing_events[app] = older
	end
	_pending_hotstring_events = prepend(buffers.hotstrings, _pending_hotstring_events)
	_pending_shortcut_events = prepend(buffers.shortcuts, _pending_shortcut_events)
	_pending_llm_events = prepend(buffers.llm, _pending_llm_events)
	_pending_window_switch_events = prepend(buffers.windows, _pending_window_switch_events)
	_pending_session_events = prepend(buffers.sessions, _pending_session_events)
	_pending_system_events = prepend(buffers.system, _pending_system_events)
	_pending_app_switch_events = prepend(buffers.switches, _pending_app_switch_events)
end

local function warn_flush_unavailable()
	if not _flush_unavailable_warned then
		_flush_unavailable_warned = true
		Logger.warn(LOG, "SQLite flush transport unavailable; pending source stays in memory and was not saved.")
	end
end

local function dispatch_flush()
	if SqliteWriter.flush_transport_available() ~= true then
		_last_flush_committed = false
		warn_flush_unavailable()
		return false
	end
	local captured, snapshot, reason = pcall(capture_flush)
	if not captured or not snapshot then
		Logger.error(LOG, "SQLite flush preparation refused; pending source remains retained.")
		return false
	end
	local payload = snapshot.payload
	if #payload.raw.typing == 0 and #payload.raw.hotstrings == 0 and #payload.raw.shortcuts == 0
		and #payload.raw.llm == 0 and #payload.raw.switches == 0 and #payload.raw.windows == 0
		and #payload.raw.sessions == 0 and #payload.raw.system == 0 and #payload.upserts == 0 then
		_last_flush_committed = true
		return true
	end
	_flush_generation = _flush_generation + 1
	_last_flush_committed = false
	local state = { snapshot = snapshot }
	_flush_state = state -- Reserve before any reentrant external allocation.
	_pending_typing_events, _pending_hotstring_events = {}, {}
	_pending_shortcut_events, _pending_app_switch_events = {}, {}
	_pending_llm_events = {}
	_pending_window_switch_events = {}
	_pending_session_events = {}
	_pending_system_events = {}
	local called, operation = pcall(SqliteWriter.start_flush, _device_id, payload)
	if not called then
		Logger.error(LOG, "SQLite dispatch raised; uncertain ownership and source remain retained.")
		return false
	end
	if not operation then
		-- Refusal acquires nothing, but a port may have synchronously admitted
		-- another input callback. Restore the old prefix without losing arrivals.
		restore_flush_buffers(snapshot.buffers)
		_flush_state = nil
		return false
	end
	state.operation = operation
	return M.pump_flush()
end

local function flush_json()
	local date = os.date("%Y-%m-%d")
	-- FALLBACK: JSON log file. It holds the session summary only, so the
	-- buffered raw events are dropped here: kept, they grew for the whole
	-- session, since only the SQLite branch ever emptied them.
	if not _log_dir then
		Logger.warn(LOG, "flush(): no log directory configured.")
		return false
	end

	os.execute(string.format("mkdir -p '%s' 2>/dev/null", _log_dir:gsub("'", "'\\''")))

	local path = _log_dir .. "/keystrokes_" .. date .. ".json"

	local fh = io.open(path, "w")
	if not fh then
		Logger.error(LOG, "flush(): cannot write to '%s'.", path)
		return false
	end
	local written = fh:write(M.export_json(), "\n")
	local closed = fh:close()
	if not written or not closed then return false end
	_pending_typing_events, _pending_hotstring_events = {}, {}
	_pending_shortcut_events, _pending_app_switch_events = {}, {}
	_pending_llm_events = {}
	_pending_window_switch_events = {}
	_pending_session_events = {}
	_pending_system_events = {}

	Logger.info(LOG, "Session flushed to JSON: %s.", path)
	return true
end

--- The flush body: retries a retained snapshot, else dispatches a new one.
--- @return boolean
local function flush_dispatch()
	if _flush_state then
		local operation = _flush_state.operation
		if operation and operation:is_retryable() then
			_flush_generation = _flush_generation + 1
			operation:retry()
		end
		return M.pump_flush()
	end
	if SqliteWriter and SqliteWriter.is_available() then return dispatch_flush() end
	return flush_json()
end

--- Dispatches or retries one immutable flush snapshot; false never means saved.
--- Counted and, at DEBUG, timed.
--- @return boolean True only after durable COMMIT and native cleanup ACK.
function M.flush()
	if _flush_stopping then return false end
	-- The periodic flush is the session's idle check (timings ingest_tick_ms).
	if may_record() then queue_session_events(_session.tick(math.floor(Monotonic.now_ms()))) end
	-- And it takes the machine's transitions the daemon's sampler saw, always,
	-- so a span when recording was forbidden is dropped rather than kept.
	if SystemMetrics then
		local transitions = SystemMetrics.take_events()
		if may_record() then
			for _, transition in ipairs(transitions) do
				_pending_system_events[#_pending_system_events + 1] = {
					ts = os.date("!%Y-%m-%d %H:%M:%S"), date = os.date("%Y-%m-%d"),
					action = transition.action, metadata = transition.metadata,
				}
			end
		end
	end
	local started = Perf.clock()
	Perf.count("keystats.flushes")
	local result = flush_dispatch()
	Perf.span("keystats.flush", started)
	return result
end

--- Quiesces producers and waits for exact native retirement, independently of
--- business success. Failed persistence remains retained and is reported; it
--- must never be mistaken for a resource still owned after its cleanup ACK.
--- @return boolean True only when no native flush work remains acquired.
function M.stop()
	if not _flush_stopping then
		-- The open session ends with the daemon, before the final flush takes it.
		if may_record() then queue_session_events(_session.stop()) end
		_flush_stopping = true
		_flush_generation = _flush_generation + 1
		_flush_listeners = {}
	end
	M.pump_flush()
	if _flush_state then
		local operation = _flush_state.operation
		if not operation then return false end
		-- A failed, physically settled attempt is not retried during shutdown.
		-- A live attempt keeps its original deadline and can finish normally.
		if operation:is_retryable() then operation:cancel(); M.pump_flush() end
		if operation:is_settled() then
			local result = operation.result
			if type(result) == "table" and result.committed ~= true then return true end
		end
		if _flush_state then return false end
	end
	if _stop_final_dispatched then return true end
	_stop_final_dispatched = true
	if SqliteWriter and SqliteWriter.is_available() then
		if dispatch_flush() then return true end
		if _flush_state then return M.stop() end
		if SqliteWriter.flush_transport_available() then
			Logger.error(LOG, "Final SQLite persistence was refused before acquisition; source remains retained.")
		end
		return true
	end
	if not _stop_fallback_attempted then
		_stop_fallback_attempted = true
		if flush_json() ~= true then Logger.error(LOG, "Final session persistence failed before shutdown.") end
	end
	return true
end


-- =========================================
-- =========================================
-- ======= 7/ Delegate Methods =============
-- =========================================
-- =========================================

--- Returns the rolling WPM (delegates to metrics_collector).
--- Returns 0 when metrics_collector is unavailable.
--- @return number
function M.get_wpm()
	if not Metrics then return 0.0 end
	return Metrics.get_wpm()
end

--- The readouts' live numbers: { wpm, source, source_variant, source_time (s) }.
--- @param now_ms number|nil Monotonic milliseconds; now when nil.
--- @return table
function M.get_live_stats(now_ms)
	return LiveWpm.stats(_live, now_ms or Monotonic.now_ms())
end

--- Returns session statistics.
--- Returns a safe empty table when metrics_collector is unavailable.
--- @return table
function M.get_session_stats()
	if not Metrics then return { keystrokes = 0, words = 0, start_time = 0, duration_ms = 0 } end
	return Metrics.get_session_stats()
end

--- Returns top N n-grams.
--- Returns empty table when metrics_collector is unavailable.
--- @param n number
--- @return table
function M.get_ngrams(n)
	if not Metrics then return {} end
	return Metrics.get_ngrams(n)
end

--- Resets all session data.
function M.reset_session()
	if M.has_flush_debt() or _flush_stopping then return false end
	_flush_generation = _flush_generation + 1
	_hold_token = {}
	if Metrics then Metrics.reset_session() end
	_app_stats = {}
	_focused_app_id         = nil
	_focused_app_started_at = nil
	_current_title      = nil
	_title_since        = nil
	_current_title_app  = nil
	_flushed_app_totals     = {}
	_flushed_app_titles     = {}
	_flushed_app_holds      = {}
	_flushed_app_ngrams     = {}
	_flushed_app_scancodes  = {}
	_flushed_app_sources    = {}
	_walker_contexts        = {}
	_typing_last_key_at     = {}
	_manifest_cache         = { revision = nil, manifest = nil }
	_pending_typing_events  = {}
	_pending_hotstring_events = {}
	_pending_shortcut_events = {}
	_pending_llm_events = {}
	_pending_window_switch_events = {}
	_pending_session_events = {}
	_pending_system_events = {}
	_pending_app_switch_events = {}
	_live = new_live_tracker()
	_session = new_session_tracker()
	_session_started_at = os.time() * 1000
	return true
end


-- =========================================
-- =========================================
-- ======= 8/ JSON Serialiser ==============
-- =========================================
-- =========================================

--- Minimal JSON encoder for export (no external dependency).
--- NOTE: assigned (not "local function") so it writes to the forward-declared
--- upvalue.  Using "local function" would create a shadow local and leave the
--- upvalue nil for closures defined between the forward-decl and this point.
_to_json = function(val)
	if type(val) == "nil" then return "null" end
	if type(val) == "boolean" then return val and "true" or "false" end
	if type(val) == "number" then
		-- Handle NaN/Inf gracefully.
		if val ~= val then return "0" end  -- NaN
		if val == math.huge or val == -math.huge then return "0" end
		return tostring(val)
	end
	if type(val) == "string" then
		-- Every U+0000-U+001F byte must travel escaped: a raw control inside
		-- the quotes is not JSON, and a strict decoder on another driver
		-- rejects the whole events_json row carrying it.
		return '"' .. val:gsub('[%z\1-\31\\"]', function(ch)
			if ch == '\\' then return '\\\\' end
			if ch == '"' then return '\\"' end
			if ch == '\n' then return '\\n' end
			if ch == '\r' then return '\\r' end
			if ch == '\t' then return '\\t' end
			if ch == '\b' then return '\\b' end
			if ch == '\f' then return '\\f' end
			return string.format('\\u%04x', string.byte(ch))
		end) .. '"'
	end
	if type(val) == "table" then
		local is_array = #val > 0 or next(val) == nil
		if is_array then
			local parts = {}
			for _, v in ipairs(val) do parts[#parts + 1] = _to_json(v) end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local parts = {}
			for k, v in pairs(val) do
				parts[#parts + 1] = _to_json(tostring(k)) .. ":" .. _to_json(v)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	return "null"
end


--- How many raw-event buffers are waiting for a flush (tests). Session events
--- are left out: the clock ticks them on its own, whatever a test types.
--- @return integer
function M._pending_buffer_count_for_test()
	local count = #_pending_hotstring_events + #_pending_shortcut_events + #_pending_llm_events
		+ #_pending_app_switch_events + #_pending_window_switch_events
	for _, pending in pairs(_pending_typing_events) do count = count + #pending.events end
	if _flush_state then
		local held = _flush_state.snapshot.buffers
		count = count + #held.hotstrings + #held.shortcuts + #held.llm + #held.switches + #held.windows
		for _, pending in pairs(held.typing) do count = count + #pending.events end
	end
	return count
end

return M

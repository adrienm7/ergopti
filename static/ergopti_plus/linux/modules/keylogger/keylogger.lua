--- modules/keylogger/keylogger.lua

--- ==============================================================================
--- MODULE: Full Keylogger (Linux)
--- DESCRIPTION:
--- Extends metrics_collector with app-level grouping, password-field detection,
--- JSON export, and SQLite-based persistence. Wraps the existing metrics_collector
--- so the daemon has a single keylogger surface. Equivalent to the macOS/Windows
--- keylogger modules (keylogger.lua / keylogger.ahk).
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
local Monotonic = require("lib.monotonic")
local Timings   = require("lib.timings")
-- Hard requires: the privacy posture must come from the shared manifest, and a
-- missing filter must fail loudly rather than degrade into "record everything".
local Manifest      = require("lib.manifest_reader")
local PrivateWindow = require("keylogger.private_window")
-- WPM ring cap single-sourced from the shared keylogger metrics module so the
-- per-app rings below never drift from the collector's global ring cap.
local SharedMetrics    = require("keylogger.metrics")
local WPM_RING_CAPACITY = SharedMetrics.DEFAULT_WPM_RING_CAPACITY
local MAX_TYPING_INTERVAL_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")
-- Metrics collector is optional — keylogger falls back gracefully without it.
local Metrics  = nil
local ok_mc, mc_mod = pcall(require, "modules.keylogger.metrics_collector")
if ok_mc then Metrics = mc_mod end

-- SQLite writer — optional (falls back to JSON when sqlite3 CLI is absent).
local SqliteWriter = nil
local ok_sw, sw_mod = pcall(require, "modules.keylogger.sqlite_writer")
if ok_sw then SqliteWriter = sw_mod end

local SqliteReader = nil
local ok_sr, sr_mod = pcall(require, "modules.keylogger.sqlite_reader")
if ok_sr then SqliteReader = sr_mod end

local LOG = "modules.keylogger.keylogger"


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
local _pending_app_switch_events = {}
local _flushed_app_ngrams = {}
local _flushed_app_scancodes = {}
local _flushed_app_sources = {}

-- Persisted manifest cache keyed by SQLite's monotonic revision. The live
-- delta is layered on a shallow copy, so an open dashboard avoids a CLI query
-- every two seconds without ever serving stale keystrokes.
local _manifest_cache = { revision = nil, manifest = nil }

-- Whether password-field suppression is active.
local _suppressed = false

-- Cross-driver privacy posture, read from the shared features manifest so the
-- three drivers cannot drift. Linux had none of these: it recorded
-- unconditionally, because the metrics section of the manifest did not list
-- "linux" and the codegen emitted no manifest for this driver to read.
local _enabled                    = Manifest.default_for("metrics.enabled")
local _private_filter_enabled     = Manifest.default_for("metrics.private_filter_enabled")
local _secure_filter_enabled      = Manifest.default_for("metrics.secure_filter_enabled")
local _system_auth_filter_enabled = Manifest.default_for("metrics.system_auth_filter_enabled")

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
-- guard in tests/unit/meta/test_keylogger.lua.
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
	if not _enabled then return false end
	if _suppressed then return false end
	if _secure_filter_enabled and _secure_field then return false end
	if _private_filter_enabled and _private_window then return false end
	return true
end

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
		llm_chars        = 0,
		llm_triggers     = 0,
		llm_input_chars  = 0,
		physical_scancodes = {},
		ngram_sources      = {},
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

--- Initialises the keylogger.
--- @param opts table { log_dir?, password_apps? }
function M.init(opts)
	local options = type(opts) == "table" and opts or {}

	-- Initialise the underlying metrics collector if available.
	if Metrics then Metrics.init({}) end

	-- Set up log / SQLite directories for persistence.
	local home = os.getenv("HOME") or "~"
	local data_home = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
	_log_dir = options.log_dir or (home .. "/.config/ergopti/logs")
	_sqlite_path = options.sqlite_path or (data_home .. "/ergopti/metrics.sqlite")

	-- Derive device ID from hostname.
	local hostname = "linux"
	local fh_host = io.popen("hostname 2>/dev/null", "r")
	if fh_host then
		hostname = fh_host:read("*l") or "linux"
		fh_host:close()
	end
	hostname = hostname:gsub("%s+", "")
	_device_id = "linux-" .. hostname

	-- Open the SQLite database (bootstraps schema on first run).
	if SqliteWriter and SqliteWriter.open_db(_sqlite_path) then
		SqliteWriter.register_device(_device_id, hostname, "linux", "", hostname)
		Logger.info(LOG, "SQLite persistence active: %s", _sqlite_path)
	else
		Logger.info(LOG, "SQLite unavailable — JSON fallback active.")
	end

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

	Logger.success(LOG, "Keylogger initialised (log_dir=%s, password_apps=%d).",
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
function M.on_keydown(ch, timestamp_ms, app_id, scancode)
	if not may_record() then return end

	-- Forward to the base metrics collector if available.
	if Metrics then
		Metrics.on_keydown(ch, timestamp_ms)
	end

	-- Per-app tracking. Focus polling is asynchronous; use an explicit Unknown
	-- bucket for the small startup/focus race rather than silently dropping a
	-- real physical character and breaking the raw-event audit trail.
	local resolved_app = (type(app_id) == "string" and app_id ~= "") and app_id or "Unknown"
	if type(ch) == "string" and ch ~= "" then
		M.record_app_key(resolved_app, ch, timestamp_ms)
		local pending = _pending_typing_events[resolved_app]
		if not pending then
			pending = { text = {}, events = {}, last_key_at = nil }
			_pending_typing_events[resolved_app] = pending
		end
		local delay = 0
		if type(pending.last_key_at) == "number" then
			delay = math.max(0, math.min(timestamp_ms - pending.last_key_at, MAX_TYPING_INTERVAL_MS))
		end
		pending.last_key_at = timestamp_ms
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
	end
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

	app.keystroke_count = app.keystroke_count + 1
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
	pending = { text = {}, events = {}, last_key_at = nil }
	_pending_typing_events[app_id] = pending
	return pending
end

local function add_synthetic_ngram(app, char, source)
	app.ngrams[char] = (app.ngrams[char] or 0) + 1
	app.ngram_sources[char] = app.ngram_sources[char] or {}
	app.ngram_sources[char][source] = (app.ngram_sources[char][source] or 0) + 1
end

local function append_synthetic_events(app_id, text, source, deletes)
	local pending = ensure_pending(app_id)
	for _ = 1, math.max(0, math.floor(tonumber(deletes) or 0)) do
		pending.events[#pending.events + 1] = { "[BS]", 0, { s = 1, st = source } }
		add_synthetic_ngram(_app_stats[app_id], "[BS]", source)
	end
	if type(text) ~= "string" or text == "" then return end
	local ok, len = pcall(utf8.len, text)
	if not ok or not len then
		pending.events[#pending.events + 1] = { text, 0, { s = 1, st = source } }
		add_synthetic_ngram(_app_stats[app_id], text, source)
		return
	end
	for _, codepoint in utf8.codes(text) do
		local char = utf8.char(codepoint)
		pending.events[#pending.events + 1] = { char, 0, { s = 1, st = source } }
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
function M.record_hotstring(app_id, trigger, replacement, timestamp_ms, h_type, deletes)
	if not may_record() or type(app_id) ~= "string" or app_id == "" then return end
	if type(replacement) ~= "string" or replacement == "" then return end
	local app = ensure_app_stats(app_id, timestamp_ms)
	app.hs_chars       = app.hs_chars + char_count(replacement)
	app.hs_triggers    = app.hs_triggers + 1
	app.hs_input_chars = app.hs_input_chars + char_count(type(trigger) == "string" and trigger or "")
	append_synthetic_events(app_id, replacement, "hotstring",
		deletes ~= nil and deletes or char_count(type(trigger) == "string" and trigger or ""))
	_pending_hotstring_events[#_pending_hotstring_events + 1] = {
		ts = os.date("!%Y-%m-%d %H:%M:%S"),
		date = os.date("!%Y-%m-%d"),
		app = dashboard_app_name(app_id),
		kind = "fired",
		trigger = trigger or "",
		replacement = replacement,
		h_type = h_type or "static",
		net_saved_chars = char_count(replacement) - char_count(trigger),
	}
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
end

--- Records a foreground application transition from the process lifecycle port.
--- @param app_id string|nil New focused application identifier.
--- @param timestamp_ms number|nil Monotonic transition timestamp in milliseconds.
function M.on_app_focus(app_id, timestamp_ms)
	if type(app_id) ~= "string" or app_id == "" then return end
	local now = type(timestamp_ms) == "number" and timestamp_ms or math.floor(Monotonic.now_ms())
	if _focused_app_id == app_id then return end
	if _focused_app_id and type(_focused_app_started_at) == "number" then
		local elapsed = math.max(0, now - _focused_app_started_at)
		local previous = ensure_app_stats(_focused_app_id, _focused_app_started_at)
		previous.focus_time_ms = previous.focus_time_ms + elapsed
		_pending_app_switch_events[#_pending_app_switch_events + 1] = {
			ts = os.date("!%Y-%m-%d %H:%M:%S"),
			date = os.date("!%Y-%m-%d"),
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

local function persisted_manifest()
	if not (SqliteWriter and SqliteWriter.is_available() and SqliteReader) then return {} end
	local revision = SqliteWriter.get_revision and SqliteWriter.get_revision() or nil
	if _manifest_cache.manifest and revision ~= nil and _manifest_cache.revision == revision then
		return _manifest_cache.manifest
	end
	local fresh = SqliteReader.read_manifest(_sqlite_path)
	_manifest_cache = { revision = revision, manifest = fresh }
	return fresh
end

local function empty_ngrams()
	return { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {}, sc_kb = {} }
end

--- Adds only unflushed character n-grams to the per-app today projection.
local function add_live_ngram_delta(today_payload)
	for app_id, stats in pairs(_app_stats) do
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
				local other_delta = math.max(0,
					((stats.ngram_sources[token] or {}).other or 0)
					- (((_flushed_app_sources[app_id] or {})[token] or {}).other or 0))
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
	return today_payload
end

--- Builds the shared manifest/prefetch contract consumed by both metrics UIs.
--- Historical rows come from SQLite; only the unflushed in-memory delta is
--- layered on top, so refreshing a dashboard never double-counts a session.
--- @return table Metrics prefetch payload matching the macOS/Windows schema.
function M.get_dashboard_payload(opts)
	local options = type(opts) == "table" and opts or {}
	local manifest = add_live_manifest_delta(persisted_manifest())
	local prefetch = nil
	if options.include_prefetch ~= false then
		prefetch = M.get_range_payload(nil, nil, nil)
	end
	return {
		metrics_manifest = manifest,
		app_icons        = {},
		_prefetch_data   = prefetch,
		driver_meta      = { os = "linux", heatmap_id = "sc_kb" },
	}
end

--- Returns n-grams for one UI-selected range without rebuilding the manifest.
--- @param start_date string|nil Inclusive range start.
--- @param end_date string|nil Inclusive range end.
--- @param apps table|nil Selected application IDs.
function M.get_range_payload(start_date, end_date, apps)
	local payload = { historical = empty_ngrams(), today = {} }
	if SqliteWriter and SqliteWriter.is_available() and SqliteReader then
		payload = SqliteReader.read_range_split_today(_sqlite_path, start_date, end_date, apps)
	end
	payload.historical = payload.historical or empty_ngrams()
	payload.today = payload.today or {}
	payload.today = add_live_ngram_delta(payload.today)
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

--- Turns keystroke collection on or off. The Linux driver had no off switch at
--- all; the other two drivers have had one since they shipped.
--- @param enabled boolean
function M.set_enabled(enabled)
	_enabled = (enabled == true)
	Logger.debug(LOG, "Metrics collection: %s.", tostring(_enabled))
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
	Logger.debug(LOG, "Private browsing window: %s.", tostring(_private_window))
end

--- Records the AT-SPI adapter's secure-field verdict for the focused window.
--- Consulted IN ADDITION to the app-name list, never instead of it.
--- @param is_secure boolean
function M.set_secure_field(is_secure)
	_secure_field = (is_secure == true)
	Logger.debug(LOG, "Secure field focused: %s.", tostring(_secure_field))
end

--- Toggles the private-browsing filter.
--- @param enabled boolean
function M.set_private_filter_enabled(enabled)
	_private_filter_enabled = (enabled == true)
	Logger.debug(LOG, "Private-browsing filter: %s.", tostring(_private_filter_enabled))
end

--- Toggles the secure-field / password-manager filter.
--- @param enabled boolean
function M.set_secure_filter_enabled(enabled)
	_secure_filter_enabled = (enabled == true)
	Logger.debug(LOG, "Secure-field filter: %s.", tostring(_secure_filter_enabled))
end

--- Toggles the OS authentication-prompt filter.
--- @param enabled boolean
function M.set_system_auth_filter_enabled(enabled)
	_system_auth_filter_enabled = (enabled == true)
	Logger.debug(LOG, "System-auth filter: %s.", tostring(_system_auth_filter_enabled))
end

--- Snapshot of the active privacy posture, for the menu and for diagnostics.
--- @return table
function M.get_privacy_state()
	return {
		enabled                    = _enabled,
		private_filter_enabled     = _private_filter_enabled,
		secure_filter_enabled      = _secure_filter_enabled,
		system_auth_filter_enabled = _system_auth_filter_enabled,
		private_window             = _private_window,
		secure_field               = _secure_field,
		suppressed                 = _suppressed,
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
	}
end

--- Serialises the session to a JSON string.
--- @return string
function M.export_json()
	local data = M.export_session()
	return _to_json(data)
end

--- Writes the current session stats to persistent storage.
---
--- Primary path: SQLite — inserts session summary into the canonical
--- events_typing table and upserts per-app aggregates + n-grams.
---
--- Fallback path: JSON log file (~/.config/ergopti/logs/keystrokes_YYYY-MM-DD.json)
--- when the sqlite3 CLI is absent.
function M.flush()
	local date = os.date("%Y-%m-%d")
	local now_iso = os.date("!%Y-%m-%d %H:%M:%S")
	local stats = M.get_session_stats()
	local wpm = M.get_wpm()

	-- PRIMARY: SQLite persistence.
	if SqliteWriter and SqliteWriter.is_available() then
		-- 1. Persist buffered physical key events before any aggregate. This is
		-- the canonical, replayable source shared with the macOS/AHK drivers.
		local typing_batch = {}
		for app_id, pending in pairs(_pending_typing_events) do
			if #pending.events > 0 then
				local total_time_ms = 0
				for _, event in ipairs(pending.events) do total_time_ms = total_time_ms + (event[2] or 0) end
				typing_batch[#typing_batch + 1] = {
					ts = now_iso, date = date, app = dashboard_app_name(app_id),
					text = table.concat(pending.text),
					wpm = SharedMetrics.compute_wpm_from_events(#pending.events, total_time_ms),
					events_json = _to_json(pending.events),
				}
			end
		end
		if #typing_batch > 0 then
			if not SqliteWriter.insert_typing_events(_device_id, typing_batch) then return end
			_pending_typing_events = {}
		end
		if #_pending_hotstring_events > 0 then
			if not SqliteWriter.insert_hotstring_events(_device_id, _pending_hotstring_events) then return end
			_pending_hotstring_events = {}
		end
		if #_pending_app_switch_events > 0 then
			if not SqliteWriter.insert_app_switch_events(_device_id, _pending_app_switch_events) then return end
			_pending_app_switch_events = {}
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
			}
			local previous = _flushed_app_totals[app_id] or {}
			local delta = {}
			local changed = false
			for field, value in pairs(current) do
				local increment = math.max(0, value - (previous[field] or 0))
				delta[field] = increment
				changed = changed or increment > 0
			end
			if changed then SqliteWriter.upsert_app_day(_device_id, date, app_name, delta) end
			_flushed_app_totals[app_id] = current
		end

		-- 3. Persist per-app character n-grams and their synthetic provenance as
		-- deltas. The physical text and generated output share one portable char
		-- stream, while esrc_json keeps their origin queryable for the UI.
		for app_id, app_stats in pairs(_app_stats) do
			local previous = _flushed_app_ngrams[app_id] or {}
			local previous_sources = _flushed_app_sources[app_id] or {}
			local delta = {}
			for token, count in pairs(app_stats.ngrams or {}) do
				local increment = math.max(0, count - (previous[token] or 0))
				if increment > 0 then
					local sources = {}
					for source, source_count in pairs((app_stats.ngram_sources or {})[token] or {}) do
						local persisted = ((previous_sources[token] or {})[source] or 0)
						local source_increment = math.max(0, source_count - persisted)
						if source_increment > 0 then sources[source] = source_increment end
					end
					delta[token] = { c = increment, sources = sources }
				end
			end
			if next(delta) ~= nil then
				if not SqliteWriter.upsert_ngrams(_device_id, date, dashboard_app_name(app_id), delta) then return end
			end
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
				if not SqliteWriter.upsert_scancodes(_device_id, date, dashboard_app_name(app_id), scancode_delta) then return end
			end
			_flushed_app_scancodes[app_id] = {}
			for scancode, count in pairs(app_stats.physical_scancodes or {}) do
				_flushed_app_scancodes[app_id][scancode] = count
			end
		end

		-- 4. Bump the revision counter so dashboards know new data exists.
		SqliteWriter.bump_rev()
		_manifest_cache = { revision = nil, manifest = nil }

		Logger.info(LOG, "Session flushed to SQLite: %s.", _sqlite_path)
		return
	end

	-- FALLBACK: JSON log file.
	if not _log_dir then
		Logger.warn(LOG, "flush(): no log directory configured.")
		return
	end

	os.execute(string.format("mkdir -p '%s' 2>/dev/null", _log_dir:gsub("'", "'\\''")))

	local path = _log_dir .. "/keystrokes_" .. date .. ".json"

	local fh = io.open(path, "w")
	if not fh then
		Logger.error(LOG, "flush(): cannot write to '%s'.", path)
		return
	end
	fh:write(M.export_json(), "\n")
	fh:close()

	Logger.info(LOG, "Session flushed to JSON: %s.", path)
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
	if Metrics then Metrics.reset_session() end
	_app_stats = {}
	_focused_app_id         = nil
	_focused_app_started_at = nil
	_flushed_app_totals     = {}
	_flushed_app_ngrams     = {}
	_flushed_app_scancodes  = {}
	_flushed_app_sources    = {}
	_manifest_cache         = { revision = nil, manifest = nil }
	_pending_typing_events  = {}
	_pending_hotstring_events = {}
	_pending_app_switch_events = {}
	_session_started_at = os.time() * 1000
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
		return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
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

return M

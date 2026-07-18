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

-- Whether password-field suppression is active.
local _suppressed = false

-- Base list of apps considered password fields (case-insensitive substring match
-- on appId). Single source — the init reset below rebuilds from this instead of
-- re-typing the same eight entries. NOTE: intentionally distinct from the AT-SPI
-- adapter's secure_field_detector.SECURE_APP_IDS (exact WM_CLASS match, smaller
-- list e.g. keepassxc). Delegating this substring check to that adapter is
-- deferred: the adapter matches exactly, so delegation would NARROW coverage
-- (dropping gpg/ssh-agent/polkit/sudo and every substring variant) and leak
-- keystrokes — a privacy regression. The broad coverage is locked by the
-- "coverage must never narrow" guard in tests/unit/meta/test_keylogger.lua.
local _DEFAULT_PASSWORD_APPS = {
	"1password", "bitwarden", "keepass", "lastpass",
	"gpg", "ssh-agent", "polkit", "sudo",
}

-- Returns a fresh shallow copy so per-init appends never mutate the base list.
local function _default_password_apps()
	local out = {}
	for i = 1, #_DEFAULT_PASSWORD_APPS do out[i] = _DEFAULT_PASSWORD_APPS[i] end
	return out
end

-- Active list (rebuilt on init when custom apps are supplied).
local _password_apps = _default_password_apps()

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
		_password_apps = _default_password_apps()
		for _, app in ipairs(options.password_apps) do
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
function M.on_keydown(ch, timestamp_ms, app_id)
	if _suppressed then return end

	-- Forward to the base metrics collector if available.
	if Metrics then
		Metrics.on_keydown(ch, timestamp_ms)
	end

	-- Per-app tracking.
	if type(app_id) == "string" and app_id ~= "" then
		M.record_app_key(app_id, ch, timestamp_ms)
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
	if _suppressed then return end

	local app = ensure_app_stats(app_id, timestamp_ms)
	if type(app.last_key_at) == "number" then
		local elapsed = timestamp_ms - app.last_key_at
		if elapsed > 0 then
			app.typing_time_ms = app.typing_time_ms + math.min(elapsed, MAX_TYPING_INTERVAL_MS)
		end
	end
	app.last_key_at = timestamp_ms

	app.keystroke_count = app.keystroke_count + 1
	app.wpm_ring[#app.wpm_ring + 1] = timestamp_ms

	-- Prune ring (keep last WPM_RING_CAPACITY entries).
	while #app.wpm_ring > WPM_RING_CAPACITY do
		table.remove(app.wpm_ring, 1)
	end
end

--- Records a completed static-hotstring expansion for metrics parity.
--- The physical trigger remains part of manual input; the dashboard subtracts
--- hs_input_chars from the generated output to calculate the net gain.
--- @param app_id string Focused application identifier.
--- @param trigger string Typed hotstring trigger.
--- @param replacement string Generated replacement text.
--- @param timestamp_ms number Event timestamp.
function M.record_hotstring(app_id, trigger, replacement, timestamp_ms)
	if _suppressed or type(app_id) ~= "string" or app_id == "" then return end
	if type(replacement) ~= "string" or replacement == "" then return end
	local function char_count(text)
		local ok, count = pcall(utf8.len, text)
		return ok and count or #text
	end
	local app = ensure_app_stats(app_id, timestamp_ms)
	app.hs_chars       = app.hs_chars + char_count(replacement)
	app.hs_triggers    = app.hs_triggers + 1
	app.hs_input_chars = app.hs_input_chars + char_count(type(trigger) == "string" and trigger or "")
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
		}
	end
	return result
end

--- Builds the shared manifest/prefetch contract consumed by both metrics UIs.
--- Linux has no historical aggregate reader yet, but this live projection keeps
--- the dashboards accurate for the current session instead of rendering empty.
--- @return table Metrics prefetch payload matching the macOS/Windows schema.
function M.get_dashboard_payload()
	local date_str = os.date("%Y-%m-%d")
	local day = {}
	for app_id, stats in pairs(M.get_app_stats()) do
		local app_name = dashboard_app_name(app_id)
		day[app_name] = {
			chars       = stats.keystrokes or 0,
			time        = stats.typing_time_ms or 0,
			think_time  = 0,
			app_time_ms = stats.focus_time_ms or 0,
			hs_chars       = stats.hs_chars or 0,
			hs_triggers    = stats.hs_triggers or 0,
			hs_input_chars = stats.hs_input_chars or 0,
			category    = "Unknown",
		}
	end
	return {
		metrics_manifest = { [date_str] = day },
		app_icons        = {},
		_prefetch_data   = { historical = {}, today = {} },
		driver_meta      = { os = "linux", heatmap_id = "kc" },
	}
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
	for _, pattern in ipairs(_password_apps) do
		if lower:find(pattern, 1, true) then return true end
	end
	return false
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
		-- 1. Insert a session summary row into events_typing.
		local apps = M.get_app_stats()
		local total_text = ""
		for app_id, _ in pairs(apps) do
			total_text = total_text .. app_id .. " "
		end
		SqliteWriter.insert_typing_events(_device_id, {
			{
				ts    = now_iso,
				date  = date,
				app   = "ergopti-session",
				text  = string.format("session: %d keystrokes, %d words, %d ms, %.1f WPM",
					stats.keystrokes, stats.words, stats.duration_ms, wpm),
				wpm   = wpm,
				events_json = M.export_json(),
			},
		})

		-- 2. Upsert per-app daily aggregates.
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

		-- 3. Upsert n-grams from the metrics collector.
		local ngrams = M.get_ngrams(100)
		if #ngrams > 0 then
			local combined = {}
			for _, entry in ipairs(ngrams) do
				if entry.gram and entry.count then
					combined[entry.gram] = entry.count
				end
			end
			SqliteWriter.upsert_ngrams(_device_id, date, "ergopti-session", combined)
		end

		-- 4. Bump the revision counter so dashboards know new data exists.
		SqliteWriter.bump_rev()

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

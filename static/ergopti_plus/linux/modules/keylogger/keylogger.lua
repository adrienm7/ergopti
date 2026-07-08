--- modules/keylogger/keylogger.lua

--- ==============================================================================
--- MODULE: Full Keylogger (Linux)
--- DESCRIPTION:
--- Extends metrics_collector with app-level grouping, password-field detection,
--- JSON export, and file-based persistence. Wraps the existing metrics_collector
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
--- 4. File persistence: flush() writes the current session to a JSON log file
---    (~/.config/ergopti/logs/keystrokes_YYYY-MM-DD.json) so data survives
---    daemon restarts.
--- 5. Zero-dependency: pure Lua — JSON export uses string concatenation; file
---    persistence uses io.open. No SQLite or external libs required.
--- ==============================================================================

local M = {}

local Logger   = require("logger.shim")
-- WPM ring cap single-sourced from the shared keylogger metrics module so the
-- per-app rings below never drift from the collector's global ring cap.
local SharedMetrics    = require("keylogger.metrics")
local WPM_RING_CAPACITY = SharedMetrics.DEFAULT_WPM_RING_CAPACITY
-- Metrics collector is optional — keylogger falls back gracefully without it.
local Metrics  = nil
local ok_mc, mc_mod = pcall(require, "modules.keylogger.metrics_collector")
if ok_mc then Metrics = mc_mod end

local LOG = "modules.keylogger.keylogger"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Per-app accumulators: { [appId] = { keystroke_count, wpm_ring, char_window, ngrams } }
local _app_stats = {}

-- Whether password-field suppression is active.
local _suppressed = false

-- Base list of apps considered password fields (case-insensitive substring match
-- on appId). Single source — the init reset below rebuilds from this instead of
-- re-typing the same eight entries. NOTE: intentionally distinct from the AT-SPI
-- adapter's secure_field_detector.SECURE_APP_IDS (exact WM_CLASS match, different
-- list e.g. keepassxc); delegating this substring check to that adapter is a
-- behaviour change deferred to TODO P0-H.2 (needs a security-detection review).
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

-- Base directory for log file persistence.
local _log_dir = nil

-- Session start timestamp for export.
local _session_started_at = nil

-- Forward-declaration: _to_json is defined in section 8 but called from section 6.
local _to_json


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

	-- Set up log directory for persistence.
	local home = os.getenv("HOME") or "~"
	_log_dir = options.log_dir or (home .. "/.config/ergopti/logs")

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

	local app = _app_stats[app_id]
	if not app then
		app = {
			keystroke_count = 0,
			wpm_ring = {},
			char_window = {},
			ngrams = {},
			first_seen = timestamp_ms,
		}
		_app_stats[app_id] = app
	end

	app.keystroke_count = app.keystroke_count + 1
	app.wpm_ring[#app.wpm_ring + 1] = timestamp_ms

	-- Prune ring (keep last WPM_RING_CAPACITY entries).
	while #app.wpm_ring > WPM_RING_CAPACITY do
		table.remove(app.wpm_ring, 1)
	end
end

--- Returns per-app statistics.
--- @return table { [appId] = { keystrokes, first_seen } }
function M.get_app_stats()
	local result = {}
	for app_id, stats in pairs(_app_stats) do
		result[app_id] = {
			keystrokes = stats.keystroke_count,
			first_seen = stats.first_seen,
		}
	end
	return result
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

--- Writes the current session stats to the log file.
--- File: ~/.config/ergopti/logs/keystrokes_YYYY-MM-DD.json
function M.flush()
	if not _log_dir then
		Logger.warn(LOG, "flush(): no log directory configured.")
		return
	end

	-- Ensure the log directory exists.
	os.execute(string.format("mkdir -p '%s' 2>/dev/null", _log_dir:gsub("'", "'\\''")))

	local date = os.date("%Y-%m-%d")
	local path = _log_dir .. "/keystrokes_" .. date .. ".json"

	local fh = io.open(path, "w")
	if not fh then
		Logger.error(LOG, "flush(): cannot write to '%s'.", path)
		return
	end
	fh:write(M.export_json(), "\n")
	fh:close()

	Logger.info(LOG, "Session flushed to %s.", path)
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

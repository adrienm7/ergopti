--- modules/keylogger/log_manager.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager (rewrite)
--- DESCRIPTION:
--- Handles all on-disk persistence for the keylogger. Implements the storage
--- model documented in static/drivers/KEYLOGGER_SPEC.md:
---
---     <config_dir>/metrics/by_device/<device_id>/device.json
---     <config_dir>/metrics/by_device/<device_id>/data.sql       (append-only SQL)
---     <config_dir>/metrics/by_device/<device_id>/today.log      (JSONL hot path)
---     <tmpdir>/ergopti_metrics/<device_id>/db.sqlite             (cache mirror)
---
--- The hot path (every keystroke) only touches `today.log`. A background
--- ingest timer drains the new JSONL lines into `data.sql` (the canonical
--- text source of truth) and the SQLite cache that serves the dashboard.
---
--- FEATURES & RATIONALE:
--- 1. Source of truth on disk is plain SQL text — Git-friendly out of the
---    box, no helper script needed (KEYLOGGER_SPEC §1.6).
--- 2. SQLite cache lives in tmpdir; the user-visible metrics folder only
---    contains data.sql + device.json (KEYLOGGER_SPEC §1.7).
--- 3. Hot path never blocks on SQLite: keystroke handler appends a JSONL
---    line and returns; aggregation happens in the ingest tick.
--- 4. Ingest is crash-safe — INSERT OR IGNORE statements wrapped in a
---    transaction make replay idempotent (KEYLOGGER_SPEC §15.2).
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.sqlite3, hs.fs, hs.timer.
--- - Canonical SQLite schema at <metrics_dir>/../../_shared/schema/schema.sql.
---
--- SCOPE OF THIS REWRITE:
--- The full legacy aggregation pipeline (n-grams, bursts, sessions, ergonomic
--- streaks) is intentionally NOT yet ported. This iteration covers raw event
--- persistence + simple `agg_app_day` counters (chars / time_ms /
--- think_time_ms / app_time_ms / category). Subsequent sessions port the
--- richer aggregations on top of the same plumbing.
--- ==============================================================================

local M = {}

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local timer   = require("hs.timer")
local utf8    = utf8

local Logger = require("lib.logger")
local LOG    = "keylogger.log_manager"




-- ===============================
-- ===============================
-- ======= 1/ Constants =======
-- ===============================
-- ===============================

--- Background ingest tick period (KEYLOGGER_SPEC §4).
local INGEST_TICK_SEC = 5

--- Maximum number of legacy-log lines processed in a single ingest cycle.
local INGEST_BATCH_LINES = 5000

--- Threshold separating "active typing" from "thinking pauses" — matches
--- the historical THINK_PAUSE_THRESHOLD_MS (KEYLOGGER_SPEC §4).
local THINK_PAUSE_THRESHOLD_MS = 2000

--- Cap on the per-event delay credited to time/credited buckets. Outliers
--- (system pauses, lock screen) would otherwise distort speed metrics.
local WPM_MAX_EVENT_DELAY_MS = 5000

--- macOS app category translations. Used by `M.get_native_app_category`
--- to populate `agg_app_day.category`. Kept minimal; the AHK port will
--- ship its own equivalent table for Windows process names.
local MAC_CATEGORIES_FR = {
	["Productivity"]      = "Productivité",
	["Social networking"] = "Réseaux sociaux",
	["Games"]             = "Jeux",
	["Entertainment"]     = "Divertissement",
	["Utilities"]         = "Utilitaires",
	["Education"]         = "Éducation",
	["Finance"]           = "Finance",
	["Business"]          = "Business",
	["Graphics design"]   = "Design graphique",
	["Photography"]       = "Photographie",
	["Video"]             = "Vidéo",
	["Music"]             = "Musique",
	["Medical"]           = "Médical",
	["Health fitness"]    = "Santé & Forme",
	["Lifestyle"]         = "Style de vie",
	["News"]              = "Actualités",
	["Weather"]           = "Météo",
	["Sports"]            = "Sport",
	["Travel"]            = "Voyage",
	["Navigation"]        = "Navigation",
	["Reference"]         = "Références",
	["Developer tools"]   = "Développement",
}




-- ===============================
-- ===============================
-- ======= 2/ Module State =======
-- ===============================
-- ===============================

--- Shared CoreState (set by M.init).
local _state = nil

--- Device identity, read from / written to device.json.
local _device_id  = nil
local _device_obj = nil

--- Resolved paths (filled by `_resolve_paths`).
local _paths = {}

--- Open SQLite handle (created by `_open_db`).
local _db = nil

--- Background ingest timer.
local _ingest_timer = nil

--- Per-device sequential id counter, persisted as `meta.next_event_id`.
local _next_event_id = 1

--- Watermark of the today.log file consumed so far by the ingest tick.
--- Persisted as `meta.today_log_offset` so a crash mid-ingest does not
--- duplicate entries on the next boot.
local _today_log_offset = 0
local _today_log_date   = nil

--- Whether `_uuid_v4` has seeded math.randomseed.
local _uuid_seeded = false




-- ============================================
-- ============================================
-- ======= 3/ Private Helpers =======
-- ============================================
-- ============================================

--- Guards every public function against being called before M.init().
local function _require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" timestamp string (local time).
local function _now_ts()
	return string.format("%s.%03d",
		os.date("%Y-%m-%d %H:%M:%S"),
		math.floor(hs.timer.absoluteTime() / 1000000) % 1000)
end

--- Returns today's "YYYY-MM-DD" string.
local function _today()
	return os.date("%Y-%m-%d")
end

--- mkdir -p equivalent.
local function _mkdir_p(path)
	pcall(hs.execute, string.format("mkdir -p %q", path))
end

--- Generates a UUID v4 (RFC 4122). Bitwise ops require Lua 5.3+, which
--- Hammerspoon ships with.
local function _uuid_v4()
	if not _uuid_seeded then
		math.randomseed(math.floor(hs.timer.absoluteTime() / 1000))
		for _ = 1, 5 do math.random() end
		_uuid_seeded = true
	end
	local b = {}
	for i = 1, 16 do b[i] = math.random(0, 255) end
	b[7] = (b[7] & 0x0F) | 0x40
	b[9] = (b[9] & 0x3F) | 0x80
	return string.format(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8],
		b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16])
end

--- Returns the macOS hardware UUID. Used as `device.host_signature` for
--- the fork-on-clone detection (KEYLOGGER_SPEC §16.1).
local function _host_signature()
	local cmd = "ioreg -d2 -c IOPlatformExpertDevice "
		.. "| grep IOPlatformUUID | awk -F\\\" '{print $4}'"
	local ok, out = pcall(hs.execute, cmd)
	if ok and type(out) == "string" then
		out = out:gsub("[%s\n\r]+", "")
		if #out >= 8 then return out end
	end
	local host = (hs.host and hs.host.localizedName and hs.host.localizedName()) or "unknown"
	return "fallback:" .. host
end




-- =====================================
-- =====================================
-- ======= 4/ Path Resolution =======
-- =====================================
-- =====================================

--- Resolve <tmpdir>/ — macOS sets TMPDIR per-user; fall back to /tmp/.
local function _resolve_tmpdir()
	local t = os.getenv("TMPDIR")
	if type(t) == "string" and t ~= "" then
		if not t:match("[/\\]$") then t = t .. "/" end
		return t
	end
	return "/tmp/"
end

--- Compute every path the log manager touches once `device_id` is known.
--- @param metrics_dir string The metrics root (CoreState.LOG_DIR).
--- @param device_id   string The current device's UUID.
local function _resolve_paths(metrics_dir, device_id)
	local md = metrics_dir
	if not md:match("[/\\]$") then md = md .. "/" end

	local by_dev = md .. "by_device/" .. device_id .. "/"
	local tmp_dir = _resolve_tmpdir() .. "ergopti_metrics/" .. device_id .. "/"

	-- The canonical schema lives outside the hammerspoon driver, in the
	-- repo's _shared/schema/. metrics_dir is <hammerspoon>/metrics, so we
	-- go two levels up to reach <repo>/static/drivers/ then into _shared.
	local config_dir = md:gsub("[/\\]?metrics[/\\]?$", "")
	if not config_dir:match("[/\\]$") then config_dir = config_dir .. "/" end
	local schema_path = config_dir .. "../_shared/schema/schema.sql"

	_paths = {
		metrics_dir       = md,
		by_device_dir     = by_dev,
		device_json_path  = by_dev .. "device.json",
		data_sql_path     = by_dev .. "data.sql",
		today_log_path    = by_dev .. "today.log",
		gitignore_path    = md .. ".gitignore",
		tmpdir_dir        = tmp_dir,
		sqlite_path       = tmp_dir .. "db.sqlite",
		schema_sql_path   = schema_path,
	}
end

--- Write the user-facing .gitignore at the metrics root if missing.
local function _ensure_gitignore()
	if fs.attributes(_paths.gitignore_path) then return end
	local f = io.open(_paths.gitignore_path, "w")
	if not f then return end
	f:write("# Local hot-path log — never commit, never sync.\n")
	f:write("# One writer per device; another machine appending here would\n")
	f:write("# corrupt the file. Ingested into data.sql by the keylogger.\n")
	f:write("today.log\n")
	f:close()
end




-- ============================================
-- ============================================
-- ======= 5/ Device Identity =======
-- ============================================
-- ============================================

--- Loads `device.json` for the current host. If the existing folder under
--- by_device/ has a host_signature matching this machine, we reuse its
--- device_id; otherwise (fresh install or clone-from-other-device) we
--- generate a new UUID. KEYLOGGER_SPEC §16.1.
--- @param metrics_dir string The metrics root.
--- @return table The fully populated device object.
local function _resolve_device(metrics_dir)
	local md = metrics_dir
	if not md:match("[/\\]$") then md = md .. "/" end
	local by_root = md .. "by_device/"
	_mkdir_p(by_root)

	local current_host = _host_signature()
	for entry in fs.dir(by_root) do
		if entry ~= "." and entry ~= ".." then
			local djpath = by_root .. entry .. "/device.json"
			local fh = io.open(djpath, "r")
			if fh then
				local raw = fh:read("*a"); fh:close()
				local ok, obj = pcall(json.decode, raw)
				if ok and type(obj) == "table"
					and type(obj.device_id) == "string"
					and obj.host_signature == current_host then
					return obj
				end
			end
		end
	end

	return {
		device_id      = _uuid_v4(),
		name           = (hs.host and hs.host.localizedName and hs.host.localizedName()) or "Mac",
		os             = "darwin",
		os_version     = (hs.host and hs.host.operatingSystemVersionString and hs.host.operatingSystemVersionString()) or "",
		host_signature = current_host,
		created_at     = _now_ts(),
		schema_version = 1,
	}
end

--- Atomically write the device object back to disk.
local function _write_device_json(obj)
	local tmp = _paths.device_json_path .. ".tmp"
	local f, err = io.open(tmp, "w")
	if not f then
		Logger.error(LOG, "Cannot write %s: %s.", tmp, tostring(err))
		return false
	end
	f:write(json.encode(obj)); f:close()
	os.rename(tmp, _paths.device_json_path)
	return true
end




-- ===============================
-- ===============================
-- ======= 6/ SQLite Open =======
-- ===============================
-- ===============================

--- Read the canonical schema.sql.
local function _read_schema_sql()
	local fh, err = io.open(_paths.schema_sql_path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open schema.sql at %s: %s.",
			_paths.schema_sql_path, tostring(err))
		return nil
	end
	local body = fh:read("*a"); fh:close()
	return body
end

--- Open db.sqlite in tmpdir, applying the schema when the file is fresh.
--- Restores the persisted offsets / counters.
--- @return boolean True on success, false on unrecoverable error.
local function _open_db()
	local existed = fs.attributes(_paths.sqlite_path) ~= nil
	local db, err = sqlite3.open(_paths.sqlite_path)
	if not db then
		Logger.error(LOG, "Cannot open SQLite at %s: %s.",
			_paths.sqlite_path, tostring(err))
		return false
	end

	db:exec("PRAGMA journal_mode = DELETE;")
	db:exec("PRAGMA synchronous = FULL;")
	db:exec("PRAGMA encoding = \"UTF-8\";")

	if not existed then
		Logger.start(LOG, "Bootstrapping fresh db.sqlite at %s…", _paths.sqlite_path)
		local schema = _read_schema_sql()
		if not schema then
			db:close()
			return false
		end
		local rc = db:exec(schema)
		if rc ~= sqlite3.OK then
			Logger.error(LOG, "Schema apply failed: %s.", db:errmsg())
			db:close()
			return false
		end
		Logger.success(LOG, "Schema applied (version 1).")
	end

	_db = db

	-- Keys we track ourselves (atop the schema-bootstrapped meta keys).
	for _, kv in ipairs({
		{ "next_event_id",     "1" },
		{ "today_log_offset",  "0" },
		{ "today_log_date",    "" },
	}) do
		_db:exec(string.format(
			"INSERT OR IGNORE INTO meta (key, value) VALUES ('%s', '%s');",
			kv[1], kv[2]))
	end

	-- Restore counters.
	for r in _db:nrows("SELECT value FROM meta WHERE key='next_event_id'") do
		_next_event_id = tonumber(r.value) or 1
	end
	for r in _db:nrows("SELECT value FROM meta WHERE key='today_log_offset'") do
		_today_log_offset = tonumber(r.value) or 0
	end
	for r in _db:nrows("SELECT value FROM meta WHERE key='today_log_date'") do
		_today_log_date = (type(r.value) == "string" and r.value ~= "") and r.value or nil
	end

	-- Make sure the device row is up to date (host signature might have
	-- been updated, name renamed via UI, etc.).
	local stmt = _db:prepare(
		"INSERT OR REPLACE INTO devices "
		.. "(device_id, name, os, os_version, host_signature, created_at, updated_at) "
		.. "VALUES (?, ?, ?, ?, ?, ?, ?)")
	if stmt then
		stmt:bind_values(
			_device_obj.device_id, _device_obj.name, _device_obj.os,
			_device_obj.os_version or "", _device_obj.host_signature,
			_device_obj.created_at, _now_ts())
		stmt:step(); stmt:finalize()
	end

	return true
end




-- =====================================
-- =====================================
-- ======= 7/ SQL Builders =======
-- =====================================
-- =====================================

--- Escape a Lua string for a SQL single-quoted literal. nil → SQL NULL.
local function _sql_str(s)
	if s == nil then return "NULL" end
	if type(s) ~= "string" then s = tostring(s) end
	return "'" .. s:gsub("'", "''") .. "'"
end

--- Format a numeric / boolean for SQL.
local function _sql_num(n)
	if n == nil then return "NULL" end
	if type(n) == "boolean" then return n and "1" or "0" end
	return tostring(n)
end

--- JSON-encode a Lua value compactly. nil → '{}'.
local function _sql_json(v)
	if v == nil then return "'{}'" end
	local ok, encoded = pcall(json.encode, v)
	if not ok then return "'{}'" end
	return _sql_str(encoded)
end

--- Allocate the next event id (per-device autoincrement).
local function _alloc_event_id()
	local id = _next_event_id
	_next_event_id = _next_event_id + 1
	return id
end

local _builders = {}

function _builders.typing(e, id)
	return string.format(
		"INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, title, url, field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json) VALUES (%s, %d, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.app or "Unknown"), _sql_str(e.title), _sql_str(e.url),
		_sql_str(e.field_role), _sql_str(e.layout), _sql_str(e.document_path),
		_sql_num(e.is_fullscreen), _sql_num(e.in_meeting),
		_sql_num(e.mouse_clicks or 0), _sql_num(e.mouse_scrolls or 0),
		_sql_num(e.mouse_distance_px or 0), _sql_num(e.pause_before_ms),
		_sql_num(e.battery_level), _sql_num(e.audio_volume), _sql_num(e.wpm),
		_sql_str(e.text or ""), _sql_str(e.rich_text), _sql_json(e.events))
end

function _builders.app_switch(e, id)
	return string.format(
		"INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES (%s, %d, %s, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.prev_app), _sql_str(e.next_app), _sql_num(e.duration_ms or 0))
end

function _builders.window_switch(e, id)
	return string.format(
		"INSERT OR IGNORE INTO events_window_switch (device_id, id, ts, date, app, prev_title, next_title, duration_ms) VALUES (%s, %d, %s, %s, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.app), _sql_str(e.prev_title), _sql_str(e.next_title),
		_sql_num(e.duration_ms or 0))
end

function _builders.shortcut(e, id)
	return string.format(
		"INSERT OR IGNORE INTO events_shortcut (device_id, id, ts, date, app, key) VALUES (%s, %d, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.app), _sql_str(e.key))
end

function _builders.system(e, id)
	local meta = {}
	for k, v in pairs(e) do
		if k ~= "type" and k ~= "timestamp" and k ~= "action" then
			meta[k] = v
		end
	end
	return string.format(
		"INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES (%s, %d, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.action), _sql_json(meta))
end

function _builders.hotstring(e, id, kind)
	return string.format(
		"INSERT OR IGNORE INTO events_hotstring (device_id, id, ts, date, app, kind, trigger, replacement, h_type, net_saved_chars) VALUES (%s, %d, %s, %s, %s, %s, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.app or "Unknown"), _sql_str(kind),
		_sql_str(e.trigger or ""), _sql_str(e.replacement or ""),
		_sql_str(e.h_type), _sql_num(e.net_saved_chars))
end

function _builders.llm(e, id, kind)
	return string.format(
		"INSERT OR IGNORE INTO events_llm (device_id, id, ts, date, app, kind, context, predictions_json, prediction, all_predictions_json, chosen_index, deletes, deleted_text, net_saved_chars, count) VALUES (%s, %d, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(e.app or "Unknown"), _sql_str(kind),
		_sql_str(e.context),
		(e.predictions and _sql_json(e.predictions) or "NULL"),
		_sql_str(e.prediction),
		(e.all_predictions and _sql_json(e.all_predictions) or "NULL"),
		_sql_num(e.chosen_index), _sql_num(e.deletes),
		_sql_str(e.deleted_text), _sql_num(e.net_saved_chars), _sql_num(e.count))
end

function _builders.session(e, id, kind)
	return string.format(
		"INSERT OR IGNORE INTO events_session (device_id, id, ts, date, kind, duration_ms) VALUES (%s, %d, %s, %s, %s, %s);",
		_sql_str(_device_id), id,
		_sql_str(e.timestamp), _sql_str(e.timestamp:sub(1, 10)),
		_sql_str(kind), _sql_num(e.duration_ms))
end

--- Translate a JSONL entry into 0+ INSERT statements (typed dispatch).
--- Returns the array of SQL strings (each ends with ';'). Unknown event
--- types are silently skipped — they will reappear next ingest if a
--- future schema knows how to handle them.
local function _build_inserts(entry)
	local t = entry.type
	if t == "typing" then
		return { _builders.typing(entry, _alloc_event_id()) }
	elseif t == "app_switch" then
		return { _builders.app_switch(entry, _alloc_event_id()) }
	elseif t == "window_switch" then
		return { _builders.window_switch(entry, _alloc_event_id()) }
	elseif t == "shortcut" then
		return { _builders.shortcut(entry, _alloc_event_id()) }
	elseif t == "system_event" then
		return { _builders.system(entry, _alloc_event_id()) }
	elseif t == "hotstring" then
		return { _builders.hotstring(entry, _alloc_event_id(), "fired") }
	elseif t == "hotstring_suggested" then
		return { _builders.hotstring(entry, _alloc_event_id(), "suggested") }
	elseif t == "hotstring_dismissed" then
		return { _builders.hotstring(entry, _alloc_event_id(), "dismissed") }
	elseif t == "llm_generation" then
		return { _builders.llm(entry, _alloc_event_id(), "generation") }
	elseif t == "llm_suggested" then
		return { _builders.llm(entry, _alloc_event_id(), "suggested") }
	elseif t == "llm_dismissed" then
		return { _builders.llm(entry, _alloc_event_id(), "dismissed") }
	elseif t == "llm_accepted" then
		return { _builders.llm(entry, _alloc_event_id(), "accepted") }
	elseif t == "session_start" then
		return { _builders.session(entry, _alloc_event_id(), "session_start") }
	elseif t == "session_end" then
		return { _builders.session(entry, _alloc_event_id(), "session_end") }
	elseif t == "idle_start" then
		return { _builders.session(entry, _alloc_event_id(), "idle_start") }
	elseif t == "idle_end" then
		return { _builders.session(entry, _alloc_event_id(), "idle_end") }
	end
	return {}
end




-- ============================================
-- ============================================
-- ======= 8/ Aggregate Updates =======
-- ============================================
-- ============================================

--- Update agg_app_day with a typing entry's coarse stats. Only the simple
--- counters are populated in this iteration; n-grams / bursts / sessions
--- / streaks are deferred to the next session.
local function _update_agg_typing(entry)
	if not _db then return end
	local app = entry.app or "Unknown"
	local date_str = entry.timestamp:sub(1, 10)

	local chars, time_ms, think_time_ms, pauses = 0, 0, 0, 0
	if type(entry.events) == "table" then
		for _, ev in ipairs(entry.events) do
			local meta = ev[3] or {}
			local ch   = ev[1]
			local d    = ev[2] or 0
			if not meta.s and type(ch) == "string"
				and not (ch:sub(1, 1) == "[" and ch:sub(-1) == "]") then
				chars = chars + 1
				if d > THINK_PAUSE_THRESHOLD_MS then
					think_time_ms = think_time_ms + d
					pauses = pauses + 1
				else
					if d > WPM_MAX_EVENT_DELAY_MS then d = WPM_MAX_EVENT_DELAY_MS end
					time_ms = time_ms + d
				end
			end
		end
	end

	local stmt = _db:prepare([[
		INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, category)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_id, date, app) DO UPDATE SET
			chars = chars + excluded.chars,
			pauses = pauses + excluded.pauses,
			time_ms = time_ms + excluded.time_ms,
			think_time_ms = think_time_ms + excluded.think_time_ms,
			category = COALESCE(agg_app_day.category, excluded.category)
	]])
	if stmt then
		stmt:bind_values(_device_id, date_str, app,
			chars, pauses, time_ms, think_time_ms,
			M.get_native_app_category(app))
		stmt:step(); stmt:finalize()
	end
end

--- Update agg_app_day.app_time_ms when an app loses focus.
local function _update_agg_app_time(entry)
	if not _db or not entry.prev_app then return end
	local date_str = entry.timestamp:sub(1, 10)
	local stmt = _db:prepare([[
		INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(device_id, date, app) DO UPDATE SET
			app_time_ms = app_time_ms + excluded.app_time_ms,
			category = COALESCE(agg_app_day.category, excluded.category)
	]])
	if stmt then
		stmt:bind_values(_device_id, date_str, entry.prev_app,
			entry.duration_ms or 0, M.get_native_app_category(entry.prev_app))
		stmt:step(); stmt:finalize()
	end
end




-- =================================================
-- =================================================
-- ======= 9/ today.log writer (hot path) =======
-- =================================================
-- =================================================

--- Append a single event entry to today.log as a JSONL line. Hot path:
--- every keystroke ends up here. Never touches SQLite.
--- @param entry table The event entry. Must contain a `type` field.
function M.append_log(entry)
	if not _require_state("append_log") then return end
	if type(entry) ~= "table" or type(entry.type) ~= "string" then
		Logger.warn(LOG, "append_log: invalid entry — skipping.")
		return
	end
	entry.timestamp = entry.timestamp or _now_ts()

	local ok, str = pcall(json.encode, entry)
	if not ok then
		Logger.error(LOG, "JSON encode failed for type '%s': %s.",
			tostring(entry.type), tostring(str))
		return
	end
	str = str:gsub("\n", "")

	local f, err = io.open(_paths.today_log_path, "a")
	if not f then
		Logger.error(LOG, "Cannot append to today.log at %s: %s.",
			_paths.today_log_path, tostring(err))
		return
	end
	f:write(str .. "\n"); f:close()
end




-- ===========================================
-- ===========================================
-- ======= 10/ flush_buffer (typing) =======
-- ===========================================
-- ===========================================

--- Serialize the keystroke buffer accumulated in CoreState into a
--- typing event and append it to today.log. Resets the per-flush
--- buffers afterwards. Mirrors the legacy behaviour at the entry-point
--- level so init.lua / shortcuts / etc. keep working unchanged.
function M.flush_buffer()
	if not _require_state("flush_buffer") then return end
	if #_state.buffer_events == 0
		and _state.session_mouse_clicks == 0
		and _state.session_mouse_scrolls == 0 then
		return
	end

	local total_time_ms, total_chars = 0, 0
	for _, ev in ipairs(_state.buffer_events) do
		local meta = ev[3] or {}
		if not meta.s then
			local d = math.min(ev[2] or 0, WPM_MAX_EVENT_DELAY_MS)
			total_time_ms = total_time_ms + d
			total_chars   = total_chars + 1
		end
	end
	local wpm = total_time_ms > 0 and ((total_chars / 5) / (total_time_ms / 60000)) or 0

	-- Build a rich-text representation (text + correction/autocomplete
	-- markup) from rich_chunks. Same shape as the legacy implementation.
	local rich_str, cur_type, cur_text = "", nil, ""
	local function flush_chunk()
		if not cur_type then return end
		if cur_type == "text" then
			rich_str = rich_str .. cur_text
		elseif cur_type == "correction" then
			rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
		else
			rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>"
		end
	end
	for _, chunk in ipairs(_state.rich_chunks or {}) do
		if chunk.type == cur_type then
			cur_text = cur_text .. chunk.text
		else
			flush_chunk()
			cur_type = chunk.type; cur_text = chunk.text
		end
	end
	flush_chunk()

	M.append_log({
		type              = "typing",
		text              = _state.buffer_text,
		rich_text         = rich_str,
		app               = _state.session_app_name,
		title             = _state.session_win_title,
		url               = _state.session_url,
		field_role        = _state.session_field_role,
		layout            = _state.session_layout,
		document_path     = _state.session_document_path,
		is_fullscreen     = _state.is_fullscreen,
		in_meeting        = _state.in_meeting,
		mouse_clicks      = _state.session_mouse_clicks,
		mouse_scrolls     = _state.session_mouse_scrolls,
		mouse_distance_px = math.floor(_state.mouse_distance_px or 0),
		pause_before_ms   = _state.current_session_pause,
		battery_level     = _state.current_battery_level,
		audio_volume      = _state.current_audio_volume,
		wpm               = tonumber(string.format("%.1f", wpm)),
		events            = _state.buffer_events,
	})

	_state.buffer_events         = {}
	_state.buffer_text           = ""
	_state.rich_chunks           = {}
	_state.last_time             = 0
	_state.pending_keyup         = {}
	_state.session_mouse_clicks  = 0
	_state.session_mouse_scrolls = 0
	_state.mouse_distance_px     = 0
	_state.last_flush_time       = hs.timer.absoluteTime() / 1000000
end




-- ============================================================
-- ============================================================
-- ======= 11/ Public log_* event entry points =======
-- ============================================================
-- ============================================================

function M.log_app_switch(prev_app, next_app, duration_ms)
	if not _require_state("log_app_switch") then return end
	M.append_log({
		type        = "app_switch",
		prev_app    = prev_app,
		next_app    = next_app,
		duration_ms = duration_ms,
	})
end

function M.log_system_event(event_type, metadata)
	if not _require_state("log_system_event") then return end
	local entry = { type = "system_event", action = event_type }
	if type(metadata) == "table" then
		for k, v in pairs(metadata) do entry[k] = v end
	end
	M.append_log(entry)
end

function M.log_shortcut(shortcut_key, app_name)
	if not _require_state("log_shortcut") then return end
	if type(shortcut_key) ~= "string" or shortcut_key == "" then return end
	M.append_log({
		type = "shortcut",
		key  = shortcut_key,
		app  = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown",
	})
end

function M.log_modifier_press(keycode, app_name)
	if not _require_state("log_modifier_press") then return end
	M.append_log({
		type    = "system_event",
		action  = "modifier_press",
		keycode = keycode,
		app     = app_name,
	})
end

function M.log_modifier_hold(keycode, app_name, hold_ms)
	if not _require_state("log_modifier_hold") then return end
	M.append_log({
		type     = "system_event",
		action   = "modifier_hold",
		keycode  = keycode,
		app      = app_name,
		hold_ms  = hold_ms,
	})
end

function M.log_karabiner_press(keycode, app_name)
	if not _require_state("log_karabiner_press") then return end
	M.append_log({
		type    = "system_event",
		action  = "karabiner_press",
		keycode = keycode,
		app     = app_name,
	})
end

function M.log_karabiner_release(keycode, app_name, hold_ms)
	if not _require_state("log_karabiner_release") then return end
	M.append_log({
		type    = "system_event",
		action  = "karabiner_release",
		keycode = keycode,
		app     = app_name,
		hold_ms = hold_ms,
	})
end

function M.log_passive_period(kind, duration_ms)
	if not _require_state("log_passive_period") then return end
	M.append_log({
		type        = "system_event",
		action      = "passive_period",
		kind        = kind,
		duration_ms = duration_ms,
	})
end

function M.tag_awake_focus(app_name, duration_ms)
	if not _require_state("tag_awake_focus") then return end
	M.append_log({
		type        = "system_event",
		action      = "awake_focus",
		app         = app_name,
		duration_ms = duration_ms,
	})
end

function M.log_focus_first_key(app_name, latency_ms)
	if not _require_state("log_focus_first_key") then return end
	M.append_log({
		type       = "system_event",
		action     = "focus_first_key",
		app        = app_name,
		latency_ms = latency_ms,
	})
end

--- Legacy entry point preserved so init.lua's `LogManager.increment_manifest_stat`
--- calls remain valid. The new format aggregates from the `events_*` tables
--- via SQLite; we just emit a logical record so the data is captured.
function M.increment_manifest_stat(app_name, stat_key, amount)
	if not _require_state("increment_manifest_stat") then return end
	M.append_log({
		type   = "system_event",
		action = "manifest_increment",
		app    = app_name,
		stat   = stat_key,
		amount = tonumber(amount) or 1,
	})
end




-- ============================================
-- ============================================
-- ======= 12/ Miscellaneous Helpers =======
-- ============================================
-- ============================================

--- Return the human-readable category for an app, looked up via macOS
--- LSApplicationCategoryType. Falls back to "Général" when the app is
--- not running or not categorized.
function M.get_native_app_category(app_name)
	if type(app_name) ~= "string" or app_name == "" then return "Général" end
	local app = hs.application.get(app_name)
	if app then
		local info = hs.application.infoForBundlePath(app:path())
		if info and info.LSApplicationCategoryType then
			local raw = info.LSApplicationCategoryType:gsub("public%.app%-category%.", "")
			raw = raw:gsub("%-", " ")
			local cap = raw:sub(1, 1):upper() .. raw:sub(2)
			return MAC_CATEGORIES_FR[cap] or cap
		end
	end
	return "Général"
end

--- Returns a stable identifier for the current device, kept here so menu
--- modules can derive display names without reading device.json directly.
--- @return string The 8-char prefix of the device UUID, plus an ellipsis.
function M.get_device_short_id()
	if not _device_id then return "" end
	return _device_id:sub(1, 8) .. "…"
end




-- ===============================
-- ===============================
-- ======= 13/ Ingest Tick =======
-- ===============================
-- ===============================

--- Read newly appended bytes of today.log past `_today_log_offset` and
--- return them as a list of { entry, raw } items, plus the post-read
--- offset. Stops after `INGEST_BATCH_LINES` entries to keep each tick
--- short.
local function _read_new_today_log()
	-- Day rollover: the offset from yesterday is meaningless; the legacy
	-- file is renamed (or deleted) at midnight by the caller of M.day_rollover.
	local today = _today()
	if _today_log_date and _today_log_date ~= today then
		Logger.info(LOG, "Day rollover detected (%s -> %s); resetting tail offset.",
			_today_log_date, today)
		_today_log_date = today
		_today_log_offset = 0
	end
	if not _today_log_date then _today_log_date = today end

	local attrs = fs.attributes(_paths.today_log_path)
	if not attrs then return {} end
	local size = attrs.size or 0
	if size <= _today_log_offset then return {} end

	local fh, err = io.open(_paths.today_log_path, "r")
	if not fh then
		Logger.warn(LOG, "Cannot open today.log %s: %s.",
			_paths.today_log_path, tostring(err))
		return {}
	end
	fh:seek("set", _today_log_offset)
	local out, lines = {}, 0
	while lines < INGEST_BATCH_LINES do
		local line = fh:read("*l")
		if not line then break end
		local ok, entry = pcall(json.decode, line)
		if ok and type(entry) == "table" and type(entry.type) == "string" then
			table.insert(out, { entry = entry, raw = line })
		end
		lines = lines + 1
	end
	local new_offset = fh:seek("cur")
	fh:close()
	return out, new_offset
end

--- Run one ingest cycle: pull new today.log entries, append the SQL
--- batch to data.sql, apply it to db.sqlite, update aggregate tables.
function M.ingest_once()
	if not _db then return end
	local entries, new_offset = _read_new_today_log()
	if #entries == 0 then return end

	-- Build the SQL once, then write to data.sql AND apply to sqlite.
	-- Builders allocate event ids as a side-effect; we capture the
	-- result so both sinks see identical statements.
	local statements = {}
	for _, item in ipairs(entries) do
		for _, sql in ipairs(_build_inserts(item.entry)) do
			table.insert(statements, sql)
		end
	end
	if #statements == 0 then
		_today_log_offset = new_offset
		return
	end

	local batch_text = string.format(
		"\n-- === ingest batch %s (offset %d -> %d, %d entry(ies)) ===\nBEGIN TRANSACTION;\n%s\nCOMMIT;\n",
		_now_ts(), _today_log_offset, new_offset, #entries,
		table.concat(statements, "\n"))

	local f, err = io.open(_paths.data_sql_path, "a")
	if not f then
		Logger.error(LOG, "Cannot append to data.sql at %s: %s.",
			_paths.data_sql_path, tostring(err))
		return
	end
	f:write(batch_text); f:close()

	local ok, exec_err = pcall(function()
		_db:exec("BEGIN TRANSACTION;")
		for _, sql in ipairs(statements) do
			local rc = _db:exec(sql)
			if rc ~= sqlite3.OK then
				error("exec failed: " .. (_db:errmsg() or "?"))
			end
		end
		for _, item in ipairs(entries) do
			if item.entry.type == "typing" then
				_update_agg_typing(item.entry)
			elseif item.entry.type == "app_switch" then
				_update_agg_app_time(item.entry)
			end
		end
		_db:exec(string.format(
			"UPDATE meta SET value='%d' WHERE key='today_log_offset';", new_offset))
		_db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", _today_log_date or ""))
		_db:exec(string.format(
			"UPDATE meta SET value='%d' WHERE key='next_event_id';", _next_event_id))
		_db:exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';")
		_db:exec("COMMIT;")
	end)
	if not ok then
		Logger.error(LOG, "Ingest batch rolled back: %s.", tostring(exec_err))
		pcall(function() _db:exec("ROLLBACK;") end)
		return
	end

	_today_log_offset = new_offset
	Logger.debug(LOG, "Ingest cycle: %d entry(ies), offset now %d.",
		#entries, new_offset)
end

--- Day rollover handler. Drains the remaining today.log into the new format,
--- then deletes today.log so it starts fresh tomorrow.
function M.day_rollover()
	if not _require_state("day_rollover") then return end
	pcall(M.ingest_once)
	-- Append a marker comment to data.sql so the file's history reads
	-- well day-by-day.
	local f = io.open(_paths.data_sql_path, "a")
	if f then
		f:write(string.format("\n-- === day rollover %s -> %s ===\n",
			_today_log_date or "", _today()))
		f:close()
	end
	pcall(os.remove, _paths.today_log_path)
	_today_log_offset = 0
	_today_log_date   = _today()
	if _db then
		_db:exec("UPDATE meta SET value='0' WHERE key='today_log_offset';")
		_db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", _today_log_date))
	end
end




-- ====================================
-- ====================================
-- ======= 14/ Lifecycle =======
-- ====================================
-- ====================================

--- Initialize the log manager. Resolves the device, opens the SQLite cache,
--- creates filesystem layout. Idempotent; calling twice is a warning.
--- @param core_state table The shared CoreState from modules/keylogger/init.lua.
function M.init(core_state)
	if _state then
		Logger.warn(LOG, "M.init() called twice — ignoring duplicate.")
		return
	end
	if type(core_state) ~= "table" or type(core_state.LOG_DIR) ~= "string" then
		Logger.error(LOG, "M.init(): invalid core_state — log manager non-functional.")
		return
	end
	_state = core_state

	Logger.start(LOG, "Initializing log manager…")

	-- Resolve device and paths.
	_device_obj = _resolve_device(_state.LOG_DIR)
	_device_id  = _device_obj.device_id
	_resolve_paths(_state.LOG_DIR, _device_id)

	-- Filesystem bootstrap.
	_mkdir_p(_paths.metrics_dir)
	_mkdir_p(_paths.by_device_dir)
	_mkdir_p(_paths.tmpdir_dir)
	_ensure_gitignore()

	-- Persist device.json (idempotent — writes back the resolved/new object).
	_write_device_json(_device_obj)

	-- Open or create the SQLite cache.
	if not _open_db() then
		Logger.error(LOG, "Cannot open db.sqlite — log manager will only write JSONL.")
	end

	-- Bootstrap data.sql header on first run.
	if not fs.attributes(_paths.data_sql_path) then
		local f, err = io.open(_paths.data_sql_path, "w")
		if f then
			f:write(string.format(
				"-- ergopti metrics — device %s — schema_version 1\n"
				.. "-- This file is APPEND-ONLY. Do not edit by hand.\n"
				.. "-- The keylogger replays its content into db.sqlite at startup.\n"
				.. "PRAGMA foreign_keys = OFF;\n",
				_device_id))
			f:close()
		else
			Logger.error(LOG, "Cannot create data.sql at %s: %s.",
				_paths.data_sql_path, tostring(err))
		end
	end

	-- Mirror the keylogger CoreState fields the LLM bridge reads from.
	-- The richer aggregation pipeline (n-grams etc.) is deferred — the
	-- LLM falls back to its remote prediction path when the local
	-- bigram cache is empty.
	_state.today_idx = _state.today_idx or {}
	_state.manifest  = _state.manifest  or {}

	-- Start the background ingest tick.
	if not _ingest_timer then
		pcall(M.ingest_once)
		_ingest_timer = timer.new(INGEST_TICK_SEC, function()
			pcall(M.ingest_once)
		end)
		_ingest_timer:start()
	end

	Logger.success(LOG, "Log manager initialized (device %s, name %s).",
		_device_id:sub(1, 8) .. "…", _device_obj.name)
end

--- Stop the ingest timer and close the SQLite cache cleanly.
function M.stop()
	if _ingest_timer then _ingest_timer:stop(); _ingest_timer = nil end
	pcall(M.ingest_once)
	if _db then
		pcall(function() _db:close() end)
		_db = nil
	end
	Logger.debug(LOG, "Log manager stopped.")
end




-- ============================================================
-- ============================================================
-- ======= 15/ Compatibility shims for the in-flight UI =======
-- ============================================================
-- ============================================================

--- The legacy UI references several helpers that have no equivalent in
--- the new model (encryption, raw-log replay, manifest snapshots). They
--- are stubbed here to no-ops so loading the UI does not crash; the
--- next session will rebuild the dashboards on top of SQLite directly.

function M.aggregate_events(_events, _app_name, _date_str)
	-- Real aggregation now lives in `_update_agg_*` and runs from the
	-- ingest tick. Kept as a callable for backward compatibility.
	return
end

function M.save_today_index() end
function M.save_manifest() end
function M.merge_day_to_db(_date_str, _idx, _manifest) end
function M.merge_day_to_db_async(_date_str, _idx, _manifest, on_done)
	if type(on_done) == "function" then pcall(on_done, true) end
end

function M.rebuild_today_from_raw_log() return false end
function M.rebuild_today_from_raw_log_async(on_done)
	if type(on_done) == "function" then pcall(on_done, false) end
end
function M.rebuild_index_if_needed() end
function M.rebuild_index_if_needed_async(on_done)
	if type(on_done) == "function" then pcall(on_done, false) end
end

function M.get_mac_serial()
	-- Old encryption helper. The new model has no encryption — return an
	-- empty string so callers that do `:gsub(...)` on the result do not
	-- crash. Encryption will be revisited if the UI needs cross-device
	-- privacy guarantees in a later iteration.
	return ""
end
function M.process_files_async(_files, _is_encrypt, _password, _on_progress, on_complete)
	if type(on_complete) == "function" then pcall(on_complete, false) end
end
function M.register_encryptor_app() end

return M

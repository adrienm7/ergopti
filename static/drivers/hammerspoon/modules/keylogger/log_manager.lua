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

--- A pause longer than this between keystrokes breaks N-gram continuity —
--- avoids welding a "morning" ngram to an "afternoon" one.
local MAX_KEYSTROKE_DELAY_MS = 5000

--- Bucket thresholds (ms) used by the UI's "ignore pauses longer than…"
--- dropdown. Cumulative ("≤ T" semantics) — see _bucket_add.
local UI_PAUSE_BUCKETS_MS = { 1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000 }

--- Lookback ring buffer length for retroactive HS / LLM trigger-time
--- reclassification. 50 covers any sane trigger length.
local TRIGGER_LOOKBACK_LEN = 50

--- A "burst" closes when the inter-keydown gap exceeds this.
local BURST_GAP_MS = 1000

--- Minimum chars in a burst to count toward the max-CPM record.
local MIN_BURST_FOR_CPM = 10

--- A "session" closes when the inter-keydown gap exceeds this (5 min).
local SESSION_GAP_MS = 300000

--- Burst length histogram boundaries. Last bucket is open-ended ("500+").
local BURST_LENGTH_BUCKETS = { 1, 5, 10, 20, 50, 100, 200, 500 }

--- Maximum session durations stored per (device,date,app).
local SESSION_DURATIONS_CAP = 100

--- Auto-repeat detection threshold (macOS auto-repeat fires every ~30 ms).
local AUTO_REPEAT_MAX_DELAY_MS = 50

--- A run of ≥ N consecutive manual backspaces is counted as one cascade.
local CASCADE_MIN_BS = 3

--- Tap vs hold threshold for kc_hold tracking.
local HOLD_THRESHOLD_MS = 250

--- Window-titles cap per (device,date,app). The lowest-(c+ms) entries are
--- dropped past this — keeps agg_app_day_titles bounded on heavy days.
local TITLE_CAP_PER_APP_DAY = 100

--- macOS virtual-keycode → finger column. MUST stay in sync with
--- KEYCODE_DATA in ui/metrics_typing/state.js. Only "content" keys are
--- listed; modifiers / thumbs are absent on purpose so they do not break
--- a streak by appearing in the middle.
local KC_TO_FINGER = {
	[0]="r_pinky",[1]="r_ring",[2]="r_mid",[3]="r_idx",[4]="l_idx",[5]="r_idx",
	[6]="r_ring",[7]="r_mid",[8]="r_idx",[9]="r_idx",[11]="r_idx",
	[12]="r_pinky",[13]="r_ring",[14]="r_mid",[15]="r_idx",[16]="l_idx",[17]="r_idx",
	[18]="r_pinky",[19]="r_ring",[20]="r_mid",[21]="r_idx",[22]="l_idx",[23]="r_idx",
	[25]="l_ring",[26]="l_idx",[28]="l_mid",[29]="l_pinky",
	[31]="l_ring",[32]="l_idx",[34]="l_mid",[35]="l_pinky",
	[37]="l_ring",[38]="l_idx",[40]="l_mid",[41]="l_pinky",
	[43]="l_mid",[44]="l_pinky",[45]="l_idx",[46]="l_idx",[47]="l_ring",
}

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
		{ "ngram_ctx_json",    "{}" },
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
	for r in _db:nrows("SELECT value FROM meta WHERE key='ngram_ctx_json'") do
		local ok, decoded = pcall(json.decode, r.value or "{}")
		if ok and type(decoded) == "table" then _ngram_ctx = decoded end
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

--- Stateful walk of typing entries that mirrors the legacy
--- `aggregate_events` byte-for-byte but emits SQL UPSERT deltas instead of
--- mutating in-memory dicts. Deltas accumulate in `_agg_batch` between
--- calls; `_flush_agg_batches()` writes them to SQLite at the end of an
--- ingest tick.
---
--- The N-gram + burst + session context survives across ticks via
--- `_ngram_ctx` (RAM, persisted to meta JSON on shutdown / day rollover).



-- ===================================
-- ===== 8.1) Aggregator state =====
-- ===================================

--- Per-app n-gram + burst + session walking context. Persists across
--- ingest ticks; reset at day rollover.
local _ngram_ctx = nil

--- Per-tick batch of pending UPSERTs. Cleared after `_flush_agg_batches`.
--- Layout:
---   batch.app_day[date|app]                 = { chars=,pauses=,time_ms=, ... }
---   batch.ngram[table_name][date|app|tok]   = { c=,td=,cd=,e=,esrc={hs=,llm=,o=} }
---   batch.kc_ngram[date|app|kc]             = count
---   batch.sc_ngram[t][date|app|tok]         = count   (t=shortcut/sc_bg)
---   batch.kc_hold[date|app|kc]              = { sum,count,max,tap,hold }
---   batch.titles[date|app|title]            = { c,ms }
---   batch.hourly[date|app|hour]             = { c,e,em,es,e_buckets={} }
---   batch.hourly_min5[date|app|slot]        = { c,e,es,e_buckets={} }
---   batch.layouts[date|app|layout]          = count
---   batch.chars_class[date|app]             = { letter,digit,punct,space,other,first,last }
---   batch.errors[date|app]                  = { bs_total,cascade_count,cascade_max_len,recovery_sum_ms,recovery_count }
---   batch.ergo[date|app]                    = { same_finger_streak_max,same_hand_streak_max,auto_repeat_count }
---   batch.bursts[date|app]                  = { count_total,max_cpm,max_chars,length_buckets={},inter_count,inter_sum,inter_sumsq }
---   batch.sessions[date|app]                = { count_total,longest_ms,longest_chars,total_active_ms,durations={} }
---   batch.app_buckets[date|app|bucket_ms]   = { time_sum,credited,hs_in_t,hs_in_c,llm_in_t,llm_in_c }
---   batch.system_day[date]                  = { wifi_changes,space_switches,... }
---   batch.app_time[date|app]                = ms
---   batch.switches_to[date|from|to]         = count
local _agg_batch = nil

--- Reset / initialise the per-tick batch.
local function _reset_batch()
	_agg_batch = {
		app_day      = {},
		ngram        = {
			ngram_chars       = {},
			ngram_bigrams     = {},
			ngram_trigrams    = {},
			ngram_quadgrams   = {},
			ngram_pentagrams  = {},
			ngram_hexagrams   = {},
			ngram_heptagrams  = {},
			ngram_words       = {},
			ngram_word_bigrams = {},
		},
		kc_ngram     = {},
		sc_ngram     = { ngram_shortcuts = {}, ngram_shortcut_bigrams = {} },
		kc_hold      = {},
		titles       = {},
		hourly       = {},
		hourly_min5  = {},
		layouts      = {},
		chars_class  = {},
		errors       = {},
		ergo         = {},
		bursts       = {},
		sessions     = {},
		app_buckets  = {},
		system_day   = {},
		app_time     = {},
		switches_to  = {},
	}
end



-- ============================
-- ===== 8.2) Helpers =====
-- ============================

--- Get-or-create a sub-table at `tbl[k]`, returning the populated default.
local function _gc(tbl, k, default)
	local v = tbl[k]
	if not v then
		v = default or {}
		tbl[k] = v
	end
	return v
end

--- Cumulative bucket accumulator. See UI_PAUSE_BUCKETS_MS.
local function _bucket_add(target_map, delay, value)
	for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
		if delay <= t then
			local k = tostring(t)
			target_map[k] = (target_map[k] or 0) + value
		end
	end
end

--- Burst length bucket label.
local function _burst_length_bucket(n)
	for _, b in ipairs(BURST_LENGTH_BUCKETS) do
		if n <= b then return tostring(b) end
	end
	return "500+"
end

--- UTF-8-aware character classifier.
local function _char_class(c)
	if not c or #c == 0 then return "other" end
	if c == " " or c == "\t" or c == "\n" or c == "\194\160" or c == "\226\128\175" then
		return "space"
	end
	local b = c:byte(1)
	if b >= 48 and b <= 57 then return "digit" end
	if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return "letter" end
	if b >= 0xC2 and b <= 0xCF then return "letter" end
	if b >= 0xD0 and b <= 0xD7 then return "letter" end
	if c:sub(1, 1) == "[" and c:sub(-1) == "]" then return "other" end
	if c:match("^[%p<>=+%*/\\|%-]$") then return "punct" end
	return "other"
end

--- Pop the last UTF-8 codepoint off a string.
local function _pop_utf8(s)
	if not s or #s == 0 then return s or "" end
	local ok, off = pcall(utf8.offset, s, -1)
	if not ok or not off then return s:sub(1, -2) end
	return s:sub(1, off - 1)
end

--- Get-or-create the n-gram context entry for an app.
local function _get_app_ctx(app)
	if not _ngram_ctx then _ngram_ctx = {} end
	local c = _ngram_ctx[app]
	if not c then
		c = {
			p1 = nil, p2 = nil, p3 = nil, p4 = nil, p5 = nil, p6 = nil,
			cur_word = "", word_err = false, hist = {},
			prev_word = nil, prev_sc = nil,
			recent_typing = {},
			current_burst = nil, current_session = nil,
			bs_run_len = 0, last_was_bs = false,
			last_finger = nil, same_finger_run = 0, same_hand_run = 0,
			last_char = nil,
		}
		_ngram_ctx[app] = c
	end
	return c
end

--- Bump a metric in the batch ngram dict.
local function _add_ngram_metric(table_name, key, delay, is_error, synth_type)
	local tbl = _agg_batch.ngram[table_name]
	if not tbl then return end
	local item = tbl[key]
	if not item then
		item = { c = 0, td = 0, cd = 0, e = 0, esrc = {} }
		tbl[key] = item
	end
	if is_error then
		item.e = item.e + 1
		if synth_type and synth_type ~= "none" then
			item.esrc[synth_type] = (item.esrc[synth_type] or 0) + 1
		end
	else
		item.c = item.c + 1
		if synth_type == "hotstring" or synth_type == "llm" or (synth_type and synth_type ~= "none") then
			item.esrc[synth_type] = (item.esrc[synth_type] or 0) + 1
		elseif delay > 0 then
			item.td = item.td + delay
			item.cd = item.cd + 1
		end
	end
end

--- Store an n-gram tuple keyed by (date,app,token).
local function _push_ngram(table_name, date_str, app, token, delay, is_error, synth_type)
	local key = date_str .. "\1" .. app .. "\1" .. token
	_add_ngram_metric(table_name, key, delay, is_error, synth_type)
end

--- Bump a per-app-day numeric counter on _agg_batch.app_day.
local function _bump_app_day(date_str, app, field, value)
	local key = date_str .. "\1" .. app
	local row = _gc(_agg_batch.app_day, key, { date = date_str, app = app })
	row[field] = (row[field] or 0) + value
end



-- ====================================
-- ===== 8.3) Burst / Session =====
-- ====================================

local function _finalize_burst(date_str, app, b)
	if not b or b.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = _gc(_agg_batch.bursts, key, {
		date = date_str, app = app,
		count_total = 0, max_cpm = 0, max_chars = 0,
		length_buckets = {}, inter_count = 0, inter_sum = 0, inter_sumsq = 0,
	})
	r.count_total = r.count_total + 1
	if b.char_count > r.max_chars then r.max_chars = b.char_count end
	if b.char_count >= MIN_BURST_FOR_CPM and b.sum_delays > 0 then
		local cpm = b.char_count * 60000 / b.sum_delays
		if cpm > r.max_cpm then r.max_cpm = cpm end
	end
	local k = _burst_length_bucket(b.char_count)
	r.length_buckets[k] = (r.length_buckets[k] or 0) + 1
	r.inter_count = r.inter_count + math.max(0, b.char_count - 1)
	r.inter_sum   = r.inter_sum   + b.sum_delays
	r.inter_sumsq = r.inter_sumsq + b.sum_delays_sq
end

local function _finalize_session(date_str, app, s)
	if not s or s.char_count <= 0 then return end
	local key = date_str .. "\1" .. app
	local r = _gc(_agg_batch.sessions, key, {
		date = date_str, app = app,
		count_total = 0, longest_ms = 0, longest_chars = 0, total_active_ms = 0,
		durations = {},
	})
	r.count_total = r.count_total + 1
	if s.total_ms   > r.longest_ms    then r.longest_ms    = s.total_ms   end
	if s.char_count > r.longest_chars then r.longest_chars = s.char_count end
	r.total_active_ms = r.total_active_ms + s.total_ms
	if #r.durations < SESSION_DURATIONS_CAP then
		table.insert(r.durations, s.total_ms)
	end
end



-- =================================
-- ===== 8.4) Typing walker =====
-- =================================

--- Replays a typing entry's per-keystroke array and pushes every metric
--- into _agg_batch. Mirrors the legacy aggregate_events() logic.
local function _walk_typing_entry(entry)
	local app      = entry.app or "Unknown"
	local date_str = entry.timestamp and entry.timestamp:sub(1, 10) or _today()
	local events   = entry.events
	if type(events) ~= "table" then return end

	local ctx = _get_app_ctx(app)
	local p1, p2, p3, p4, p5, p6 = ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6
	local cur_word  = ctx.cur_word or ""
	local word_err  = ctx.word_err or false
	local backtrack = ctx.hist or {}
	local prev_word = ctx.prev_word
	local prev_sc   = ctx.prev_sc
	local prev_synth_type = "none"

	-- Compute current_hour / current_min5 from the entry timestamp so a
	-- batch ingested late still bins to the right slot.
	local current_hour, current_min5
	do
		local ts = entry.timestamp or ""
		local hh = ts:sub(12, 13); local mm = ts:sub(15, 16)
		if hh == "" then hh = os.date("%H") end
		if mm == "" then mm = os.date("%M") end
		current_hour = hh
		local mn = tonumber(mm) or 0
		current_min5 = string.format("%s:%02d", hh, math.floor(mn / 5) * 5)
	end

	local app_day_key = date_str .. "\1" .. app
	local hourly_key  = app_day_key .. "\1" .. current_hour
	local min5_key    = app_day_key .. "\1" .. current_min5
	local hr  = _gc(_agg_batch.hourly,      hourly_key, { date=date_str, app=app, hour=current_hour, c=0, e=0, em=0, es=0, e_buckets={} })
	local m5  = _gc(_agg_batch.hourly_min5, min5_key,   { date=date_str, app=app, slot=current_min5, c=0, e=0, es=0, e_buckets={} })
	local cc  = _gc(_agg_batch.chars_class, app_day_key,{ date=date_str, app=app, letter=0,digit=0,punct=0,space=0,other=0 })
	local er  = _gc(_agg_batch.errors,      app_day_key,{ date=date_str, app=app, bs_total=0,cascade_count=0,cascade_max_len=0,recovery_sum_ms=0,recovery_count=0 })
	local eg  = _gc(_agg_batch.ergo,        app_day_key,{ date=date_str, app=app, same_finger_streak_max=0,same_hand_streak_max=0,auto_repeat_count=0 })

	-- Layout tag.
	if type(entry.layout) == "string" and entry.layout ~= "" then
		local lk = app_day_key .. "\1" .. entry.layout
		_agg_batch.layouts[lk] = (_agg_batch.layouts[lk] or { date=date_str, app=app, layout=entry.layout, count=0 })
		_agg_batch.layouts[lk].count = _agg_batch.layouts[lk].count + 1
	end

	-- Window-title tag.
	if type(entry.title) == "string" and entry.title ~= "" then
		local tk = app_day_key .. "\1" .. entry.title
		local tr = _gc(_agg_batch.titles, tk, { date=date_str, app=app, title=entry.title, c=0, ms=0 })
		tr.c = tr.c + 1
	end

	for _, ev in ipairs(events) do
		local char         = ev[1]
		local delay        = ev[2] or 0
		local meta         = ev[3] or {}
		local shortcut_key = meta.sc
		local is_backspace = (char == "[BS]")
		local synth_type   = meta.st or "none"
		local is_synthetic = meta.s or false

		if type(shortcut_key) == "string" and shortcut_key ~= "" then
			local sc_tbl   = _agg_batch.sc_ngram.ngram_shortcuts
			local scbg_tbl = _agg_batch.sc_ngram.ngram_shortcut_bigrams
			local sk = app_day_key .. "\1" .. shortcut_key
			sc_tbl[sk] = (sc_tbl[sk] or { date=date_str, app=app, token=shortcut_key, count=0 })
			sc_tbl[sk].count = sc_tbl[sk].count + 1
			if prev_sc then
				local bgt = prev_sc .. "→" .. shortcut_key
				local bk = app_day_key .. "\1" .. bgt
				scbg_tbl[bk] = (scbg_tbl[bk] or { date=date_str, app=app, token=bgt, count=0 })
				scbg_tbl[bk].count = scbg_tbl[bk].count + 1
			end
			prev_sc = shortcut_key
		else
			-- Long pause breaks N-gram continuity.
			if delay >= MAX_KEYSTROKE_DELAY_MS and not is_synthetic then
				p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
				backtrack = {}
				if #cur_word > 0 then
					if prev_word then
						_push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
					end
					_push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
				end
				cur_word = ""; word_err = false; prev_word = nil; prev_sc = nil
			end

			-- Count synth triggers once per burst.
			if is_synthetic and synth_type ~= "none" and synth_type ~= prev_synth_type then
				if synth_type == "hotstring" then
					_bump_app_day(date_str, app, "hs_triggers", 1)
				elseif synth_type == "llm" then
					_bump_app_day(date_str, app, "llm_triggers", 1)
				end
			end
			prev_synth_type = is_synthetic and synth_type or "none"

			if is_backspace then
				if #backtrack > 0 then
					local last_entry = table.remove(backtrack)
					if last_entry.c ~= "[BS]" then
						if last_entry.c  then _push_ngram("ngram_chars",      date_str, app, last_entry.c,  0, true, synth_type) end
						if last_entry.bg then _push_ngram("ngram_bigrams",    date_str, app, last_entry.bg, 0, true, synth_type) end
						if last_entry.tg then _push_ngram("ngram_trigrams",   date_str, app, last_entry.tg, 0, true, synth_type) end
						if last_entry.qg then _push_ngram("ngram_quadgrams",  date_str, app, last_entry.qg, 0, true, synth_type) end
						if last_entry.pg then _push_ngram("ngram_pentagrams", date_str, app, last_entry.pg, 0, true, synth_type) end
						if last_entry.hx then _push_ngram("ngram_hexagrams",  date_str, app, last_entry.hx, 0, true, synth_type) end
						if last_entry.hp then _push_ngram("ngram_heptagrams", date_str, app, last_entry.hp, 0, true, synth_type) end
					end
				end
				cur_word = _pop_utf8(cur_word)
				word_err = true

				if is_synthetic then
					hr.es = hr.es + 1; m5.es = m5.es + 1
					local trigger_evt = table.remove(ctx.recent_typing)
					if synth_type == "hotstring" then
						_bump_app_day(date_str, app, "hs_chars", -1)
						_bump_app_day(date_str, app, "hs_input_chars", 1)
						if trigger_evt then
							local bk_tsum = app_day_key
							-- bucket aggregation by per-bucket key
							for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = bk_tsum .. "\1" .. tostring(t)
									local row = _gc(_agg_batch.app_buckets, bkey, {
										date=date_str, app=app, bucket_ms=t,
										time_sum=0, credited=0,
										hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
									})
									row.hs_in_t = row.hs_in_t + trigger_evt.delay
									row.hs_in_c = row.hs_in_c + 1
								end
							end
						end
					elseif synth_type == "llm" then
						_bump_app_day(date_str, app, "llm_chars", -1)
						_bump_app_day(date_str, app, "llm_input_chars", 1)
						if trigger_evt then
							for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
								if trigger_evt.delay <= t then
									local bkey = app_day_key .. "\1" .. tostring(t)
									local row = _gc(_agg_batch.app_buckets, bkey, {
										date=date_str, app=app, bucket_ms=t,
										time_sum=0, credited=0,
										hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
									})
									row.llm_in_t = row.llm_in_t + trigger_evt.delay
									row.llm_in_c = row.llm_in_c + 1
								end
							end
						end
					end
				else
					hr.e  = hr.e  + 1; hr.em = hr.em + 1; m5.e  = m5.e  + 1
					_bump_app_day(date_str, app, "chars", 1)
					if delay > THINK_PAUSE_THRESHOLD_MS then
						_bump_app_day(date_str, app, "think_time_ms", delay)
						_bump_app_day(date_str, app, "pauses", 1)
					else
						_bump_app_day(date_str, app, "time_ms", delay)
					end
					_bucket_add(hr.e_buckets, delay, 1)
					_bucket_add(m5.e_buckets, delay, 1)
					table.remove(ctx.recent_typing)
					ctx.bs_run_len = ctx.bs_run_len + 1
					ctx.last_was_bs = true
					er.bs_total = er.bs_total + 1
					ctx.last_finger = nil
					ctx.same_finger_run = 0
					ctx.same_hand_run   = 0
					ctx.last_char = nil
				end

				local bs_entry = {}
				_push_ngram("ngram_chars", date_str, app, "[BS]", delay, false, synth_type); bs_entry.c = "[BS]"
				if p1 then _push_ngram("ngram_bigrams",  date_str, app, p1 .. "[BS]", delay, false, synth_type); bs_entry.bg = p1 .. "[BS]" end
				if p2 then _push_ngram("ngram_trigrams", date_str, app, p2 .. p1 .. "[BS]", delay, false, synth_type); bs_entry.tg = p2 .. p1 .. "[BS]" end
				table.insert(backtrack, bs_entry)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = "[BS]"
			else
				local k_c  = char
				local k_bg = p1 and (p1 .. k_c) or nil
				local k_tg = p2 and (p2 .. p1 .. k_c) or nil
				local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
				local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

				local is_bracket_key = type(k_c) == "string" and k_c:sub(1, 1) == "[" and k_c:sub(-1) == "]"
				local record_delay   = delay < MAX_KEYSTROKE_DELAY_MS and delay or 0

				local entry_marks = {}
				if is_synthetic or is_bracket_key or delay < MAX_KEYSTROKE_DELAY_MS then
					_push_ngram("ngram_chars", date_str, app, k_c, record_delay, false, synth_type); entry_marks.c = k_c
					if k_bg then _push_ngram("ngram_bigrams",    date_str, app, k_bg, record_delay, false, synth_type); entry_marks.bg = k_bg end
					if k_tg then _push_ngram("ngram_trigrams",   date_str, app, k_tg, record_delay, false, synth_type); entry_marks.tg = k_tg end
					if k_qg then _push_ngram("ngram_quadgrams",  date_str, app, k_qg, record_delay, false, synth_type); entry_marks.qg = k_qg end
					if k_pg then _push_ngram("ngram_pentagrams", date_str, app, k_pg, record_delay, false, synth_type); entry_marks.pg = k_pg end
					if k_hx then _push_ngram("ngram_hexagrams",  date_str, app, k_hx, record_delay, false, synth_type); entry_marks.hx = k_hx end
					if k_hp then _push_ngram("ngram_heptagrams", date_str, app, k_hp, record_delay, false, synth_type); entry_marks.hp = k_hp end

					if not is_synthetic then
						_bump_app_day(date_str, app, "chars", 1)
						hr.c = hr.c + 1; m5.c = m5.c + 1
						if record_delay > THINK_PAUSE_THRESHOLD_MS then
							_bump_app_day(date_str, app, "think_time_ms", record_delay)
							_bump_app_day(date_str, app, "pauses", 1)
						else
							_bump_app_day(date_str, app, "time_ms", record_delay)
						end
						-- Time / credited buckets.
						for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
							if record_delay <= t then
								local bkey = app_day_key .. "\1" .. tostring(t)
								local row = _gc(_agg_batch.app_buckets, bkey, {
									date=date_str, app=app, bucket_ms=t,
									time_sum=0, credited=0,
									hs_in_t=0, hs_in_c=0, llm_in_t=0, llm_in_c=0,
								})
								row.time_sum = row.time_sum + record_delay
								row.credited = row.credited + 1
							end
						end
						table.insert(ctx.recent_typing, { delay = record_delay })
						if #ctx.recent_typing > TRIGGER_LOOKBACK_LEN then
							table.remove(ctx.recent_typing, 1)
						end

						-- Burst tracking.
						if (not ctx.current_burst) or record_delay > BURST_GAP_MS then
							_finalize_burst(date_str, app, ctx.current_burst)
							ctx.current_burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
						else
							local b = ctx.current_burst
							b.char_count    = b.char_count + 1
							b.sum_delays    = b.sum_delays + record_delay
							b.sum_delays_sq = b.sum_delays_sq + (record_delay * record_delay)
							if record_delay > b.max_delay then b.max_delay = record_delay end
						end

						-- Session tracking.
						if (not ctx.current_session) or record_delay > SESSION_GAP_MS then
							_finalize_session(date_str, app, ctx.current_session)
							ctx.current_session = { char_count = 1, total_ms = 0 }
						else
							local s = ctx.current_session
							s.char_count = s.char_count + 1
							s.total_ms   = s.total_ms + record_delay
						end

						-- Cascade close + recovery.
						if ctx.last_was_bs then
							if ctx.bs_run_len >= CASCADE_MIN_BS then
								er.cascade_count = er.cascade_count + 1
								if ctx.bs_run_len > er.cascade_max_len then
									er.cascade_max_len = ctx.bs_run_len
								end
							end
							if record_delay <= MAX_KEYSTROKE_DELAY_MS then
								er.recovery_sum_ms = er.recovery_sum_ms + record_delay
								er.recovery_count  = er.recovery_count + 1
							end
							ctx.bs_run_len = 0; ctx.last_was_bs = false
						end

						-- Same-finger / same-hand streaks.
						local kc_num     = type(meta.kc) == "number" and meta.kc or nil
						local cur_finger = kc_num and KC_TO_FINGER[kc_num] or nil
						if cur_finger then
							if ctx.last_finger == cur_finger then
								ctx.same_finger_run = (ctx.same_finger_run or 1) + 1
							else
								ctx.same_finger_run = 1
							end
							if ctx.same_finger_run > eg.same_finger_streak_max then
								eg.same_finger_streak_max = ctx.same_finger_run
							end
							local cur_hand  = cur_finger:sub(1, 1)
							local last_hand = ctx.last_finger and ctx.last_finger:sub(1, 1) or nil
							if last_hand == cur_hand then
								ctx.same_hand_run = (ctx.same_hand_run or 1) + 1
							else
								ctx.same_hand_run = 1
							end
							if ctx.same_hand_run > eg.same_hand_streak_max then
								eg.same_hand_streak_max = ctx.same_hand_run
							end
							ctx.last_finger = cur_finger
						else
							ctx.last_finger = nil
							ctx.same_finger_run = 0
							ctx.same_hand_run   = 0
						end

						-- Auto-repeat.
						if ctx.last_char == k_c and record_delay > 0 and record_delay <= AUTO_REPEAT_MAX_DELAY_MS then
							eg.auto_repeat_count = eg.auto_repeat_count + 1
						end
						ctx.last_char = k_c

						-- Char class.
						local cls = _char_class(k_c)
						if     cls == "letter" then cc.letter = cc.letter + 1
						elseif cls == "digit"  then cc.digit  = cc.digit  + 1
						elseif cls == "punct"  then cc.punct  = cc.punct  + 1
						elseif cls == "space"  then cc.space  = cc.space  + 1
						else                        cc.other  = cc.other  + 1
						end

						if not cc.first_typed_min then cc.first_typed_min = current_min5 end
						cc.last_typed_min = current_min5
					else
						if synth_type == "hotstring" then
							_bump_app_day(date_str, app, "hs_chars", 1)
						elseif synth_type == "llm" then
							_bump_app_day(date_str, app, "llm_chars", 1)
						end
					end

					-- Word boundary detection.
					local is_separator = type(k_c) == "string" and (
						k_c:match("[%s.,!?;:\"'()%%{}%[%]<>=+*/\\|%-]") ~= nil
						or k_c == "\n" or k_c == "\194\160" or k_c == "\226\128\175")
					if is_separator then
						if #cur_word > 0 then
							if prev_word then
								_push_ngram("ngram_word_bigrams", date_str, app, prev_word .. " " .. cur_word, 0, word_err, "none")
							end
							_push_ngram("ngram_words", date_str, app, cur_word, 0, word_err, "none")
							prev_word = cur_word
							cur_word  = ""
							word_err  = false
						end
					else
						cur_word = cur_word .. k_c
					end
				end

				table.insert(backtrack, entry_marks)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
			end
		end

		-- Physical keycode tally (non-synthetic only).
		if not is_synthetic and type(meta.kc) == "number" then
			local kk = app_day_key .. "\1" .. tostring(meta.kc)
			_agg_batch.kc_ngram[kk] = (_agg_batch.kc_ngram[kk] or { date=date_str, app=app, keycode=meta.kc, count=0 })
			_agg_batch.kc_ngram[kk].count = _agg_batch.kc_ngram[kk].count + 1
		end
	end

	-- Persist context for next tick.
	ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = p1, p2, p3, p4, p5, p6
	ctx.cur_word  = cur_word
	ctx.word_err  = word_err
	ctx.hist      = backtrack
	ctx.prev_word = prev_word
	ctx.prev_sc   = prev_sc

	-- agg_app_day category + the typing event also contributes to titles.ms
	-- only if we had a clear duration — left for the app_switch path below.
	_bump_app_day(date_str, app, "_category_seed", 0) -- ensure row exists for category UPSERT
end



-- =============================================
-- ===== 8.5) Non-typing event aggregation =====
-- =============================================

--- agg_app_day.app_time_ms gets credited on app_switch.
local function _walk_app_switch(entry)
	if not entry.prev_app then return end
	local date_str = entry.timestamp:sub(1, 10)
	local key = date_str .. "\1" .. entry.prev_app
	_agg_batch.app_time[key] = (_agg_batch.app_time[key] or { date=date_str, app=entry.prev_app, ms=0 })
	_agg_batch.app_time[key].ms = _agg_batch.app_time[key].ms + (entry.duration_ms or 0)
	if entry.next_app then
		local sk = date_str .. "\1" .. entry.prev_app .. "\1" .. entry.next_app
		_agg_batch.switches_to[sk] = (_agg_batch.switches_to[sk] or { date=date_str, app_from=entry.prev_app, app_to=entry.next_app, count=0 })
		_agg_batch.switches_to[sk].count = _agg_batch.switches_to[sk].count + 1
	end
end

--- agg_app_day_titles.ms gets credited on window_switch.
local function _walk_window_switch(entry)
	if type(entry.prev_title) ~= "string" or entry.prev_title == "" then return end
	local date_str = entry.timestamp:sub(1, 10)
	local app = entry.app or "Unknown"
	local tk = date_str .. "\1" .. app .. "\1" .. entry.prev_title
	local tr = _gc(_agg_batch.titles, tk, { date=date_str, app=app, title=entry.prev_title, c=0, ms=0 })
	tr.ms = tr.ms + (entry.duration_ms or 0)
end

--- kc_hold tracking for modifier_hold / karabiner_release.
local function _walk_system_event(entry)
	local date_str = entry.timestamp:sub(1, 10)
	local action   = entry.action
	if action == "modifier_hold" or action == "karabiner_release" then
		local kc = entry.keycode
		local app = entry.app or "Unknown"
		local hold = entry.hold_ms or 0
		if type(kc) == "number" then
			local key = date_str .. "\1" .. app .. "\1" .. tostring(kc)
			local r = _gc(_agg_batch.kc_hold, key, {
				date=date_str, app=app, keycode=kc,
				sum_ms=0, count=0, max_ms=0, tap_count=0, hold_count=0,
			})
			r.sum_ms = r.sum_ms + hold; r.count = r.count + 1
			if hold > r.max_ms then r.max_ms = hold end
			if hold <= HOLD_THRESHOLD_MS then r.tap_count = r.tap_count + 1
			else r.hold_count = r.hold_count + 1 end
		end
	end
	-- Per-day system stats.
	local s = _gc(_agg_batch.system_day, date_str, {
		date=date_str, wifi_changes=0, space_switches=0,
		audio_muted_ms=0, locked_ms=0, sleep_ms=0, awake_ms=0,
		passive_count=0, night_wake_count=0,
	})
	if action == "wifi_change" then s.wifi_changes = s.wifi_changes + 1
	elseif action == "space_change" then s.space_switches = s.space_switches + 1
	elseif action == "passive_period" then s.passive_count = s.passive_count + 1
	elseif action == "lock" or action == "sleep" then
		-- locked_ms / sleep_ms credited on the matching unlock/wake via duration_ms
	elseif action == "unlock" then s.locked_ms = s.locked_ms + (entry.duration_ms or 0)
	elseif action == "wake" then s.sleep_ms  = s.sleep_ms  + (entry.duration_ms or 0)
	end
end



-- ====================================
-- ===== 8.6) Batch flush to DB =====
-- ====================================

--- One-shot UPSERT helper. `cols` is the column list, `pk_cols` lists the
--- PK columns, `add_cols` lists the columns added on conflict, `set_cols`
--- lists the ones simply replaced (max / coalesce semantics expressed via
--- the build-it-yourself update SQL).
local function _exec(sql)
	local rc = _db:exec(sql)
	if rc ~= sqlite3.OK then
		Logger.error(LOG, "exec failed: %s — %s.", _db:errmsg() or "?", sql:sub(1, 200))
	end
end

--- Encode a simple table as a JSON literal for SQL.
local function _json_lit(tbl)
	if type(tbl) ~= "table" then return "'{}'" end
	local ok, s = pcall(json.encode, tbl)
	if not ok then return "'{}'" end
	return "'" .. (s:gsub("'", "''")) .. "'"
end

--- Sql escape.
local function _sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function _flush_agg_batches()
	if not _db then return end
	local d = _sq(_device_id)

	-- agg_app_day (counters + category).
	for _, row in pairs(_agg_batch.app_day) do
		local cat = M.get_native_app_category(row.app)
		_exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_input_chars, llm_input_chars, category) "
			.. "VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "chars=chars+excluded.chars,"
			.. "pauses=pauses+excluded.pauses,"
			.. "time_ms=time_ms+excluded.time_ms,"
			.. "think_time_ms=think_time_ms+excluded.think_time_ms,"
			.. "hs_chars=hs_chars+excluded.hs_chars,"
			.. "llm_chars=llm_chars+excluded.llm_chars,"
			.. "hs_triggers=hs_triggers+excluded.hs_triggers,"
			.. "llm_triggers=llm_triggers+excluded.llm_triggers,"
			.. "hs_input_chars=hs_input_chars+excluded.hs_input_chars,"
			.. "llm_input_chars=llm_input_chars+excluded.llm_input_chars,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, _sq(row.date), _sq(row.app),
			row.chars or 0, row.pauses or 0, row.time_ms or 0, row.think_time_ms or 0,
			row.hs_chars or 0, row.llm_chars or 0,
			row.hs_triggers or 0, row.llm_triggers or 0,
			row.hs_input_chars or 0, row.llm_input_chars or 0,
			_sq(cat)))
	end

	-- agg_app_day app_time (separate UPSERT path).
	for _, row in pairs(_agg_batch.app_time) do
		local cat = M.get_native_app_category(row.app)
		_exec(string.format(
			"INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category) VALUES (%s,%s,%s,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "app_time_ms=app_time_ms+excluded.app_time_ms,"
			.. "category=COALESCE(agg_app_day.category, excluded.category)",
			d, _sq(row.date), _sq(row.app), row.ms or 0, _sq(cat)))
	end

	-- agg_app_day_buckets.
	for _, row in pairs(_agg_batch.app_buckets) do
		_exec(string.format(
			"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET "
			.. "time_sum=time_sum+excluded.time_sum,"
			.. "credited=credited+excluded.credited,"
			.. "hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,"
			.. "hs_input_credited=hs_input_credited+excluded.hs_input_credited,"
			.. "llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,"
			.. "llm_input_credited=llm_input_credited+excluded.llm_input_credited",
			d, _sq(row.date), _sq(row.app), row.bucket_ms,
			row.time_sum or 0, row.credited or 0,
			row.hs_in_t or 0, row.hs_in_c or 0,
			row.llm_in_t or 0, row.llm_in_c or 0))
	end

	-- N-grams (chars / bigrams / … / words / word_bigrams).
	for tbl_name, tbl in pairs(_agg_batch.ngram) do
		for key, item in pairs(tbl) do
			-- key is "date\1app\1token"; split on \1
			local s, e = key:find("\1")
			local date_str = key:sub(1, s - 1)
			local rest = key:sub(e + 1)
			local s2, e2 = rest:find("\1")
			local app = rest:sub(1, s2 - 1)
			local token = rest:sub(e2 + 1)
			_exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET "
				.. "c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e, "
				.. "esrc_json=excluded.esrc_json",
				tbl_name, d, _sq(date_str), _sq(app), _sq(token),
				item.c or 0, item.td or 0, item.cd or 0, item.e or 0,
				_json_lit(item.esrc)))
		end
	end

	-- ngram_keycodes.
	for _, row in pairs(_agg_batch.kc_ngram) do
		_exec(string.format(
			"INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES (%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c",
			d, _sq(row.date), _sq(row.app), row.keycode, row.count or 0))
	end

	-- ngram_shortcuts / ngram_shortcut_bigrams.
	for tbl_name, tbl in pairs(_agg_batch.sc_ngram) do
		for _, row in pairs(tbl) do
			_exec(string.format(
				"INSERT INTO %s (device_id, date, app, token, c) VALUES (%s,%s,%s,%s,%d) "
				.. "ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c",
				tbl_name, d, _sq(row.date), _sq(row.app), _sq(row.token), row.count or 0))
		end
	end

	-- agg_app_day_kc_hold.
	for _, row in pairs(_agg_batch.kc_hold) do
		_exec(string.format(
			"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET "
			.. "sum_ms=sum_ms+excluded.sum_ms,"
			.. "count=count+excluded.count,"
			.. "max_ms=MAX(max_ms, excluded.max_ms),"
			.. "tap_count=tap_count+excluded.tap_count,"
			.. "hold_count=hold_count+excluded.hold_count",
			d, _sq(row.date), _sq(row.app), row.keycode,
			row.sum_ms, row.count, row.max_ms, row.tap_count, row.hold_count))
	end

	-- agg_app_day_titles.
	for _, row in pairs(_agg_batch.titles) do
		_exec(string.format(
			"INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (%s,%s,%s,%s,%d,%d) "
			.. "ON CONFLICT(device_id, date, app, title) DO UPDATE SET "
			.. "c=c+excluded.c, ms=ms+excluded.ms",
			d, _sq(row.date), _sq(row.app), _sq(row.title), row.c or 0, row.ms or 0))
	end
	-- Trim titles past cap.
	for key, _ in pairs(_agg_batch.titles) do
		local s, e = key:find("\1")
		local rest = key:sub(e + 1)
		local s2, e2 = rest:find("\1")
		local date_str = key:sub(1, s - 1)
		local app = rest:sub(1, s2 - 1)
		_exec(string.format(
			"DELETE FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s AND title NOT IN ("
			.. "SELECT title FROM agg_app_day_titles WHERE device_id=%s AND date=%s AND app=%s "
			.. "ORDER BY (c + ms) DESC LIMIT %d)",
			d, _sq(date_str), _sq(app), d, _sq(date_str), _sq(app), TITLE_CAP_PER_APP_DAY))
	end

	-- agg_app_day_hourly.
	for _, row in pairs(_agg_batch.hourly) do
		_exec(string.format(
			"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, hour) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, em=em+excluded.em, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, _sq(row.date), _sq(row.app), _sq(row.hour),
			row.c, row.e, row.em, row.es, _json_lit(row.e_buckets)))
	end

	-- agg_app_day_hourly_min5.
	for _, row in pairs(_agg_batch.hourly_min5) do
		_exec(string.format(
			"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES (%s,%s,%s,%s,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app, slot) DO UPDATE SET "
			.. "c=c+excluded.c, e=e+excluded.e, es=es+excluded.es, "
			.. "e_buckets_json=excluded.e_buckets_json",
			d, _sq(row.date), _sq(row.app), _sq(row.slot),
			row.c, row.e, row.es, _json_lit(row.e_buckets)))
	end

	-- agg_app_day_layouts.
	for _, row in pairs(_agg_batch.layouts) do
		_exec(string.format(
			"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count",
			d, _sq(row.date), _sq(row.app), _sq(row.layout), row.count))
	end

	-- agg_app_day_chars_class.
	for _, row in pairs(_agg_batch.chars_class) do
		_exec(string.format(
			"INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES (%s,%s,%s,%d,%d,%d,%d,%d,%s,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "letter=letter+excluded.letter,"
			.. "digit=digit+excluded.digit,"
			.. "punct=punct+excluded.punct,"
			.. "space=space+excluded.space,"
			.. "other=other+excluded.other,"
			.. "first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),"
			.. "last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min)",
			d, _sq(row.date), _sq(row.app),
			row.letter, row.digit, row.punct, row.space, row.other,
			row.first_typed_min and _sq(row.first_typed_min) or "NULL",
			row.last_typed_min  and _sq(row.last_typed_min)  or "NULL"))
	end

	-- agg_app_day_errors.
	for _, row in pairs(_agg_batch.errors) do
		_exec(string.format(
			"INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES (%s,%s,%s,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "bs_total=bs_total+excluded.bs_total,"
			.. "cascade_count=cascade_count+excluded.cascade_count,"
			.. "cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),"
			.. "recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,"
			.. "recovery_count=recovery_count+excluded.recovery_count",
			d, _sq(row.date), _sq(row.app),
			row.bs_total, row.cascade_count, row.cascade_max_len,
			row.recovery_sum_ms, row.recovery_count))
	end

	-- agg_app_day_ergo.
	for _, row in pairs(_agg_batch.ergo) do
		_exec(string.format(
			"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count) VALUES (%s,%s,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),"
			.. "same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),"
			.. "auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count",
			d, _sq(row.date), _sq(row.app),
			row.same_finger_streak_max, row.same_hand_streak_max, row.auto_repeat_count))
	end

	-- agg_app_day_burst.
	for _, row in pairs(_agg_batch.bursts) do
		_exec(string.format(
			"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (%s,%s,%s,%d,%f,%d,%s,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "max_cpm=MAX(max_cpm, excluded.max_cpm),"
			.. "max_chars=MAX(max_chars, excluded.max_chars),"
			.. "length_buckets_json=excluded.length_buckets_json,"
			.. "inter_delay_count=inter_delay_count+excluded.inter_delay_count,"
			.. "inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,"
			.. "inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq",
			d, _sq(row.date), _sq(row.app),
			row.count_total, row.max_cpm, row.max_chars,
			_json_lit(row.length_buckets),
			row.inter_count, row.inter_sum, row.inter_sumsq))
	end

	-- agg_app_day_session.
	for _, row in pairs(_agg_batch.sessions) do
		_exec(string.format(
			"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (%s,%s,%s,%d,%d,%d,%d,%s) "
			.. "ON CONFLICT(device_id, date, app) DO UPDATE SET "
			.. "count_total=count_total+excluded.count_total,"
			.. "longest_ms=MAX(longest_ms, excluded.longest_ms),"
			.. "longest_chars=MAX(longest_chars, excluded.longest_chars),"
			.. "total_active_ms=total_active_ms+excluded.total_active_ms,"
			.. "durations_json=excluded.durations_json",
			d, _sq(row.date), _sq(row.app),
			row.count_total, row.longest_ms, row.longest_chars, row.total_active_ms,
			_json_lit(row.durations)))
	end

	-- agg_app_day_switches_to.
	for _, row in pairs(_agg_batch.switches_to) do
		_exec(string.format(
			"INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES (%s,%s,%s,%s,%d) "
			.. "ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count",
			d, _sq(row.date), _sq(row.app_from), _sq(row.app_to), row.count))
	end

	-- agg_system_day.
	for _, row in pairs(_agg_batch.system_day) do
		_exec(string.format(
			"INSERT INTO agg_system_day (device_id, date, wifi_changes, space_switches, audio_muted_ms, locked_ms, sleep_ms, awake_ms, passive_count, night_wake_count) VALUES (%s,%s,%d,%d,%d,%d,%d,%d,%d,%d) "
			.. "ON CONFLICT(device_id, date) DO UPDATE SET "
			.. "wifi_changes=wifi_changes+excluded.wifi_changes,"
			.. "space_switches=space_switches+excluded.space_switches,"
			.. "audio_muted_ms=audio_muted_ms+excluded.audio_muted_ms,"
			.. "locked_ms=locked_ms+excluded.locked_ms,"
			.. "sleep_ms=sleep_ms+excluded.sleep_ms,"
			.. "awake_ms=awake_ms+excluded.awake_ms,"
			.. "passive_count=passive_count+excluded.passive_count,"
			.. "night_wake_count=night_wake_count+excluded.night_wake_count",
			d, _sq(row.date), row.wifi_changes, row.space_switches,
			row.audio_muted_ms, row.locked_ms, row.sleep_ms, row.awake_ms,
			row.passive_count, row.night_wake_count))
	end

	_reset_batch()
end



-- ==========================================
-- ===== 8.7) Public dispatch helpers =====
-- ==========================================

local function _update_agg_typing(entry)
	if not _db then return end
	_walk_typing_entry(entry)
end

local function _update_agg_app_time(entry)
	if not _db then return end
	_walk_app_switch(entry)
end

local function _update_agg_window_switch(entry)
	if not _db then return end
	_walk_window_switch(entry)
end

local function _update_agg_system_event(entry)
	if not _db then return end
	_walk_system_event(entry)
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
		if not _agg_batch then _reset_batch() end
		for _, item in ipairs(entries) do
			local et = item.entry.type
			if et == "typing" then
				_update_agg_typing(item.entry)
			elseif et == "app_switch" then
				_update_agg_app_time(item.entry)
			elseif et == "window_switch" then
				_update_agg_window_switch(item.entry)
			elseif et == "system_event" then
				_update_agg_system_event(item.entry)
			end
		end
		_flush_agg_batches()
		_db:exec(string.format(
			"UPDATE meta SET value='%d' WHERE key='today_log_offset';", new_offset))
		_db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", _today_log_date or ""))
		_db:exec(string.format(
			"UPDATE meta SET value='%d' WHERE key='next_event_id';", _next_event_id))
		_db:exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';")
		-- Persist the n-gram walking context so a crash mid-tick does not
		-- lose the partial cur_word / p1..p6 / current_burst / streak state.
		local ok_enc, enc = pcall(json.encode, _ngram_ctx or {})
		if ok_enc then
			_db:exec(string.format(
				"UPDATE meta SET value=%s WHERE key='ngram_ctx_json';",
				_sq(enc)))
		end
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
	-- A new day starts every n-gram context fresh: yesterday's partial
	-- word / streak / burst is meaningless at midnight.
	_ngram_ctx = {}
	if _db then
		_db:exec("UPDATE meta SET value='0' WHERE key='today_log_offset';")
		_db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", _today_log_date))
		_db:exec("UPDATE meta SET value='{}' WHERE key='ngram_ctx_json';")
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

	-- Initialise per-tick batch dicts.
	_reset_batch()

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

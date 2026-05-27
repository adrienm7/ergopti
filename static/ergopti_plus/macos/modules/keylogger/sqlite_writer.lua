--- modules/keylogger/sqlite_writer.lua

--- ==============================================================================
--- MODULE: Keylogger SQLite Writer
--- DESCRIPTION:
--- Encapsulates all SQLite interactions for the keylogger persistence layer.
--- Handles opening (or bootstrapping) db.sqlite from the canonical schema.sql,
--- building type-specific INSERT OR IGNORE statements for every event kind, and
--- maintaining the per-device sequential event-id counter.
---
--- DESIGN CONTRACT:
--- Callers must invoke M.init(deps) before any other function. The module
--- exposes a single open_db/close pair used by the log manager lifecycle, plus
--- the build_inserts dispatcher used by the ingest tick.
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.sqlite3, hs.fs.
--- - Canonical SQLite schema: static/ergopti_plus/shared/schema/schema.sql.
--- ==============================================================================

local M = {}

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")

local Logger = require("lib.logger")
local LOG    = "keylogger.sqlite_writer"




-- ==============================
--- ===============================
-- ======= 1/ Module State =======
--- ===============================
-- ==============================

--- Resolved path bundle (set by M.init).
local _paths = nil

--- Device object (set by M.init).
local _device_obj = nil

--- Device id shortcut (set by M.init).
local _device_id = nil

--- Open SQLite handle. nil until M.open_db() succeeds.
local _db = nil

--- Per-device sequential event id counter.
local _next_event_id = 1

--- Whether M.init has been called.
local _initialized = false




-- ======================================================
--- =======================================================
-- ======= 2/ Guards and Internal Timestamp Helper =======
--- =======================================================
-- ======================================================

--- Guards public functions against being called before M.init().
local function _require_init(func_name)
	if not _initialized then
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




-- ======================================
--- ===================================
-- ======= 3/ Schema Bootstrap =======
--- ===================================
-- ======================================

--- Resolve the schema.sql path relative to this source file.
--- This file lives at modules/keylogger/, so four levels up reaches
--- static/ergopti_plus/ → shared/schema/.
local _SCHEMA_SQL_PATH = (function()
	local src = debug.getinfo(1, "S").source:sub(2)
	local dir = src:match("^(.*[/\\])")
	return dir .. "../../../shared/schema/schema.sql"
end)()

--- Read the canonical schema.sql from disk.
--- @return string|nil The full DDL text, or nil on IO error.
local function _read_schema_sql()
	local fh, err = io.open(_SCHEMA_SQL_PATH, "r")
	if not fh then
		Logger.error(LOG, "Cannot open schema.sql at %s: %s.",
			_SCHEMA_SQL_PATH, tostring(err))
		return nil
	end
	local body = fh:read("*a"); fh:close()
	return body
end




-- ===================================
--- ===================================
-- ======= 4/ SQLite Lifecycle =======
--- ===================================
-- ===================================

--- Open db.sqlite in tmpdir, applying the schema when the file is fresh.
--- Restores persisted counters (next_event_id, today_log_offset, etc.).
--- @return boolean True on success, false on unrecoverable error.
function M.open_db()
	if not _require_init("open_db") then return false end

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

	-- Ensure meta keys exist (INSERT OR IGNORE is idempotent on replay).
	for _, kv in ipairs({
		{ "next_event_id",    "1"  },
		{ "today_log_offset", "0"  },
		{ "today_log_date",   ""   },
		{ "ngram_ctx_json",   "{}" },
	}) do
		_db:exec(string.format(
			"INSERT OR IGNORE INTO meta (key, value) VALUES ('%s', '%s');",
			kv[1], kv[2]))
	end

	-- Restore persisted counter.
	for r in _db:nrows("SELECT value FROM meta WHERE key='next_event_id'") do
		_next_event_id = tonumber(r.value) or 1
	end

	-- Upsert the local device row so name / os_version stay fresh.
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

--- Close the SQLite handle cleanly.
function M.close_db()
	if _db then
		pcall(function() _db:close() end)
		_db = nil
	end
end

--- Return the raw SQLite handle. Log manager uses this for ingest transactions.
--- @return userdata|nil The open sqlite3 handle, or nil.
function M.get_db()
	return _db
end

--- Persist the next_event_id counter back into meta.
function M.persist_next_event_id()
	if not _db then return end
	_db:exec(string.format(
		"UPDATE meta SET value='%d' WHERE key='next_event_id';", _next_event_id))
end




-- =================================
--- =================================
-- ======= 5/ SQL Primitives =======
--- =================================
-- =================================

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




-- ===================================
--- ==================================
-- ======= 6/ INSERT Builders =======
--- ==================================
-- ===================================

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
--- Returns an array of SQL strings. Unknown event types return an empty
--- array — they will re-appear on the next ingest if a future schema
--- handles them.
--- @param entry table The decoded JSONL event entry.
--- @return table Array of SQL statement strings.
function M.build_inserts(entry)
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




-- ==============================
--- ==============================
-- ======= 7/ Initializer =======
--- ==============================
-- ==============================

--- Initialize the SQLite writer with resolved paths and device identity.
--- Must be called before open_db() or build_inserts().
--- @param deps table Must contain: paths (table), device_obj (table), device_id (string).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table"
		or type(deps.paths)      ~= "table"
		or type(deps.device_obj) ~= "table"
		or type(deps.device_id)  ~= "string" then
		Logger.error(LOG, "M.init(): invalid deps — sqlite_writer non-functional.")
		return
	end
	if _initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_paths      = deps.paths
	_device_obj = deps.device_obj
	_device_id  = deps.device_id
	_initialized = true
	Logger.success(LOG, "Initialized (device %s).", _device_id:sub(1, 8) .. "…")
end

return M

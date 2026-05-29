--- modules/keylogger/log_manager.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager
--- DESCRIPTION:
--- Thin orchestrator for all on-disk persistence for the keylogger. Implements
--- the storage model from static/ergopti_plus/KEYLOGGER_SPEC.md:
---
---     <config_dir>/metrics/by_device/<device_id>/device.json
---     <config_dir>/metrics/by_device/<device_id>/data.sql       (append-only SQL)
---     <config_dir>/metrics/by_device/<device_id>/today.log      (JSONL hot path)
---     <tmpdir>/ergopti_metrics/<device_id>/db.sqlite             (cache mirror)
---
--- SUBMODULES (each owns a distinct concern):
--- - sqlite_writer  — SQLite lifecycle, schema bootstrap, INSERT builders.
--- - aggregator     — N-gram / burst / session walking + batch DB flush.
--- - rotation       — today.log append, tail read, day rollover.
--- - export         — App category lookup, device id, SQLite path/rev, foreign sync.
---
--- FEATURES & RATIONALE:
--- 1. Source of truth on disk is plain SQL text — Git-friendly, no helper
---    needed (KEYLOGGER_SPEC §1.6).
--- 2. SQLite cache lives in tmpdir; user-visible folder only has data.sql +
---    device.json (KEYLOGGER_SPEC §1.7).
--- 3. Hot path never blocks on SQLite: keystroke handler appends a JSONL line;
---    aggregation runs in the ingest tick.
--- 4. Ingest is crash-safe — INSERT OR IGNORE in a transaction is idempotent
---    on replay (KEYLOGGER_SPEC §15.2).
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.sqlite3, hs.fs, hs.timer.
--- ==============================================================================

local M = {}

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local timer   = require("hs.timer")

local Logger = require("lib.logger")
local i18n   = require("lib.i18n")  -- kept for MAC_CATEGORIES_FR still used by export
local LOG    = "keylogger.log_manager"

local SqliteWriter = require("modules.keylogger.sqlite_writer")
local Aggregator   = require("modules.keylogger.aggregator")
local Rotation     = require("modules.keylogger.rotation")
local Export       = require("modules.keylogger.export")
local Metrics      = require("keylogger.metrics")




-- ==============================
--- ============================
-- ======= 1/ Constants =======
--- ============================
-- ==============================

--- Background ingest tick period (KEYLOGGER_SPEC §4).
local INGEST_TICK_SEC = 5

--- Cap on the per-event delay credited to WPM calculation.
local WPM_MAX_EVENT_DELAY_MS = 5000




-- ===============================
--- ===============================
-- ======= 2/ Module State =======
--- ===============================
-- ===============================

--- Shared CoreState (set by M.init).
local _state = nil

--- Device identity, read from / written to device.json.
local _device_id  = nil
local _device_obj = nil

--- Resolved paths (filled by `_resolve_paths`).
local _paths = {}

--- Background ingest timer.
local _ingest_timer = nil

--- Whether `_uuid_v4` has seeded math.randomseed.
local _uuid_seeded = false




-- ============================================
--- ==================================
-- ======= 3/ Private Helpers =======
--- ==================================
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

--- Generates a UUID v4 (RFC 4122).
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

--- Returns the macOS hardware UUID (KEYLOGGER_SPEC §16.1).
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
--- ==================================
-- ======= 4/ Path Resolution =======
--- ==================================
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

	local by_dev  = md .. "by_device/" .. device_id .. "/"
	local tmp_dir = _resolve_tmpdir() .. "ergopti_metrics/" .. device_id .. "/"

	_paths = {
		metrics_dir      = md,
		by_device_dir    = by_dev,
		device_json_path = by_dev .. "device.json",
		data_sql_path    = by_dev .. "data.sql",
		today_log_path   = by_dev .. "today.log",
		tmpdir_dir       = tmp_dir,
		sqlite_path      = tmp_dir .. "db.sqlite",
	}
end




-- ============================================
--- ==================================
-- ======= 5/ Device Identity =======
--- ==================================
-- ============================================

--- Loads `device.json` for the current host. Reuses an existing UUID if the
--- host_signature matches; otherwise generates a new UUID. KEYLOGGER_SPEC §16.1.
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




-- ==============================================================
--- ==============================================================
-- ======= 6/ Public log_* event entry points (delegates) =======
--- ==============================================================
-- ==============================================================

--- Append a single event entry to today.log as a JSONL line.
--- Delegates to Rotation.append_log (hot path — no SQLite).
--- @param entry table The event entry. Must contain a `type` field.
function M.append_log(entry)
	Rotation.append_log(entry)
end

--- Serialize the keystroke buffer accumulated in CoreState into a
--- typing event and append it to today.log. Resets per-flush buffers.
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
	local wpm = Metrics.compute_wpm_from_events(total_chars, total_time_ms)

	-- Build a rich-text representation from rich_chunks.
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

function M.log_app_switch(prev_app, next_app, duration_ms)
	if not _require_state("log_app_switch") then return end
	M.append_log({ type = "app_switch", prev_app = prev_app, next_app = next_app, duration_ms = duration_ms })
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
		type = "shortcut", key = shortcut_key,
		app  = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown",
	})
end

function M.log_modifier_press(keycode, app_name)
	if not _require_state("log_modifier_press") then return end
	M.append_log({ type = "system_event", action = "modifier_press", keycode = keycode, app = app_name })
end

function M.log_modifier_hold(keycode, app_name, hold_ms)
	if not _require_state("log_modifier_hold") then return end
	M.append_log({ type = "system_event", action = "modifier_hold", keycode = keycode, app = app_name, hold_ms = hold_ms })
end

function M.log_karabiner_press(keycode, app_name)
	if not _require_state("log_karabiner_press") then return end
	M.append_log({ type = "system_event", action = "karabiner_press", keycode = keycode, app = app_name })
end

function M.log_karabiner_release(keycode, app_name, hold_ms)
	if not _require_state("log_karabiner_release") then return end
	M.append_log({ type = "system_event", action = "karabiner_release", keycode = keycode, app = app_name, hold_ms = hold_ms })
end

function M.log_passive_period(kind, duration_ms)
	if not _require_state("log_passive_period") then return end
	M.append_log({ type = "system_event", action = "passive_period", kind = kind, duration_ms = duration_ms })
end

function M.tag_awake_focus(app_name, duration_ms)
	if not _require_state("tag_awake_focus") then return end
	M.append_log({ type = "system_event", action = "awake_focus", app = app_name, duration_ms = duration_ms })
end

function M.log_focus_first_key(app_name, latency_ms)
	if not _require_state("log_focus_first_key") then return end
	M.append_log({ type = "system_event", action = "focus_first_key", app = app_name, latency_ms = latency_ms })
end

function M.increment_manifest_stat(app_name, stat_key, amount)
	if not _require_state("increment_manifest_stat") then return end
	M.append_log({ type = "system_event", action = "manifest_increment", app = app_name, stat = stat_key, amount = tonumber(amount) or 1 })
end




-- =============================================================
-- =============================================================
-- ======= 7/ Export delegate accessors (thin wrappers) =======
-- =============================================================
-- =============================================================

--- Delegates to Export.get_native_app_category.
function M.get_native_app_category(app_name)
	return Export.get_native_app_category(app_name)
end

--- Delegates to Export.get_device_short_id.
function M.get_device_short_id()
	return Export.get_device_short_id()
end

--- Delegates to Export.get_sqlite_path.
function M.get_sqlite_path()
	return Export.get_sqlite_path()
end

--- Delegates to Export.get_db_rev.
function M.get_db_rev()
	return Export.get_db_rev()
end




-- ========================================
--- ===========================================
-- ======= 8/ Ingest Tick Orchestrator =======
--- ===========================================
-- ========================================

--- Helper to safely SQL-escape a string.
local function _sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- Run one ingest cycle: pull new today.log entries, append SQL batch to
--- data.sql, apply it to db.sqlite, update aggregate tables.
function M.ingest_once()
	local db = SqliteWriter.get_db()
	if not db then return end

	pcall(Export.sync_foreign_data_sql)

	local entries, new_offset = Rotation.read_new_entries()
	if #entries == 0 then return end

	local statements = {}
	for _, item in ipairs(entries) do
		for _, sql in ipairs(SqliteWriter.build_inserts(item.entry)) do
			table.insert(statements, sql)
		end
	end
	if #statements == 0 then
		Rotation.set_offset(new_offset, Rotation.get_date())
		return
	end

	local batch_text = string.format(
		"\n-- === ingest batch %s (offset %d -> %d, %d entry(ies)) ===\nBEGIN TRANSACTION;\n%s\nCOMMIT;\n",
		_now_ts(), Rotation.get_offset(), new_offset, #entries,
		table.concat(statements, "\n"))

	local f, err = io.open(_paths.data_sql_path, "a")
	if not f then
		Logger.error(LOG, "Cannot append to data.sql at %s: %s.",
			_paths.data_sql_path, tostring(err))
		return
	end
	f:write(batch_text); f:close()

	local ok, exec_err = pcall(function()
		db:exec("BEGIN TRANSACTION;")
		for _, sql in ipairs(statements) do
			local rc = db:exec(sql)
			if rc ~= sqlite3.OK then
				error("exec failed: " .. (db:errmsg() or "?"))
			end
		end
		for _, item in ipairs(entries) do
			local et = item.entry.type
			if et == "typing" then
				Aggregator.walk_typing(item.entry)
			elseif et == "app_switch" then
				Aggregator.walk_app_switch(item.entry)
			elseif et == "window_switch" then
				Aggregator.walk_window_switch(item.entry)
			elseif et == "system_event" then
				Aggregator.walk_system_event(item.entry)
			end
		end
		Aggregator.flush()
		db:exec(string.format(
			"UPDATE meta SET value='%d' WHERE key='today_log_offset';", new_offset))
		db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", Rotation.get_date() or ""))
		SqliteWriter.persist_next_event_id()
		db:exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';")
		-- Serialise n-gram walking context so a crash mid-tick does not lose
		-- the partial cur_word / p1..p6 / current_burst / streak state.
		local ctx = Aggregator.get_ngram_ctx()
		local ok_enc, enc = pcall(json.encode, ctx or {})
		if ok_enc then
			db:exec(string.format(
				"UPDATE meta SET value=%s WHERE key='ngram_ctx_json';",
				_sq(enc)))
		end
		db:exec("COMMIT;")
	end)
	if not ok then
		Logger.error(LOG, "Ingest batch rolled back: %s.", tostring(exec_err))
		pcall(function() db:exec("ROLLBACK;") end)
		return
	end

	Rotation.set_offset(new_offset, Rotation.get_date())
	Logger.debug(LOG, "Ingest cycle: %d entry(ies), offset now %d.", #entries, new_offset)
end

--- Day rollover handler. Drains remaining today.log then delegates to
--- Rotation.rollover to reset the file and offset.
function M.day_rollover()
	if not _require_state("day_rollover") then return end
	pcall(M.ingest_once)
	Rotation.rollover(_paths.data_sql_path)
	Aggregator.reset_ngram_ctx()
	local db = SqliteWriter.get_db()
	if db then
		db:exec("UPDATE meta SET value='0' WHERE key='today_log_offset';")
		db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", Rotation.get_date() or ""))
		db:exec("UPDATE meta SET value='{}' WHERE key='ngram_ctx_json';")
	end
end




-- ===============================
--- ============================
-- ======= 9/ Lifecycle =======
--- ============================
-- ===============================

--- Initialize the log manager. Resolves the device, opens the SQLite cache,
--- creates the filesystem layout. Idempotent; calling twice is a warning.
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

	_device_obj = _resolve_device(_state.LOG_DIR)
	_device_id  = _device_obj.device_id
	_resolve_paths(_state.LOG_DIR, _device_id)

	_mkdir_p(_paths.metrics_dir)
	_mkdir_p(_paths.by_device_dir)
	_mkdir_p(_paths.tmpdir_dir)

	_write_device_json(_device_obj)

	-- Initialise submodules.
	SqliteWriter.init({ paths = _paths, device_obj = _device_obj, device_id = _device_id })
	Aggregator.init({ device_id = _device_id })

	if not SqliteWriter.open_db() then
		Logger.error(LOG, "Cannot open db.sqlite — log manager will only write JSONL.")
	else
		-- Restore persisted counters and n-gram context from meta.
		local db = SqliteWriter.get_db()
		if db then
			local offset_val = 0
			local date_val   = nil
			for r in db:nrows("SELECT value FROM meta WHERE key='today_log_offset'") do
				offset_val = tonumber(r.value) or 0
			end
			for r in db:nrows("SELECT value FROM meta WHERE key='today_log_date'") do
				date_val = (type(r.value) == "string" and r.value ~= "") and r.value or nil
			end
			Rotation.init({ paths = _paths, state = _state, today_log_offset = offset_val, today_log_date = date_val })
			for r in db:nrows("SELECT value FROM meta WHERE key='ngram_ctx_json'") do
				local ok, decoded = pcall(json.decode, r.value or "{}")
				if ok and type(decoded) == "table" then
					Aggregator.set_ngram_ctx(decoded)
				end
			end
		end
	end

	-- Fallback init for Rotation when the DB path above didn't run.
	if not Rotation.get_offset then
		Rotation.init({ paths = _paths, state = _state })
	end

	Export.init({ paths = _paths, device_id = _device_id, get_db = SqliteWriter.get_db })

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

	_state.today_idx = _state.today_idx or {}
	_state.manifest  = _state.manifest  or {}

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
	SqliteWriter.close_db()
	Logger.debug(LOG, "Log manager stopped")
end




-- ============================================================
--- ============================================================
-- ======= 10/ Compatibility shims for the in-flight UI =======
--- ============================================================
-- ============================================================

--- Legacy compatibility stubs — no-ops so loading the old UI does not crash.

function M.aggregate_events(_events, _app_name, _date_str) return end
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
function M.get_mac_serial() return "" end
function M.process_files_async(_files, _is_encrypt, _password, _on_progress, on_complete)
	if type(on_complete) == "function" then pcall(on_complete, false) end
end
function M.register_encryptor_app() end

return M

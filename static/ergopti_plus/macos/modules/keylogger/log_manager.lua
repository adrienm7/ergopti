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
local text_utils = require("infra.text_utils")
local json    = require("hs.json")
local sqlite3 = require("hs.sqlite3")
local timer   = require("hs.timer")

local Logger  = require("infra.logger")
local Timings = require("infra.timings")
local i18n    = require("infra.i18n")  -- kept for MAC_CATEGORIES_FR still used by export
local FileSystem = require("adapters.file_system")
local TimerScheduler = require("adapters.timer_scheduler")
local LOG     = "keylogger.log_manager"

local SqliteWriter = require("modules.keylogger.sqlite_writer")
local Aggregator   = require("modules.keylogger.aggregator")
local Rotation     = require("modules.keylogger.rotation")
local Export       = require("modules.keylogger.export")
local Metrics      = require("keylogger.metrics")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Background ingest tick period (KEYLOGGER_SPEC §4). Shared cross-driver value
--- ([keylogger] ingest_tick_ms).
local INGEST_TICK_SEC = Timings.sec("keylogger", "ingest_tick_ms")

--- Cap on the per-event delay credited to WPM calculation. Shared cross-driver
--- value ([keylogger] max_keystroke_delay_ms).
local WPM_MAX_EVENT_DELAY_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")

--- Maximum drain iterations during day_rollover. At 5000 lines/batch this
--- covers 100 000 lines before giving up and preserving the file.
local MAX_ROLLOVER_DRAIN_ITERS = 20





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

--- Background ingest timer.
local _ingest_timer = nil
local _ingest_timer_committed = false

--- A failed initialization retains this flag until every partially acquired
--- timer/database has been released. No later init may publish over that debt.
local _init_cleanup_pending = false

--- Last foreign-sync failure already surfaced by the log-manager boundary.
--- Repeated ingest ticks retain the retry without alternating two ERROR lines
--- with infra.fs_dir's own diagnostic; a changed failure is reported again.
local _foreign_sync_error_key = nil

--- Registered post-ingest listeners — called after every successful ingest cycle.
--- Each entry is a function(); errors are swallowed so one broken listener cannot
--- prevent the others from firing. Register via M.on_ingest_done().
local _ingest_listeners = {}

--- Whether `_uuid_v4` has seeded math.randomseed.
local _uuid_seeded = false

--- Ordered outbox used when an eventtap must detach a typing run without doing
--- any serialization or file I/O. Once this queue is non-empty, later
--- append_log() calls join it so they cannot overtake the detached run.
local _deferred_log_queue = {}
local _deferred_log_head  = 1
local _deferred_log_tail  = 0
local _deferred_log_timer = nil

--- Retry delay after a timer-allocation or sink failure. The ingest timer also
--- retries the queue, so a one-shot scheduling failure cannot strand it.
local DEFERRED_LOG_RETRY_SEC = 0.1





-- ==================================
-- ==================================
-- ======= 3/ Private Helpers =======
-- ==================================
-- ==================================

--- Guards every public function against being called before M.init().
local function _require_state(func_name)
	if not _state then
		-- Early boot events (wake, lock, etc.) can trigger calls before the
		-- engine has finished its M.init() handshake. We ignore them quietly
		-- at DEBUG level rather than emitting a scary ERROR.
		Logger.debug(LOG, "'%s' called before M.init() — ignoring early boot event.", func_name)
		return false
	end
	return true
end

--- Returns a "%Y-%m-%d HH:MM:SS.mmm" timestamp string (local time).
-- Single-sourced in modules/keylogger/timestamp.lua so the seconds and the .mmm
-- fraction share one wall clock (F-L1).
local Timestamp = require("modules.keylogger.timestamp")
local _now_ts = Timestamp.now_ts

--- Returns today's "YYYY-MM-DD" string.
local function _today()
	return os.date("%Y-%m-%d")
end

--- mkdir -p equivalent.
local function _mkdir_p(path)
	pcall(hs.execute, "mkdir -p " .. text_utils.shell_quote(path))
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





-- ==================================
-- ==================================
-- ======= 4/ Path Resolution =======
-- ==================================
-- ==================================

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
--- @return table Resolved path bundle. The caller publishes it only after the
--- device identity transaction commits.
local function _resolve_paths(metrics_dir, device_id)
	local md = metrics_dir
	if not md:match("[/\\]$") then md = md .. "/" end

	local by_dev  = md .. "by_device/" .. device_id .. "/"
	local tmp_dir = _resolve_tmpdir() .. "ergopti_metrics/" .. device_id .. "/"

	return {
		metrics_dir      = md,
		by_device_dir    = by_dev,
		device_json_path = by_dev .. "device.json",
		data_sql_path    = by_dev .. "data.sql",
		today_log_path   = by_dev .. "today.log",
		tmpdir_dir       = tmp_dir,
		sqlite_path      = tmp_dir .. "db.sqlite",
	}
end





-- ==================================
-- ==================================
-- ======= 5/ Device Identity =======
-- ==================================
-- ==================================

--- Loads `device.json` for the current host. Reuses an existing UUID if the
--- host_signature matches; otherwise generates a new UUID only after every
--- existing candidate was read and decoded successfully. KEYLOGGER_SPEC §16.1.
--- @param metrics_dir string The metrics root.
--- @return table|nil device The fully populated device object, or nil when the
--- identity scan did not commit.
--- @return boolean needs_publication True only for a newly generated identity.
local function _resolve_device(metrics_dir)
	local md = metrics_dir
	if not md:match("[/\\]$") then md = md .. "/" end
	local by_root = md .. "by_device/"
	_mkdir_p(by_root)

	local current_host = _host_signature()
	local dir_ok, iterator, dir_state = pcall(fs.dir, by_root)
	if not dir_ok or type(iterator) ~= "function" then
		Logger.error(LOG, "Cannot enumerate existing device identities; initialization refused.")
		return nil
	end

	local scan_ok, matching_device, unresolved_candidate = pcall(function()
		local unresolved = false
		for entry in iterator, dir_state do
			if entry ~= "." and entry ~= ".." then
				local candidate_dir = by_root .. entry
				local djpath = candidate_dir .. "/device.json"
				local raw, read_status = FileSystem.read_with_status(djpath)
				if read_status ~= "absent" then
					if read_status ~= "ok" or type(raw) ~= "string" then
						unresolved = true
					else
						local decode_ok, obj = pcall(json.decode, raw)
						local valid = decode_ok and type(obj) == "table"
							and type(obj.device_id) == "string" and obj.device_id ~= ""
							and type(obj.host_signature) == "string" and obj.host_signature ~= ""
						if not valid then
							unresolved = true
						elseif obj.host_signature == current_host then
							return obj, false
						end
					end
				end
			end
		end
		return nil, unresolved
	end)

	if not scan_ok then
		Logger.error(LOG, "Existing device identity scan failed; initialization refused.")
		return nil
	end
	if matching_device then return matching_device, false end
	if unresolved_candidate then
		Logger.error(LOG, "An existing device identity could not be owned; initialization refused.")
		return nil
	end

	return {
		device_id      = _uuid_v4(),
		name           = (hs.host and hs.host.localizedName and hs.host.localizedName()) or "Mac",
		os             = "darwin",
		os_version     = (hs.host and hs.host.operatingSystemVersionString and hs.host.operatingSystemVersionString()) or "",
		host_signature = current_host,
		created_at     = _now_ts(),
		schema_version = 1,
	}, true
end

--- Publishes a new device identity without replacing a concurrent winner.
--- @return boolean committed
--- @return table|nil published_device Exact created/adopted device object.
local function _write_device_json(obj, device_json_path)
	local encode_ok, encoded = pcall(json.encode, obj)
	if not encode_ok or type(encoded) ~= "string" then
		Logger.error(LOG, "Cannot encode device identity; initialization refused.")
		return false
	end

	-- A generated identity is derived from proven absence. Replacing an entry
	-- that appeared after the scan would steal another process's identity.
	local write_ok, created, create_status = pcall(
		FileSystem.create_if_absent,
		device_json_path,
		encoded
	)
	if not write_ok then
		Logger.error(LOG, "Device identity publication did not commit; initialization refused.")
		return false, nil
	end
	if created == true and create_status == "created" then return true, obj end
	if create_status ~= "exists" then
		Logger.error(LOG, "Device identity publication did not commit; initialization refused.")
		return false, nil
	end

	-- Another initializer won the same create-only target. Adopt only an exact,
	-- internally consistent identity for this host and directory; every other
	-- outcome is ambiguous and therefore fails closed.
	local read_ok, raw, read_status = pcall(FileSystem.read_with_status, device_json_path)
	if not read_ok or read_status ~= "ok" or type(raw) ~= "string" then
		Logger.error(LOG, "Concurrent device identity could not be owned; initialization refused.")
		return false, nil
	end
	local decode_ok, winner = pcall(json.decode, raw)
	local valid = decode_ok and type(winner) == "table"
		and type(winner.device_id) == "string" and winner.device_id == obj.device_id
		and type(winner.host_signature) == "string"
		and winner.host_signature == obj.host_signature
	if not valid then
		Logger.error(LOG, "Concurrent device identity was inconsistent; initialization refused.")
		return false, nil
	end
	Logger.info(LOG, "Adopted the concurrently published device identity.")
	return true, winner
end





-- ==============================================================
-- ==============================================================
-- ======= 6/ Public log_* event entry points (delegates) =======
-- ==============================================================
-- ==============================================================

local _drain_deferred_logs


--- Returns whether the ordered deferred outbox contains any work.
--- @return boolean
local function _has_deferred_logs()
	return _deferred_log_head <= _deferred_log_tail
end


--- Appends one operation to the in-memory ordered outbox.
--- @param operation table Ordered entry, typing snapshot, or deferred builder.
local function _queue_deferred_log(operation)
	_deferred_log_tail = _deferred_log_tail + 1
	_deferred_log_queue[_deferred_log_tail] = operation
end


--- Schedules the outbox drain on the next run-loop turn.
--- The shared scheduler publishes the exact unstarted native candidate before
--- activation. If start raises after activation and rollback refuses, that
--- candidate remains the only owner and blocks every sibling drain timer until
--- teardown can retry its cleanup.
--- @param delay number|nil Delay in seconds (zero for the initial drain).
--- @return boolean scheduled
local function _schedule_deferred_log_drain(delay)
	if not _has_deferred_logs() then return true end
	if _deferred_log_timer ~= nil then
		return _deferred_log_timer.committed == true
	end

	-- Forward-declare before the closure: declaring this local below the closure
	-- would bind the callback to a nil global instead of the scheduler handle.
	local scheduled_handle
	local committed
	scheduled_handle, committed = TimerScheduler.after(delay or 0, function()
		-- TimerScheduler fences repeat delivery before invoking us. Clear the
		-- scheduling gate only when its exact native cleanup actually settled.
		if _deferred_log_timer == scheduled_handle
			and scheduled_handle.timer == nil then
			_deferred_log_timer = nil
		end
		local drained_ok, drain_err = xpcall(_drain_deferred_logs, debug.traceback)
		if not drained_ok then
			Logger.error(LOG, "Deferred keylogger drain failed: %s.", tostring(drain_err))
		end
		if _has_deferred_logs() then
			_schedule_deferred_log_drain(DEFERRED_LOG_RETRY_SEC)
		end
	end)

	-- A failed acquisition can still own a live candidate when native start
	-- activated and then raised while rollback refused. Retain that exact debt;
	-- otherwise discard the settled wrapper so a later ingest/action may retry.
	if scheduled_handle and scheduled_handle.timer ~= nil then
		_deferred_log_timer = scheduled_handle
	end
	if committed ~= true then
		if not scheduled_handle or scheduled_handle.timer == nil then
			_deferred_log_timer = nil
		end
		Logger.error(LOG, "Cannot schedule deferred keylogger drain transactionally.")
		return false
	end
	_deferred_log_timer = scheduled_handle
	return true
end


--- Captures the scalar context shared by physical and synthetic typing records.
--- The epoch stays numeric here so timestamp formatting remains outside input
--- callbacks with the rest of the deferred typing-entry construction.
--- @return table snapshot
local function _capture_typing_context(timestamp_epoch)
	return {
		timestamp_epoch       = timestamp_epoch or Timestamp.now_epoch(),
		session_app_name      = _state.session_app_name,
		session_win_title     = _state.session_win_title,
		session_url           = _state.session_url,
		session_field_role    = _state.session_field_role,
		session_layout        = _state.session_layout,
		session_document_path = _state.session_document_path,
		is_fullscreen         = _state.is_fullscreen,
		in_meeting            = _state.in_meeting,
		session_mouse_clicks  = _state.session_mouse_clicks,
		session_mouse_scrolls = _state.session_mouse_scrolls,
		mouse_distance_px     = _state.mouse_distance_px,
		current_session_pause = _state.current_session_pause,
		current_battery_level = _state.current_battery_level,
		current_audio_volume  = _state.current_audio_volume,
	}
end


--- Detaches the current mutable typing run in O(1).
--- No loop, JSON encoding, SQLite access, or file append is allowed here: this
--- function is the action-epoch backstop reached from the keyboard eventtap.
--- @return table|nil snapshot
local function _detach_buffer_snapshot()
	if #_state.buffer_events == 0
		and _state.session_mouse_clicks == 0
		and _state.session_mouse_scrolls == 0 then
		return nil
	end

	local captured_epoch = type(_state.buffer_started_epoch) == "number"
		and _state.buffer_started_epoch or nil
	local snapshot = _capture_typing_context(captured_epoch)
	snapshot.buffer_events = _state.buffer_events
	snapshot.buffer_text = _state.buffer_text
	snapshot.rich_chunks = _state.rich_chunks or {}

	_state.buffer_events         = {}
	_state.buffer_text           = ""
	_state.rich_chunks           = {}
	_state.buffer_started_epoch  = nil
	_state.last_time             = 0
	_state.session_mouse_clicks  = 0
	_state.session_mouse_scrolls = 0
	_state.mouse_distance_px     = 0
	_state.last_flush_time       = hs.timer.absoluteTime() / 1000000
	return snapshot
end


--- Converts an immutable detached snapshot into its persisted typing entry.
--- @param snapshot table Snapshot returned by _detach_buffer_snapshot().
--- @return table entry
local function _typing_entry_from_snapshot(snapshot)
	local total_time_ms, total_chars = 0, 0
	for _, ev in ipairs(snapshot.buffer_events) do
		local meta = ev[3] or {}
		if not meta.s then
			local d = math.min(ev[2] or 0, WPM_MAX_EVENT_DELAY_MS)
			total_time_ms = total_time_ms + d
			total_chars   = total_chars + 1
		end
	end
	local wpm = Metrics.compute_wpm_from_events(total_chars, total_time_ms)

	local rich_str, cur_type, cur_text = "", nil, ""
	local function flush_chunk()
		if not cur_type then return end
		if cur_type == "text" then
			rich_str = rich_str .. cur_text
		elseif cur_type == "correction" then
			rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
		else
			rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">"
				.. cur_text .. "</autocomplete>"
		end
	end
	for _, chunk in ipairs(snapshot.rich_chunks) do
		if chunk.type == cur_type then
			cur_text = cur_text .. chunk.text
		else
			flush_chunk()
			cur_type = chunk.type
			cur_text = chunk.text
		end
	end
	flush_chunk()

	return {
		type              = "typing",
		timestamp         = Timestamp.format_epoch(snapshot.timestamp_epoch),
		text              = snapshot.buffer_text,
		rich_text         = rich_str,
		app               = snapshot.session_app_name,
		title             = snapshot.session_win_title,
		url               = snapshot.session_url,
		field_role        = snapshot.session_field_role,
		layout            = snapshot.session_layout,
		document_path     = snapshot.session_document_path,
		is_fullscreen     = snapshot.is_fullscreen,
		in_meeting        = snapshot.in_meeting,
		mouse_clicks      = snapshot.session_mouse_clicks,
		mouse_scrolls     = snapshot.session_mouse_scrolls,
		mouse_distance_px = math.floor(snapshot.mouse_distance_px or 0),
		pause_before_ms   = snapshot.current_session_pause,
		battery_level     = snapshot.current_battery_level,
		audio_volume      = snapshot.current_audio_volume,
		wpm               = tonumber(string.format("%.1f", wpm)),
		events            = snapshot.buffer_events,
	}
end


--- Drains queued operations in strict insertion order.
--- The head advances only after Rotation returns exact true, so either a thrown
--- or non-throwing filesystem refusal leaves the exact item available for retry.
--- @return boolean drained Whether the queue is now empty.
_drain_deferred_logs = function()
	while _has_deferred_logs() do
		local operation = assert(_deferred_log_queue[_deferred_log_head],
			"keylogger deferred-log queue is sparse")
		local is_builder = operation.kind == "typing_builder"
			or operation.kind == "entry_builder"
		if is_builder and operation.prepared ~= true then
			local build_ok, built_or_err = xpcall(operation.build, debug.traceback)
			local valid_typing = operation.kind ~= "typing_builder"
				or (type(built_or_err) == "table"
					and type(built_or_err.buffer_events) == "table"
					and type(built_or_err.rich_chunks) == "table")
			if not build_ok or type(built_or_err) ~= "table" or not valid_typing then
				Logger.error(LOG, "Cannot prepare deferred keylogger entry: %s.",
					tostring(build_ok and "builder returned an invalid snapshot" or built_or_err))
				return false
			end
			if operation.kind == "typing_builder" then
				operation.value.buffer_events = built_or_err.buffer_events
				operation.value.buffer_text = type(built_or_err.buffer_text) == "string"
					and built_or_err.buffer_text or ""
				operation.value.rich_chunks = built_or_err.rich_chunks
			else
				operation.value = built_or_err
			end
			operation.prepared = true
			operation.build = nil
		end
		local entry = (operation.kind == "entry" or operation.kind == "entry_builder")
			and operation.value
			or _typing_entry_from_snapshot(operation.value)
		local ok, accepted_or_err = xpcall(function()
			return Rotation.append_log(entry)
		end, debug.traceback)
		if not ok or accepted_or_err ~= true then
			Logger.error(LOG, "Cannot append deferred keylogger entry: %s.",
				tostring(accepted_or_err))
			return false
		end
		_deferred_log_queue[_deferred_log_head] = nil
		_deferred_log_head = _deferred_log_head + 1
	end
	_deferred_log_head = 1
	_deferred_log_tail = 0
	return true
end


--- Append a single event entry to today.log as a JSONL line.
--- The FIFO owns the entry before this function returns; persistence occurs only
--- from the retained drain after an eventtap callback has returned.
--- @param entry table The event entry. Must contain a `type` field.
--- @return boolean accepted True once the ordered outbox owns the entry.
function M.append_log(entry)
	_queue_deferred_log({ kind = "entry", value = entry })
	-- Queue insertion is the acceptance boundary. Persistence never runs in the
	-- caller because append_log is reached from keyboard and mouse eventtaps.
	-- The ingest tick and stop path independently retry accepted work if timer
	-- allocation is temporarily unavailable.
	_schedule_deferred_log_drain(0)
	return true
end

--- Defers construction and persistence of one non-typing entry.
--- @param builder function Zero-argument function returning an entry table.
--- @return boolean accepted True once the ordered outbox owns the builder.
function M.defer_entry_builder(builder)
	if not _require_state("defer_entry_builder") then return false end
	if type(builder) ~= "function" then
		Logger.error(LOG, "defer_entry_builder(): builder must be a function.")
		return false
	end
	_queue_deferred_log({
		kind = "entry_builder",
		build = builder,
		prepared = false,
	})
	_schedule_deferred_log_drain(0)
	return true
end

--- Detaches the keystroke buffer accumulated in CoreState and queues it for
--- serialization and persistence after the caller returns.
--- @return boolean|nil accepted True after detachment, nil when empty or uninitialized.
function M.flush_buffer()
	if not _require_state("flush_buffer") then return end
	local snapshot = _detach_buffer_snapshot()
	if not snapshot then return end
	_queue_deferred_log({ kind = "typing_snapshot", value = snapshot })
	_schedule_deferred_log_drain(0)
	return true
end

--- Captures typing context now and defers an expensive snapshot builder.
--- The builder runs at most once after the originating eventtap has returned;
--- an append refusal retries the already-prepared immutable snapshot.
--- @param builder function Zero-argument function returning buffer_events,
--- rich_chunks, and optional buffer_text fields.
--- @return boolean accepted True once the ordered outbox owns the builder.
function M.defer_typing_builder(builder)
	if not _require_state("defer_typing_builder") then return false end
	if type(builder) ~= "function" then
		Logger.error(LOG, "defer_typing_builder(): builder must be a function.")
		return false
	end
	_queue_deferred_log({
		kind = "typing_builder",
		value = _capture_typing_context(),
		build = builder,
		prepared = false,
	})
	_schedule_deferred_log_drain(0)
	return true
end

--- Detaches the current typing buffer and queues it for a post-eventtap drain.
--- This is the only flush primitive allowed in an eventtap action-epoch
--- backstop. It performs O(1) table swaps and never calls the persistence sink.
--- @return boolean accepted False only when no initialized outbox can accept work.
function M.defer_flush_buffer()
	if not _require_state("defer_flush_buffer") then return false end
	local snapshot = _detach_buffer_snapshot()
	if snapshot then
		_queue_deferred_log({ kind = "typing_snapshot", value = snapshot })
	end
	if not _has_deferred_logs() then return true end
	-- The snapshot is already owned by the FIFO; reporting the scheduling result
	-- as acceptance made the epoch listener retry the completed detach and abort
	-- every later physical key when timer allocation stayed unavailable
	_schedule_deferred_log_drain(0)
	return true
end

---@param prev_app string
---@param next_app string|nil nil closes an interval without adding a switch edge.
---@param duration_ms number
---@param timestamp string|nil Optional timestamp for a midnight split.
function M.log_app_switch(prev_app, next_app, duration_ms, timestamp)
	if not _require_state("log_app_switch") then return end
	M.append_log({
		type = "app_switch", prev_app = prev_app, next_app = next_app,
		duration_ms = duration_ms, timestamp = timestamp,
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





-- ============================================================
-- ============================================================
-- ======= 7/ Export delegate accessors (thin wrappers) =======
-- ============================================================
-- ============================================================

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

--- Register a callback to be called after every successful ingest cycle.
--- The callback receives no arguments; use M.get_db_rev() to read the new rev.
--- Errors inside the callback are swallowed.
---@param fn function The listener to register.
---@return boolean registered True only after the listener is owned.
function M.on_ingest_done(fn)
	assert(type(fn) == "function", "on_ingest_done requires a callback")
	table.insert(_ingest_listeners, fn)
	return true
end

local function _notify_ingest_listeners()
	for _, fn in ipairs(_ingest_listeners) do
		pcall(fn)
	end
end





-- ===========================================
-- ===========================================
-- ======= 8/ Ingest Tick Orchestrator =======
-- ===========================================
-- ===========================================

--- Helper to safely SQL-escape a string.
local function _sq(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- Require an exact SQLite success code inside a transaction.
--- lsqlite3 reports lock and I/O failures as return codes, not Lua errors, so a
--- surrounding pcall is not a commit verdict by itself.
--- @param db userdata|table SQLite handle.
--- @param sql string Statement to execute.
--- @param action string Stable diagnostic describing the intended mutation.
local function _exec_sqlite_or_error(db, sql, action)
	local rc = db:exec(sql)
	if rc == sqlite3.OK then return end
	local detail = db:errmsg() or ("SQLite result " .. tostring(rc))
	error(action .. ": " .. tostring(detail), 0)
end

--- Attempt a transaction rollback and keep a native refusal visible.
--- @param db userdata|table SQLite handle.
--- @param action string Transaction label for diagnostics.
--- @return boolean True only when SQLite accepted the rollback.
local function _rollback_sqlite(db, action)
	local ok, rc_or_error = pcall(function() return db:exec("ROLLBACK;") end)
	if ok and rc_or_error == sqlite3.OK then return true end
	local detail = ok and (db:errmsg() or ("SQLite result " .. tostring(rc_or_error)))
		or rc_or_error
	Logger.error(LOG, "%s rollback failed: %s.", action, tostring(detail))
	return false
end

local DATA_SQL_OUTBOX_KEY = "local_data_sql_outbox"
local REPLAY_FLUSH_EVENT_COUNT = 500
local AGGREGATE_CACHE_REVISION = "1"
-- Every table written by aggregator/sql.lua.  Replaying a device's canonical
-- raw rows is additive, so its old derived partition must be cleared first.
local DERIVED_DEVICE_TABLES = {
	"agg_app_day", "agg_app_day_buckets", "agg_app_day_burst", "agg_app_day_session",
	"agg_app_day_chars_class", "agg_app_day_errors", "agg_app_day_ergo",
	"agg_app_day_layouts", "agg_app_day_kc_hold", "agg_app_day_titles",
	"agg_app_day_hourly", "agg_app_day_hourly_min5", "agg_app_day_switches_to",
	"agg_system_day",
	"ngram_chars", "ngram_bigrams", "ngram_trigrams", "ngram_quadgrams",
	"ngram_pentagrams", "ngram_hexagrams", "ngram_heptagrams", "ngram_words",
	"ngram_word_bigrams", "ngram_shortcuts", "ngram_shortcut_bigrams",
	"ngram_keycodes", "ngram_scancodes",
}

--- Returns the byte offset through the last complete transaction in a ledger.
--- A torn append may end after BEGIN TRANSACTION; applying that suffix would
--- leave the recovered cache in a transaction and poison the first live ingest.
---@param ledger string
---@return integer
local function _last_complete_ledger_offset(ledger)
	return Export._last_complete_batch_offset(ledger)
end

--- Derive the current today.log cursor from durable local ledger comments.
--- data.sql records byte offsets for every successful ingest batch. Reusing the
--- most recent offset after a tmp-cache loss prevents already-ledgered JSONL
--- lines from being assigned fresh ids and counted a second time at next boot.
---@param ledger string
---@param complete_offset integer
---@return table { offset: integer, date: string|nil }
local function _local_ledger_replay_cursor(ledger, complete_offset)
	local full_ledger = ledger or ""
	local safe_ledger = full_ledger:sub(1, complete_offset or 0)
	-- Day-rollover markers are deliberately written after the final transaction
	-- (they are comments, not SQL statements). Preserve a complete trailing
	-- marker so a newly-created today.log resumes at byte 0; reject any suffix
	-- containing a partial BEGIN/INSERT batch, which is not yet durable.
	local trailing = full_ledger:sub((complete_offset or 0) + 1)
	if trailing:match("^%s*%-%- === day rollover .- %-%> %d%d%d%d%-%d%d%-%d%d ===%s*$") then
		safe_ledger = safe_ledger .. trailing
	end
	local offset, date, segment_start = 0, nil, 1
	local pos = 1
	while true do
		local _, e, next_date = safe_ledger:find(
			"%-%- === day rollover .- %-%> (%d%d%d%d%-%d%d%-%d%d) ===", pos)
		if not e then break end
		date = next_date
		segment_start = e + 1
		pos = e + 1
	end

	pos = segment_start
	while true do
		local _, e, batch_ts, _, batch_end = safe_ledger:find(
			"%-%- === ingest batch ([^%(]-) %(offset (%d+) %-%> (%d+),", pos)
		if not e then break end
		offset = tonumber(batch_end) or offset
		if not date then date = batch_ts:match("(%d%d%d%d%-%d%d%-%d%d)") end
		pos = e + 1
	end
	return { offset = offset, date = date }
end

-- Test seam for the restart/deduplication invariant above.
M._local_ledger_replay_cursor = _local_ledger_replay_cursor

--- Apply the durable portion of this device's ledger to a newly-created cache.
---@param db userdata
---@return boolean, table
local function _replay_local_data_sql(db)
	local empty_cursor = { offset = 0, date = nil }
	local attrs = fs.attributes(_paths.data_sql_path)
	if not attrs or (attrs.size or 0) == 0 then return true, empty_cursor end
	local ledger = FileSystem.read(_paths.data_sql_path)
	if type(ledger) ~= "string" then
		Logger.error(LOG, "Cannot read local data.sql at %s for cache recovery.", _paths.data_sql_path)
		return false, empty_cursor
	end
	local complete_offset = _last_complete_ledger_offset(ledger)
	local cursor = _local_ledger_replay_cursor(ledger, complete_offset)
	if complete_offset == 0 then return true, cursor end

	local rc = db:exec(ledger:sub(1, complete_offset))
	if rc ~= sqlite3.OK then
		pcall(function() db:exec("ROLLBACK;") end)
		Logger.error(LOG, "Local data.sql replay failed: %s.", db:errmsg() or "?")
		return false, empty_cursor
	end
	Logger.done(LOG, "Replayed %d durable local-ledger byte(s).", complete_offset)
	return true, cursor
end

--- Flush the current recovery walker batch atomically.
---@param db userdata
---@return boolean
local function _flush_recovery_batch(db)
	local begin_rc = db:exec("BEGIN TRANSACTION;")
	if begin_rc ~= sqlite3.OK then
		Logger.error(LOG, "Cannot begin aggregate recovery transaction: %s.", db:errmsg() or "?")
		return false
	end
	local ok, flushed_or_err = pcall(Aggregator.flush)
	if not ok or not flushed_or_err then
		pcall(function() db:exec("ROLLBACK;") end)
		Logger.error(LOG, "Aggregate recovery flush failed: %s.", tostring(flushed_or_err or "pending aggregate rows"))
		return false
	end
	local commit_rc = db:exec("COMMIT;")
	if commit_rc ~= sqlite3.OK then
		pcall(function() db:exec("ROLLBACK;") end)
		Logger.error(LOG, "Cannot commit aggregate recovery transaction: %s.", db:errmsg() or "?")
		return false
	end
	Aggregator.reset_batch()
	return true
end

--- Remove a single device partition before deterministic re-aggregation.
---@param db userdata
---@param device_id string
---@return boolean
local function _clear_derived_device_rows(db, device_id)
	local begin_rc = db:exec("BEGIN TRANSACTION;")
	if begin_rc ~= sqlite3.OK then return false end
	local ok, err = pcall(function()
		for _, table_name in ipairs(DERIVED_DEVICE_TABLES) do
			local rc = db:exec("DELETE FROM " .. table_name .. " WHERE device_id=" .. _sq(device_id) .. ";")
			if rc ~= sqlite3.OK then error(db:errmsg() or ("cannot clear " .. table_name)) end
		end
		local commit_rc = db:exec("COMMIT;")
		if commit_rc ~= sqlite3.OK then error(db:errmsg() or "cannot commit derived cleanup") end
	end)
	if not ok then
		_rollback_sqlite(db, "Data.sql outbox clear")
		Logger.error(LOG, "Cannot clear derived rows for device %s: %s.", device_id:sub(1, 8), tostring(err))
		return false
	end
	return true
end

--- Rebuild UI aggregate tables from canonical raw rows.  Passing device ids
--- rebuilds only those partitions after a foreign ledger import; omitting it
--- repairs the entire cache (first start or an aggregate-version migration).
---@param db userdata
---@param requested_device_ids string[]|nil
---@return boolean
local function _rebuild_aggregates_from_raw(db, requested_device_ids)
	local device_ids = {}
	local rebuilding_local = false
	if type(requested_device_ids) == "table" then
		local seen = {}
		for _, device_id in ipairs(requested_device_ids) do
			if type(device_id) == "string" and device_id ~= "" and not seen[device_id] then
				seen[device_id] = true
				table.insert(device_ids, device_id)
				if device_id == _device_id then rebuilding_local = true end
			end
		end
	else
		local device_sql = [[SELECT DISTINCT device_id FROM (
			SELECT device_id FROM events_typing UNION SELECT device_id FROM events_app_switch
			UNION SELECT device_id FROM events_window_switch UNION SELECT device_id FROM events_system
		) ORDER BY device_id;]]
		local ok_devices, device_err = pcall(function()
			for row in db:nrows(device_sql) do
				if type(row.device_id) == "string" and row.device_id ~= "" then
					table.insert(device_ids, row.device_id)
				end
			end
		end)
		if not ok_devices then
			Logger.error(LOG, "Cannot enumerate raw devices for aggregate recovery: %s.", tostring(device_err))
			return false
		end
		-- Leave the live local context selected at the end of a full recovery.
		for i = #device_ids, 1, -1 do
			if device_ids[i] == _device_id then
				rebuilding_local = true
				table.remove(device_ids, i)
				table.insert(device_ids, _device_id)
				break
			end
		end
		if not rebuilding_local then table.insert(device_ids, _device_id); rebuilding_local = true end
	end
	if #device_ids == 0 then return true end

	-- Foreign-only recovery must not inject the other device's n-gram continuity
	-- into the next local typing event.
	local saved_local_ctx = nil
	if not rebuilding_local then
		local ok_ctx, encoded = pcall(json.encode, Aggregator.get_ngram_ctx() or {})
		if ok_ctx then saved_local_ctx = encoded end
	end

	for _, replay_device_id in ipairs(device_ids) do
		if not _clear_derived_device_rows(db, replay_device_id) then return false end
		Aggregator.set_device_id(replay_device_id)
		Aggregator.reset_ngram_ctx()
		Aggregator.reset_batch()
		local processed = 0
		local function flush_if_needed(force)
			if processed == 0 or (not force and processed < REPLAY_FLUSH_EVENT_COUNT) then return true end
			if not _flush_recovery_batch(db) then return false end
			processed = 0
			return true
		end
		local function walked()
			processed = processed + 1
			return flush_if_needed(false)
		end
		local quoted_device = _sq(replay_device_id)
		local ok, replay_err = pcall(function()
			for row in db:nrows("SELECT ts, app, title, layout, events_json FROM events_typing WHERE device_id=" .. quoted_device .. " ORDER BY ts, id") do
				local decoded_ok, events = pcall(json.decode, row.events_json or "[]")
				if decoded_ok and type(events) == "table" then
					Aggregator.walk_typing({ timestamp=row.ts, app=row.app, title=row.title, layout=row.layout, events=events })
					if not walked() then error("typing aggregate flush failed") end
				end
			end
			for row in db:nrows("SELECT ts, prev_app, next_app, duration_ms FROM events_app_switch WHERE device_id=" .. quoted_device .. " ORDER BY ts, id") do
				Aggregator.walk_app_switch({ timestamp=row.ts, prev_app=row.prev_app, next_app=row.next_app, duration_ms=row.duration_ms })
				if not walked() then error("app-switch aggregate flush failed") end
			end
			for row in db:nrows("SELECT ts, app, prev_title, next_title, duration_ms FROM events_window_switch WHERE device_id=" .. quoted_device .. " ORDER BY ts, id") do
				Aggregator.walk_window_switch({ timestamp=row.ts, app=row.app, prev_title=row.prev_title, next_title=row.next_title, duration_ms=row.duration_ms })
				if not walked() then error("window-switch aggregate flush failed") end
			end
			for row in db:nrows("SELECT ts, action, metadata_json FROM events_system WHERE device_id=" .. quoted_device .. " ORDER BY ts, id") do
				local entry = {}
				local decoded_ok, metadata = pcall(json.decode, row.metadata_json or "{}")
				if decoded_ok and type(metadata) == "table" then
					for key, value in pairs(metadata) do entry[key] = value end
				end
				entry.timestamp, entry.action = row.ts, row.action
				Aggregator.walk_system_event(entry)
				if not walked() then error("system aggregate flush failed") end
			end
			if not flush_if_needed(true) then error("final aggregate flush failed") end
		end)
		if not ok then
			Aggregator.set_device_id(_device_id)
			Aggregator.reset_batch()
			if saved_local_ctx then
				local restored_ok, restored_ctx = pcall(json.decode, saved_local_ctx)
				if restored_ok and type(restored_ctx) == "table" then Aggregator.set_ngram_ctx(restored_ctx)
				else Aggregator.reset_ngram_ctx() end
			else
				Aggregator.reset_ngram_ctx()
			end
			Logger.error(LOG, "Aggregate recovery failed for device %s: %s.", replay_device_id:sub(1, 8), tostring(replay_err))
			return false
		end
	end
	Aggregator.set_device_id(_device_id)
	if saved_local_ctx then
		local restored_ok, restored_ctx = pcall(json.decode, saved_local_ctx)
		if restored_ok and type(restored_ctx) == "table" then Aggregator.set_ngram_ctx(restored_ctx)
		else Aggregator.reset_ngram_ctx() end
	end
	return true
end

--- Synchronise cache metadata after a successful fresh-cache recovery.
---@param db userdata
---@param cursor table
local function _persist_recovery_state(db, cursor)
	local max_id = 0
	for row in db:nrows("SELECT MAX(id) AS max_id FROM ("
		.. "SELECT id FROM events_typing WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_app_switch WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_window_switch WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_shortcut WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_system WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_hotstring WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_llm WHERE device_id=" .. _sq(_device_id)
		.. " UNION ALL SELECT id FROM events_session WHERE device_id=" .. _sq(_device_id)
		.. ")") do
		max_id = tonumber(row.max_id) or 0
	end
	SqliteWriter.set_next_event_id(max_id + 1)
	SqliteWriter.persist_next_event_id()
	db:exec(string.format("UPDATE meta SET value='%d' WHERE key='today_log_offset';", tonumber(cursor.offset) or 0))
	db:exec("UPDATE meta SET value=" .. _sq(cursor.date or "") .. " WHERE key='today_log_date';")
	local ok, context_json = pcall(json.encode, Aggregator.get_ngram_ctx() or {})
	if ok then db:exec("UPDATE meta SET value=" .. _sq(context_json) .. " WHERE key='ngram_ctx_json';") end
end

--- Return the aggregate-cache compatibility marker from meta.
---@param db userdata
---@return string
local function _aggregate_cache_revision(db)
	for row in db:nrows("SELECT value FROM meta WHERE key='aggregate_cache_revision'") do
		return tostring(row.value or "0")
	end
	return "0"
end

--- Mark a fully rebuilt derived cache and make every dashboard snapshot stale.
---@param db userdata
---@return boolean
local function _mark_aggregate_cache_rebuilt(db)
	local begin_rc = db:exec("BEGIN TRANSACTION;")
	if begin_rc ~= sqlite3.OK then return false end
	local ok, err = pcall(function()
		local version_rc = db:exec("UPDATE meta SET value=" .. _sq(AGGREGATE_CACHE_REVISION)
			.. " WHERE key='aggregate_cache_revision';")
		if version_rc ~= sqlite3.OK then error(db:errmsg() or "cannot update aggregate cache revision") end
		local rev_rc = db:exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';")
		if rev_rc ~= sqlite3.OK then error(db:errmsg() or "cannot update metrics revision") end
		local commit_rc = db:exec("COMMIT;")
		if commit_rc ~= sqlite3.OK then error(db:errmsg() or "cannot commit aggregate cache revision") end
	end)
	if not ok then
		pcall(function() db:exec("ROLLBACK;") end)
		Logger.error(LOG, "Cannot mark aggregate cache rebuilt: %s.", tostring(err))
		return false
	end
	return true
end

--- Return the local-only ledger batch waiting to reach data.sql.
--- This value must never be appended to data.sql itself: it is a cursor-local
--- recovery record, not data to replay into a different device cache.
local function _get_local_outbox(db)
	for row in db:nrows("SELECT value FROM meta WHERE key=" .. _sq(DATA_SQL_OUTBOX_KEY)) do
		return type(row.value) == "string" and row.value or ""
	end
	return ""
end

--- Clear the outbox only after its full batch has reached the append-only ledger.
--- A failure after the write leaves an idempotent INSERT OR IGNORE batch to retry.
local function _clear_local_outbox(db)
	local ok, err = pcall(function()
		_exec_sqlite_or_error(db, "BEGIN TRANSACTION;", "cannot begin data.sql outbox clear")
		_exec_sqlite_or_error(db,
			"UPDATE meta SET value='' WHERE key=" .. _sq(DATA_SQL_OUTBOX_KEY) .. ";",
			"cannot clear data.sql outbox")
		_exec_sqlite_or_error(db, "COMMIT;", "cannot commit data.sql outbox clear")
	end)
	if not ok then
		_rollback_sqlite(db, "Data.sql outbox clear")
		Logger.error(LOG, "Cannot clear committed data.sql outbox: %s.", tostring(err))
		return false
	end
	return true
end

--- Flush a committed local batch before allocating any new event id.
--- @return boolean True when no batch is pending or the pending batch is durable.
local function _flush_local_data_sql_outbox(db)
	local batch_text = _get_local_outbox(db)
	if batch_text == "" then return true end

	local f, ferr = io.open(_paths.data_sql_path, "a")
	if not f then
		Logger.error(LOG, "Cannot append pending data.sql outbox at %s: %s.",
			_paths.data_sql_path, tostring(ferr))
		return false
	end
	local write_ok, write_err = f:write(batch_text)
	local close_ok, close_err = f:close()
	if not write_ok or not close_ok then
		Logger.error(LOG, "Cannot flush pending data.sql outbox: %s.",
			tostring(write_err or close_err))
		return false
	end
	return _clear_local_outbox(db)
end

--- Runs foreign ledger sync behind one checked boundary for ingest and startup.
---@param on_applied fun(device_id:string):boolean|nil|nil
---@return string[] synced_devices
local function _sync_foreign_data_sql(on_applied)
	local call_ok, result_or_err, detail = xpcall(function()
		return Export.sync_foreign_data_sql(on_applied)
	end, debug.traceback)
	if call_ok and type(result_or_err) == "table" then
		_foreign_sync_error_key = nil
		return result_or_err
	end

	local failure_kind = call_ok and "did not commit" or "raised"
	local failure_detail = call_ok and detail or result_or_err
	local error_key = failure_kind .. ":" .. tostring(failure_detail)
	if _foreign_sync_error_key ~= error_key then
		Logger.error(LOG, "Foreign data.sql sync %s: %s.",
			failure_kind, tostring(failure_detail))
		_foreign_sync_error_key = error_key
	end
	return {}
end

--- Run one ingest cycle: pull new today.log entries, append SQL batch to
--- data.sql, apply it to db.sqlite, update aggregate tables.
function M.ingest_once()
	-- A failed timer allocation still leaves the ordered outbox intact. The
	-- recurring ingest tick is the independent retry path that guarantees an
	-- action with no following key cannot strand its detached typing run.
	if _has_deferred_logs() then _drain_deferred_logs() end
	local db = SqliteWriter.get_db()
	if not db then return end

	local foreign_devices = _sync_foreign_data_sql(function(device_id)
		if not _rebuild_aggregates_from_raw(db, { device_id }) then return false end
		return _mark_aggregate_cache_rebuilt(db)
	end)
	-- A previous cache transaction may have committed while data.sql was locked.
	-- Drain that exact source batch first so a tmp-cache loss can never make it
	-- invisible to sync/replay, and so we never allocate new ids for old JSONL.
	if not _flush_local_data_sql_outbox(db) then
		if #foreign_devices > 0 then _notify_ingest_listeners() end
		return
	end

	local entries, new_offset, read_status = Rotation.read_new_entries()
	if read_status == "failed" then
		Logger.warn(LOG, "Ingest skipped because today.log tail read did not commit.")
		return false
	end
	if #entries == 0 then
		if #foreign_devices > 0 then _notify_ingest_listeners() end
		return
	end

	-- Snapshot the event-id counter BEFORE build_inserts allocates ids: if the
	-- transaction below rolls back, the offset is not advanced and this exact batch
	-- is re-read next tick — restoring the counter makes the retry reuse the same
	-- ids so INSERT OR IGNORE dedups them, rather than re-keying with fresh ids and
	-- leaving a permanent id gap (which desyncs a data.sql peer replay).
	local saved_event_id = SqliteWriter.get_next_event_id()
	-- The walker mutates its n-gram/session context before aggregate UPSERTs are
	-- committed. Keep a serialised snapshot so a failed aggregate transaction can
	-- retry the same JSONL rows without double-counting their continuity state.
	local saved_ngram_ctx_json = nil
	local ctx_snapshot_ok, ctx_snapshot = pcall(json.encode, Aggregator.get_ngram_ctx() or {})
	if ctx_snapshot_ok then saved_ngram_ctx_json = ctx_snapshot end

	local statements = {}
	for _, item in ipairs(entries) do
		for _, sql in ipairs(SqliteWriter.build_inserts(item.entry)) do
			table.insert(statements, sql)
		end
	end
	if #statements == 0 then
		Rotation.set_offset(new_offset, Rotation.get_date())
		if #foreign_devices > 0 then _notify_ingest_listeners() end
		return
	end

	-- Build the SQL text upfront; write to data.sql only AFTER the SQLite
	-- transaction commits successfully — a failed COMMIT must not leave
	-- unreplayable statements in the append-only source-of-truth file.
	local batch_text = string.format(
		"\n-- === ingest batch %s (offset %d -> %d, %d entry(ies)) ===\nBEGIN TRANSACTION;\n%s\nCOMMIT;\n",
		_now_ts(), Rotation.get_offset(), new_offset, #entries,
		table.concat(statements, "\n"))

	local ok, exec_err = pcall(function()
		-- Defensively clear any transaction a prior step (e.g. a torn foreign
		-- data.sql sync) may have left open, so our BEGIN below can never fail with
		-- "cannot start a transaction within a transaction" and abort this batch
		-- (F-M3). Harmless no-op when no transaction is active.
		pcall(function() db:exec("ROLLBACK;") end)
		_exec_sqlite_or_error(db, "BEGIN TRANSACTION;", "cannot begin ingest transaction")
		for _, sql in ipairs(statements) do
			_exec_sqlite_or_error(db, sql, "cannot persist ingest event")
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
		local aggregates_flushed = Aggregator.flush()
		if aggregates_flushed == false then
			error("aggregate flush left pending rows")
		end
		_exec_sqlite_or_error(db, string.format(
			"UPDATE meta SET value='%d' WHERE key='today_log_offset';", new_offset),
			"cannot persist today.log offset")
		_exec_sqlite_or_error(db, string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", Rotation.get_date() or ""),
			"cannot persist today.log date")
		if SqliteWriter.persist_next_event_id() ~= true then
			error("cannot persist next event id", 0)
		end
		_exec_sqlite_or_error(db,
			"UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';",
			"cannot increment metrics revision")
		-- Serialise n-gram walking context so a crash mid-tick does not lose
		-- the partial cur_word / p1..p6 / current_burst / streak state.
		local ctx = Aggregator.get_ngram_ctx()
		local ok_enc, enc = pcall(json.encode, ctx or {})
		if not ok_enc then error("cannot encode n-gram context: " .. tostring(enc), 0) end
		_exec_sqlite_or_error(db, string.format(
			"UPDATE meta SET value=%s WHERE key='ngram_ctx_json';",
			_sq(enc)), "cannot persist n-gram context")
		-- Commit the canonical SQL batch alongside the cache changes.  If the
		-- following append fails, this local durable outbox is replayed before
		-- the next ingest instead of silently advancing past the source record.
		_exec_sqlite_or_error(db, string.format(
			"UPDATE meta SET value=%s WHERE key=%s;",
			_sq(batch_text), _sq(DATA_SQL_OUTBOX_KEY)),
			"cannot persist data.sql outbox")
		_exec_sqlite_or_error(db, "COMMIT;", "cannot commit ingest transaction")
	end)
	if not ok then
		Logger.error(LOG, "Ingest batch rolled back: %s.", tostring(exec_err))
		_rollback_sqlite(db, "Ingest batch")
		-- Undo the event-id allocations from the rolled-back build_inserts so the
		-- next retry of this same (offset-unchanged) batch reuses identical ids.
		SqliteWriter.set_next_event_id(saved_event_id)
		Aggregator.reset_batch()
		if saved_ngram_ctx_json then
			local restored_ok, restored_ctx = pcall(json.decode, saved_ngram_ctx_json)
			if restored_ok and type(restored_ctx) == "table" then
				Aggregator.set_ngram_ctx(restored_ctx)
			else
				Aggregator.reset_ngram_ctx()
			end
		else
			Aggregator.reset_ngram_ctx()
		end
		return
	end

	-- SQLite transaction committed — now safe to append to data.sql (the
	-- source-of-truth SQL log). Writing here rather than before the COMMIT
	-- ensures data.sql never contains statements that were not persisted.
	Rotation.set_offset(new_offset, Rotation.get_date())
	if not _flush_local_data_sql_outbox(db) then
		-- The in-memory cursor must still advance: the committed outbox owns this
		-- exact batch, while replaying today.log here would allocate new ids and
		-- duplicate metrics in the cache.
		Logger.warn(LOG, "Ingest committed but data.sql append is pending retry.")
		return
	end
	Logger.debug(LOG, "Ingest cycle: %d entry(ies), offset now %d.", #entries, new_offset)

	-- Notify live-update listeners — dashboard UIs use this to invalidate
	-- their caches immediately rather than waiting for the next JS poll.
	_notify_ingest_listeners()
end


--- Verifies one native ingest timer's observable running state. Real
--- Hammerspoon timers expose running(); the boolean branch keeps the narrow
--- pure-Lua timer doubles faithful without accepting an unreadable userdata.
--- @param timer_handle table|userdata Native timer candidate.
--- @param expected boolean Required running state.
--- @return boolean matches True only when the observable state matches.
--- @return string|nil detail Probe failure detail.
local function _ingest_timer_running_matches(timer_handle, expected)
	local member_ok, member_or_err = pcall(function() return timer_handle.running end)
	if not member_ok then return false, tostring(member_or_err) end
	if type(member_or_err) == "boolean" and type(timer_handle) == "table" then
		if member_or_err == expected then return true end
		return false, string.format("running state was %s", tostring(member_or_err))
	end
	if type(member_or_err) ~= "function" then return false, "running() unavailable" end
	local probe_ok, running_or_err = xpcall(function()
		return member_or_err(timer_handle)
	end, debug.traceback)
	if not probe_ok or type(running_or_err) ~= "boolean" then
		return false, tostring(running_or_err)
	end
	if running_or_err ~= expected then
		return false, string.format("running() returned %s", tostring(running_or_err))
	end
	return true
end

--- Fences and releases the exact recurring ingest timer. A truthy chainable
--- stop result is not a native-state verdict; retain the handle until
--- running() proves that it is stopped.
--- @param timer_handle table|userdata Exact timer owned by this module.
--- @param label string Cleanup context for the file logger.
--- @return boolean stopped True only when native state is observably stopped.
local function _stop_ingest_timer(timer_handle, label)
	if not timer_handle then return true end
	if _ingest_timer == timer_handle then _ingest_timer_committed = false end
	local stop_ok, stopped_or_err = xpcall(function()
		return timer_handle:stop()
	end, debug.traceback)
	local state_stopped, state_detail = _ingest_timer_running_matches(timer_handle, false)
	if not stop_ok or stopped_or_err == false or not state_stopped then
		pcall(Logger.error, LOG, "%s cleanup remains pending: %s.", label,
			tostring(not stop_ok and stopped_or_err
				or (stopped_or_err == false and "stop returned false")
				or state_detail))
		return false
	end
	if _ingest_timer == timer_handle then _ingest_timer = nil end
	return true
end

--- Acquires and starts the one recurring ingest timer. Construction and start
--- are one transaction: a handle whose start raises or explicitly refuses stays
--- retained so M.stop() can retry its exact cleanup.
--- @return boolean started True when one owned timer is committed.
local function _start_ingest_timer()
	if _ingest_timer then return _ingest_timer_committed end

	local timer_candidate = nil
	local create_ok, timer_or_err = xpcall(function()
		timer_candidate = timer.new(INGEST_TICK_SEC, function()
			-- Native timers can invoke a queued callback after stop() refused or
			-- after start() raised despite activating the candidate. Publication is
			-- therefore both identity- and commit-scoped, never handle-presence-only.
			if _ingest_timer ~= timer_candidate or _ingest_timer_committed ~= true then
				return
			end
			Logger.pcall(LOG, M.ingest_once)
		end)
		return timer_candidate
	end, debug.traceback)
	if not create_ok or timer_or_err == nil then
		pcall(Logger.error, LOG, "Cannot create ingest timer: %s.",
			tostring(timer_or_err or "hs.timer.new returned nil"))
		return false
	end

	_ingest_timer = timer_or_err
	local start_ok, started_or_err = xpcall(function()
		return timer_or_err:start()
	end, debug.traceback)
	local state_started, state_detail = _ingest_timer_running_matches(timer_or_err, true)
	if not start_ok or started_or_err == false or not state_started then
		pcall(Logger.error, LOG,
			"Cannot start ingest timer; exact cleanup remains owned: %s.",
			tostring(not start_ok and started_or_err
				or (started_or_err == false and "start returned false")
				or state_detail))
		return false
	end
	_ingest_timer_committed = true
	return true
end

--- Day rollover handler. Drains remaining today.log then delegates to
--- Rotation.rollover to reset the file and offset.
--- @return boolean True when the drain fully completed and rollover ran; false
--- when the drain stalled and today.log/state were deliberately preserved for
--- retry on the next midnight tick.
function M.day_rollover()
	if not _require_state("day_rollover") then return false end

	-- read_new_entries caps at INGEST_BATCH_LINES per call, so a single
	-- ingest_once may leave data behind. Loop until empty or stalled to prevent
	-- Rotation.rollover from deleting un-ingested lines.
	local drained = false
	local committed_eof = nil
	local prev_offset = Rotation.get_offset()
	for _ = 1, MAX_ROLLOVER_DRAIN_ITERS do
		local pending, _, read_status = Rotation.read_new_entries()
		if read_status == "failed" then
			Logger.warn(LOG,
				"day_rollover: tail read failed — preserving today.log.")
			break
		elseif #pending == 0 then
			if read_status == "eof" then
				drained = true
				committed_eof = read_status
			else
				Logger.warn(LOG,
					"day_rollover: tail read did not commit EOF — preserving today.log.")
			end
			break
		end
		pcall(M.ingest_once)
		local new_offset = Rotation.get_offset()
		if new_offset == prev_offset then
			-- Offset unchanged after a batch with pending data: persistent SQL
			-- error; preserve today.log so un-ingested lines survive the rollover.
			Logger.warn(LOG,
				"day_rollover: ingest stalled at offset %d — preserving today.log.",
				prev_offset)
			break
		end
		prev_offset = new_offset
	end

	if not drained then
		-- The drain stalled: today.log, the ngram context, and the meta
		-- bookmarks must all survive untouched so the next midnight tick can
		-- retry from exactly where this attempt gave up (G1, G2).
		Logger.warn(LOG, "day_rollover: today.log not fully drained — file preserved, rotation skipped.")
		return false
	end

	-- The outbox lives in the disposable SQLite cache.  If its append-only
	-- ledger write is still blocked, deleting today.log here would remove the
	-- only durable source from which a fresh cache can recreate that batch.
	-- Keep the old day intact and retry the append before a later rotation.
	local db = SqliteWriter.get_db()
	if db and not _flush_local_data_sql_outbox(db) then
		Logger.warn(LOG, "day_rollover: local data.sql outbox is not durable — preserving today.log.")
		return false
	end

	if Rotation.rollover(_paths.data_sql_path, committed_eof) == false then
		Logger.warn(LOG, "day_rollover: rotation rejected the EOF proof — today.log preserved.")
		return false
	end
	Aggregator.reset_ngram_ctx()
	if db then
		db:exec("UPDATE meta SET value='0' WHERE key='today_log_offset';")
		db:exec(string.format(
			"UPDATE meta SET value='%s' WHERE key='today_log_date';", Rotation.get_date() or ""))
		db:exec("UPDATE meta SET value='{}' WHERE key='ngram_ctx_json';")
	end
	return true
end





-- ============================
-- ============================
-- ======= 9/ Lifecycle =======
-- ============================
-- ============================

--- Releases resources acquired by an initialization attempt. Timer handles are
--- cleared only after their exact stop call completes, so a failed teardown can
--- be retried without constructing a sibling owner.
--- @return boolean complete True only when no initialization cleanup debt remains.
local function _release_failed_init_resources()
	local complete = true

	local ingest_timer = _ingest_timer
	if ingest_timer then
		if not _stop_ingest_timer(ingest_timer, "Failed-init ingest timer") then
			complete = false
		end
	end

	local deferred_timer = _deferred_log_timer
	if deferred_timer then
		local ok, result_or_err = xpcall(function()
			return TimerScheduler.cancel(deferred_timer)
		end,
			debug.traceback)
		if ok and result_or_err == true then
			if _deferred_log_timer == deferred_timer then _deferred_log_timer = nil end
		else
			complete = false
			pcall(Logger.error, LOG,
				"Failed-init deferred timer cleanup remains pending: %s.",
				tostring(result_or_err))
		end
	end

	local db_ok, db_result_or_err = xpcall(function() return SqliteWriter.close_db() end,
		debug.traceback)
	if not db_ok or db_result_or_err == false then
		complete = false
		pcall(Logger.error, LOG,
			"Failed-init database cleanup remains pending: %s.",
			tostring(db_result_or_err))
	end
	return complete
end

--- Revokes all log-manager publication from a failed initialization and starts
--- cleanup of any native resources that attempt acquired.
--- @return boolean complete True only when every cleanup completed.
local function _rollback_failed_init()
	_state = nil
	_device_obj = nil
	_device_id = nil
	_paths = {}
	_init_cleanup_pending = true
	local complete = _release_failed_init_resources()
	_init_cleanup_pending = not complete
	return complete
end

--- Initialize the log manager. Resolves the device, opens the SQLite cache,
--- creates the filesystem layout. Idempotent; calling twice is a warning.
--- @param core_state table The shared CoreState from modules/keylogger/init.lua.
local function _init(core_state)
	if _state then
		Logger.warn(LOG, "M.init() called twice — ignoring duplicate.")
		return true
	end
	if type(core_state) ~= "table" or type(core_state.LOG_DIR) ~= "string" then
		Logger.error(LOG, "M.init(): invalid core_state — log manager non-functional.")
		return false
	end

	Logger.start(LOG, "Initializing log manager…")

	local device_obj, needs_publication = _resolve_device(core_state.LOG_DIR)
	if not device_obj then
		Logger.error(LOG, "M.init(): device identity could not be resolved — log manager disabled.")
		return false
	end
	local device_id = device_obj.device_id
	local paths = _resolve_paths(core_state.LOG_DIR, device_id)

	_mkdir_p(paths.metrics_dir)
	_mkdir_p(paths.by_device_dir)
	_mkdir_p(paths.tmpdir_dir)

	if needs_publication then
		local identity_committed, published_device = _write_device_json(
			device_obj,
			paths.device_json_path
		)
		if not identity_committed then return false end
		device_obj = published_device
		device_id = device_obj.device_id
		paths = _resolve_paths(core_state.LOG_DIR, device_id)
	end

	-- Publish the shared state only after a new identity is durable (or an
	-- existing identity was read and owned). Every public method remains behind
	-- _require_state until this transaction commits.
	_state = core_state
	_device_obj = device_obj
	_device_id = device_id
	_paths = paths
	local cache_was_fresh = fs.attributes(_paths.sqlite_path) == nil

	-- Initialise submodules.
	SqliteWriter.init({ paths = _paths, device_obj = _device_obj, device_id = _device_id })
	Aggregator.init({ device_id = _device_id })
	Export.init({ paths = _paths, device_id = _device_id, get_db = SqliteWriter.get_db })

	if not SqliteWriter.open_db() then
		Logger.error(LOG, "Cannot open db.sqlite — log manager will only write JSONL.")
	else
		local db = SqliteWriter.get_db()
		local recovery_cursor = nil
		local recovery_ready = true
		if cache_was_fresh and db then
			local replay_ok, cursor = _replay_local_data_sql(db)
			if replay_ok then recovery_cursor = cursor
			else
				recovery_ready = false
				Logger.error(LOG, "Skipped aggregate recovery because local ledger replay failed.")
			end
		end
		if db and recovery_ready
			and (cache_was_fresh or _aggregate_cache_revision(db) ~= AGGREGATE_CACHE_REVISION) then
			-- Foreign ledgers also carry raw rows only. Import them before the
			-- deterministic aggregate walk so cross-device totals survive a normal
			-- TMPDIR purge and older caches gain the missing foreign aggregates.
			_sync_foreign_data_sql()
			if _rebuild_aggregates_from_raw(db) then
				if recovery_cursor then _persist_recovery_state(db, recovery_cursor) end
				if _mark_aggregate_cache_rebuilt(db) then
					Logger.success(LOG, "Rebuilt aggregate cache from durable raw ledgers.")
				else
					Logger.error(LOG, "Aggregate cache rebuild completed but could not be marked for reuse.")
				end
			else
				Logger.error(LOG, "Aggregate cache recovery failed; raw events remain durable for retry.")
			end
		end
		-- Restore persisted counters and n-gram context from meta.
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

	-- Rotation is normally initialised inside the SQLite branch above, which is
	-- skipped entirely when db.sqlite cannot be opened. Without this fallback
	-- Rotation._require_init rejects EVERY append_log, so not a single keystroke
	-- reaches today.log — contradicting the JSONL-only contract logged above.
	-- The previous probe (`not Rotation.get_offset`) was unreachable dead code:
	-- the accessor is defined at require time and is always truthy, so the test
	-- must interrogate the initialisation flag itself, never a function's existence.
	if not Rotation.is_initialized() then
		Logger.warn(LOG, "SQLite cache unavailable — initialising rotation for JSONL-only operation.")
		Rotation.init({ paths = _paths, state = _state })
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

	_state.today_idx = _state.today_idx or {}
	_state.manifest  = _state.manifest  or {}

	if not _ingest_timer then
		Logger.pcall(LOG, M.ingest_once)
		if not _start_ingest_timer() then error("ingest timer acquisition failed") end
	end

	Logger.success(LOG, "Log manager initialized (device %s, name %s).",
		_device_id:sub(1, 8) .. "…", _device_obj.name)
	return true
end

--- Runs initialization as a transaction. A dependency may raise after a native
--- timer or database has already become live; contain that exception, revoke the
--- prematurely published state, and retain any failed cleanup for exact retry.
--- @param core_state table The shared CoreState from modules/keylogger/init.lua.
--- @return boolean initialized True only when the complete initialization commits.
function M.init(core_state)
	if not _state and _init_cleanup_pending then
		local cleanup_complete = _release_failed_init_resources()
		_init_cleanup_pending = not cleanup_complete
		if not cleanup_complete then
			pcall(Logger.error, LOG,
				"M.init() refused while prior initialization cleanup remains pending.")
			return false
		end
	end

	local state_was_committed = _state ~= nil
	local ok, initialized_or_err = xpcall(_init, debug.traceback, core_state)
	if ok then return initialized_or_err end

	local cleanup_complete = true
	if not state_was_committed then cleanup_complete = _rollback_failed_init() end
	pcall(Logger.error, LOG,
		"M.init() raised; initialization was rejected%s: %s.",
		cleanup_complete and "" or " with cleanup still pending",
		tostring(initialized_or_err))
	return false
end

--- Re-creates the ingest timer if it was stopped by M.stop() without a
--- full re-init. Idempotent when already running; before init it reports false
--- and acquires nothing. Called unconditionally from keylogger M.start() so the
--- ingest loop survives toggle OFF/ON without a full re-initialization.
--- @return boolean running True only when one timer owner is committed.
function M.ensure_ingest_running()
	if not _state then return false end
	-- A candidate may have become native-live before start() raised/refused. It is
	-- cleanup debt, not an ingest owner; never reopen the database underneath it.
	if _ingest_timer and not _ingest_timer_committed then return false end

	-- Re-arm must be symmetric with M.stop(), which tears down BOTH the timer and
	-- the SQLite cache. Restoring only the timer left the ingest tick running
	-- against a closed database for the rest of the session, so toggling Metrics
	-- OFF then ON permanently killed ingest and midnight rotation. keylogger.start()
	-- latches on its own _state and never calls M.init() again, so this is the only
	-- place the cache can be re-acquired after that toggle.
	-- Safe to re-enter: open_db() is a no-op when a handle is already live.
	if not SqliteWriter.get_db() then
		if SqliteWriter.open_db() then
			Logger.done(LOG, "SQLite cache re-opened after stop/start cycle.")
		else
			Logger.error(LOG, "Cannot re-open the SQLite cache after a stop/start cycle — ingest stays offline.")
		end
	end

	if _ingest_timer then return true end
	if not _start_ingest_timer() then return false end
	Logger.done(LOG, "Ingest timer re-armed after stop/start cycle.")
	return true
end

--- Stop every retained timer and close the SQLite cache cleanly.
--- Native stop/close methods may explicitly refuse or raise after leaving their
--- resource live. Retain the exact handle in that case so the lifecycle owner can
--- retry instead of publishing a successor beside an orphan.
--- @return boolean complete True only when every owned resource was released.
function M.stop()
	local complete = true
	local ingest_timer = _ingest_timer
	if ingest_timer then
		if not _stop_ingest_timer(ingest_timer, "Ingest timer") then
			complete = false
		end
	end

	local deferred_timer = _deferred_log_timer
	if deferred_timer then
		local ok, result_or_err = xpcall(function()
			return TimerScheduler.cancel(deferred_timer)
		end,
			debug.traceback)
		if ok and result_or_err == true then
			if _deferred_log_timer == deferred_timer then _deferred_log_timer = nil end
		else
			complete = false
			pcall(Logger.error, LOG,
				"Deferred timer cleanup remains pending: %s.", tostring(result_or_err))
		end
	end

	if _has_deferred_logs() then
		local drain_ok, drained_or_err = xpcall(_drain_deferred_logs, debug.traceback)
		if not drain_ok or drained_or_err == false then
			complete = false
			pcall(Logger.error, LOG,
				"Deferred log cleanup remains pending: %s.", tostring(drained_or_err))
		end
	end
	pcall(M.ingest_once)
	local db_ok, db_result_or_err = xpcall(function() return SqliteWriter.close_db() end,
		debug.traceback)
	if not db_ok or db_result_or_err == false then
		complete = false
		pcall(Logger.error, LOG,
			"Database cleanup remains pending: %s.", tostring(db_result_or_err))
	end
	pcall(Logger.debug, LOG, complete and "Log manager stopped"
		or "Log manager cleanup remains pending")
	return complete
end





-- ============================================================
-- ============================================================
-- ======= 10/ Compatibility shims for the in-flight UI =======
-- ============================================================
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

return M

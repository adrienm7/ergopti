--- lib/file_watchers.lua

--- ==============================================================================
--- MODULE: Auto-Reload File Watchers (Linux)
--- DESCRIPTION:
--- Inotify-based file watchers for the Linux daemon. Mirrors the macOS
--- lib/file_watchers.lua contract: watches hotstring TOML files and project
--- .lua files, debounces rapid successive saves into a single reload callback.
---
--- When luv (libuv Lua binding) is available, uses luv.new_fs_event() which
--- wraps inotify(7) — callbacks fire within the existing luv event loop with
--- zero polling overhead. When luv is absent (pump fallback mode), falls back
--- to mtime polling via posix.stat(), driven by M.pump() from the daemon's
--- onPeriodic callback (250 ms interval).
---
--- FEATURES & RATIONALE:
--- 1. Dual backend: luv fs_event (inotify) when luv is present; mtime polling
---    via posix.stat() otherwise. Both paths share the same debounce timer
---    and callback contract.
--- 2. Debounced reload: rapid successive saves collapse into a single reload
---    via a 500 ms timer (matches macOS lib/file_watchers.lua).
--- 3. Directory + per-file coverage: a directory-level watcher catches file
---    creation/deletion; per-file watchers catch in-place edits that some
---    filesystems may not propagate to the directory notification.
--- 4. Recursive personal-dir scan: watch_personal_dir recurses into sub-folders
---    and arms per-file watchers for each .toml (same guard depth as macOS).
--- 5. GC-safe: luv handles are pinned in a local table; M.stop() closes every
---    handle and clears the table.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Monotonic = require("lib.monotonic")
local reload_gate = require("reload_gate")
local FileSystem = require("adapters.file_system")
local LOG = "file_watchers"


-- =========================================
-- =========================================
-- ======= 1/ Capability Detection =========
-- =========================================
-- =========================================

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end

local ok_posix, posix = pcall(require, "posix")
if not ok_posix then posix = nil end

-- Hard cap on recursive personal-directory scan depth (matches macOS).
local SCAN_MAX_DEPTH = 16

-- Filesystem event flags for luv.fs_event_start (libuv inotify wrapper).
-- When luv is unavailable these are nil; the pump mode ignores them.
local FS_EVENT_FLAGS = {}
if luv and luv.constants then
	FS_EVENT_FLAGS.watch_entry = luv.constants.FS_EVENT_WATCH_ENTRY or 1
	-- FS_EVENT_STAT (0x2) polls; FS_EVENT_RECURSIVE (0x4) is Linux 5.10+.
	-- We use WATCH_ENTRY only — per-directory watchers give us everything.
end


-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

-- All active luv fs_event handles: { handle = userdata, path = string, filter = function }
local _luv_handles = {}

-- Pump-mode entries: { path = string, last_mtime = number, filter = function, is_dir = bool }
local _pump_entries = {}

-- Callback invoked on debounced change detection.
local _on_reload = nil

-- Wall-clock source (milliseconds) for the debounce deadline. Injectable via
-- M.start for tests; defaults to the monotonic clock. Deliberately not the CPU
-- clock: on Linux that barely advances in an I/O-bound daemon, so a deadline
-- derived from it never lines up with real elapsed time.
local _now_ms = Monotonic.now_ms

-- Debounce deadline: monotonic wall-clock time (ms) after which the reload
-- fires. Set by _schedule_reload(); cleared after the callback fires.
local _reload_deadline = nil

-- Debounce window in seconds.
local _debounce_sec = 0.5

-- Absolute path of the driver source tree (opts.base_dir); used to probe whether
-- a git operation is currently rewriting it.
local _base_dir = nil

-- Adaptive-settle burst state: distinct source paths changed since the current
-- burst began, and the epoch (ms) of the last change. A BULK write (git pull,
-- OneDrive / Dropbox sync, rsync, mass save — many files) is held until activity
-- has been quiet for the shared bulk-settle window, so the daemon never re-scans
-- a half-written TOML; a lone edit still reloads after the short edit window.
local _burst_paths = {}
local _burst_count = 0
local _last_change_ms = 0

-- Consecutive hold re-polls with no new file activity; reset by any real event,
-- capped so only a quiet-but-stuck state (a stale index.lock) can bypass the hold.
local _defer_count = 0
local GIT_SETTLE_MAX_DEFERRALS = 120   -- 120 * _debounce_sec = 60s of a quiet-but-stuck repo


-- =========================================
-- =========================================
-- ======= 3/ File-system Helpers ==========
-- =========================================
-- =========================================

--- Returns the mtime of a path as a number (epoch seconds), or nil on error.
--- Uses posix.stat() when available, falls back to a shell invocation.
--- @param path string Absolute or relative path.
--- @return number|nil mtime in seconds, or nil.
local function _mtime(path)
	if posix and posix.stat then
		local ok, st = pcall(posix.stat, path)
		if ok and st and type(st) == "table" then
			-- posix.stat returns { mtime = { sec = ..., nsec = ... } } on many builds,
			-- or { mtime = number } on others. Normalise to a single number.
			if type(st.mtime) == "table" and st.mtime.sec then
				return tonumber(st.mtime.sec) + (tonumber(st.mtime.nsec) or 0) * 1e-9
			elseif type(st.mtime) == "number" then
				return st.mtime
			elseif type(st.modification) == "number" then
				return st.modification
			end
		end
	end
	-- Fallback: date -r (GNU date), which reports fractional seconds via %N.
	-- `stat -c %Y` only has whole-second resolution, so two writes within the
	-- same wall-clock second are indistinguishable and a real edit can be
	-- missed entirely (file-watcher-mtime-subsecond-collision).
	local fh = io.popen("date -r '" .. path:gsub("'", "'\\''") .. "' +%s.%N 2>/dev/null", "r")
	if fh then
		local out = fh:read("*a")
		fh:close()
		local mtime = tonumber(out)
		if mtime then return mtime end
	end
	return nil
end

--- Lists directory entries, skipping . and ..
--- Prefers posix.dir() when available (no shell spawn); falls back to ls.
--- @param dir string Directory path.
--- @return table List of entry names.
local function _list_dir(dir)
	if posix and posix.dir then
		local ok, entries = pcall(posix.dir, dir)
		if ok and type(entries) == "table" then
			local result = {}
			for _, name in ipairs(entries) do
				if name ~= "." and name ~= ".." then
					result[#result + 1] = name
				end
			end
			return result
		end
	end
	-- Fallback: ls -1 (POSIX).
	local entries = {}
	local ok, fh = pcall(io.popen, "ls -1 '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null", "r")
	if ok and fh then
		for line in fh:lines() do
			if line ~= "" then entries[#entries + 1] = line end
		end
		fh:close()
	end
	return entries
end

--- Checks if a path is a directory.
--- @param path string
--- @return boolean
local function _is_dir(path)
	if posix and posix.stat then
		local ok, st = pcall(posix.stat, path)
		if ok and st and st.type then
			return st.type == "directory"
		elseif ok and st and st.mode then
			return st.mode == "directory"
		end
	end
	-- Fallback.
	local fh = io.popen("test -d '" .. path:gsub("'", "'\\''") .. "' && echo 1 || echo 0", "r")
	if fh then
		local out = fh:read("*l")
		fh:close()
		return out == "1"
	end
	return false
end


-- =========================================
-- =========================================
-- ======= 4/ Debounced Reload =============
-- =========================================
-- =========================================

--- Schedules a debounced reload. Safe to call many times in rapid succession —
--- only the final call within the debounce window fires. The reload is
--- executed in M.pump() after the deadline passes (luv mode includes a timer
--- fallback that calls pump via a fast poll).
--- @param reason string Human-readable reason logged at debug level.
local function _schedule_reload(reason, paths)
	Logger.debug(LOG, "Change detected (%s) — settle armed (%.1fs).", reason, _debounce_sec)
	if type(paths) == "table" then
		for _, p in ipairs(paths) do
			if type(p) == "string" and not _burst_paths[p] then
				_burst_paths[p] = true
				_burst_count = _burst_count + 1
			end
		end
	end
	_last_change_ms = _now_ms()
	-- Genuine activity resets the stuck-state counter, so an ongoing bulk write
	-- never bypasses the hold; only a quiet-but-stuck state climbs toward the cap.
	_defer_count = 0
	_reload_deadline = _now_ms() + _debounce_sec * 1000
end

--- Fires the reload callback if the deadline has passed AND the working tree has
--- settled. Called from M.pump().
local function _check_deadline()
	if not _reload_deadline then return end
	if _now_ms() < _reload_deadline then return end

	-- Deadline reached, but hold the reload while the tree is still being written
	-- FROM ANY SOURCE, so the daemon never re-scans a half-written config. Two
	-- signals shared with the macOS driver through reload_gate: quiescence for a
	-- bulk write of many files, and the precise git index.lock guard. (The Linux
	-- reload is an in-process TOML re-scan, so this prevents loading a partial file
	-- rather than a crash — macos-reload-during-git-pull.)
	local elapsed_sec = (_now_ms() - _last_change_ms) / 1000
	local hold, why
	if not reload_gate.is_settled(elapsed_sec, _burst_count) then
		hold, why = true, "filesystem settling"
	elseif reload_gate.git_operation_in_progress(FileSystem, _base_dir) then
		hold, why = true, "git operation in progress"
	end
	if hold and _defer_count < GIT_SETTLE_MAX_DEFERRALS then
		_defer_count = _defer_count + 1
		Logger.debug(LOG, "Reload held (%s) — re-polling (%d/%d).", why, _defer_count, GIT_SETTLE_MAX_DEFERRALS)
		_reload_deadline = _now_ms() + _debounce_sec * 1000
		return
	end

	_reload_deadline = nil
	_burst_paths, _burst_count, _defer_count = {}, 0, 0
	Logger.info(LOG, "Debounced reload firing.")
	if _on_reload then
		local ok, err = pcall(_on_reload)
		if not ok then Logger.error(LOG, "on_reload callback raised: %s", tostring(err)) end
	end
end


-- =========================================
-- =========================================
-- ======= 5/ File Filter ==================
-- =========================================
-- =========================================

--- Returns true when a filename matches the TOML watch filter.
--- @param fname string File basename.
--- @return boolean
local function _is_toml(fname)
	return fname:match("%.toml$") ~= nil
end

--- Returns true when a path matches the Lua watch filter.
--- @param path string Absolute path.
--- @return boolean
local function _is_watched_lua(path)
	-- Ignore temporary / system paths.
	if path:find("^/tmp/") or path:find("^/dev/") then return false end
	if path:find("hs_hf_token_") or path:find("hs_hf_login_") then return false end
	return path:match("%.lua$") ~= nil
end


-- =========================================
-- =========================================
-- ======= 6/ Luv Backend (inotify) ========
-- =========================================
-- =========================================

--- Arms a single luv fs_event watcher on a path (file or directory).
--- @param path string Absolute path to watch.
--- @param accept_fn function(fname) → bool  Returns true when the event should trigger a reload.
local function _arm_luv_watcher(path, accept_fn)
	if not luv then return end

	local handle = luv.new_fs_event()
	if not handle then
		Logger.warn(LOG, "luv.new_fs_event() returned nil for '%s' — skipping.", path)
		return
	end

	local ok_err, err_msg = pcall(function()
		luv.fs_event_start(handle, path, FS_EVENT_FLAGS, function(err, fname, events)
			if err then
				Logger.warn(LOG, "fs_event error on '%s': %s", path, tostring(err))
				return
			end
			-- fname is the basename of the changed file (nil for file watchers).
			-- events is a table like {"change"} or {"rename"}.
			if type(fname) == "string" and fname ~= "" then
				-- Directory watcher: filter by filename.
				if accept_fn(fname) then
					_schedule_reload(string.format("inotify: %s/%s", path:match("[^/]+$"), fname), { path .. "/" .. fname })
				end
			elseif events and #events > 0 then
				-- File watcher: fire on any event.
				_schedule_reload(string.format("inotify: %s (%s)", path:match("[^/]+$"), table.concat(events, ",")), { path })
			end
		end)
	end)

	if not ok_err then
		Logger.warn(LOG, "luv.fs_event_start() failed for '%s': %s — skipping.", path, tostring(err_msg))
		pcall(function() luv.close(handle) end)
		return
	end

	table.insert(_luv_handles, { handle = handle, path = path, filter = accept_fn })
	Logger.debug(LOG, "luv fs_event armed on '%s'.", path)
end

--- Arms luv watchers on all .toml files in a directory.
--- @param dir string Directory path.
local function _arm_luv_per_file_watchers(dir)
	if not luv then return end
	for _, fname in ipairs(_list_dir(dir)) do
		if _is_toml(fname) then
			local fpath = dir .. "/" .. fname
			_arm_luv_watcher(fpath, function() return true end)
		end
	end
end


-- =========================================
-- =========================================
-- ======= 7/ Pump Backend (mtime poll) ====
-- =========================================
-- =========================================

--- Registers a pump-mode entry.
--- @param path string Absolute path to watch.
--- @param filter_fn function(fname, is_dir) → bool
--- @param is_dir boolean
local function _add_pump_entry(path, filter_fn, is_dir)
	local mtime = _mtime(path)
	table.insert(_pump_entries, {
		path      = path,
		filter    = filter_fn,
		is_dir    = is_dir or false,
		last_mtime = mtime,
		checked   = mtime ~= nil,
	})
end

--- Checks all pump-mode entries for mtime changes. Called from M.pump().
local function _pump_check_all()
	local changed = {}
	for _, entry in ipairs(_pump_entries) do
		local mtime = _mtime(entry.path)
		if mtime then
			if not entry.checked then
				-- First successful stat — store baseline, don't fire.
				entry.last_mtime = mtime
				entry.checked = true
			elseif mtime ~= entry.last_mtime then
				-- File or directory mtime moved (a dir's mtime changes on any entry
				-- create / delete / rename); record the path so the adaptive settle
				-- can tell a lone edit from a bulk write.
				entry.last_mtime = mtime
				changed[#changed + 1] = entry.path
			end
		end
	end
	if #changed > 0 then
		_schedule_reload("mtime poll", changed)
	end
end


-- =========================================
-- =========================================
-- ======= 8/ Recursive Personal Scan ======
-- =========================================
-- =========================================

--- Recursively scans personal_dir for .toml files, arming watchers on each
--- directory and per-file. Guards against symlink cycles and depth bombs.
--- @param dir string Absolute directory path.
--- @param depth number Current recursion depth.
--- @param visited table Set of canonical directory paths already entered.
local function _scan_personal_dir(dir, depth, visited)
	depth = depth or 1
	if depth > SCAN_MAX_DEPTH then
		Logger.warn(LOG, "Personal hotstrings scan hit max depth %d at '%s' — not descending further (directory cycle?).",
			SCAN_MAX_DEPTH, dir)
		return
	end

	if not _is_dir(dir) then
		Logger.debug(LOG, "Personal hotstrings dir '%s' is not a directory — skipping.", dir)
		return
	end

	local canonical = dir:gsub("[/\\]+$", ""):lower()
	if visited[canonical] then
		Logger.warn(LOG, "Personal hotstrings scan revisited '%s' — skipping to break a directory cycle.", dir)
		return
	end
	visited[canonical] = true

	-- Watch the directory itself (catches new .toml files).
	if luv then
		_arm_luv_watcher(dir, _is_toml)
	else
		_add_pump_entry(dir, _is_toml, true)
	end

	-- Scan entries.
	for _, fname in ipairs(_list_dir(dir)) do
		local fpath = dir .. "/" .. fname
		if _is_dir(fpath) then
			_scan_personal_dir(fpath, depth + 1, visited)
		elseif _is_toml(fname) then
			-- Per-file watcher.
			if luv then
				_arm_luv_watcher(fpath, function() return true end)
			else
				_add_pump_entry(fpath, function() return true end, false)
			end
		end
	end
end


-- =========================================
-- =========================================
-- ======= 9/ Public API ===================
-- =========================================
-- =========================================

--- Arms every auto-reload file watcher.
---
--- @param opts table
---   .hotstrings_dir  string  Absolute path to the main hotstrings TOML directory.
---   .base_dir        string  Absolute path to the project root (for .lua watching).
---   .personal_dir    string  Absolute path to personal hotstrings (recursive .toml scan).
---   .on_reload       function()  Called after the debounce window when a change is detected.
---   .now_ms          function() → number  Optional wall-clock source (ms) for tests.
function M.start(opts)
	opts = type(opts) == "table" and opts or {}
	local hotstrings_dir = opts.hotstrings_dir
	local base_dir       = opts.base_dir
	local personal_dir   = opts.personal_dir or ""
	_on_reload           = opts.on_reload
	_base_dir            = base_dir
	if type(opts.now_ms) == "function" then _now_ms = opts.now_ms end

	if not hotstrings_dir and not base_dir and personal_dir == "" then
		Logger.warn(LOG, "start() called with no directories to watch — no-op.")
		return
	end

	local backend_label = luv and "luv (inotify)" or "pump (mtime poll)"
	Logger.info(LOG, "Arming file watchers (%s, debounce=%.1fs)…", backend_label, _debounce_sec)

	-- ── 9.1) Hotstrings directory ──
	if hotstrings_dir and _is_dir(hotstrings_dir) then
		-- Directory-level: catches creation, deletion, rename (luv only —
		-- pump mode uses per-file entries below; a dir-level mtime check
		-- can't filter by file type so it would fire on any change).
		if luv then
			_arm_luv_watcher(hotstrings_dir, _is_toml)
		end

		-- Per-file safety net: catches in-place edits (both backends).
		if luv then
			_arm_luv_per_file_watchers(hotstrings_dir)
		else
			for _, fname in ipairs(_list_dir(hotstrings_dir)) do
				if _is_toml(fname) then
					local fpath = hotstrings_dir .. "/" .. fname
					_add_pump_entry(fpath, function() return true end, false)
				end
			end
		end
		Logger.debug(LOG, "Hotstrings dir watched: %s", hotstrings_dir)
	else
		Logger.debug(LOG, "Hotstrings dir not found or empty — skipping: %s", tostring(hotstrings_dir))
	end

	-- ── 9.2) Personal hotstrings (recursive .toml scan) ──
	if personal_dir ~= "" then
		local clean_dir = personal_dir:gsub("[/\\]+$", "")
		_scan_personal_dir(clean_dir, 1, {})
	end

	-- ── 9.3) Project .lua files ──
	-- Luv mode: directory-level fs_event with filename filter — inotify fires
	-- on in-place edits to files inside the watched directory even though the
	-- directory's own mtime does not change for those edits.
	-- Pump mode: a directory-level mtime poll only catches entry creation/
	-- deletion/rename (the only changes that touch the directory's own
	-- mtime), so an edit to an already-present .lua file would otherwise go
	-- undetected. Add a per-file pump entry for each .lua file found at start
	-- time, mirroring the hotstrings_dir per-file safety net above.
	if base_dir and _is_dir(base_dir) then
		if luv then
			_arm_luv_watcher(base_dir, function(fname)
				return _is_watched_lua(base_dir .. "/" .. fname)
			end)
		else
			_add_pump_entry(base_dir, nil, true)
			for _, fname in ipairs(_list_dir(base_dir)) do
				local fpath = base_dir .. "/" .. fname
				if _is_watched_lua(fpath) then
					_add_pump_entry(fpath, function() return true end, false)
				end
			end
		end
		Logger.debug(LOG, "Base dir watched for .lua: %s", base_dir)
	end

	local watcher_count = luv and #_luv_handles or #_pump_entries
	Logger.success(LOG, "File watchers armed: %d handle(s) (%s).", watcher_count, backend_label)
end

--- Drives both the debounce deadline check AND pump-mode mtime polling.
---
--- Call this from the daemon's onPeriodic callback (every ~250 ms).
--- In luv mode (inotify), only the deadline check runs — fs_event callbacks
--- fire within the luv event loop automatically. In pump mode, both the
--- deadline check AND mtime polling run.
function M.pump()
	-- Always check the debounce deadline (both backends).
	_check_deadline()

	-- Pump-mode mtime polling (no-op when luv handles the watching).
	if luv then return end
	if #_pump_entries == 0 then return end
	_pump_check_all()
end

--- Stops all file watchers and clears state. Safe to call at any time,
--- including before start() or after a prior stop(). Idempotent.
function M.stop()
	-- Close luv handles.
	for _, entry in ipairs(_luv_handles) do
		pcall(function() luv.fs_event_stop(entry.handle) end)
		pcall(function() luv.close(entry.handle) end)
	end
	_luv_handles = {}

	-- Clear pump entries.
	_pump_entries = {}

	-- Clear pending debounce deadline and adaptive-settle burst state.
	_reload_deadline = nil
	_burst_paths, _burst_count, _last_change_ms, _defer_count = {}, 0, 0, 0
	_base_dir = nil

	_on_reload = nil
	Logger.debug(LOG, "All file watchers stopped.")
end

--- Returns true when luv (inotify) backend is active.
--- @return boolean
function M.has_inotify()
	return luv ~= nil
end

return M

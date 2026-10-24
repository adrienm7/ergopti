--- infra/file_watchers.lua

--- ==============================================================================
--- MODULE: Auto-Reload File Watchers (Linux)
--- DESCRIPTION:
--- Inotify-based file watchers for the Linux daemon. Mirrors the macOS
--- infra/file_watchers.lua contract: watches hotstring TOML files and project
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
---    via a 500 ms timer (matches macOS infra/file_watchers.lua).
--- 3. Directory + per-file coverage: a directory-level watcher catches file
---    creation/deletion; per-file watchers catch in-place edits that some
---    filesystems may not propagate to the directory notification.
--- 4. Recursive personal-dir scan: watch_personal_dir recurses into sub-folders
---    and arms per-file watchers for each .toml (same guard depth as macOS).
--- 5. GC-safe: luv handles are pinned in a local table; M.stop() closes every
---    handle and clears the table.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")
local TextUtils = require("text_utils")

local Logger = require("logger.shim")
local Monotonic = require("infra.monotonic")
local reload_gate = require("reload_gate")
local FileSystem = require("adapters.file_system")
local RuntimeLog = require("diagnostics.runtime_log")
local Shell = require("adapters.shell_runner")
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

-- Personal coverage is an independent owner even when another root overlaps it.
local _personal_root, _personal_dirty, _personal_retry_at = nil, false, nil
local _personal_file = false
local _personal_epoch, _personal_revision = 0, 0
local _personal_entries, _personal_retiring = {}, {}
local _personal_anchor, _personal_rebind = nil, false
-- Last refusal text and next identity check of the selected file (see section 8).
local _personal_last_refusal, _personal_verify_at = nil, nil
-- How often the selected file's path is resolved again, in milliseconds.
local _PERSONAL_VERIFY_MS = 1000
local _reconcile_personal
local _personal_metadata
local _verify_personal_file

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

--- Removes directory separators without changing Linux filename identity.
--- Case and backslashes are literal; an all-slash path still names the root.
--- @param path string Directory path.
--- @return string path without trailing separators, or the filesystem root.
local function _directory_path(path)
	local normalized = path:gsub("/+$", "")
	return normalized == "" and "/" or normalized
end

--- Recognizes regular files from the supported POSIX, luv and GNU stat ports.
local function _personal_regular_file(attributes)
	if not attributes then return false end
	return attributes.kind == "regular" or attributes.kind == "file"
		or attributes.kind == "regular file" or attributes.kind == "regular empty file"
end

--- Returns the mtime of a path as a number (epoch seconds), or nil on error.
--- Uses a complete posix timespec when available, otherwise GNU date.
--- @param path string Absolute or relative path.
--- @return number|nil mtime in seconds, or nil.
local function _mtime(path)
	if posix and posix.stat then
		local ok, st = pcall(posix.stat, path)
		if ok and st and type(st) == "table" then
			-- Scalar receipts on luaposix builds contain only whole seconds.
			-- A missing nanosecond field cannot certify subsecond precision either.
			if type(st.mtime) == "table" then
				local seconds, nanoseconds = tonumber(st.mtime.sec), tonumber(st.mtime.nsec)
				if seconds and nanoseconds then
					return seconds + nanoseconds * 1e-9
				end
			end
		end
	end
	-- Fallback: date -r (GNU date), which reports fractional seconds via %N.
	-- `stat -c %Y` only has whole-second resolution, so two writes within the
	-- same wall-clock second are indistinguishable and a real edit can be
	-- missed entirely (file-watcher-mtime-subsecond-collision).
	local fh = io.popen("date -r " .. TextUtils.shell_quote(path) .. " +%s.%N 2>/dev/null", "r")
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
	local ok, fh = pcall(io.popen, "ls -1 " .. TextUtils.shell_quote(dir) .. " 2>/dev/null", "r")
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
	local fh = io.popen("test -d " .. TextUtils.shell_quote(path) .. " && echo 1 || echo 0", "r")
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

	if _personal_dirty then
		local epoch = _personal_epoch
		local reconciled = _reconcile_personal()
		if epoch ~= _personal_epoch then return end
		if reconciled then _personal_retry_at = nil else _personal_retry_at = _now_ms() + _debounce_sec * 1000 end
		-- Coverage is observational: refusal never withholds an accepted source
		-- burst. Actual activity while staging still extends the shared settle.
		if _reload_deadline and _now_ms() < _reload_deadline then return end
	end
	_reload_deadline = nil
	-- Name what changed. The paths were gathered for the settle heuristic and then
	-- thrown away, so a reload in the log could never be traced back to a file.
	local changed = RuntimeLog.describe_paths(_burst_paths)
	_burst_paths, _burst_count, _defer_count = {}, 0, 0
	Logger.info(LOG, "Debounced reload firing (%s).", changed)
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

	local protected, activated, activation_error = pcall(function()
		return luv.fs_event_start(handle, path, FS_EVENT_FLAGS, function(err, fname, events)
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

	if not protected or activated == nil or activated == false then
		local reason = protected and activation_error or activated
		Logger.warn(LOG, "luv.fs_event_start() failed for '%s': %s — skipping.", path, tostring(reason))
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
	for _, entry in pairs(_personal_entries) do
		local observed = not _personal_file or _personal_regular_file(_personal_metadata(entry.path))
		local mtime = observed and _mtime(entry.path) or nil
		if mtime ~= entry.last_mtime then
			entry.last_mtime = mtime
			changed[#changed + 1] = entry.path
			-- A selected file whose timestamp moved may be another file under the
			-- same name: resolve its identity again with the reload that follows.
			if entry.kind == "directory" or mtime == nil or _personal_file then
				_personal_dirty = true
				_personal_revision = _personal_revision + 1
			end
		end
	end
	if #changed > 0 then
		_schedule_reload("mtime poll", changed)
	end
end





-- ==========================================
-- ==========================================
-- ======= 8/ Recursive Personal Scan =======
-- ==========================================
-- ==========================================

--- Uses the shared checked command owner; partial failed output is never empty data.
local function _personal_command(command)
	local called, completed, output, detail = pcall(Shell.exec_checked, command)
	if not called or completed ~= true or type(output) ~= "string" then
		return nil, called and detail or "personal filesystem command refused"
	end
	return output
end

--- Keeps the existing POSIX no-follow / shell-follow directory policy.
_personal_metadata = function(path)
	-- The selected file is the user's explicit choice: a symlink to it (a dotfile
	-- manager's layout) names the file it points to, so it is judged by what it
	-- resolves to. Directory roots keep the no-follow policy below.
	if _personal_file and path == _personal_root and luv and type(luv.fs_stat) == "function" then
		local called, attributes = pcall(luv.fs_stat, path)
		if not called or type(attributes) ~= "table" or attributes.dev == nil or attributes.ino == nil then
			return nil, "selected TOML file metadata is unavailable: " .. path
		end
		return { dev = attributes.dev, ino = attributes.ino, kind = attributes.type }
	end
	if posix and type(posix.stat) == "function" then
		local called, attributes = pcall(posix.stat, path)
		if not called or type(attributes) ~= "table" or attributes.dev == nil or attributes.ino == nil then
			return nil, "personal filesystem metadata is unavailable: " .. path
		end
		return { dev = attributes.dev, ino = attributes.ino, kind = attributes.type or attributes.mode }
	end
	if luv and type(luv.fs_stat) == "function" then
		local called, attributes = pcall(luv.fs_stat, path)
		if not called or type(attributes) ~= "table" or attributes.dev == nil or attributes.ino == nil then
			return nil, "personal native filesystem metadata is unavailable: " .. path
		end
		return { dev = attributes.dev, ino = attributes.ino, kind = attributes.type }
	end
	local content, detail = _personal_command("LC_ALL=C stat -L -c '%d:%i:%F' -- " .. Shell.quote(path) .. " 2>/dev/null")
	if not content then return nil, detail end
	local device, inode, kind = content:match("^(%d+):(%d+):([^\r\n]+)\n$")
	if not device then return nil, "personal filesystem metadata is malformed: " .. path end
	return { dev = device, ino = inode, kind = kind }
end

--- A refused directory listing retains all admitted coverage for explicit retry.
local function _personal_list(path)
	local entries
	if posix and type(posix.dir) == "function" then
		local called, result = pcall(posix.dir, path)
		if not called or type(result) ~= "table" then return nil, "personal directory enumeration refused: " .. path end
		entries = result
	else
		local content, detail = _personal_command("ls -1A --zero -- " .. Shell.quote(path) .. " 2>/dev/null")
		if not content then return nil, detail end
		if content ~= "" and content:sub(-1) ~= "\0" then return nil, "personal directory enumeration has incomplete NUL framing" end
		entries = {}
		for name in content:gmatch("([^%z]*)%z") do entries[#entries + 1] = name end
	end
	local result, seen = {}, {}
	for _, name in ipairs(entries) do
		if type(name) ~= "string" or name == "" or name:find("/", 1, true) or seen[name] then
			return nil, "personal directory enumeration returned an invalid entry"
		end
		seen[name] = true
		if name ~= "." and name ~= ".." then result[#result + 1] = name end
	end
	return result
end

local function _same_personal_binding(entry, attributes)
	return entry and entry.dev == attributes.dev and entry.ino == attributes.ino and entry.kind == attributes.kind
end

--- Close requests remain pinned until the actual native callback acknowledges them.
local function _retire_personal(entry)
	entry.active, entry.staging = false, false
	if not entry.handle or entry.retired then return true end
	_personal_retiring[entry] = true
	if entry.close_requested then return false end
	if entry.started and not entry.stopped then
		local called, status, detail = pcall(entry.stop, entry.handle)
		if not called or status == nil or status == false then
			Logger.warn(LOG, "Personal watcher stop remains owned for '%s': %s.", entry.path, tostring(called and detail or status))
			return false
		end
		entry.stopped = true
	end
	entry.close_requested = true
	local called, status, detail = pcall(entry.close, entry.handle, function()
		entry.retired = true
		_personal_retiring[entry] = nil
	end)
	if not called or status == false or detail ~= nil then
		entry.close_requested = false
		Logger.warn(LOG, "Personal watcher close remains owned for '%s': %s.", entry.path, tostring(called and detail or status))
		return false
	end
	return entry.retired == true
end

local function _retry_personal_retirement()
	for entry in pairs(_personal_retiring) do _retire_personal(entry) end
end

local function _personal_rename(events)
	if type(events) ~= "table" then return false end
	if events.rename == true then return true end
	for _, event in ipairs(events) do if event == "rename" then return true end end
	return false
end

--- Admits only this exact active lexical binding and its original session.
local function _personal_event(entry, err, filename, events)
	if entry.epoch ~= _personal_epoch or _personal_root == nil or entry.retired or entry.close_requested then return end
	if entry.anchor_name and err then
		Logger.warn(LOG, "Personal parent fs_event error on '%s': %s.", entry.path, tostring(err))
		if entry.active and _personal_anchor == entry then
			_personal_anchor = nil
			_retire_personal(entry)
			_personal_dirty, _personal_rebind = true, true
			_personal_revision = _personal_revision + 1
			_personal_retry_at = _now_ms() + _debounce_sec * 1000
		elseif entry.staging then
			entry.anchor_failed = true
		end
		return
	end
	if entry.anchor_name then
		-- Observe only this admitted lexical root, never its parent's siblings.
		-- The parent's own removal or rename is reported under its own basename
		-- (inotify IN_MOVE_SELF / IN_DELETE_SELF): the root's path then names
		-- another directory, so it is a topology change of the root as well.
		if type(filename) == "string" and filename ~= "" then
			if filename ~= entry.anchor_name and not (filename == entry.parent_name and _personal_rename(events)) then return end
		elseif not _personal_rename(events) then
			return
		end
	end
	if not entry.active then
		if entry.staging then
			_personal_revision = _personal_revision + 1
			if not err then
				local changed = entry.path
				if entry.kind == "directory" and type(filename) == "string" and filename ~= "" then changed = entry.path .. "/" .. filename end
				_schedule_reload("personal staging activity: " .. changed, { changed })
			end
		end
		return
	end
	if (entry.anchor_name and _personal_anchor ~= entry) or (not entry.anchor_name and _personal_entries[entry.path] ~= entry) then return end
	if err then
		Logger.warn(LOG, "Personal fs_event error on '%s': %s.", entry.path, tostring(err))
		return
	end
	local changed, topology = entry.path, false
	if entry.anchor_name then
		changed, topology = _personal_root, true
		-- A deleted directory can reuse its inode before this event is drained.
		-- Rebind its sources rather than retaining watches on the old objects.
		if _personal_rename(events) then _personal_rebind = true end
	elseif entry.kind == "directory" then
		if type(filename) == "string" and filename ~= "" then
			changed = entry.path .. "/" .. filename
			local previous = _personal_entries[changed]
			if _is_toml(filename) then
				topology = _personal_rename(events)
			elseif previous and previous.kind == "directory" then
				topology = true
			else
				local attributes = _personal_metadata(changed)
				if not attributes or attributes.kind ~= "directory" then return end
				topology = true
			end
		elseif type(events) == "table" and next(events) ~= nil then
			topology = true
		else
			return
		end
	else
		topology = _personal_rename(events)
	end
	if topology then
		_personal_dirty = true
		_personal_revision = _personal_revision + 1
	end
	_schedule_reload("personal source: " .. changed, { changed })
end

--- Arms new directories before enumerating them; queued events cannot fall into a gap.
local function _new_personal_entry(path, attributes, epoch, anchor_name)
	local entry = { path = path, dev = attributes.dev, ino = attributes.ino, kind = attributes.kind,
		epoch = epoch, active = false, staging = true, anchor_name = anchor_name }
	if not luv then
		entry.last_mtime = _mtime(path)
		if entry.last_mtime == nil then return nil, "personal polling timestamp is unavailable: " .. path end
		return entry
	end
	entry.stop, entry.close = luv.fs_event_stop, luv.close
	local called, handle = pcall(luv.new_fs_event)
	if not called or not handle then return nil, "personal watcher allocation refused: " .. path end
	entry.handle = handle
	local protected, activated, detail = pcall(luv.fs_event_start, handle, path, FS_EVENT_FLAGS, function(err, filename, events)
		_personal_event(entry, err, filename, events)
	end)
	if not protected or activated == nil or activated == false then
		_retire_personal(entry)
		return nil, "personal watcher activation refused: " .. path .. ": " .. tostring(protected and detail or activated)
	end
	entry.started = true
	if entry.anchor_failed then _retire_personal(entry); return nil, "personal parent watcher failed during activation: " .. path end
	return entry
end

--- Keeps one native parent binding across removal/replacement of the admitted root.
--- Refusal remains retryable without discarding healthy recursive coverage.
local function _ensure_personal_anchor(epoch)
	if not luv or _personal_root == "/" then return true end
	local parent, name = _personal_root:match("^(.*)/([^/]+)$")
	if not parent then parent, name = ".", _personal_root elseif parent == "" then parent = "/" end
	local attributes = _personal_metadata(parent)
	if not attributes or attributes.kind ~= "directory" then return false end
	if _personal_anchor and _personal_anchor.path == parent and _same_personal_binding(_personal_anchor, attributes) then return true end
	local entry, detail = _new_personal_entry(parent, attributes, epoch, name)
	if not entry then
		Logger.warn(LOG, "Personal parent watcher admission refused for '%s': %s.", parent, tostring(detail))
		return false
	end
	entry.parent_name = parent:match("([^/]+)$")
	if epoch ~= _personal_epoch then _retire_personal(entry); return false end
	local previous = _personal_anchor
	_personal_anchor = entry
	entry.staging, entry.active = false, true
	if previous then _retire_personal(previous) end
	return true
end

--- Produces a complete census, keeping ambiguous or refused subtrees unjudged.
local function _personal_census(path, depth, desired, staged, previous, epoch)
	if depth > SCAN_MAX_DEPTH then
		Logger.warn(LOG, "Personal hotstrings scan hit max depth %d at '%s' — not descending further (directory cycle?).", SCAN_MAX_DEPTH, path)
		return true
	end
	local attributes, detail = _personal_metadata(path)
	if not attributes then return false, detail end
	local function admit(target, image)
		local entry = previous[target]
		if not _same_personal_binding(entry, image) then
			entry, detail = _new_personal_entry(target, image, epoch)
			if not entry then return false end
			staged[#staged + 1] = entry
		end
		desired[target] = entry
		return true
	end
	if _personal_file then
		-- A selected file never authorizes its siblings or a replacement directory.
		if path ~= _personal_root or not _personal_regular_file(attributes) then return false, "selected TOML file is unavailable: " .. path end
		if not admit(path, attributes) then return false, detail end
		local after
		after, detail = _personal_metadata(path)
		if not after or not _same_personal_binding(desired[path], after) then return false, detail or "selected TOML file changed during admission" end
		return true
	end
	if attributes.kind ~= "directory" then return false, "personal directory is unavailable: " .. path end
	if not admit(path, attributes) then return false, detail end
	local entries
	entries, detail = _personal_list(path)
	if not entries then return false, detail end
	for _, name in ipairs(entries) do
		local child = path .. "/" .. name
		local image
		image, detail = _personal_metadata(child)
		if not image then return false, detail end
		if image.kind == "directory" then
			local accepted
			accepted, detail = _personal_census(child, depth + 1, desired, staged, previous, epoch)
			if not accepted then return false, detail end
		elseif _is_toml(name) then
			if not admit(child, image) then return false, detail end
			local after
			after, detail = _personal_metadata(child)
			if not after or not _same_personal_binding(desired[child], after) then return false, detail or "personal file changed during admission" end
		end
	end
	local after
	after, detail = _personal_metadata(path)
	if not after or not _same_personal_binding(desired[path], after) then return false, detail or "personal directory changed during admission" end
	return true
end

_reconcile_personal = function()
	if _personal_root == nil then _personal_dirty = false; return true end
	local epoch, revision, previous = _personal_epoch, _personal_revision, _personal_entries
	local anchored = _ensure_personal_anchor(epoch)
	if epoch ~= _personal_epoch then return false end
	local desired, staged = {}, {}
	local called, accepted, detail = pcall(_personal_census, _personal_root, 1, desired, staged, _personal_rebind and {} or previous, epoch)
	if not called or not accepted or epoch ~= _personal_epoch or previous ~= _personal_entries or revision ~= _personal_revision then
		for _, entry in ipairs(staged) do _retire_personal(entry) end
		-- The retry runs twice a second: name a refusal once, then keep it quiet
		-- until the cause changes or coverage is repaired.
		local message = tostring(called and detail or accepted)
		if message ~= _personal_last_refusal then
			Logger.warn(LOG, "Personal watcher coverage remains unchanged; reconciliation refused: %s.", message)
		else
			Logger.debug(LOG, "Personal watcher coverage still refused: %s.", message)
		end
		_personal_last_refusal = message
		return false
	end
	_personal_last_refusal = nil
	local changed = false
	for path, entry in pairs(desired) do if previous[path] ~= entry then changed = true end end
	for path, entry in pairs(previous) do if desired[path] ~= entry then changed = true end end
	_personal_entries, _personal_dirty, _personal_rebind = desired, not anchored, false
	for _, entry in pairs(desired) do entry.staging, entry.active = false, true end
	for path, entry in pairs(previous) do if desired[path] ~= entry then _retire_personal(entry) end end
	return anchored, changed
end

--- Resolves the selected file's path again on a bounded cadence and rebinds when
--- it no longer names the admitted file. The kernel reports nothing to a watch
--- on the file or its parent when an ancestor directory is renamed or replaced,
--- when a symlink is retargeted from another directory, or (mtime polling) when
--- another file with the same timestamp takes the name: only the path's own
--- device and inode tell.
_verify_personal_file = function()
	if not _personal_file or _personal_root == nil or _personal_dirty then return end
	local now = _now_ms()
	if _personal_verify_at and now < _personal_verify_at then return end
	_personal_verify_at = now + _PERSONAL_VERIFY_MS
	local entry = _personal_entries[_personal_root]
	local attributes = _personal_metadata(_personal_root)
	local moved
	if entry and entry.active then
		moved = not attributes or not _same_personal_binding(entry, attributes)
	else
		moved = attributes ~= nil
	end
	if not moved then return end
	_personal_dirty, _personal_rebind = true, true
	_personal_revision = _personal_revision + 1
	_schedule_reload("personal source identity changed: " .. _personal_root, { _personal_root })
end

--- Repairs coverage on a bounded independent deadline, never once per idle pump.
local function _retry_personal_coverage()
	if not _personal_retry_at or _now_ms() < _personal_retry_at or _reload_deadline then return end
	local epoch = _personal_epoch
	local accepted, changed = _reconcile_personal()
	if epoch ~= _personal_epoch then return end
	if accepted then _personal_retry_at = nil else _personal_retry_at = _now_ms() + _debounce_sec * 1000 end
	if changed then
		-- A successful census may repair source coverage while the optional
		-- parent binding is still refused and retains its own retry deadline.
		-- Files could change while their refused bindings were unobserved. Admit
		-- one fresh consumer read through the existing settle/generation owner.
		_schedule_reload("personal coverage repaired", { _personal_root })
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
---   .personal_dir    string  Personal hotstrings directory or an existing selected TOML file.
---   .on_reload       function()  Called after the debounce window when a change is detected.
---   .now_ms          function() → number  Optional wall-clock source (ms) for tests.
function M.start(opts)
	opts = type(opts) == "table" and opts or {}
	local hotstrings_dir = opts.hotstrings_dir
	local base_dir       = opts.base_dir
	local personal_dir   = opts.personal_dir or ""
	assert(personal_dir == "" or _personal_root == nil, "Personal watchers are already armed")
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
		local clean_dir = _directory_path(personal_dir)
		local is_directory = _is_dir(clean_dir)
		-- A selected TOML file is the user's explicit choice (--config FILE.toml):
		-- a missing one is waited for, a symlink to one is followed, and any other
		-- object under that name is refused loudly instead of silently unwatched.
		local selected = not is_directory and _is_toml(clean_dir)
		local is_file = false
		if selected then
			_personal_file, _personal_root = true, clean_dir
			local attributes = _personal_metadata(clean_dir)
			_personal_file, _personal_root = false, nil
			if attributes == nil then
				is_file = true
				Logger.info(LOG, "Selected TOML file '%s' is absent; waiting for it to appear.", clean_dir)
			elseif _personal_regular_file(attributes) then
				is_file = true
			else
				Logger.warn(LOG, "Selected TOML path '%s' is not a regular file; it is not watched.", clean_dir)
			end
		end
		if is_directory or is_file then
			_personal_epoch = _personal_epoch + 1
			_personal_root, _personal_dirty = clean_dir, true
			_personal_file = is_file == true
			_personal_verify_at = _now_ms() + _PERSONAL_VERIFY_MS
			local epoch = _personal_epoch
			local reconciled = _reconcile_personal()
			if epoch ~= _personal_epoch then return false end
			if not reconciled then _personal_retry_at = _now_ms() + _debounce_sec * 1000 end
		end
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

	local watcher_count = (luv and #_luv_handles or #_pump_entries) + TableUtil.count(_personal_entries)
	if _personal_anchor then watcher_count = watcher_count + 1 end
	Logger.success(LOG, "File watchers armed: %d handle(s) (%s).", watcher_count, backend_label)
end

--- Drives both the debounce deadline check AND pump-mode mtime polling.
---
--- Call this from the daemon's onPeriodic callback (every ~250 ms).
--- In luv mode (inotify), only the deadline check runs — fs_event callbacks
--- fire within the luv event loop automatically. In pump mode, both the
--- deadline check AND mtime polling run.
function M.pump()
	_retry_personal_retirement()
	-- Always check the debounce deadline (both backends).
	_check_deadline()
	_retry_personal_coverage()
	_verify_personal_file()

	-- Pump-mode mtime polling (no-op when luv handles the watching).
	if luv then return end
	if #_pump_entries == 0 and next(_personal_entries) == nil then return end
	_pump_check_all()
end

--- Stops all file watchers and clears state. Safe to call at any time,
--- including before start() or after a prior stop(). Idempotent.
function M.stop()
	_personal_epoch = _personal_epoch + 1
	_personal_root, _personal_dirty, _personal_retry_at, _personal_rebind = nil, false, nil, false
	_personal_file, _personal_last_refusal, _personal_verify_at = false, nil, nil
	if _personal_anchor then _retire_personal(_personal_anchor); _personal_anchor = nil end
	for _, entry in pairs(_personal_entries) do _retire_personal(entry) end
	_personal_entries = {}
	_retry_personal_retirement()
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
	local retired = next(_personal_retiring) == nil
	Logger.debug(LOG, retired and "All file watchers stopped." or "File watchers deactivated; Personal native retirement remains owned.")
	return retired
end

--- Returns true when luv (inotify) backend is active.
--- @return boolean
function M.has_inotify()
	return luv ~= nil
end

return M

--- infra/logger_sink.lua

--- ==============================================================================
--- MODULE: Logger File Sink (Linux)
--- DESCRIPTION:
--- Installs the output channel that the shared logger core
--- (`_shared/lua/logger/init.lua`) deliberately does not provide. The core
--- formats a line, pushes it into a 200-entry ring buffer and then forwards it to
--- an injected sink — so without a sink every `Logger.*` call on this driver was
--- written nowhere: not to a file, not to stdout, not to the journal. Including
--- the two fatal errors the daemon can emit before exiting ("No keyboard device
--- found", "Keyboard hook failed to start").
---
--- FEATURES & RATIONALE:
--- 1. One log directory, resolved in one place. `M.log_dir()` is the single
---    resolver; the tray's "open logs" action and the keylogger fallback both call
---    it instead of re-deriving `$HOME` (three independent expressions before).
--- 2. Dual output. The daily file is the durable record; stdout is mirrored so
---    `journalctl --user -u ergopti-hotstrings` shows the same lines when the
---    daemon runs under systemd.
--- 3. Errors-only mirror. WARNING and ERROR are additionally appended to
---    `ErgoptiPlus_errors_<date>.log`, matching the convention the other two
---    drivers already follow: triaging a report starts with the short file.
--- 4. Date rollover repoints BOTH handles. Repointing only the main file is a
---    bug the macOS driver already shipped and fixed; doing it here from the start
---    is cheaper than rediscovering it.
--- 5. Dependency-free by construction. This module is installed before any
---    adapter, and `adapters/shell_runner.lua` itself requires the logger — so
---    using it here would be a load-time cycle. mkdir and mktemp quote
---    inline with the same POSIX idiom, and a unit test pins that quoting against
---    `shell_runner.quote()` so the two can never diverge.
--- 6. Never fatal. A directory that cannot be created degrades to stdout-only and
---    says so; a broken handle degrades to stdout. The daemon must not die
---    because logging failed.
--- 7. The logger boot. install() is also where this driver arms the core's
---    repeat collapsing (logger SPEC § 4.2), once; the daemon's periodic callback
---    and exit paths own its flushes.
--- ==============================================================================

local M = {}




-- ===============================
-- ===============================
-- ======= 1/ Constants ==========
-- ===============================
-- ===============================

--- Application folder and log file names, generated from
--- _shared/modules/paths/app_dirs.toml. The folder itself is resolved by
--- infra/config_paths (LogsDirPath, or ${XDG_STATE_HOME:-~/.local/state}/
--- ergopti_plus/logs).
local AppDirs = require("app_dirs")

--- Basename prefixes for the two files. The date suffix is the day the line was
--- written, not the day the daemon started, so a long-running daemon rolls over.
local MAIN_PREFIX   = AppDirs.files.unified_prefix
local ERRORS_PREFIX = AppDirs.files.errors_prefix
local LOG_EXT       = AppDirs.files.extension

--- Variants that are additionally mirrored into the errors-only file.
local ERROR_VARIANTS = { warn = true, error = true }

--- How many days of rolled files are kept. From the shared registry, which the
--- other two drivers already read for the same purpose — this driver rolled a
--- new pair of files every day and deleted none, so the directory grew without
--- bound for the life of the install. Read lazily, because this module is
--- loaded before the timing registry on some start-up paths and a logger that
--- cannot load is worse than one that keeps too much.
local _retention_days = nil

--- @return number|nil Days to keep, or nil when the registry is unreadable.
local function retention_days()
	if _retention_days ~= nil then return _retention_days end
	local ok, Timings = pcall(require, "infra.timings")
	if not ok or not Timings then return nil end
	local ok_value, value = pcall(Timings.count, "logger", "retention_days")
	if not ok_value or type(value) ~= "number" or value <= 0 then return nil end
	_retention_days = value
	return _retention_days
end

--- POSIX single-quote escape: close, insert an escaped quote, reopen.
--- Identical to `adapters/shell_runner.lua`'s QUOTE_ESCAPE; pinned by
--- `tests/unit/meta/test_logger_sink.lua` so the two cannot drift.
local QUOTE_ESCAPE = "'\\''"




-- ===================================
-- ===================================
-- ======= 2/ Module State ===========
-- ===================================
-- ===================================

--- Resolved log directory, or nil when it could not be created.
local _dir = nil

--- Date string the currently-open handles belong to ("YYYY-MM-DD").
local _date = nil

--- Open append handles. Either may be nil after an I/O failure.
local _main_handle   = nil
local _errors_handle = nil

--- True once M.install() has wired the sink into the shared core.
local _installed = false

--- True when the log directory could not be created; output is stdout-only.
local _stdout_only = false




-- =======================================
-- =======================================
-- ======= 3/ Path Resolution ============
-- =======================================
-- =======================================

--- Quotes a value for a POSIX shell command line.
--- @param value string Raw value.
--- @return string Single-quoted, escape-safe token.
function M.shell_quote(value)
	if value == nil then return "''" end
	local s = (type(value) == "string") and value or tostring(value)
	return "'" .. (s:gsub("'", QUOTE_ESCAPE)) .. "'"
end

--- Resolves the canonical log directory for this driver.
--- This is the single source: every consumer that needs the log path calls it
--- rather than re-deriving $HOME. Once the sink is installed it names the
--- folder the lines actually reach: a LogsDirPath saved in bootstrap storage
--- only takes effect when M.repoint() moves the sink there, and an opener or a
--- health check naming the saved folder before that would point at files
--- nobody writes. Before install it resolves the configured folder.
--- @return string Absolute path, no trailing slash.
function M.log_dir()
	if _installed and _dir then return _dir end
	return require("infra.config_paths").get_logs_dir()
end

--- The folder crash dumps are written to, inside the logs folder.
--- @return string Absolute path, no trailing slash.
function M.crash_reports_dir()
	return M.log_dir() .. "/" .. AppDirs.crash_reports_dir
end

--- Returns today's date stamp used in the log basenames.
--- @return string "YYYY-MM-DD".
local function today()
	return os.date("%Y-%m-%d")
end

--- Absolute path of the file the driver is writing to right now.
---
--- Exposed because the "open today's log" action needs it and the three pieces
--- that compose it — the directory, the prefix and the extension — are locals.
--- A caller that rebuilt the name from its own copy of "ErgoptiPlus_" would open
--- the wrong file the day either constant changed, and would do it silently:
--- xdg-open on a missing path fails without telling anyone.
--- @return string
function M.main_log_path()
	return M.log_dir() .. "/" .. MAIN_PREFIX .. today() .. LOG_EXT
end

--- Absolute path of today's errors-only mirror.
--- @return string
function M.errors_log_path()
	return M.log_dir() .. "/" .. ERRORS_PREFIX .. today() .. LOG_EXT
end

--- Creates the log directory if it is missing.
--- @param dir string Absolute directory path.
--- @return boolean True when the directory exists afterwards.
local function ensure_dir(dir)
	-- `mkdir -p` is idempotent, so this is safe to call on every install.
	local ok = os.execute("mkdir -p " .. M.shell_quote(dir) .. " 2>/dev/null")
	-- The actual log handles prove writability at install/repoint. A fixed probe
	-- here deleted unrelated files and followed unrelated symlinks.
	return ok == true or ok == 0
end




-- =========================================
-- =========================================
-- ======= 4/ Handle Lifecycle =============
-- =========================================
-- =========================================

--- Closes both handles, ignoring errors.
local function close_handles()
	if _main_handle then pcall(function() _main_handle:close() end) end
	if _errors_handle then pcall(function() _errors_handle:close() end) end
	_main_handle   = nil
	_errors_handle = nil
end

--- Opens (or reopens) both handles for the given date.
--- Both are repointed together: repointing only the main file leaves WARNING and
--- ERROR lines appended to yesterday's errors file forever.
--- @param date string "YYYY-MM-DD".
local function open_handles(date)
	close_handles()
	_date = date
	if not _dir then return end
	_main_handle   = io.open(_dir .. "/" .. MAIN_PREFIX   .. date .. LOG_EXT, "a")
	_errors_handle = io.open(_dir .. "/" .. ERRORS_PREFIX .. date .. LOG_EXT, "a")
end

--- Deletes rolled files older than the retention window.
---
--- Called at install and again on each rollover. Install is the one that
--- matters: a daemon started in the morning and stopped at night never crosses
--- midnight, so a purge that only ran on rollover would never run at all on the
--- most common usage pattern.
---
--- Both prefixes are swept explicitly. The errors prefix happens to begin with
--- the main one today, so one sweep would reach both — but that is a property
--- of two constants that are free to change independently, and relying on it
--- would make renaming one silently stop purging the other.
---
--- Uses `find -mtime` rather than parsing the date out of each name: the daemon
--- may have been off for a month, and a purge that only understands "yesterday"
--- leaves everything older untouched.
local function purge_old()
	local days = retention_days()
	if not days or not _dir then return end
	local quoted = M.shell_quote(_dir)
	for _, prefix in ipairs({ MAIN_PREFIX, ERRORS_PREFIX }) do
		os.execute(string.format(
			"find %s -maxdepth 1 -type f -name %s -mtime +%d -delete 2>/dev/null",
			quoted, M.shell_quote(prefix .. "*" .. LOG_EXT), math.floor(days)))
	end
end

--- Ensures the open handles belong to the current date.
local function rollover_if_needed()
	local now = today()
	if now ~= _date then
		open_handles(now)
		purge_old()
	end
end




-- ===========================================
-- ===========================================
-- ======= 5/ The Sink =======================
-- ===========================================
-- ===========================================

--- Appends one complete line and retires a failed native channel immediately.
--- @param handle userdata Owned append handle.
--- @param line string
--- @param channel string Technical diagnostic label.
--- @return userdata|nil The retained handle, only after write and flush succeed.
local function append_line(handle, line, channel)
	local protected, accepted, failure = pcall(function()
		local written, write_error = handle:write(line, "\n")
		if not written then return nil, write_error end
		return handle:flush()
	end)
	if protected and accepted ~= nil and accepted ~= false then return handle end
	pcall(function() handle:close() end)
	local reason = protected and failure or accepted
	-- Calling Logger here would recursively invoke this same failed sink.
	pcall(function()
		io.stderr:write("[logger_sink] " .. channel .. " write/flush failed: " .. tostring(reason)
			.. " — channel retired; logging continues through other outputs.\n")
	end)
	return nil
end

--- Writes one formatted line to every configured output.
--- Signature is the shared core's sink contract: (line, variant).
--- @param line string Already-formatted log line.
--- @param variant string One of debug/trace/done/info/start/success/warn/error.
local function sink(line, variant)
	-- stdout first: it is the output that cannot fail, and under systemd it is
	-- what journald records.
	io.stdout:write(line, "\n")
	io.stdout:flush()

	if _stdout_only then return end

	rollover_if_needed()

	if _main_handle then
		_main_handle = append_line(_main_handle, line, "main")
	end

	if _errors_handle and ERROR_VARIANTS[variant] then
		_errors_handle = append_line(_errors_handle, line, "errors")
	end
end




-- =============================================
-- =============================================
-- ======= 6/ Install / Uninstall ==============
-- =============================================
-- =============================================

--- Installs the file sink into the shared logger core.
--- Idempotent: a second call is a no-op so a reload cannot double-write.
--- @param logger table The logger module returned by require("logger.shim").
--- @param opts table|nil { log_dir = string } to override the resolved directory.
--- @return boolean True when a durable file sink is active, false when the sink
---   is installed but degraded to stdout-only.
function M.install(logger, opts)
	if type(logger) ~= "table" or type(logger.set_sink) ~= "function"
		or type(logger.enable_repeat_collapsing) ~= "function" then
		io.stderr:write("[logger_sink] install(): logger is not the shared core — no output installed.\n")
		return false
	end
	if _installed then return M.is_file_sink_active() end

	opts = opts or {}
	_dir = opts.log_dir or M.log_dir()

	if ensure_dir(_dir) then
		_stdout_only = false
		open_handles(today())
		if not _main_handle then
			-- Directory exists but the file will not open (permissions, full disk).
			_stdout_only = true
		end
		-- After the handles are open, so today's pair is never a candidate. This
		-- driver rolled a new pair every day and deleted none, so the directory
		-- grew for the life of the install.
		purge_old()
	else
		_stdout_only = true
	end

	logger.set_sink(sink)
	-- Armed here, behind the _installed guard, so a repeated install() stays the
	-- no-op it is documented to be instead of tripping the core's refusal of a
	-- second arming.
	logger.enable_repeat_collapsing()
	_installed = true

	if _stdout_only then
		io.stderr:write(
			"[logger_sink] Could not open a log file under " .. tostring(_dir) ..
			" — logging to stdout only.\n"
		)
		return false
	end
	return true
end

--- Creates a logs folder and proves it writable before anything names it: the
--- paths editor calls this before storing LogsDirPath, since install() at the
--- next start would otherwise fall back to stdout for a folder it cannot use.
--- @param dir string Absolute folder, no trailing slash.
--- @return boolean ready
--- @return string|nil error_message
function M.prepare_dir(dir)
	if type(dir) ~= "string" or dir:sub(1, 1) ~= "/" or dir:find("\0", 1, true) then
		return false, "the logs folder must be an absolute path"
	end
	if not ensure_dir(dir) then
		return false, "the logs folder '" .. dir .. "' could not be created"
	end
	-- mktemp exclusively creates a mode-0600 file. Only that owned path may be
	-- opened and removed; .write_probe may already belong to somebody else.
	local created, probe_path = pcall(function()
		local pipe = io.popen("mktemp -- " .. M.shell_quote(dir .. "/.ergopti-log-probe-XXXXXXXXXX")
			.. " 2>/dev/null", "r")
		if not pipe then return nil end
		local path = pipe:read("*a")
		pipe:close()
		-- Preserve any literal line breaks in dir; only mktemp's final LF frames it.
		if type(path) ~= "string" or path:sub(-1) ~= "\n" then return nil end
		path = path:sub(1, -2)
		local prefix = dir .. "/.ergopti-log-probe-"
		if path:sub(1, #prefix) ~= prefix or not path:sub(#prefix + 1):match("^%w+$") then return nil end
		return path
	end)
	if not created or not probe_path then
		return false, "the logs folder '" .. dir .. "' is not writable"
	end
	local opened, probe = pcall(io.open, probe_path, "a")
	local wrote, accepted = false, false
	local closed_ok, closed = false, false
	if opened and probe then
		wrote, accepted = pcall(function()
			return probe:write("Ergopti logger write probe.\n") and probe:flush()
		end)
		closed_ok, closed = pcall(probe.close, probe)
	end
	local removed_ok, removed = pcall(os.remove, probe_path)
	if not wrote or not accepted or not closed_ok or not closed or not removed_ok or not removed then
		return false, "the logs folder '" .. dir .. "' could not complete a write probe"
	end
	return true
end

--- Moves the installed file sink to the logs folder infra/config_paths now
--- resolves. The paths editor saves LogsDirPath while the daemon keeps running
--- (its reload re-reads the hotstrings, it does not restart the process), so
--- this is where a saved folder takes effect. The old folder keeps its files;
--- a folder that cannot be created or written leaves the sink where it was.
--- @return boolean moved True when the sink writes to the resolved folder, or
---   when no sink is installed yet (install() will resolve the same folder).
--- @return string|nil error_message Why the sink stayed where it was.
function M.repoint()
	if not _installed then return true end
	local target = require("infra.config_paths").get_logs_dir()
	if target == _dir and not _stdout_only and _main_handle ~= nil then return true end
	if not ensure_dir(target) then
		return false, "the logs folder '" .. target .. "' could not be created"
	end
	-- Acquired descriptors may still work after their path becomes unwritable.
	-- Keep them until the candidate is usable; reopening is not a rollback.
	local date = today()
	local main_ok, main = pcall(io.open, target .. "/" .. MAIN_PREFIX .. date .. LOG_EXT, "a")
	local errors_ok, errors = pcall(io.open, target .. "/" .. ERRORS_PREFIX .. date .. LOG_EXT, "a")
	if not main_ok or not main then
		if errors_ok and errors then pcall(function() errors:close() end) end
		return false, "the logs folder '" .. target .. "' is not writable"
	end
	local previous_main, previous_errors = _main_handle, _errors_handle
	_dir, _date = target, date
	_main_handle, _errors_handle = main, errors_ok and errors or nil
	_stdout_only = false
	if previous_main then pcall(function() previous_main:close() end) end
	if previous_errors then pcall(function() previous_errors:close() end) end
	purge_old()
	return true
end

--- Removes the sink and closes the handles. Exists for the test suite; production
--- installs once and keeps it for the process lifetime.
--- @param logger table|nil The logger module, to clear its sink.
function M.uninstall(logger)
	if type(logger) == "table" and type(logger.set_sink) == "function" then
		logger.set_sink(nil)
	end
	if type(logger) == "table" and type(logger.disable_repeat_collapsing) == "function" then
		logger.disable_repeat_collapsing()
	end
	close_handles()
	_dir         = nil
	_date        = nil
	_installed   = false
	_stdout_only = false
end

--- Reports whether a durable file sink is currently active.
--- @return boolean
function M.is_file_sink_active()
	return _installed and not _stdout_only and _main_handle ~= nil
end

return M

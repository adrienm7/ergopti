--- lib/logger_sink.lua

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
---    using it here would be a load-time cycle. The one shell-out (mkdir) quotes
---    inline with the same POSIX idiom, and a unit test pins that quoting against
---    `shell_runner.quote()` so the two can never diverge.
--- 6. Never fatal. A directory that cannot be created degrades to stdout-only and
---    says so; a broken handle degrades to stdout. The daemon must not die
---    because logging failed.
--- ==============================================================================

local M = {}




-- ===============================
-- ===============================
-- ======= 1/ Constants ==========
-- ===============================
-- ===============================

--- Environment variable that overrides the XDG data root.
local XDG_DATA_HOME_ENV = "XDG_DATA_HOME"

--- Fallback data root when XDG_DATA_HOME is unset, relative to $HOME.
local DEFAULT_DATA_HOME_REL = "/.local/share"

--- Log directory relative to the data root. Matches the path the tray menu opens.
local LOG_SUBDIR = "/ergopti/logs"

--- Basename prefixes for the two files. The date suffix is the day the line was
--- written, not the day the daemon started, so a long-running daemon rolls over.
local MAIN_PREFIX   = "ErgoptiPlus_"
local ERRORS_PREFIX = "ErgoptiPlus_errors_"
local LOG_EXT       = ".log"

--- Variants that are additionally mirrored into the errors-only file.
local ERROR_VARIANTS = { warn = true, error = true }

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
--- rather than re-deriving $HOME.
--- @return string Absolute path, no trailing slash.
function M.log_dir()
	local data_home = os.getenv(XDG_DATA_HOME_ENV)
	if not data_home or data_home == "" then
		local home = require("lib.config_paths").home()
		data_home = home .. DEFAULT_DATA_HOME_REL
	end
	return data_home .. LOG_SUBDIR
end

--- Returns today's date stamp used in the log basenames.
--- @return string "YYYY-MM-DD".
local function today()
	return os.date("%Y-%m-%d")
end

--- Creates the log directory if it is missing.
--- @param dir string Absolute directory path.
--- @return boolean True when the directory exists afterwards.
local function ensure_dir(dir)
	-- `mkdir -p` is idempotent, so this is safe to call on every install.
	local ok = os.execute("mkdir -p " .. M.shell_quote(dir) .. " 2>/dev/null")
	-- os.execute returns true / 0 / (true, "exit", 0) depending on the Lua build,
	-- so probe the result by actually opening a file rather than trusting it.
	local probe = io.open(dir .. "/.write_probe", "a")
	if probe then
		probe:close()
		os.remove(dir .. "/.write_probe")
		return true
	end
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

--- Ensures the open handles belong to the current date.
local function rollover_if_needed()
	local now = today()
	if now ~= _date then open_handles(now) end
end




-- ===========================================
-- ===========================================
-- ======= 5/ The Sink =======================
-- ===========================================
-- ===========================================

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
		_main_handle:write(line, "\n")
		_main_handle:flush()
	end

	if _errors_handle and ERROR_VARIANTS[variant] then
		_errors_handle:write(line, "\n")
		_errors_handle:flush()
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
	if type(logger) ~= "table" or type(logger.set_sink) ~= "function" then
		io.stderr:write("[logger_sink] install(): logger has no set_sink — no output installed.\n")
		return false
	end
	if _installed then return not _stdout_only end

	opts = opts or {}
	_dir = opts.log_dir or M.log_dir()

	if ensure_dir(_dir) then
		_stdout_only = false
		open_handles(today())
		if not _main_handle then
			-- Directory exists but the file will not open (permissions, full disk).
			_stdout_only = true
		end
	else
		_stdout_only = true
	end

	logger.set_sink(sink)
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

--- Removes the sink and closes the handles. Exists for the test suite; production
--- installs once and keeps it for the process lifetime.
--- @param logger table|nil The logger module, to clear its sink.
function M.uninstall(logger)
	if type(logger) == "table" and type(logger.set_sink) == "function" then
		logger.set_sink(nil)
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

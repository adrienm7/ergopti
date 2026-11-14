--- infra/logger_sink.lua

--- ==============================================================================
--- MODULE: Logger File Sink (Linux)
--- DESCRIPTION:
--- Installs the output channel that the shared logger core
--- (`_shared/core/logger/engine/init.lua`) deliberately does not provide. The core
--- formats a line, pushes it into a 200-entry ring buffer and then forwards it to
--- an injected sink — so without a sink every `Logger.*` call on this driver was
--- written nowhere: not to a file, not to stdout, not to the journal. Including
--- the two fatal errors the daemon can emit before exiting ("No keyboard device
--- found", "Keyboard hook failed to start").
---
--- FEATURES & RATIONALE:
--- 1. One log directory, resolved in one place. `M.log_dir()` is the single
---    resolver; the tray's "open logs" action and the keystats fallback both call
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
--- 5. No load-time shell adapter dependency: this module is installed before
---    adapters, and the shell adapter itself requires the logger. Only the later
---    public directory preparation loads its checked capture owner lazily, after
---    this module is available. mkdir quotes with the same POSIX idiom; a unit
---    test pins it against shell_runner.quote(). The retention purge
---    lists the folder in process through core/fs/engine/native_directory.lua, which
---    needs no logger.
--- 6. Never fatal. A directory that cannot be created degrades to stdout-only and
---    says so; a broken handle degrades to stdout. The daemon must not die
---    because logging failed.
--- 7. Privacy admission. Canonical rules and the captured account identity are
---    admitted before output. A missing policy or identity refuses startup;
---    directory/write failure still degrades to redacted stdout, never raw text.
--- 8. Topical fan-out. A line that matches a pattern of _generated/
---    logger_sub_files.lua (declared once in _shared/core/logger/data/sub_files.toml
---    for all three drivers) is also appended to that topic's file, so "what did
---    the hotstrings do?" opens ErgoptiPlus_hotstrings.log here exactly as on the
---    other two drivers. Topical files carry no date in their name; like macOS,
---    the first write of a new day truncates one whose first line is from an
---    earlier day. A refusing topical handle is retired for the day and reported
---    once, and never starves the main file.
--- 9. The logger boot. install() is also where this driver arms the core's
---    repeat collapsing (logger SPEC § 4.2), once; the daemon's periodic callback
---    and exit paths own its flushes.
--- ==============================================================================

local M = {}
local TextUtils = require("core.text.engine.utils_core")




-- ===============================
-- ===============================
-- ======= 1/ Constants ==========
-- ===============================
-- ===============================

--- Application folder and log file names, generated from
--- _shared/core/fs/data/paths/app_dirs.toml. The folder itself is resolved by
--- infra/config_paths (LogsDirPath, or ${XDG_STATE_HOME:-~/.local/state}/
--- ergopti/logs).
local AppDirs = require("core.fs.engine.app_dirs")
local Redact = require("diagnostics.engine.reports.redact")
local Json = require("core.text.engine.json")
local NativeDirectory = require("core.fs.engine.native_directory")

--- Topical routing table generated from _shared/core/logger/data/sub_files.toml:
--- an array of { name = "<file name>", patterns = { ... } }.
local SUB_FILES = require("_generated.logger_sub_files")

--- Basename prefixes for the two files. The date suffix is the day the line was
--- written, not the day the daemon started, so a long-running daemon rolls over.
local MAIN_PREFIX   = AppDirs.files.unified_prefix
local ERRORS_PREFIX = AppDirs.files.errors_prefix
local LOG_EXT       = AppDirs.files.extension

--- Variants that are additionally mirrored into the errors-only file.
local ERROR_VARIANTS = { warn = true, error = true }

--- Seconds in the whole day the retention window counts in.
local DAY_SECONDS = 86400

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

--- Open topical append handles keyed by file name. `false` marks a topic whose
--- handle was refused today: it stays retired until the next rollover, repoint
--- or reinstall instead of failing again on every line.
local _topical = {}

--- True once M.install() has wired the sink into the shared core.
local _installed = false

--- True when the log directory could not be created; output is stdout-only.
local _stdout_only = false

--- Pure redactor captured before the first output; never resolved on emission.
local _redact = nil

--- The configuration directory the user chose, followed for the redactor: its
--- folder and file names are personal, and the user may move it at runtime.
local _config_dir = nil




-- =======================================
-- =======================================
-- ======= 3/ Path Resolution ============
-- =======================================
-- =======================================

--- Admits canonical privacy data before any output or writable handle is acquired.
--- The existing pure layout resolver does not emit its missing-root diagnostic.
--- @param supplied table|nil Explicit identity dependency for portable fixtures.
--- @return function Captured immutable-context redactor.
local function admit_redaction(supplied)
	local context = supplied or { home = require("infra.config_paths").account_home(), user = require("infra.account_name").resolve() }
	assert(type(context) == "table", "logger_sink: privacy identity unavailable")
	assert(type(context.home) == "string" and context.home ~= "", "logger_sink: privacy identity unavailable: HOME is not an absolute directory")
	assert(type(context.user) == "string" and context.user ~= "", "logger_sink: privacy identity unavailable: no account name from USER, LOGNAME or the passwd entry")
	local captured = { home = context.home, user = context.user, case_insensitive = false }
	local Paths = require("core.fs.engine.paths")
	local root = Paths.shared_root_from(Paths.driver_root())
	assert(type(root) == "string" and root ~= "", "logger_sink: canonical privacy tree unavailable")
	local file = require("core.fs.engine.regular_file_reader").open_source(root .. "/diagnostics/data/redaction.json")
	assert(file, "logger_sink: canonical privacy policy unavailable")
	local read_ok, raw = pcall(file.read, file, "*a")
	local close_ok, closed = pcall(file.close, file)
	assert(read_ok and type(raw) == "string" and close_ok and closed == true,
		"logger_sink: canonical privacy policy read did not complete")
	local decoded, rules = pcall(Json.decode, raw)
	assert(decoded and type(rules) == "table", "logger_sink: canonical privacy policy invalid")
	for _, key in ipairs({ "home_placeholder", "account_placeholder", "secret_placeholder" }) do
		assert(type(rules[key]) == "string" and rules[key] ~= "", "logger_sink: canonical privacy placeholder invalid")
	end
	for _, key in ipairs({ "min_account_name_length", "bearer_min_length" }) do
		assert(type(rules[key]) == "number" and rules[key] >= 1 and rules[key] == math.floor(rules[key]),
			"logger_sink: canonical privacy bound invalid")
	end
	assert(type(rules.token_prefixes) == "table" and type(rules.secret_keys) == "table",
		"logger_sink: canonical privacy inventory invalid")
	assert(pcall(Redact.apply, "", rules, captured), "logger_sink: canonical privacy rules invalid")
	return function(text)
		return Redact.apply(text, rules, {
			home = captured.home, user = captured.user, case_insensitive = captured.case_insensitive,
			config_dir = _config_dir,
		})
	end
end

--- Quotes a value for a POSIX shell command line, as adapters/shell_runner's
--- quote does (tests/unit/infra/logger/test_logger_sink.lua pins the pair).
--- @param value string Raw value; nil becomes the empty word.
--- @return string Single-quoted, escape-safe token.
function M.shell_quote(value)
	if value == nil then return "''" end
	return TextUtils.shell_quote(value)
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

-- The "YYYY-MM-DD HH:MM:SS" face of the last second a line was stamped in, so
-- a burst of lines formats the calendar once instead of once per line.
local _stamp_second, _stamp_face = nil, nil

--- Builds a line timestamp with its milliseconds from the wall clock (luv's
--- gettimeofday), the format the macOS and Windows drivers already write. The
--- core's own default writes ":000", which left every Linux field log unable
--- to say how far apart two lines of the same second are.
--- @param gettimeofday function luv.gettimeofday, returning seconds and microseconds.
--- @return function timestamp() → "YYYY-MM-DD HH:MM:SS:mmm".
local function millisecond_timestamp(gettimeofday)
	return function()
		local seconds, microseconds = gettimeofday()
		if seconds ~= _stamp_second then
			_stamp_second, _stamp_face = seconds, os.date("%Y-%m-%d %H:%M:%S", seconds)
		end
		return string.format("%s:%03d", _stamp_face, math.floor(microseconds / 1000))
	end
end

--- The timestamp provider install() gives the core, or nil without luv: the
--- core's second-resolution default then stays, as the coarse monotonic clock
--- does (infra/monotonic.lua) on the same runtime.
--- @param gettimeofday function|nil A wall clock answering seconds, microseconds
---   (tests); luv's when absent.
--- @return function|nil
function M.timestamp_provider(gettimeofday)
	if gettimeofday then return millisecond_timestamp(gettimeofday) end
	local ok, luv = pcall(require, "luv")
	if not ok or type(luv) ~= "table" or type(luv.gettimeofday) ~= "function" then return nil end
	return millisecond_timestamp(luv.gettimeofday)
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

--- Closes every topical handle and forgets retirements, so the next matching
--- line decides afresh whether its file starts a new day.
local function close_topical()
	for _, handle in pairs(_topical) do
		if handle then pcall(function() handle:close() end) end
	end
	_topical = {}
end

--- io.open mode for a topical file: "a" when it is absent, empty or already
--- carries today's lines, "w" when its first line is from an earlier day. Topical
--- files have no date in their name, so this is what rotates them daily. An
--- unparsable first line is kept ("a"): a stale line is recoverable, a deleted
--- one is not.
--- @param path string Absolute topical file path.
--- @param date string "YYYY-MM-DD" of the line about to be written.
--- @return string "a" or "w".
local function topical_mode(path, date)
	local handle = require("core.fs.engine.regular_file_reader").open_source(path)
	if not handle then return "a" end
	local ok, first = pcall(handle.read, handle, "*l")
	pcall(handle.close, handle)
	if not ok or type(first) ~= "string" then return "a" end
	local stamp = first:match("^(%d%d%d%d%-%d%d%-%d%d) ")
	if stamp and stamp ~= date then return "w" end
	return "a"
end

--- Reports lost optional mirroring without recursively invoking the logger sink.
--- The main channel remains the durable owner; stderr failure cannot retire it.
--- @param path string Refused mirror path.
--- @param failure any Native or protected open refusal.
local function report_mirror_refusal(path, failure)
	local description = require("diagnostics.engine.reports.error_description").describe(failure)
	pcall(function()
		io.stderr:write(_redact("[logger_sink] errors channel could not be opened: " .. path
			.. " (" .. description .. ") — mirror disabled; logging continues through main and stdout.\n"))
	end)
end

--- Opens (or reopens) both handles for the given date.
--- Both are repointed together: repointing only the main file leaves WARNING and
--- ERROR lines appended to yesterday's errors file forever.
--- @param date string "YYYY-MM-DD".
local function open_handles(date)
	close_handles()
	close_topical()
	_date = date
	if not _dir then return end
	_main_handle = require("core.fs.engine.regular_file_writer").open(_dir .. "/" .. MAIN_PREFIX .. date .. LOG_EXT, "a")
	local errors_path = _dir .. "/" .. ERRORS_PREFIX .. date .. LOG_EXT
	local failure
	_errors_handle, failure = require("core.fs.engine.regular_file_writer").open(errors_path, "a")
	if _main_handle and not _errors_handle then report_mirror_refusal(errors_path, failure) end
end

--- Whether a basename is a generated daily log for this prefix.
--- @param name string Basename.
--- @param prefix string Literal prefix (no glob character).
--- @return string|nil date Admitted calendar date, or nil for an unrelated name.
local function rolled_name(name, prefix)
	if name:sub(1, #prefix) ~= prefix or name:sub(-#LOG_EXT) ~= LOG_EXT then return nil end
	local date = name:sub(#prefix + 1, #name - #LOG_EXT)
	if not date:match("^%d%d%d%d%-%d%d%-%d%d$") then return nil end
	local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local ok, stamp = pcall(os.time, { year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
	if not ok or not stamp or os.date("%Y-%m-%d", stamp) ~= date then return nil end
	return date
end

local function topical_name(name)
	for _, sub in ipairs(SUB_FILES) do if sub.name == name then return true end end
	return false
end

--- Reports a purge refusal on stderr: the sink cannot log through itself.
--- @param what string What was refused.
--- @param path string The path concerned.
--- @param message any The native refusal.
local function report_purge_refusal(what, path, message)
	pcall(function()
		io.stderr:write(_redact("[logger_sink] retention purge could not " .. what .. " " .. path .. ": "
			.. tostring(message) .. " — the file is kept.\n"))
	end)
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
--- Daily logs age by their date; topical views have no date and age by mtime.
---
--- The sweep selects regular files directly in the folder (never a link or
--- folder). Daily dates older than the calendar cutoff expire; declared topical
--- names retain the historical mtime cutoff of N + 1 whole days.
--- A refusal the purge used to discard is now reported, and never fatal.
local function purge_old()
	local days = retention_days()
	if not days or not _dir then return end
	-- A runtime without the native directory backend raises; for the purge that
	-- is one more refusal to report, so a log sink (and --help, which loads one
	-- before parsing its arguments) still installs where luv is absent.
	local listed, entries, message, code = pcall(NativeDirectory.entries, _dir)
	if not listed then
		report_purge_refusal("list", _dir, entries)
		return
	end
	if entries == nil then
		-- An absent folder holds nothing to purge; any other refusal is reported.
		if code ~= "ENOENT" then report_purge_refusal("list", _dir, message) end
		return
	end
	local now = os.time()
	local cutoff = now - (math.floor(days) + 1) * DAY_SECONDS
	local cutoff_calendar = os.date("*t", now)
	cutoff_calendar.day = cutoff_calendar.day - math.floor(days)
	cutoff_calendar.hour, cutoff_calendar.min, cutoff_calendar.sec, cutoff_calendar.isdst = 12, 0, 0, nil
	local cutoff_date = os.date("%Y-%m-%d", os.time(cutoff_calendar))
	for _, entry in ipairs(entries) do
		local name = entry.name
		local date = rolled_name(name, MAIN_PREFIX) or rolled_name(name, ERRORS_PREFIX)
		if entry.kind == "file" and (date or topical_name(name)) then
			local path = NativeDirectory.join(_dir, name)
			local inspected, stat, stat_message, stat_code = pcall(NativeDirectory.stat, path)
			if not inspected then
				report_purge_refusal("inspect", path, stat)
				stat = nil
			elseif not stat and stat_code ~= "ENOENT" then
				report_purge_refusal("inspect", path, stat_message)
			end
			-- lstat again: the entry may have been replaced since the listing.
			local expired = (date and date < cutoff_date) or (not date and stat and stat.modified and stat.modified < cutoff)
			if stat and stat.kind == "file" and expired then
				local called, removed, remove_error = pcall(os.remove, path)
				if not called or not removed then report_purge_refusal("delete", path, called and remove_error or removed) end
			end
		end
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
		io.stderr:write(_redact("[logger_sink] " .. channel .. " write/flush failed: " .. tostring(reason)
			.. " — channel retired; logging continues through other outputs.\n"))
	end)
	return nil
end

--- Appends the line to every topical file whose patterns match it.
--- @param line string Redacted, formatted line.
local function fan_out(line)
	for _, sub in ipairs(SUB_FILES) do
		local routed = false
		for _, pattern in ipairs(sub.patterns) do
			if line:find(pattern, 1, true) then routed = true; break end
		end
		if routed and _topical[sub.name] ~= false then
			local handle = _topical[sub.name]
			if not handle then
				local path = _dir .. "/" .. sub.name
				handle = require("core.fs.engine.regular_file_writer").open(path, topical_mode(path, _date))
				if not handle then
					pcall(function()
						io.stderr:write(_redact("[logger_sink] topical file " .. sub.name
							.. " could not be opened — retired for today; logging continues through other outputs.\n"))
					end)
				end
			end
			_topical[sub.name] = handle and append_line(handle, line, "topical " .. sub.name) or false
		end
	end
end

--- Writes one formatted line to every configured output.
--- Signature is the shared core's sink contract: (line, variant).
--- @param line string Already-formatted log line.
--- @param variant string One of debug/trace/done/info/start/success/warn/error.
local function sink(line, variant)
	-- Core-owned timestamp, severity and module identifiers must remain intact.
	-- The message is the untrusted/free-text part, including multiline errors.
	local prefix, body = line:match("^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d %[[A-Z]+%] %[[^%]]*%] )(.*)$")
	line = prefix and (prefix .. _redact(body)) or _redact(line)
	-- A closed or otherwise failing stdout must not starve the durable files.
	-- Under systemd this remains the mirror consumed by journald.
	pcall(function()
		io.stdout:write(line, "\n")
		io.stdout:flush()
	end)

	if _stdout_only then return end

	rollover_if_needed()

	if _main_handle then
		_main_handle = append_line(_main_handle, line, "main")
	end

	if _errors_handle and ERROR_VARIANTS[variant] then
		_errors_handle = append_line(_errors_handle, line, "errors")
	end

	if _dir then fan_out(line) end
end




-- =============================================
-- =============================================
-- ======= 6/ Install / Uninstall ==============
-- =============================================
-- =============================================

--- Installs the file sink into the shared logger core.
--- Idempotent: a second call is a no-op so a reload cannot double-write.
--- @param logger table The logger module returned by require("core.logger.engine.shim").
--- @param opts table|nil { log_dir = string, redaction_context = table } directory or fixture identity dependencies.
--- @return boolean True when a durable file sink is active, false when the sink
---   is installed but degraded to stdout-only.
function M.install(logger, opts)
	if type(logger) ~= "table" or type(logger.set_sink) ~= "function"
		or type(logger.enable_repeat_collapsing) ~= "function" then
		return false, "logger_sink: logger is not the shared core — no output installed"
	end
	if _installed then return M.is_file_sink_active() end

	opts = opts or {}
	_redact = admit_redaction(opts.redaction_context)
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
	-- Milliseconds on every line, unless a caller (a test) already owns the clock face.
	local stamp = logger.timestamp_fn == logger.default_timestamp and M.timestamp_provider() or nil
	if stamp then logger.timestamp_fn = stamp end
	-- Armed here, behind the _installed guard, so a repeated install() stays the
	-- no-op it is documented to be instead of tripping the core's refusal of a
	-- second arming.
	logger.enable_repeat_collapsing()
	_installed = true
	-- The folder resolved now; infra.config_paths hands over every later move.
	-- Read after the sink is live, so a line its storage read writes is redacted.
	M.follow_config_dir(require("infra.config_paths").get_config_dir())

	if _stdout_only then
		pcall(function()
			io.stderr:write(_redact(
				"[logger_sink] Could not open a log file under " .. tostring(_dir) ..
				" — logging to stdout only.\n"
			))
		end)
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
		local completed, path = require("adapters.shell_runner").exec_checked(
			"mktemp -- " .. M.shell_quote(dir .. "/.ergopti-log-probe-XXXXXXXXXX") .. " 2>/dev/null",
			{ output_dir = dir })
		if not completed then return nil end
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
	local opened, probe = pcall(require("core.fs.engine.regular_file_writer").open, probe_path, "a")
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
	local main_ok, main = pcall(require("core.fs.engine.regular_file_writer").open, target .. "/" .. MAIN_PREFIX .. date .. LOG_EXT, "a")
	local errors_path = target .. "/" .. ERRORS_PREFIX .. date .. LOG_EXT
	local errors_ok, errors, errors_failure = pcall(require("core.fs.engine.regular_file_writer").open, errors_path, "a")
	if not main_ok or not main then
		if errors_ok and errors then pcall(function() errors:close() end) end
		return false, "the logs folder '" .. target .. "' is not writable"
	end
	local previous_main, previous_errors = _main_handle, _errors_handle
	close_topical()
	_dir, _date = target, date
	_main_handle, _errors_handle = main, errors_ok and errors or nil
	_stdout_only = false
	if not _errors_handle then report_mirror_refusal(errors_path, errors_ok and errors_failure or errors) end
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
	if type(logger) == "table" and type(logger.default_timestamp) == "function" then
		logger.timestamp_fn = logger.default_timestamp
	end
	close_handles()
	close_topical()
	_dir         = nil
	_date        = nil
	_installed   = false
	_stdout_only = false
	_redact = nil
	_config_dir = nil
end

--- Follows the configuration directory the redactor masks. infra.config_paths
--- calls it after each committed move, so a line written after the user changes
--- folders hides the new folder's names, not the old ones.
--- @param dir string|nil Absolute directory, or nil/"" while none is resolved.
function M.follow_config_dir(dir)
	if dir ~= nil and type(dir) ~= "string" then
		error("logger_sink: the followed configuration directory must be a path", 2)
	end
	_config_dir = (dir ~= nil and dir ~= "") and dir or nil
end

--- Reports whether a durable file sink is currently active.
--- @return boolean
function M.is_file_sink_active()
	return _installed and not _stdout_only and _main_handle ~= nil
end

--- Captures this exact privacy admission without acquiring output resources.
--- Closing/reinstalling retires both functions; no successor is substituted.
--- @return function|nil redact Returns a string only while the admission is live.
--- @return function|nil current Strict lifetime acknowledgement.
function M.capture_redactor()
	if not _installed or type(_redact) ~= "function" then return nil end
	local active, factory = _redact, M.capture_redactor
	local function current()
		return _installed and _redact == active and M.capture_redactor == factory
			and rawequal(package.loaded["infra.logger_sink"], M)
	end
	return function(text)
		if type(text) ~= "string" or not current() then return nil end
		local ok, result = pcall(active, text)
		if not ok or type(result) ~= "string" or not current() then return nil end
		return result
	end, current
end

return M

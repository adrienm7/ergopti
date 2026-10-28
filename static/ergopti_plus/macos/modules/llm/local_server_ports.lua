--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (macOS)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/lua/llm/
--- local_server_ports.lua): the catalogue's processes, the servers' settings
--- files and their listening TCP ports.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the main thread on a command: pgrep, lsof and ps run as
---    asynchronous tasks, pgrep bounded by local_server_process_lookup_timeout_ms
---    and the others by local_server_port_scan_timeout_ms.
--- 2. pgrep -l -f lists only the processes whose command line names a
---    catalogue server. The full listing it replaces (ps -axww -o pid=,args=)
---    printed every argument of every process: on a managed Mac that outgrew
---    the 64 KiB pipe hs.task reads only once its child exits, so ps blocked on
---    its write until it was killed at its deadline (field report
---    2026-10-28). No shell runs it: pgrep is executed directly.
--- 3. pgrep, not lsof, finds the process: oMLX renames itself 'omlx-server'
---    with setproctitle, which a command line shows, while lsof names it by its
---    interpreter.
--- 4. lsof runs only when a running server gave no port by its command line or
---    settings file, and only on that server's pids (lsof -a -p), so a sweep
---    costs one pgrep in the common case.
--- 5. Without a process list, the settings files are still read, then every
---    listening socket (lsof -F pcn) and the command lines of its pids only
---    (ps -p), before a server falls back to its catalogue port.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local Timings        = require("infra.timings")
local FileSystem     = require("adapters.file_system")
local JsonCodec      = require("adapters.json_codec")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local Policy         = require("llm.local_server_ports")

local LOG = "llm.local_server_ports"

local PGREP_BIN = "/usr/bin/pgrep"
local PS_BIN    = "/bin/ps"
local LSOF_BIN  = "/usr/sbin/lsof"
local SH_BIN    = "/bin/sh"
-- lsof exits 1 when no socket matches; the script keeps that ordinary answer
-- from reading as a failed command
local LSOF_SCRIPT = '/usr/sbin/lsof -nP -a -iTCP -sTCP:LISTEN -p "$1" -F pn; exit 0'

-- pgrep, ps -p and lsof exit 1 when nothing matches: an empty answer, not a failure
local NONE_MATCHED = { [0] = true, [1] = true }
local SUCCEEDED    = { [0] = true }

-- Test seams: the asynchronous runner, the file reader and the home folder.
-- M._run(executable, args, on_done(exit_code, stdout)) returns (started, handle).
M._run = function(executable, args, on_done)
	local handle = ShellRunner.spawn(executable, args, function(exit_code, stdout)
		on_done(exit_code, stdout)
	end)
	if handle.isSettled() then return false, nil end
	return handle.start() == true, handle
end
M._read_file = function(path)
	local raw, status = FileSystem.read_with_status(path)
	if status == "ok" and type(raw) == "string" then return raw end
	return nil
end
M._home = function() return os.getenv("HOME") end





-- =====================================
-- =====================================
-- ======= 1/ Bounded Commands =========
-- =====================================
-- =====================================

--- Runs one command asynchronously and settles once: with its output, or with
--- nil and the cause when it failed, could not start or outlived its deadline.
--- @param label string Command name for the log.
--- @param executable string Absolute path.
--- @param args table Argument vector.
--- @param accepted table Exit codes that are an answer.
--- @param timeout_ms number Its deadline.
--- @param on_done function Receives (stdout|nil, cause|nil).
local function run_bounded(label, executable, args, accepted, timeout_ms, on_done)
	local settled, timer, handle = false, nil, nil
	local function finish(output, cause)
		if settled then return end
		settled = true
		if timer then TimerScheduler.cancel(timer) end
		on_done(output, cause)
	end
	local started
	started, handle = M._run(executable, args, function(exit_code, stdout)
		if accepted[exit_code] ~= true then
			Logger.warn(LOG, "%s failed (exit %s): no reading this sweep.", label, tostring(exit_code))
			finish(nil, label .. " exited with " .. tostring(exit_code))
			return
		end
		finish(type(stdout) == "string" and stdout or "")
	end)
	if started ~= true then
		Logger.error(LOG, "%s could not start.", label)
		finish(nil, label .. " could not start")
		return
	end
	timer = TimerScheduler.after(timeout_ms / 1000, function()
		if settled then return end
		Logger.warn(LOG, "%s outlived its %d ms deadline; terminating it.", label, timeout_ms)
		if handle and type(handle.terminate) == "function" then handle.terminate() end
		finish(nil, label .. " outlived its " .. tostring(timeout_ms) .. " ms deadline")
	end)
end

--- Joins pids for a command-line list.
--- @param pids table Array of numbers.
--- @return string
local function pid_list(pids)
	local listed = {}
	for index, pid in ipairs(pids) do listed[index] = tostring(pid) end
	return table.concat(listed, ",")
end





-- =====================================
-- =====================================
-- ======= 2/ Scan =====================
-- =====================================
-- =====================================

--- Finds where each catalogue server listens, asynchronously.
--- @param entries table Array of { id, descriptor, base_url } (catalogue order).
--- @param on_done function Receives results: id -> { id, running, pids,
---        base_url, port, source, detail } (llm.local_server_ports).
--- @return boolean started
function M.scan(entries, on_done)
	if type(entries) ~= "table" or type(on_done) ~= "function" then
		error("local_server_ports.scan: entries and on_done are required")
	end
	Policy.scan(entries, {
		os = "macos", home = M._home(), read_file = M._read_file, decode_json = JsonCodec.decode,
		logger = Logger, log = LOG,
		list_processes = function(pattern, on_text)
			run_bounded("pgrep", PGREP_BIN, { "-l", "-f", "-i", pattern }, NONE_MATCHED,
				Timings.ms("llm", "local_server_process_lookup_timeout_ms"), on_text)
		end,
		list_listeners = function(pids, on_listeners)
			run_bounded("lsof", SH_BIN, { "-c", LSOF_SCRIPT, "sh", pid_list(pids) }, SUCCEEDED,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), function(output)
					on_listeners(output and Policy.parse_lsof(output) or nil)
				end)
		end,
		list_all_listeners = function(on_listeners)
			run_bounded("lsof", LSOF_BIN, { "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn" }, NONE_MATCHED,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), function(output)
					on_listeners(output and Policy.parse_lsof(output) or nil)
				end)
		end,
		describe_processes = function(pids, on_text)
			run_bounded("ps", PS_BIN, { "-ww", "-o", "pid=,args=", "-p", pid_list(pids) }, NONE_MATCHED,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), on_text)
		end,
	}, on_done)
	return true
end

return M

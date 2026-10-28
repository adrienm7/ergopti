--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (macOS)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/lua/llm/
--- local_server_ports.lua): the process list, the servers' settings files and,
--- only for a running server that gave no port, its listening TCP ports.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the main thread on a command: ps and lsof run as
---    asynchronous tasks, each bounded by local_server_port_scan_timeout_ms.
--- 2. lsof runs only when a running server gave no port by its command line or
---    settings file, and only on that server's pids (lsof -a -p), so a sweep
---    costs one ps in the common case.
--- 3. ps, not lsof, finds the process: oMLX renames itself 'omlx-server' with
---    setproctitle, which ps shows, while lsof names it by its interpreter.
--- 4. An unreadable process list is an infrastructure failure, logged as an
---    error: every server is then probed at its catalogue port, said as such.
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

local PS_BIN   = "/bin/ps"
local SH_BIN   = "/bin/sh"
-- lsof exits 1 when no socket matches; the script keeps that ordinary answer
-- from reading as a failed command
local LSOF_SCRIPT = '/usr/sbin/lsof -nP -a -iTCP -sTCP:LISTEN -p "$1" -F pn; exit 0'

-- Test seams: the asynchronous runner, the file reader and the home folder
M._run = function(executable, args, on_done) return ShellRunner.run(executable, args, on_done) end
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
--- nil when it failed, could not start or outlived its deadline.
--- @param label string Command name for the log.
--- @param executable string Absolute path.
--- @param args table Argument vector.
--- @param on_done function Receives (stdout|nil).
local function run_bounded(label, executable, args, on_done)
	local settled, timer, handle = false, nil, nil
	local function finish(output)
		if settled then return end
		settled = true
		if timer then TimerScheduler.cancel(timer) end
		on_done(output)
	end
	local started
	started, handle = M._run(executable, args, function(ok, stdout)
		if ok ~= true then Logger.warn(LOG, "%s failed: no reading this sweep.", label) end
		finish(ok == true and (stdout or "") or nil)
	end)
	if started ~= true then
		Logger.error(LOG, "%s could not start.", label)
		finish(nil)
		return
	end
	local timeout_ms = Timings.ms("llm", "local_server_port_scan_timeout_ms")
	timer = TimerScheduler.after(timeout_ms / 1000, function()
		if settled then return end
		Logger.warn(LOG, "%s outlived its %d ms deadline; terminating it.", label, timeout_ms)
		if handle and type(handle.terminate) == "function" then handle.terminate() end
		finish(nil)
	end)
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
		list_processes = function(on_text) run_bounded("ps", PS_BIN, { "-axww", "-o", "pid=,args=" }, on_text) end,
		list_listeners = function(pids, on_listeners)
			local listed = {}
			for index, pid in ipairs(pids) do listed[index] = tostring(pid) end
			run_bounded("lsof", SH_BIN, { "-c", LSOF_SCRIPT, "sh", table.concat(listed, ",") }, function(output)
				on_listeners(output and Policy.parse_lsof(output) or nil)
			end)
		end,
	}, on_done)
	return true
end

return M

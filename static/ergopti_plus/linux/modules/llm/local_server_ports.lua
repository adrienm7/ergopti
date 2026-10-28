--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (Linux)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/lua/llm/
--- local_server_ports.lua): pgrep for the catalogue's processes, the servers'
--- settings files, and ss for the listening TCP ports of a running server that
--- gave no port by its command line or settings file. Every command runs
--- through the asynchronous process runner, bounded by
--- local_server_process_lookup_timeout_ms (pgrep) or
--- local_server_port_scan_timeout_ms (ss, ps -p), so the daemon's input loop
--- never waits.
---
--- FEATURES & RATIONALE:
--- 1. pgrep -a -f lists only the processes whose command line names a
---    catalogue server. The full listing it replaces (ps -eww -o pid=,args=)
---    printed every argument of every process, which a desktop with a browser
---    pushes past the runner's 64 KiB output bound: the sweep then had no
---    process list at all.
--- 2. Without a process list, the settings files are still read, then every
---    listening socket (ss names its owner) and the command lines of those
---    pids only (ps -p), before a server falls back to its catalogue port.
--- ==============================================================================

local M = {}
local Json = require("json")
local Logger = require("logger.shim")
local Timings = require("infra.timings")
local ProcessRunner = require("adapters.process_runner")
local ConfigPaths = require("infra.config_paths")
local Policy = require("llm.local_server_ports")

local LOG = "llm.local_server_ports"
-- A settings file larger than this is not a server's port setting
local MAX_SETTINGS_BYTES = 1048576

-- pgrep and ps -p exit 1 when no process matches: an empty answer, not a failure
local NONE_MATCHED = { [0] = true, [1] = true }
local SUCCEEDED    = { [0] = true }

--- Runs one command through the process runner, then hands its stdout on.
--- @param program string
--- @param args table
--- @param accepted table Exit codes that are an answer.
--- @param timeout_ms number Its deadline.
--- @param on_text function Receives stdout, or nil and the cause when the command failed.
local function run(program, args, accepted, timeout_ms, on_text)
	local settled = false
	local function finish(text, cause)
		if settled then return end
		settled = true
		on_text(text, cause)
	end
	local admitted = M._run(program, args, { timeout_ms = timeout_ms },
		function(result)
			-- A deadline, an output bound or a failed start reads as exit code -1
			if type(result) ~= "table" or accepted[result.exit_code] ~= true then
				local cause = tostring(type(result) == "table" and (result.error or result.exit_code) or "no result")
				Logger.warn(LOG, "%s failed (%s): no reading this sweep.", program, cause)
				finish(nil, program .. ": " .. cause)
				return
			end
			finish(result.stdout or "")
		end)
	-- A refused admission may never call back (runner shutting down)
	if admitted ~= true then finish(nil, program .. " was not admitted") end
end

--- Joins pids for a command-line list.
--- @param pids table Array of numbers.
--- @return string
local function pid_list(pids)
	local listed = {}
	for index, pid in ipairs(pids) do listed[index] = tostring(pid) end
	return table.concat(listed, ",")
end

-- Test seams: the process runner, the file reader and the home folder
M._run = function(program, args, options, callback) return ProcessRunner.run(program, args, options, callback) end
M._read_file = function(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local raw = file:read(MAX_SETTINGS_BYTES)
	file:close()
	return raw
end
-- The account home only: a server's settings file is never looked for in the
-- temporary folder home() falls back to when HOME is unset.
M._home = function() return ConfigPaths.account_home() end

--- Finds where each catalogue server listens, asynchronously.
--- @param entries table Array of { id, descriptor, base_url } (catalogue order).
--- @param on_done function Receives results: id -> llm.local_server_ports result.
function M.scan(entries, on_done)
	if type(entries) ~= "table" or type(on_done) ~= "function" then
		error("local_server_ports.scan: entries and on_done are required")
	end
	--- Reads every listening socket with its owner.
	--- @param on_listeners function Receives parsed rows, or nil when unread.
	local function listeners(on_listeners)
		run("ss", { "-Hltnp" }, SUCCEEDED, Timings.ms("llm", "local_server_port_scan_timeout_ms"), function(output)
			on_listeners(output and Policy.parse_ss(output) or nil)
		end)
	end
	Policy.scan(entries, {
		os = "linux", home = M._home(), read_file = M._read_file, decode_json = Json.decode,
		logger = Logger, log = LOG,
		list_processes = function(pattern, on_text)
			run("pgrep", { "-a", "-f", "-i", pattern }, NONE_MATCHED,
				Timings.ms("llm", "local_server_process_lookup_timeout_ms"), on_text)
		end,
		-- ss names the owner of a socket only for the user's own processes,
		-- which is where a local server the user started runs
		list_listeners = function(_, on_listeners) listeners(on_listeners) end,
		list_all_listeners = listeners,
		describe_processes = function(pids, on_text)
			run("ps", { "-ww", "-o", "pid=,args=", "-p", pid_list(pids) }, NONE_MATCHED,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), on_text)
		end,
	}, on_done)
end

return M

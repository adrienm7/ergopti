--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (Linux)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/lua/llm/
--- local_server_ports.lua): ps for the process list, the servers' settings
--- files, and ss for the listening TCP ports of a running server that gave no
--- port by its command line or settings file. Both commands run through the
--- asynchronous process runner, bounded by local_server_port_scan_timeout_ms,
--- so the daemon's input loop never waits.
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

--- Runs one command through the process runner, then hands its stdout on.
--- @param program string
--- @param args table
--- @param on_text function Receives stdout, or nil when the command failed.
local function run(program, args, on_text)
	local settled = false
	local function finish(text)
		if settled then return end
		settled = true
		on_text(text)
	end
	local admitted = M._run(program, args, { timeout_ms = Timings.ms("llm", "local_server_port_scan_timeout_ms") },
		function(result)
			if type(result) ~= "table" or result.exit_code ~= 0 then
				Logger.warn(LOG, "%s failed (%s): no reading this sweep.", program,
					tostring(type(result) == "table" and (result.error or result.exit_code) or "no result"))
				finish(nil)
				return
			end
			finish(result.stdout or "")
		end)
	-- A refused admission may never call back (runner shutting down)
	if admitted ~= true then finish(nil) end
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
	Policy.scan(entries, {
		os = "linux", home = M._home(), read_file = M._read_file, decode_json = Json.decode,
		logger = Logger, log = LOG,
		list_processes = function(on_text) run("ps", { "-eww", "-o", "pid=,args=" }, on_text) end,
		-- ss names the owner of a socket only for the user's own processes,
		-- which is where a local server the user started runs
		list_listeners = function(_, on_listeners)
			run("ss", { "-Hltnp" }, function(output) on_listeners(output and Policy.parse_ss(output) or nil) end)
		end,
	}, on_done)
end

return M

--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (Linux)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/lua/llm/
--- local_server_ports.lua): the command lines of the catalogue's processes
--- from /proc, the servers' settings files, and ss for the listening TCP ports
--- of a running server that gave no port by its command line or settings
--- file. The /proc walk runs in slices on the timer loop, bounded by
--- local_server_process_lookup_timeout_ms (catalogue lookup) or
--- local_server_port_scan_timeout_ms (listening pids), and ss runs through the
--- asynchronous process runner, so the daemon's input loop never waits.
---
--- FEATURES & RATIONALE:
--- 1. /proc/<pid>/cmdline, not pgrep or ps: busybox pgrep has neither -a nor
---    -i and busybox ps has neither -ww nor -p, and on Alpine the busybox
---    applet is found first even with procps-ng installed, so every server read
---    as stopped. The kernel's own record needs no tool on any distribution.
--- 2. Only the rows the shared pattern matches leave the walk: the full listing
---    (ps -eww -o pid=,args=) it replaces printed every argument of every
---    process, which a desktop with a browser pushes past the runner's 64 KiB
---    output bound.
--- 3. A pid that vanishes during the walk, or whose command line /proc hides
---    (hidepid, another user's process), is skipped: it is no server the user
---    can reach as theirs. Only an unreadable /proc fails the reading.
--- 4. Without a process list, the settings files are still read, then every
---    listening socket (ss names its owner) and the command lines of those
---    pids only, before a server falls back to its catalogue port.
--- ==============================================================================

local M = {}
local Json = require("json")
local Logger = require("logger.shim")
local Timings = require("infra.timings")
local Monotonic = require("infra.monotonic")
local ProcessRunner = require("adapters.process_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local ConfigPaths = require("infra.config_paths")
local Policy = require("llm.local_server_ports")

local LOG = "llm.local_server_ports"
-- A settings file larger than this is not a server's port setting
local MAX_SETTINGS_BYTES = 1048576
-- Bytes of a command line read: ports and names sit well inside this
local MAX_CMDLINE_BYTES = Timings.count("limits", "proc_cmdline_bytes")
-- Pids read per slice before the walk yields to the loop
local PIDS_PER_SLICE = 128

local SUCCEEDED = { [0] = true }

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

--- Reads the command lines of pids in slices, keeping the "pid command" rows
--- the filter accepts, within a deadline.
--- @param pids table Array of numbers.
--- @param keep function Receives a command line, returns whether to keep it.
--- @param timeout_ms number The whole walk's deadline.
--- @param on_text function Receives the rows, or nil and the cause.
local function read_command_lines(pids, keep, timeout_ms, on_text)
	local deadline = M._now_ms() + timeout_ms
	local rows, index = {}, 1
	local function slice()
		local last = math.min(index + PIDS_PER_SLICE - 1, #pids)
		for position = index, last do
			local pid = pids[position]
			local raw = M._read_cmdline(pid)
			-- Arguments are NUL-terminated (LuaJIT patterns cannot name NUL, %c
			-- does, and turns a newline inside an argument into a space so it
			-- cannot split the row); a kernel thread or a zombie has none
			local command = raw and raw:gsub("%c", " "):gsub("%s+$", "") or ""
			if command ~= "" and keep(command) then rows[#rows + 1] = tostring(pid) .. " " .. command end
		end
		index = last + 1
		if index > #pids then on_text(table.concat(rows, "\n")); return end
		if M._now_ms() > deadline then
			local cause = string.format("/proc walk did not finish within %d ms", timeout_ms)
			Logger.warn(LOG, "%s: no reading this sweep.", cause)
			on_text(nil, cause)
			return
		end
		if not M._defer(slice) then
			Logger.warn(LOG, "The /proc walk could not yield to the loop: no reading this sweep.")
			on_text(nil, "/proc walk was not scheduled")
		end
	end
	slice()
end

--- Lists the pids /proc shows.
--- @return table|nil pids Array of numbers, or nil when /proc is unreadable.
--- @return string|nil cause
local function proc_pids()
	local names, cause = M._list_proc()
	if not names then return nil, cause end
	local pids = {}
	for _, name in ipairs(names) do
		if name:match("^%d+$") then pids[#pids + 1] = tonumber(name) end
	end
	return pids
end

-- Test seams: the process runner, /proc, the loop, the file reader and the home folder
M._run = function(program, args, options, callback) return ProcessRunner.run(program, args, options, callback) end
M._proc_root = "/proc"
M._list_proc = function()
	local available, uv = pcall(require, "luv")
	if not available or type(uv.fs_scandir) ~= "function" then return nil, "luv is unavailable to read /proc" end
	local iterator, failure = uv.fs_scandir(M._proc_root)
	if not iterator then return nil, "/proc is unreadable: " .. tostring(failure) end
	local names = {}
	while true do
		local name = uv.fs_scandir_next(iterator)
		if name == nil then break end
		names[#names + 1] = name
	end
	return names
end
M._read_cmdline = function(pid)
	-- A vanished pid or a hidden one (hidepid) cannot be opened: no row
	local file = io.open(M._proc_root .. "/" .. tostring(pid) .. "/cmdline", "rb")
	if not file then return nil end
	local raw = file:read(MAX_CMDLINE_BYTES)
	file:close()
	return raw
end
M._now_ms = function() return Monotonic.now_ms() end
M._defer = function(fn) return TimerScheduler.after(0, fn).fired ~= true end
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
			local pids, cause = proc_pids()
			if not pids then
				Logger.warn(LOG, "%s: no reading this sweep.", cause)
				on_text(nil, cause)
				return
			end
			read_command_lines(pids, Policy.process_matcher(pattern),
				Timings.ms("llm", "local_server_process_lookup_timeout_ms"), on_text)
		end,
		-- ss names the owner of a socket only for the user's own processes,
		-- which is where a local server the user started runs
		list_listeners = function(_, on_listeners) listeners(on_listeners) end,
		list_all_listeners = listeners,
		describe_processes = function(pids, on_text)
			read_command_lines(pids, function() return true end,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), on_text)
		end,
	}, on_done)
end

return M

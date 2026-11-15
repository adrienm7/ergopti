--- modules/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Scan (Linux)
--- DESCRIPTION:
--- Reads the machine for the shared port policy (_shared/ai/engine/
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
local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.shim")
local Timings = require("core.timing.engine.timings")
local Monotonic = require("core.logger.engine.monotonic")
local ProcessRunner = require("core.process.adapters.runner")
local TimerScheduler = require("core.events.timer_scheduler")
local ConfigPaths = require("infra.config_paths")
local Policy = require("ai.engine.local_servers.ports_core")

local LOG = "ai.engine.local_servers.ports_core"
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
local function run(program, args, accepted, timeout_ms, on_text, scope)
	local settled = false
	local function finish(text, cause)
		if settled or (scope and scope:is_cancelled()) then return end
		settled = true
		on_text(text, cause)
	end
	local start = scope and function(program_name, arguments, options, callback)
		return scope:run(program_name, arguments, options, callback)
	end or M._run
	local admitted = start(program, args, { timeout_ms = timeout_ms },
		function(result)
			-- A zero-exit leader may still leave an unretired process group;
			-- that supervision error makes its captured output inconclusive.
			if type(result) ~= "table" or result.error ~= nil or accepted[result.exit_code] ~= true then
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
local function read_command_lines(pids, keep, timeout_ms, on_text, scope)
	local deadline = M._now_ms() + timeout_ms
	local rows, index = {}, 1
	local function slice()
		if scope and not scope:admitted() then scope:cancel(); return end
		local last = math.min(index + PIDS_PER_SLICE - 1, #pids)
		for position = index, last do
			if scope and not scope:admitted() then scope:cancel(); return end
			local pid = pids[position]
			local raw = M._read_cmdline(pid)
			-- Arguments are NUL-terminated (LuaJIT patterns cannot name NUL, %c
			-- does, and turns a newline inside an argument into a space so it
			-- cannot split the row); a kernel thread or a zombie has none
			local command = raw and raw:gsub("%c", " "):gsub("%s+$", "") or ""
			if command ~= "" and keep(command) then rows[#rows + 1] = tostring(pid) .. " " .. command end
		end
		index = last + 1
		if M._now_ms() > deadline then
			local cause = string.format("/proc walk did not finish within %d ms", timeout_ms)
			Logger.warn(LOG, "%s: no reading this sweep.", cause)
			on_text(nil, cause)
			return
		end
		if index > #pids then on_text(table.concat(rows, "\n")); return end
		local function refused()
			if scope and scope:is_cancelled() then return end
			Logger.warn(LOG, "The /proc walk could not yield to the loop: no reading this sweep.")
			on_text(nil, "/proc walk was not scheduled")
		end
		local deferred = scope and scope:defer(slice, refused) or (not scope and M._defer(slice))
		if not deferred then refused() end
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
-- An incomplete read or close is not usable discovery evidence. Always release
-- the acquired stream, including when a native read raises.
local function read_bounded(file, limit, require_complete)
	if not file then return nil end
	local read_ok, raw = pcall(file.read, file, limit + (require_complete and 1 or 0))
	local close_ok, closed = pcall(file.close, file)
	if not read_ok or type(raw) ~= "string" or not close_ok or closed ~= true then return nil end
	if require_complete and #raw > limit then return nil end
	return raw
end

M._read_cmdline = function(pid)
	-- A vanished pid or a hidden one (hidepid) cannot be opened: no row
	local file = io.open(M._proc_root .. "/" .. tostring(pid) .. "/cmdline", "rb")
	-- A truncated final argument may look like a different valid port.
	return read_bounded(file, MAX_CMDLINE_BYTES, true)
end
M._now_ms = function() return Monotonic.now_ms() end
M._defer = function(fn) return TimerScheduler.after(0, fn).fired ~= true end
M._read_file = function(path)
	local file = require("core.fs.engine.regular_file_reader").open_source(path)
	return read_bounded(file, MAX_SETTINGS_BYTES, true)
end
-- The account home only: a server's settings file is never looked for in the
-- temporary folder home() falls back to when HOME is unset.
M._home = function() return ConfigPaths.account_home() end

--- Finds where each catalogue server listens, asynchronously.
--- @param entries table Array of { id, descriptor, base_url } (catalogue order).
--- @param on_done function Receives results: id -> llm.local_server_ports result.
local function scan(entries, on_done, scope)
	if type(entries) ~= "table" or type(on_done) ~= "function" then
		error("local_server_ports.scan: entries and on_done are required")
	end
	--- Reads every listening socket with its owner.
	--- @param on_listeners function Receives parsed rows, or nil when unread.
	local function listeners(on_listeners)
		run("ss", { "-Hltnp" }, SUCCEEDED, Timings.ms("llm", "local_server_port_scan_timeout_ms"), function(output)
			on_listeners(output and Policy.parse_ss(output) or nil)
		end, scope)
	end
	local function read_file(path)
		if scope and not scope:admitted() then scope:cancel(); return nil end
		local content = M._read_file(path)
		if scope and not scope:admitted() then scope:cancel(); return nil end
		return content
	end
	Policy.scan(entries, {
		os = "linux", home = M._home(), read_file = read_file, decode_json = Json.decode,
		logger = Logger, log = LOG,
		list_processes = function(pattern, on_text)
			local pids, cause = proc_pids()
			if not pids then
				Logger.warn(LOG, "%s: no reading this sweep.", cause)
				on_text(nil, cause)
				return
			end
			read_command_lines(pids, Policy.process_matcher(pattern),
				Timings.ms("llm", "local_server_process_lookup_timeout_ms"), on_text, scope)
		end,
		-- ss names the owner of a socket only for the user's own processes,
		-- which is where a local server the user started runs
		list_listeners = function(_, on_listeners) listeners(on_listeners) end,
		list_all_listeners = listeners,
		describe_processes = function(pids, on_text)
			read_command_lines(pids, function() return true end,
				Timings.ms("llm", "local_server_port_scan_timeout_ms"), on_text, scope)
		end,
	}, on_done)
end

--- Legacy callback API; its existing process and timer ownership is unchanged.
function M.scan(entries, on_done)
	return scan(entries, on_done, nil)
end

--- Starts a scan with exact child process and timer ownership.
--- A throwing constructor retains unknown debt rather than inventing an ACK.
function M.scan_owned(entries, on_done, admission)
	if type(entries) ~= "table" or type(on_done) ~= "function"
		or (admission ~= nil and type(admission) ~= "function") then
		error("local_server_ports.scan_owned: entries and on_done are required")
	end
	local scope, children, tokens = {}, {}, {}
	local constructing, cancelled, cancelling_scope, observing, completed, uncertain = 0, false, false, false, false, false
	function scope:admitted()
		if cancelled then return false end
		if admission == nil then return true end
		constructing = constructing + 1
		local ok, current = pcall(admission)
		constructing = constructing - 1
		return ok and current == true and not cancelled
	end
	local function add(start)
		constructing = constructing + 1
		local called, child = pcall(start)
		constructing = constructing - 1
		if not called or type(child) ~= "table" or type(child.cancel) ~= "function"
			or type(child.is_settled) ~= "function" then
			uncertain = true
			scope.failed = true
			scope:cancel()
			Logger.error(LOG, "Owned local server scan child could not be acquired.")
			return nil
		end
		local record = { child = child, cancel = child.cancel, settled = child.is_settled }
		children[#children + 1] = record
		if cancelled then pcall(record.cancel, child) end
		return child
	end
	local function dispatch(callback, ...)
		constructing = constructing + 1
		if not scope:admitted() then
			scope:cancel()
			constructing = constructing - 1
			return
		end
		local ok = pcall(callback, ...)
		constructing = constructing - 1
		if not ok then
			scope.failed, uncertain = true, true
			scope:cancel()
			Logger.error(LOG, "Owned local server scan callback raised an error.")
		end
	end
	function scope:is_cancelled() return cancelled end
	function scope:is_settled()
		if observing or constructing ~= 0 or uncertain or not (completed or cancelled) then return false end
		observing = true
		local all_settled = true
		for _, record in ipairs(children) do
			local ok, settled = pcall(record.settled, record.child)
			if not ok or settled ~= true then all_settled = false; break end
		end
		observing = false
		return all_settled and constructing == 0 and not uncertain and (completed or cancelled)
	end
	function scope:cancel()
		if cancelling_scope then return false end
		cancelled, cancelling_scope = true, true
		constructing = constructing + 1
		for _, record in ipairs(children) do pcall(record.cancel, record.child) end
		constructing = constructing - 1
		cancelling_scope = false
		return self:is_settled()
	end
	function scope:run(program, args, options, callback)
		if not self:admitted() then self:cancel(); return false end
		local token = {}
		tokens[#tokens + 1] = token
		local owner = "local-server-port:" .. tostring(token)
		local child = add(function()
			return M._owned_process(program, args, { owner = owner, timeout_ms = options.timeout_ms,
				authorized = function() return scope:admitted() end }, function(result)
				dispatch(callback, result)
			end)
		end)
		if child == nil or not self:admitted() then self:cancel(); return false end
		if child.started == true and child.error == nil then return true end
		local inspected, settled = pcall(child.is_settled, child)
		if inspected and settled == true then return false end
		if type(child.on_settled) ~= "function" then
			self.failed = true
			self:cancel()
			Logger.error(LOG, "Owned local server scan cannot observe child settlement.")
			return false
		end
		local registered, ack = pcall(child.on_settled, child, function()
			dispatch(callback, { error = "native process dispatch refused" })
		end)
		if not registered or ack ~= true then
			self.failed = true
			self:cancel()
			Logger.error(LOG, "Owned local server scan settlement observer was refused.")
			return false
		end
		return not cancelled
	end
	function scope:defer(callback, refused)
		if not self:admitted() then self:cancel(); return false end
		local child = add(function()
			return M._owned_timer(Monotonic.now_ms(), function()
				dispatch(callback)
			end)
		end)
		if child == nil or not self:admitted() then self:cancel(); return false end
		if child.started == true then return true end
		local inspected, settled = pcall(child.is_settled, child)
		if inspected and settled == true then return false end
		if type(child.on_settled) ~= "function" then
			self.failed = true
			self:cancel()
			Logger.error(LOG, "Owned local server scan cannot observe child settlement.")
			return false
		end
		local registered, ack = pcall(child.on_settled, child, function()
			dispatch(refused)
		end)
		if not registered or ack ~= true then
			self.failed = true
			self:cancel()
			Logger.error(LOG, "Owned local server scan settlement observer was refused.")
			return false
		end
		return not cancelled
	end
	constructing = constructing + 1
	local ok = pcall(scan, entries, function(results)
		if completed then return end
		if not scope:admitted() then scope:cancel(); return end
		completed = true
		on_done(results)
	end, scope)
	constructing = constructing - 1
	if not ok then scope.failed = true; uncertain = true; scope:cancel() end
	return scope
end

M._owned_process = function(...) return require("core.process.adapters.owned_process").start(...) end
M._owned_timer = function(...) return require("core.network.engine.managed_http_deadline").start(...) end

return M

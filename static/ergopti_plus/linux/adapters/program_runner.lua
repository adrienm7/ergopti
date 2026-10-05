--- adapters/program_runner.lua

--- Owns one private detached group until leader exit and native group absence.
local ProcessGroup = require("infra.libuv_process_group")
local Exit = require("infra.libuv_exit")
local loaded, Native = pcall(require, "luv")
if not loaded then Native = nil end
local M = {}

function M.supported()
	return type(Native) == "table" and type(Native.spawn) == "function"
		and type(Native.fs_stat) == "function" and type(Native.kill) == "function"
end

--- Checks current native execution capability and target availability.
--- @param executable string Absolute native target.
--- @param native table|nil Controlled native port; production uses luv.
--- @return boolean
function M.available(executable, native)
	local port = native or Native
	if type(port) ~= "table" or type(port.spawn) ~= "function" or type(port.fs_stat) ~= "function"
		or type(port.kill) ~= "function" then return false end
	if type(executable) ~= "string" or executable:sub(1, 1) ~= "/" or executable:find("%z") then return false end
	local ok, info = pcall(port.fs_stat, executable)
	if not ok or type(info) ~= "table" or info.type ~= "file" or type(info.mode) ~= "number" then return false end
	local mode = info.mode
	return math.floor(mode / 64) % 2 == 1 or math.floor(mode / 8) % 2 == 1 or mode % 2 == 1
end

--- Constructs a lazy native child whose output is never captured or logged.
--- @param executable string Absolute target.
--- @param arguments table Dense literal argv.
--- @param completed function Closed terminal receipt: decoded numeric status only.
--- @param admitted function Fresh binding/lifecycle admission predicate.
--- @param native table|nil Controlled native port.
--- @return table handle Exact start, terminate and settlement capability.
function M.spawn(executable, arguments, completed, admitted, native)
	local port = native or Native
	local process, pid = nil, nil
	local state, cancelled = "prepared", false
	local exited, code, group_absent, delivered = false, nil, false, false
	local closing, retired, close_attempt = false, false, nil
	local observers = {}
	local handle = {}
	local function authorized()
		local ok, value = pcall(admitted)
		return ok and value == true
	end
	local function observe()
		if state ~= "exited" and state ~= "refused" then return end
		local pending = observers
		observers = {}
		for _, callback in ipairs(pending) do pcall(callback) end
	end
	local function refresh()
		if not exited or state == "starting" or state == "exited" then return end
		if not group_absent and pid then
			local _, absent = ProcessGroup.signal(port, pid, 0)
			group_absent = absent
		end
		if not group_absent then return end
		if process then
			if not retired then
				if closing then return end
				closing = true
				local owned = process
				-- Only this call can admit its callback, even when native close reenters.
				local attempt = { admitted = false, callback_seen = false }
				close_attempt = attempt
				local ok, result, close_error = pcall(owned.close, owned, function()
					if process ~= owned or close_attempt ~= attempt then return end
					attempt.callback_seen = true
					if not attempt.admitted then return end
					retired = true
					refresh()
				end)
				if not ok or close_error ~= nil or not (result == nil or result == 0 or result == true) then
					close_attempt = nil
					closing, retired = false, false
					return
				end
				attempt.admitted = true
				retired = attempt.callback_seen
				if not retired then return end
			end
			process = nil
		end
		pid, state = nil, "exited"
		if not delivered then
			delivered = true
			if not cancelled and authorized() then pcall(completed, code) end
		end
		observe()
	end
	function handle.isSettled()
		refresh()
		return process == nil and state ~= "starting" and state ~= "running" and state ~= "unknown"
	end
	function handle.onSettled(callback)
		if type(callback) ~= "function" then return false end
		if handle.isSettled() then pcall(callback) else observers[#observers + 1] = callback end
		return true
	end
	function handle.terminate(force)
		cancelled = true
		if handle.isSettled() then return true, "settled" end
		if not pid then return false, "pending" end
		local accepted, absent = ProcessGroup.signal(port, pid, force == true and "sigkill" or "sigterm")
		if not accepted then return false, "refused" end
		group_absent = absent
		if handle.isSettled() then return true, "settled" end
		return false, "pending"
	end
	function handle.start()
		if state ~= "prepared" or cancelled or not authorized()
			or not M.available(executable, port) then return false end
		if type(arguments) ~= "table" or type(completed) ~= "function" then return false end
		local count = 0
		for index, argument in pairs(arguments) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or type(argument) ~= "string"
				or argument:find("%z") then return false end
			count = count + 1
		end
		for index = 1, count do if rawget(arguments, index) == nil then return false end end
		local args = {}
		for index = 1, count do args[index] = arguments[index] end
		state = "starting"
		local function terminal(exit_code, signal)
			if exited then return end
			exited, code = true, Exit.status(exit_code, signal)
			if state == "starting" then return end
			refresh()
		end
		local ok, acquired, native_pid = pcall(port.spawn, executable, {
			args = args, stdio = { nil, nil, nil }, detached = true,
		}, terminal)
		if not ok then state = "unknown"; return false end
		if acquired == nil or acquired == false then state = "refused"; observe(); return false end
		process = acquired
		if type(native_pid) == "number" and native_pid % 1 == 0 and native_pid > 0 then pid = native_pid end
		if pid == nil then
			state = "unknown"
			if exited then refresh() end
			return false
		end
		state = "running"
		if exited then refresh() end
		if cancelled or not authorized() then handle.terminate(); return false end
		return true
	end
	return handle
end

return M

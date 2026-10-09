--- adapters/native_python_probe.lua

--- ==============================================================================
--- MODULE: Retained Native Python Header Probe
--- DESCRIPTION:
--- Reads a bounded Mach-O header in an owned system utility task. The GUI never
--- opens candidate bytes, and no private interpreter runs before native proof.
--- ==============================================================================

local M = {}
local FileSystem = require("adapters.file_system")
local Interpreter = require("adapters.python_interpreter")
local ShellRunner = require("adapters.shell_runner")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local Budget = require("modules.llm.bootstrap_retry_generated")
local Logger = require("infra.logger")
local hs = hs
local HEADER_BYTES = 4096
local OD = "/usr/bin/od"
local pending, cached
M._active_tasks = {}

local function finite(value)
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function now()
	local ok, value = pcall(TimerScheduler.now_ns)
	return ok and type(value) == "number" and value == value and value >= 0
		and value < math.huge and value / 1e9 or nil
end

local function snapshot(candidate, namespace, architecture)
	local ok, absolute = pcall(function() return hs.fs.pathToAbsolute(candidate) end)
	if not ok or type(absolute) ~= "string" or absolute:sub(1, #namespace) ~= namespace then return nil end
	local observed, attributes, status = pcall(FileSystem.classify_no_follow, absolute)
	if not observed or status ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file"
		or type(attributes.permissions) ~= "string" or not attributes.permissions:find("x", 1, true) then return nil end
	local fields = { candidate, absolute, namespace, architecture, attributes.permissions }
	for _, name in ipairs({ "dev", "ino", "size", "modification", "change" }) do
		local value = attributes[name]
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
		if (name == "ino" or name == "size") and (value < 0 or value % 1 ~= 0) then return nil end
		fields[#fields + 1] = tostring(value)
	end
	if attributes.size < 8 then return nil end
	return { key = table.concat(fields, "\0"), absolute = absolute }
end

local function native_header(stdout, architecture)
	if type(stdout) ~= "string" or #stdout > HEADER_BYTES * 4 then return false end
	local bytes = {}
	for word in stdout:gmatch("%S+") do
		if not word:match("^[%da-fA-F][%da-fA-F]$") or #bytes >= HEADER_BYTES then return false end
		bytes[#bytes + 1] = string.char(tonumber(word, 16))
	end
	local slices = Interpreter.parse_header(table.concat(bytes))
	if type(slices) ~= "table" then return false end
	for _, slice in ipairs(slices) do if slice == architecture then return true end end
	return false
end

local function close_timer(operation)
	local timer = operation.timer
	if timer == nil then return true end
	local ok, closed = pcall(TimerScheduler.cancel, timer)
	if not ok or closed ~= true then return false end
	M._active_tasks[timer] = nil
	operation.timer = nil
	return true
end

local function request_termination(operation)
	operation.cancelled = true
	if operation.handle == nil or operation.termination_accepted then return end
	local ok, accepted = pcall(TaskLifecycle.terminate, operation.handle, "private Python header probe")
	if ok and accepted == true then operation.termination_accepted = true end
end

local function settle(operation)
	if pending ~= operation or operation.acquiring or operation.dispatching or operation.closing then return false end
	local clock = now()
	if not clock or clock >= operation.deadline then request_termination(operation) end
	if operation.handle ~= nil then
		local observed, retired = pcall(operation.handle.isSettled)
		if not observed or retired ~= true then return false end
	end
	operation.closing = true
	local timer_closed = close_timer(operation)
	operation.closing = false
	if not timer_closed then return false end
	local current = snapshot(operation.candidate, operation.namespace, operation.architecture)
	clock = now()
	if operation.committed and not operation.cancelled and clock and clock < operation.deadline then
		-- Every completed native probe outcome is terminal for this exact
		-- snapshot. Settlement observers must not silently renew the original
		-- admission by starting another probe. Cancellation or source change can retry.
		cached = { key = operation.key,
			path = current and current.key == operation.key
				and operation.status == 0 and operation.stderr == ""
				and native_header(operation.stdout, operation.architecture) and current.absolute or nil }
	end
	if operation.handle ~= nil then M._active_tasks[operation.handle] = nil end
	pending = nil
	local observers = operation.observers
	operation.observers = {}
	for _, observer in ipairs(observers) do
		local ok = pcall(observer)
		if not ok then Logger.error("native_python_probe", "Private Python settlement observer refused.") end
	end
	return true
end

--- Return native header proof only after the original child and timer retire.
--- @param candidate string Exact generated interpreter pathname.
--- @param namespace string Exact generated interpreter installation root.
--- @param architecture string Required native process architecture.
--- @param remaining_seconds number|nil Remaining original caller admission budget.
--- @param original_deadline number|nil Earlier deadline captured before system lookup.
--- @return string|nil executable Native private interpreter.
--- @return string|nil state `pending` includes physical rollback debt.
function M.get(candidate, namespace, architecture, remaining_seconds, original_deadline)
	-- Capture before any metadata work or pending settlement. The resolver may
	-- supply an earlier deadline captured before its native system lookup.
	local entry_clock = now()
	local duration = finite(Budget.admission_seconds) and
		(remaining_seconds == nil or finite(remaining_seconds)) and
		math.min(Budget.admission_seconds, remaining_seconds or Budget.admission_seconds) or nil
	local deadline = entry_clock and duration and entry_clock + duration or nil
	if original_deadline ~= nil then
		deadline = deadline and finite(original_deadline) and math.min(deadline, original_deadline) or nil
	end
	if type(candidate) ~= "string" or type(namespace) ~= "string" or namespace:sub(1, 1) ~= "/"
		or namespace:sub(-1) ~= "/" or candidate:sub(1, #namespace) ~= namespace
		or candidate:find("\0", 1, true) or namespace:find("\0", 1, true)
		or (architecture ~= "arm64" and architecture ~= "x86_64") then return nil end
	local previous = pending
	if pending ~= nil then
		settle(pending)
		if pending ~= nil then return nil, "pending" end
	end
	local clock = now()
	if not deadline or not clock or clock >= deadline then return nil end
	local current = snapshot(candidate, namespace, architecture)
	clock = now()
	if not current then cached = nil; return nil end
	if not clock or clock >= deadline then return nil end
	if cached and cached.key == current.key then return cached.path end
	cached = nil
	-- Retiring an original attempt never starts a successor in the same call.
	-- A caller may retry later with its own remaining original admission budget.
	if previous ~= nil then return nil end
	local operation = { candidate = candidate, namespace = namespace, architecture = architecture,
		key = current.key, deadline = deadline, acquiring = true, observers = {}, committed = false }
	pending = operation
	local constructed, handle = pcall(ShellRunner.spawn, OD,
		{ "-An", "-v", "-N", tostring(HEADER_BYTES), "-t", "x1", current.absolute },
		function(status, stdout, stderr)
			if operation.status == nil then operation.status, operation.stdout, operation.stderr = status, stdout, stderr end
			settle(operation)
		end, nil, nil, true)
	if constructed and type(handle) == "table" then
		operation.handle = handle
		M._active_tasks[handle] = true
	end
	if operation.handle ~= nil then
		local registered, accepted = pcall(handle.onSettled, function() settle(operation) end)
		if not registered or accepted ~= true then operation.cancelled = true end
	else operation.cancelled = true end
	local remaining = operation.deadline - (now() or operation.deadline)
	if remaining > 0 and not operation.cancelled then
		local created, timer, committed = pcall(TimerScheduler.after, remaining, function()
			request_termination(operation)
			settle(operation)
		end)
		if created and type(timer) == "table" then
			operation.timer = timer
			M._active_tasks[timer] = true
			local registered, accepted = pcall(TimerScheduler.onSettled, timer, function() settle(operation) end)
			if not registered or accepted ~= true then operation.cancelled = true end
		end
		if not created or type(timer) ~= "table" or committed ~= true then operation.cancelled = true end
	else operation.cancelled = true end
	operation.acquiring = false
	if operation.cancelled or not now() or now() >= operation.deadline then
		request_termination(operation)
	else
		operation.dispatching = true
		local launched, started = pcall(TaskLifecycle.start, handle, "private Python header probe")
		if launched and started == true then operation.committed = true else request_termination(operation) end
		operation.dispatching = false
	end
	settle(operation)
	if pending ~= nil then return nil, "pending" end
	return cached and cached.key == current.key and cached.path or nil
end

--- Request and retry exact native retirement; signal acceptance never releases pins.
--- @return boolean settled Original task and timer are physically retired.
function M.cancel()
	cached = nil
	if pending == nil then return true end
	request_termination(pending)
	return settle(pending)
end

--- Observe exact probe retirement, including failure; no successor is authorized.
--- @param callback function Retirement receiver.
--- @return boolean accepted Receiver retained or invoked after retirement.
function M.onSettled(callback)
	if type(callback) ~= "function" then return false end
	if pending == nil then return pcall(callback) end
	pending.observers[#pending.observers + 1] = callback
	return true
end

return M

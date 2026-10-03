--- adapters/keyboard_source_probe.lua

--- ==============================================================================
--- MODULE: Direct Keyboard Source Proof Adapter
--- DESCRIPTION:
--- Asynchronously asks the signed launcher to classify physical keys in the
--- actual selected TIS source. Results cannot outlive their source identity or
--- cancellation; exact task and deadline cleanup remain owned until settled.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local JsonCodec = require("adapters.json_codec")
local LauncherHelper = require("platform.remap.lease_helper")
local Timings = require("infra.timings")

local LOG = "adapters.keyboard_source_probe"
local PROBE_FLAG = "--keyboard-source-probe"
local PROTOCOL_VERSION = 1
local MAX_SOURCE_BYTES = 1024
local MAX_CODES = 128
local MAX_CODE = 127
local MAX_RECEIPT_BYTES = 65536
local MAX_KEYBOARD_TYPE = 4294967295
local TIMEOUT_SEC = Timings.sec("ui", "input_source_operation_timeout_ms")
local active_operations = {}

--- Reads the selected source; a layout-name fallback could hide an active IME.
--- @return string|nil source_id Exact TIS input-source identity.
function M.current_source_id()
	local ok, value = xpcall(function() return hs.keycodes.currentSourceID() end, debug.traceback)
	if ok and type(value) == "string" and value ~= "" and #value <= MAX_SOURCE_BYTES
		and not value:find("\0", 1, true) then return value end
	Logger.error(LOG, "Selected input source could not be proved: %s.", tostring(value))
	return nil
end

--- Rejects additional fields rather than accepting an unrelated JSON object.
--- @param value any Candidate object.
--- @param keys table Set of allowed fields.
--- @return boolean valid
local function only_fields(value, keys)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do if not keys[key] then return false end end
	return true
end

--- Copies a dense, unique native-code request before asynchronous work starts.
--- @param request table {source_id, codes}.
--- @return table|nil validated Private snapshot.
local function validate_request(request)
	if not only_fields(request, { source_id = true, codes = true })
		or type(request.source_id) ~= "string" or request.source_id == ""
		or #request.source_id > MAX_SOURCE_BYTES or request.source_id:find("\0", 1, true)
		or type(request.codes) ~= "table" then return nil end
	local count, seen, codes = 0, {}, {}
	for key, code in pairs(request.codes) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #request.codes
			or type(code) ~= "number" or code % 1 ~= 0 or code < 0 or code > MAX_CODE
			or seen[code] then return nil end
		count = count + 1
		seen[code] = true
		codes[key] = code
	end
	if count == 0 or count ~= #request.codes or count > MAX_CODES then return nil end
	return { source_id = request.source_id, codes = codes }
end

--- Validates exact ordered physical identities and explicit native dead proof.
--- @param stdout string Native JSON.
--- @param request table Private request snapshot.
--- @return table|nil receipt Validated native data.
local function decode_receipt(stdout, request)
	if type(stdout) ~= "string" or #stdout > MAX_RECEIPT_BYTES then return nil end
	local receipt, decode_error = JsonCodec.decode(stdout)
	if decode_error ~= nil or not only_fields(receipt,
		{ version = true, source_id = true, keyboard_type = true, levels = true })
		or receipt.version ~= PROTOCOL_VERSION or receipt.source_id ~= request.source_id
		or type(receipt.keyboard_type) ~= "number" or receipt.keyboard_type % 1 ~= 0
		or receipt.keyboard_type < 0 or receipt.keyboard_type > MAX_KEYBOARD_TYPE
		or type(receipt.levels) ~= "table" or #receipt.levels ~= #request.codes then return nil end
	local count = 0
	for index, level in pairs(receipt.levels) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #request.codes
			or not only_fields(level, { code = true, text = true, dead = true, direct = true })
			or level.code ~= request.codes[index] or type(level.text) ~= "string"
			or type(level.dead) ~= "boolean" or type(level.direct) ~= "boolean"
			or level.direct ~= (level.dead == false and level.text ~= "") then return nil end
		count = count + 1
	end
	if count ~= #request.codes then return nil end
	return receipt
end

--- Owns one read-only probe and its deadline. The callback can run before this
--- function returns; consumers must publish their cohort fence before calling.
--- Cancellation closes delivery immediately, but returns true only after both
--- exact native capabilities are gone, including asynchronous SIGTERM delivery.
--- @param request table {source_id=string, codes=number[]}.
--- @param callback function fn(receipt|nil, reason|nil).
--- @return table operation {cancel, is_settled, on_settled}.
function M.request(request, callback)
	assert(type(callback) == "function", "keyboard source proof requires a result callback")
	local snapshot = validate_request(request)
	local owner = { frames = 0, done = false, observers = {} }
	local operation = {}
	active_operations[operation] = owner
	local drain

	local function invoke(fn, ...)
		local ok, detail = xpcall(fn, debug.traceback, ...)
		if not ok then Logger.error(LOG, "Keyboard proof callback failed: %s.", tostring(detail)) end
	end

	local function task_is_settled(handle)
		local ok, result = xpcall(function() return handle.isSettled() end, debug.traceback)
		return ok and result == true
	end

	local function stop_task()
		local handle = owner.task
		if handle == nil then return true end
		if task_is_settled(handle) then owner.task = nil; return true end
		local ok, accepted = xpcall(function() return handle.terminate() end, debug.traceback)
		if owner.task ~= handle or task_is_settled(handle) then owner.task = nil; return true end
		if not ok or accepted ~= true then
			Logger.error(LOG, "Keyboard probe termination refused; exact task retained: %s.", tostring(accepted))
		end
		return false
	end

	local function stop_timer()
		local handle = owner.timer
		if handle == nil then return true end
		local ok, settled = xpcall(TimerScheduler.cancel, debug.traceback, handle)
		if owner.timer ~= handle or (ok and settled == true) then owner.timer = nil; return true end
		Logger.error(LOG, "Keyboard probe deadline cleanup refused; exact timer retained: %s.", tostring(settled))
		return false
	end

	local function pending(receipt, reason)
		if owner.done then return end
		if owner.cancel_reason ~= nil then receipt, reason = nil, owner.cancel_reason end
		if owner.pending == nil or owner.cancel_reason ~= nil or reason ~= nil then
			owner.pending = { receipt = receipt, reason = reason }
		end
		drain()
	end

	drain = function()
		if owner.done or owner.frames ~= 0 or owner.draining or owner.pending == nil then return end
		owner.draining = true
		-- Natural completion is already settled; failures/cancellation must join
		-- any prepared or running task before publishing their terminal callback.
		local task_settled = owner.task == nil
		if not task_settled and task_is_settled(owner.task) then owner.task = nil; task_settled = true end
		if owner.cancel_reason ~= nil or owner.pending.reason ~= nil then task_settled = stop_task() end
		local timer_settled = stop_timer()
		owner.draining = false
		if not task_settled or not timer_settled then return end
		local result = owner.pending
		owner.pending = nil
		if owner.cancel_reason ~= nil then result = { reason = owner.cancel_reason } end
		if result.receipt ~= nil and M.current_source_id() ~= snapshot.source_id then
			result = { reason = "source_changed" }
		end
		owner.done = true
		active_operations[operation] = nil
		if result.receipt then Logger.done(LOG, "Native keyboard source proof committed.")
		else Logger.error(LOG, "Native keyboard source proof refused: %s.", tostring(result.reason)) end
		invoke(callback, result.receipt, result.reason)
		local observers = owner.observers
		owner.observers = {}
		for _, observer in ipairs(observers) do invoke(observer) end
	end

	--- Cancels logical delivery before retrying exact native cleanup.
	--- @return boolean settled True only after native task and timer settlement.
	function operation.cancel()
		if owner.done then return true end
		owner.cancel_reason = owner.cancel_reason or "cancelled"
		pending(nil, owner.cancel_reason)
		return owner.done
	end

	--- @return boolean settled True when no capability remains.
	function operation.is_settled() return owner.done end

	--- Registers an in-memory continuation after exact cleanup.
	--- @param observer function Zero-arity continuation.
	--- @return boolean registered
	function operation.on_settled(observer)
		if type(observer) ~= "function" then return false end
		if owner.done then invoke(observer) else owner.observers[#owner.observers + 1] = observer end
		return true
	end

	if snapshot == nil then pending(nil, "invalid_request"); return operation end
	Logger.start(LOG, "Reading direct physical output for the selected keyboard source.")
	if M.current_source_id() ~= snapshot.source_id then pending(nil, "source_changed"); return operation end
	local resolve_ok, executable, _, environment = xpcall(LauncherHelper.resolve, debug.traceback)
	if not resolve_ok or type(executable) ~= "string" or executable == "" then
		pending(nil, "helper_unavailable"); return operation
	end
	local args = { PROBE_FLAG, snapshot.source_id }
	for _, code in ipairs(snapshot.codes) do args[#args + 1] = string.format("%d", code) end
	owner.frames = owner.frames + 1
	local spawn_ok, task = xpcall(ShellRunner.spawn, debug.traceback, executable, args,
		function(exit_code, stdout)
			if owner.done then return end
			local receipt
			if owner.cancel_reason == nil and exit_code == 0 then
				local decode_ok, decoded = xpcall(decode_receipt, debug.traceback, stdout, snapshot)
				if decode_ok then receipt = decoded end
			end
			local reason
			if receipt == nil then reason = "invalid_receipt" end
			pending(receipt, reason)
		end, nil, environment)
	if spawn_ok and type(task) == "table" then owner.task = task end
	owner.frames = owner.frames - 1
	if owner.task == nil then pending(nil, "construction_failed"); return operation end
	owner.frames = owner.frames + 1
	local observe_ok, observed = xpcall(function()
		return task.onSettled(function()
			if owner.task == task and task_is_settled(task) then owner.task = nil end
			drain()
		end)
	end, debug.traceback)
	owner.frames = owner.frames - 1
	if not observe_ok or observed ~= true then pending(nil, "task_observer_failed"); return operation end
	if owner.pending ~= nil then
		if owner.task ~= nil then owner.cancel_reason = "completion_during_construction" end
		drain(); return operation
	end
	if owner.task == nil then pending(nil, "construction_failed"); return operation end
	owner.frames = owner.frames + 1
	local timer_ok, timer, committed = xpcall(TimerScheduler.after, debug.traceback, TIMEOUT_SEC, function()
		if owner.done then return end
		owner.cancel_reason = owner.cancel_reason or "timeout"
		pending(nil, owner.cancel_reason)
	end)
	if timer_ok and type(timer) == "table" then owner.timer = timer end
	owner.frames = owner.frames - 1
	if owner.timer ~= nil then
		owner.frames = owner.frames + 1
		local timer_observe_ok, timer_observed = xpcall(TimerScheduler.onSettled, debug.traceback, timer, function()
			if owner.timer == timer and timer.timer == nil then owner.timer = nil end
			drain()
		end)
		owner.frames = owner.frames - 1
		if not timer_observe_ok or timer_observed ~= true then pending(nil, "timer_observer_failed"); return operation end
	end
	if not timer_ok or committed ~= true or owner.timer == nil then
		pending(nil, "deadline_failed"); return operation
	end
	if owner.pending ~= nil then drain(); return operation end
	owner.frames = owner.frames + 1
	local start_ok, started = xpcall(function() return task.start() end, debug.traceback)
	owner.frames = owner.frames - 1
	if not start_ok or started ~= true then
		owner.cancel_reason = owner.cancel_reason or "launch_failed"
		pending(nil, owner.cancel_reason)
	else drain() end
	return operation
end

return M

--- adapters/desktop_opener.lua

--- ==============================================================================
--- MODULE: Desktop Launch Confirmations (Linux)
--- DESCRIPTION:
--- Owns the bounded confirmation helper, not the accepted desktop application.
--- The helper transfers xdg-open to a separate session with no inherited streams.
--- Cancelling a page or stopping the daemon retires only its confirmation work.
--- ==============================================================================

local M = {}

local records = {}
local stopping, checking_shutdown = false, false

local DEFAULT_DEPS = {
	exepath = function() return require("luv").exepath() end,
	update_time = function() return require("luv").update_time() end,
	worker = function() return require("infra.paths").driver_root() .. "/adapters/desktop_opener_worker.lua" end,
	timeout = function() return require("infra.timings").ms("ui", "desktop_open_timeout_ms") end,
	start = function(...) return require("adapters.owned_process").start(...) end,
}
local deps = DEFAULT_DEPS

--- Tests authority around a possibly reentrant caller predicate.
--- @param record table Exact private admission.
--- @return boolean
local function current(record)
	if stopping or not record.active then return false end
	if record.authorized then
		local called, admitted = pcall(record.authorized)
		if not called or admitted ~= true then record.active = false end
	end
	return not stopping and record.active
end

--- Retires only an exact physical receipt; public request fields are not evidence.
--- @param record table
--- @return boolean
local function retire(record)
	if record.settled then return true end
	if record.constructing or record.uncertain or record.checking then return false end
	if record.operation then
		record.checking = true
		local called, acknowledged = pcall(record.is_settled, record.operation)
		record.checking = false
		if not called or acknowledged ~= true then return false end
	end
	record.settled = true
	records[record] = nil
	local listeners = record.listeners
	record.listeners = {}
	if record.result and current(record) then
		record.active = false
		pcall(record.done, record.result)
	end
	for _, listener in ipairs(listeners) do pcall(listener) end
	return true
end

--- Revokes business delivery before a native cancellation can call back.
--- @param record table
--- @return boolean
local function cancel(record)
	record.active = false
	if record.settled then return true end
	if record.operation and type(record.cancel) == "function" then
		pcall(record.cancel, record.operation)
	end
	return retire(record)
end

--- Begins a desktop intent and retains only its confirmation helper's lifetime.
--- Native constructor admission is not a successful desktop launch receipt.
--- @param target string Literal path or URL.
--- @param on_done function Receives { ok, code, error } after helper retirement.
--- @param authorized function|nil Exact page/action predicate.
--- @return table|nil request Dot-call cancel/is_settled/on_settled ports.
--- @return string|nil Pre-acquisition refusal reason.
function M.open(target, on_done, authorized)
	if type(target) ~= "string" or target == "" or target:find("\0", 1, true) then
		return nil, "a literal desktop target is required"
	end
	if type(on_done) ~= "function" or (authorized ~= nil and type(authorized) ~= "function") then
		return nil, "desktop completion and authority ports are required"
	end
	if stopping then return nil, "desktop launch admission is closed" end
	local record = { active = true, constructing = true, listeners = {}, done = on_done, authorized = authorized }
	records[record] = true
	local request = {}
	function request.cancel() return cancel(record) end
	function request.is_settled() retire(record); return record.settled == true end
	function request.on_settled(listener)
		if type(listener) ~= "function" then return false end
		if record.settled then pcall(listener) else record.listeners[#record.listeners + 1] = listener end
		return true
	end
	local acquired = false
	local called, reason = pcall(function()
		if not current(record) then return end
		local executable = deps.exepath()
		if not current(record) then return end
		local worker = deps.worker()
		if not current(record) then return end
		for _, path in ipairs({ executable or false, worker or false }) do
			assert(type(path) == "string" and path:sub(1, 1) == "/" and not path:find("\0", 1, true),
				"desktop helper paths must be absolute native paths")
		end
		local timeout = deps.timeout()
		if not current(record) then return end
		assert(type(timeout) == "number" and timeout > 0 and timeout < math.huge and timeout % 1 == 0,
			"desktop confirmation needs its canonical finite deadline")
		assert(deps.update_time() ~= false, "desktop helper clock refresh refused")
		if not current(record) then return end
		acquired = true
		local operation = deps.start(executable, { worker, target, string.format("%.0f", timeout) }, {
			owner = "desktop_confirmation:" .. tostring(record), timeout_ms = timeout, authorized = function() return current(record) end,
		}, function(result)
			record.result = { ok = result.ok == true, code = result.exit_code, error = result.error }
			retire(record)
		end)
		if operation == nil then acquired = false; error("desktop helper refused before acquisition") end
		record.operation = operation
		if type(operation) ~= "table" then record.uncertain = true; return end
		record.cancel, record.is_settled = operation.cancel, operation.is_settled
		local subscribe = operation.on_settled
		if type(record.cancel) ~= "function" or type(record.is_settled) ~= "function" or type(subscribe) ~= "function" then
			record.uncertain = true
			return
		end
		local subscribed, accepted = pcall(subscribe, operation, function() retire(record) end)
		if not subscribed or accepted ~= true then record.uncertain = true end
	end)
	if not called and acquired then record.uncertain = true end
	record.constructing = false
	if not current(record) then cancel(record) else retire(record) end
	if not called and not acquired then return nil, tostring(reason) end
	return request
end

--- Closes admission and waits for every helper, including constructing claims.
--- Desktop applications and their launchers have intentionally transferred lives;
--- this receipt never promises their exit or that they consumed a file.
--- @return boolean acknowledged Every confirmation helper is physically retired.
function M.shutdown()
	stopping = true
	if checking_shutdown then return false end
	checking_shutdown = true
	local snapshot = {}
	for record in pairs(records) do
		record.active = false
		snapshot[#snapshot + 1] = record
	end
	for _, record in ipairs(snapshot) do cancel(record) end
	checking_shutdown = false
	return next(records) == nil
end

--- Replaces native boundaries only when no prior admission retains debt.
--- @param overrides table|nil
function M._set_deps_for_test(overrides)
	assert(next(records) == nil, "desktop launch confirmations still own cleanup debt")
	deps = overrides and setmetatable(overrides, { __index = DEFAULT_DEPS }) or DEFAULT_DEPS
end

return M

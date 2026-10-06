--- _shared/lua/llm/ollama_install_phase.lua

--- Archive installation consumes the runtime controller's single master budget.
--- This facade adds no timer, process policy or guessed cancellation receipt.
local M = {}
local Installer = require("llm.ollama_archive_installer")

local function copy(source)
	local result = {}; for key, value in next, source do result[key] = value end; return result
end

local function empty_operation(reason, callback)
	local operation = { started = false, result = { ok = false, exit_code = -1, status = 0, stdout = "", error = reason } }
	function operation:is_settled() return true end
	function operation:cancel() return true end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		pcall(listener); return true
	end
	if type(callback) == "function" then pcall(callback, operation.result) end
	return operation
end

--- Starts the archive phase within an already admitted shared runtime budget.
--- @param ports table Exact file/process/HTTP operation ports.
--- @param options table Original installer options plus immutable budget capability.
--- @param callback function Called after exact native/file retirement if current.
--- @return table operation The underlying exact archive installer operation.
function M.start(ports, options, callback)
	if type(ports) ~= "table" or type(options) ~= "table" then return empty_operation("install_phase_port_unavailable", callback) end
	local budget, source = rawget(options, "budget"), rawget(options, "authorized")
	local timeout = rawget(options, "timeout_ms")
	if type(budget) ~= "table" or type(budget.remaining_ms) ~= "function" or type(budget.current) ~= "function"
		or type(budget.on_cancel) ~= "function" or type(source) ~= "function"
		or type(ports.files) ~= "table" or type(ports.files.current) ~= "function"
		or type(ports.process) ~= "table" or type(ports.process.start) ~= "function"
		or type(ports.http) ~= "table" or type(ports.http.get_owned) ~= "function" then
		return empty_operation("install_phase_port_unavailable", callback)
	end
	local remaining, budget_current, subscribe = budget.remaining_ms, budget.current, budget.on_cancel
	local files_current = ports.files.current
	local start_process, start_http = ports.process.start, ports.http.get_owned
	local cancelled, subscribing, subscribed, delegate = false, false, false, nil
	local function limit(local_budget)
		local read, value = pcall(remaining)
		if not read or type(value) ~= "number" or value <= 0 or value % 1 ~= 0
			or type(local_budget) ~= "number" or local_budget <= 0 or local_budget % 1 ~= 0 then return nil end
		return math.min(value, local_budget)
	end
	local function current()
		if cancelled or subscribing then return false end
		-- Installer reserves its exact directory before this first external call.
		if not subscribed then
			subscribing = true
			local registered, receipt = pcall(subscribe, function()
				cancelled = true
				if delegate and not delegate:is_settled() then delegate:cancel() end
			end)
			subscribing = false
			subscribed = registered and receipt == true
			if not subscribed then cancelled = true return false end
		end
		local allowed, value = pcall(source)
		if not allowed or value ~= true or cancelled then return false end
		local held, receipt = pcall(budget_current)
		if not held or receipt ~= true or cancelled then return false end
		local rooted, fresh = pcall(files_current)
		if not rooted or fresh ~= true or cancelled then return false end
		-- Admission callbacks may consume the last remaining millisecond.
		return limit(timeout) ~= nil and not cancelled
	end
	local function stage_options(value)
		local result = copy(value)
		result.authorized = current
		if current() then result.timeout_ms = limit(value.timeout_ms) else result.timeout_ms = nil end
		return result
	end
	local scoped = { files = ports.files, process = {}, http = {} }
	function scoped.process.start(executable, arguments, value, done)
		local admitted = stage_options(value)
		if not admitted.timeout_ms then return empty_operation("install_budget_exhausted", done) end
		return start_process(executable, arguments, admitted, done)
	end
	function scoped.http.get_owned(url, headers, value, done)
		local admitted = stage_options(value)
		if not admitted.timeout_ms then return empty_operation("install_budget_exhausted", done) end
		return start_http(url, headers, admitted, done)
	end
	local captured = copy(options)
	captured.authorized = current
	delegate = Installer.start(scoped, captured, callback)
	if cancelled and not delegate:is_settled() then delegate:cancel() end
	return delegate
end

return M

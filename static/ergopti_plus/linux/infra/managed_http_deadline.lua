--- infra/managed_http_deadline.lua

--- ==============================================================================
--- MODULE: Managed HTTP Deadline Ownership
--- DESCRIPTION:
--- Owns one deadline timer and its actual close acknowledgement. Relative arming
--- belongs to the existing native timer helper; this ledger never resets the
--- caller's absolute budget or mistakes a scheduled close for retirement.
--- ==============================================================================

local M = {}
local NativeTimer = require("infra.native_timer")
local Monotonic = require("infra.monotonic")
local Logger = require("logger.shim")
local LOG = "infra.managed_http_deadline"
local loaded, luv = pcall(require, "luv")
if not loaded then luv = nil end

--- Arms an absolute deadline or retains the precise failed allocation debt.
--- @param deadline number Original monotonic deadline in milliseconds.
--- @param callback function Logical expiry notification, separate from close ACK.
--- @return table operation { started, cancel, is_settled, on_settled }.
function M.start(deadline, callback)
	local operation = { started = false }
	local timer, state, terminal = nil, "absent", false
	local listeners = {}

	--- Delivers physical retirement to protected registered listeners.
	local function settled()
		local pending = listeners
		listeners = {}
		for _, listener in ipairs(pending) do
			local ok = pcall(listener)
			if not ok then Logger.error(LOG, "Deadline settlement callback raised.") end
		end
	end

	--- Retires only this timer; refusal retains the same native handle.
	--- @return boolean
	local function retire()
		terminal = true
		if state == "absent" or state == "closed" then return true end
		if state == "closing" then return true end
		local inspected, closing = pcall(luv.is_closing, timer)
		if not inspected or closing then return false end
		local stopped, stop_ack, stop_error = pcall(luv.timer_stop, timer)
		if not stopped or stop_ack == nil or stop_ack == false or stop_error ~= nil then return false end
		state = "closing"
		local called, close_ack, close_error = pcall(luv.close, timer, function()
			state = "closed"
			settled()
		end)
		if not called or close_ack == false or close_error ~= nil then
			if state ~= "closed" then state = "open" end
			return false
		end
		-- luv.close returns void. Its native closing bit acknowledges scheduling;
		-- only the callback above acknowledges physical retirement.
		if state ~= "closed" then
			local observed, scheduled = pcall(luv.is_closing, timer)
			if not observed or scheduled ~= true then state = "open"; return false end
		end
		return true
	end

	function operation:is_settled() return state == "absent" or state == "closed" end
	function operation:cancel() return retire() end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if self:is_settled() then
			local ok = pcall(listener)
			if not ok then Logger.error(LOG, "Deadline settlement callback raised.") end
		else listeners[#listeners + 1] = listener end
		return true
	end
	if not luv or type(deadline) ~= "number" or deadline ~= deadline
		or math.abs(deadline) == math.huge or type(callback) ~= "function" then return operation end
	local allocated, value = pcall(luv.new_timer)
	if not allocated or not value then return operation end
	timer, state = value, "open"
	local budget = math.max(0, math.floor(deadline - Monotonic.now_ms()))
	local armed, ack, native_error = pcall(NativeTimer.start, luv, timer, budget, 0, function()
		if terminal then return end
		terminal = true
		-- Logical expiry is observable even when native close ACK is withheld.
		local ok = pcall(callback)
		if not ok then Logger.error(LOG, "Deadline terminal callback raised.") end
		retire()
	end)
	if not armed or ack == nil or ack == false or native_error ~= nil then retire(); return operation end
	operation.started = true
	return operation
end

return M

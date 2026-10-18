--- modules/gestures/click_hold.lua

--- Retains exact synthetic buttons and bounded native helpers through retirement.
local M = {}
local Process = require("adapters.owned_process")
local Timings = require("infra.timings")
local Clock = require("infra.monotonic")
local warn = require("logger.shim").warn
local LOG = "modules.gestures.click_hold"

--- Builds a button owner; only native physical settlement can authorize an UP.
--- @param active function Whether new acquisitions remain admitted.
--- @return table owner
function M.new(active)
	local start, now = Process.start, Clock.now_ms
	local timeout = Timings.ms("gestures", "aux_shell_timeout_ms")
	local retry = Timings.ms("gestures", "aux_shell_cleanup_retry_ms")
	local states, busy, sequence, epoch, retiring = {}, false, 0, 0, false
	local owner = {}
	local function admitted()
		local ok, yes = pcall(active)
		return ok and yes == true
	end
	local function retire()
		for _, state in pairs(states) do state.wanted = false end
	end
	-- Reserve before logging: a sink can retire this exact owner synchronously.
	-- Retry attempts keep the same debt, so they cannot create warning storms.
	local function report(button, state, press, category)
		local phase = press and "DOWN" or "UP"
		state.reported = state.reported or {}
		if state.reported[phase] then return end
		state.reported[phase] = true
		pcall(warn, LOG, "Synthetic mouse button %s %s refused (%s).", button, phase, category)
	end
	local function failure_category(claim, result)
		if claim.child.not_found == true then return "unavailable" end
		if claim.child.started == false then return "dispatch_refused" end
		if type(result) ~= "table" then return "receipt_unknown" end
		if result.error == "process deadline exceeded" then return "deadline" end
		if type(result.exit_code) == "number" and result.exit_code ~= 0 then return "exit_failed" end
		return "native_refused"
	end
	local function diagnose(button, state, claim, result)
		local intentional = claim.press and not state.wanted and type(result) == "table"
			and (result.error == "cancelled" or result.error == "process source admission refused")
		if not intentional then report(button, state, claim.press, failure_category(claim, result)) end
	end
	local function dispatch(button, state, press)
		sequence = sequence + 1
		local claim = { press = press }
		state.operation = claim -- Reserve before allocation/source callback reentry.
		local called, child = pcall(start, "xdotool", { press and "mousedown" or "mouseup", button }, {
			owner = "gesture-click-" .. tostring(owner) .. "-" .. button .. "-" .. sequence,
			timeout_ms = timeout, capture_output = false,
			authorized = press and function()
				return states[button] == state and state.operation == claim and state.wanted and admitted()
					and states[button] == state and state.operation == claim and state.wanted
			end or nil,
		}, function() end)
		if not called or type(child) ~= "table" or type(child.is_settled) ~= "function"
			or type(child.cancel) ~= "function" then
			-- A throwing constructor cannot certify that no child was acquired.
			claim.unknown = true
			state.wanted = false
			report(button, state, press, "constructor_unknown")
			return
		end
		claim.child, claim.settled, claim.cancel = child, child.is_settled, child.cancel
	end

	--- Harvests receipts without running libuv recursively or holding an input loop.
	function owner.pump()
		if busy then return false end
		busy = true
		if not admitted() then retiring = true; retire() end
		for _, button in ipairs({ "1", "3" }) do
			local state = states[button]
			if state then
				local claim = state.operation
				if claim and not claim.unknown then
					if claim.press and not state.wanted and not claim.cancelled then
						claim.cancelled = true
						local called = pcall(claim.cancel, claim.child)
						if not called then report(button, state, true, "cancel_unknown") end
					end
					-- A terminal failure is visible before native close/group ACK arrives.
					-- Reporting it cannot authorize the compensating UP below.
					local pending_result = claim.child.result
					if type(pending_result) == "table" and pending_result.ok == false then
						diagnose(button, state, claim, pending_result)
					end
					local called, settled = pcall(claim.settled, claim.child)
					if not called then report(button, state, claim.press, "receipt_unknown") end
					if called and settled == true then
						local result = claim.child.result
						local success = type(result) == "table" and result.ok == true
						state.operation = nil
						if claim.press then
							if claim.child.started == false then states[button] = nil
							elseif not success then state.wanted = false end
						elseif success then states[button] = nil
						else state.retry_at = now() + retry end
						if not success then diagnose(button, state, claim, result) end
					end
				end
				if states[button] == state and not state.wanted and not state.operation
					and now() >= (state.retry_at or 0) then
					dispatch(button, state, false)
				end
			end
		end
		busy = false
		if next(states) == nil then retiring = false; return true end
		return false
	end

	--- Retires DOWN helpers before admitting their compensating UP helpers.
	function owner.release_all()
		epoch = epoch + 1
		retiring = true
		retire()
		return owner.pump()
	end

	--- Accepts one toggle without waiting for any native child in the callback.
	function owner.toggle(button)
		if (button ~= "1" and button ~= "3") or busy or retiring then return false end
		local state = states[button]
		if state then
			state.wanted = false
			owner.pump()
			return false
		end
		busy = true
		local captured = epoch
		if not admitted() or epoch ~= captured then busy = false; return false end
		state = { wanted = true }
		states[button] = state -- The obligation precedes fallible native admission.
		dispatch(button, state, true)
		busy = false
		owner.pump()
		return states[button] == state and state.wanted
	end
	return owner
end
return M

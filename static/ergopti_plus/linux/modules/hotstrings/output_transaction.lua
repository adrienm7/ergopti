--- modules/hotstrings/output_transaction.lua

--- ==============================================================================
--- MODULE: Failure-Atomic Output Transaction (Linux)
--- DESCRIPTION:
--- Owns one grabbed-keyboard output transaction from the first physical
--- modifier neutralisation through synthetic keystrokes to exact restoration.
--- No caller may publish undo, metrics or engine state until finish().ok.
---
--- WHY THIS IS A MODULE:
--- A uinput emission is two writes (EV_KEY then SYN_REPORT) and returns false
--- when either fails. Checking some call sites is therefore indistinguishable
--- from checking none: the unguarded call is the one that leaves a key down.
--- Centralising the wire, pressed-key stack and cleanup gives every injection
--- path the same commit boundary and makes fault injection exhaustive.
---
--- GUARANTEES:
--- 1. Every false return and exception is a transaction failure.
--- 2. Every successfully-pressed synthetic key is released in reverse order.
--- 3. Physical modifier keycodes are restored exactly; RightShift never becomes
---    LeftShift and two simultaneously-held Shift keys remain two keys.
--- 4. Cleanup runs on success, ordinary failure and unexpected exceptions. A
---    cleanup failure is reported separately and can never become a commit.
--- ==============================================================================

local M = {}

local VALUE_UP = 0
local VALUE_DOWN = 1

--- Creates one transaction around an already-open uinput channel.
--- @param channel table Exposes is_open() and emit(code, value) -> boolean.
--- @return table transaction
function M.new(channel)
	local failure = nil
	local failed_phase = nil
	local cleanup_ok = true
	local down_stack = {}
	local physical_modifiers = {}
	local finished = false

	local function mark_failed(reason, phase)
		if not failure then
			failure = tostring(reason or "output emission failed")
			failed_phase = phase
		end
	end

	local function channel_open()
		if type(channel) ~= "table" or type(channel.emit) ~= "function" then return false end
		if type(channel.is_open) ~= "function" then return true end
		local ok, open = pcall(channel.is_open)
		return ok and open == true
	end

	local function wire(code, value, phase, cleanup)
		if not channel_open() then
			if cleanup then cleanup_ok = false end
			mark_failed("uinput channel is not open", phase)
			return false
		end
		local ok, emitted = pcall(channel.emit, code, value)
		if not ok or emitted ~= true then
			if cleanup then cleanup_ok = false end
			mark_failed(ok and "uinput emit returned false" or emitted, phase)
			return false
		end
		return true
	end

	local function remove_down(code)
		for index = #down_stack, 1, -1 do
			if down_stack[index] == code then
				table.remove(down_stack, index)
				return
			end
		end
	end

	local tx = {}

	--- Emits and tracks one synthetic transition.
	--- @param code integer Exact evdev keycode.
	--- @param value integer 0 release or 1 press.
	--- @param phase string|nil Diagnostic phase.
	--- @return boolean
	function tx.emit(code, value, phase)
		if finished or failure then return false end
		if type(code) ~= "number" or (value ~= VALUE_UP and value ~= VALUE_DOWN) then
			mark_failed("invalid synthetic key transition", phase)
			return false
		end
		if not wire(code, value, phase or "synthetic key", false) then return false end
		if value == VALUE_DOWN then
			down_stack[#down_stack + 1] = code
		else
			remove_down(code)
		end
		return true
	end

	--- Releases the exact physical modifiers before synthetic text starts.
	--- Every attempted key is retained for restoration even if its key-up fails:
	--- a failed SYN leaves delivery ambiguous, and an extra key-down is safer than
	--- silently substituting or forgetting a modifier the user still holds.
	--- @param codes table Ordered exact evdev keycodes.
	--- @return boolean
	function tx.neutralize(codes)
		if finished or failure then return false end
		for _, code in ipairs(codes or {}) do
			physical_modifiers[#physical_modifiers + 1] = code
			if not wire(code, VALUE_UP, "physical modifier up", false) then return false end
		end
		return true
	end

	--- Records a non-wire failure raised by the transaction body.
	--- @param reason any
	--- @param phase string|nil
	function tx.fail(reason, phase)
		mark_failed(reason, phase or "transaction body")
	end

	--- @return boolean
	function tx.is_failed()
		return failure ~= nil
	end

	--- @return string|nil
	function tx.error()
		return failure
	end

	--- A channel-shaped view for helpers such as clipboard paste.
	--- Its emit function still passes through this transaction's checked stack.
	--- @return table
	function tx.channel()
		return {
			is_open = function() return not finished and not failure and channel_open() end,
			emit = function(code, value) return tx.emit(code, value, "clipboard paste chord") end,
		}
	end

	--- Cleans up and returns the only commit token callers may trust.
	--- @return table { ok, error, failed_phase, cleanup_ok }
	function tx.finish()
		if finished then
			return {
				ok = false,
				error = "transaction already finished",
				failed_phase = "finish",
				cleanup_ok = cleanup_ok,
			}
		end
		finished = true

		if #down_stack > 0 and not failure then
			mark_failed("transaction body left synthetic keys pressed", "synthetic cleanup")
		end
		for index = #down_stack, 1, -1 do
			wire(down_stack[index], VALUE_UP, "synthetic cleanup key-up", true)
		end
		down_stack = {}

		for index = #physical_modifiers, 1, -1 do
			local code = physical_modifiers[index]
			if not wire(code, VALUE_DOWN, "physical modifier restore", false) then
				-- One immediate best-effort retry is cleanup, not a commit attempt.
				-- It handles a one-shot failed write while keeping the first failure
				-- visible in the transaction result.
				wire(code, VALUE_DOWN, "physical modifier restore retry", true)
			end
		end
		physical_modifiers = {}

		return {
			ok = failure == nil and cleanup_ok,
			error = failure,
			failed_phase = failed_phase,
			cleanup_ok = cleanup_ok,
		}
	end

	return tx
end

return M

--- tests/unit/modules/hotstrings/test_output_transaction.lua

--- ==============================================================================
--- MODULE: Failure-Atomic Output Transaction Tests
--- DESCRIPTION:
--- Fails each individual emission in a synthetic replacement and proves that
--- every successfully-pressed key is released, the exact physical modifier is
--- restored, and no failed transaction can report a commit.
---
--- ROOT CAUSE ENCODED:
--- uinput returns false for both an EV_KEY write failure and its following
--- SYN_REPORT failure. The old injector ignored that boolean, restored physical
--- modifiers only on its success tail, and represented RightShift as the generic
--- role "shift" which was later re-created as LeftShift. A partial write could
--- therefore claim success, arm undo/metrics and leave a key logically held.
--- ==============================================================================

local helpers = require("tests.helpers")

local VALUE_UP = 0
local VALUE_DOWN = 1
local KEY_RIGHTSHIFT = 54
local KEY_LEFTSHIFT = 42
local KEY_BACKSPACE = 14
local KEY_A = 30

--- Builds a channel whose one selected call fails without changing key state.
--- @param fail_at integer|nil One-based emit call to fail.
--- @return table channel, table state, table calls
local function channel_failing_at(fail_at)
	local state = { [KEY_RIGHTSHIFT] = true }
	local calls = {}
	local channel = {
		is_open = function() return true end,
		emit = function(code, value)
			calls[#calls + 1] = { code = code, value = value }
			if #calls == fail_at then return false end
			if value == VALUE_DOWN then state[code] = true end
			if value == VALUE_UP then state[code] = nil end
			return true
		end,
	}
	return channel, state, calls
end

local function drive(fail_at)
	local Transaction = helpers.load_module("modules.hotstrings.output_transaction")
	local channel, state, calls = channel_failing_at(fail_at)
	local tx = Transaction.new(channel)

	if tx.neutralize({ KEY_RIGHTSHIFT }) then
		tx.emit(KEY_BACKSPACE, VALUE_DOWN, "backspace down")
		tx.emit(KEY_BACKSPACE, VALUE_UP, "backspace up")
		tx.emit(KEY_LEFTSHIFT, VALUE_DOWN, "synthetic shift down")
		tx.emit(KEY_A, VALUE_DOWN, "letter down")
		tx.emit(KEY_A, VALUE_UP, "letter up")
		tx.emit(KEY_LEFTSHIFT, VALUE_UP, "synthetic shift up")
	end

	return tx.finish(), state, calls
end





-- =========================================
-- =========================================
-- ======= 1/ Successful commit ============
-- =========================================
-- =========================================

helpers.describe("output transaction: commit", function()
	helpers.it("commits only after balanced output and exact modifier restoration", function()
		local result, state, calls = drive(nil)
		helpers.assert_true(result.ok, "all emissions reached the wire")
		helpers.assert_true(result.cleanup_ok, "no cleanup emission failed")
		helpers.assert_eq(state, { [KEY_RIGHTSHIFT] = true },
			"the application ends with the exact physical modifier it started with")
		helpers.assert_eq(calls[1], { code = KEY_RIGHTSHIFT, value = VALUE_UP },
			"RightShift is neutralised as RightShift")
		helpers.assert_eq(calls[#calls], { code = KEY_RIGHTSHIFT, value = VALUE_DOWN },
			"and restored as RightShift, never substituted with LeftShift")
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Failure at every step =========
-- =========================================
-- =========================================

helpers.describe("output transaction: every emission can fail", function()
	helpers.it("never commits and always balances state after one failed step", function()
		-- Eight normal calls: physical modifier up, six synthetic transitions,
		-- physical modifier down. Each position is failed in its own transaction.
		for fail_at = 1, 8 do
			local result, state, calls = drive(fail_at)
			helpers.assert_true(not result.ok,
				"failure at emission " .. fail_at .. " must prevent commit")
			helpers.assert_true(result.error ~= nil,
				"failure at emission " .. fail_at .. " must retain a diagnosis")
			helpers.assert_true(result.cleanup_ok,
				"the one-shot failure leaves cleanup available at emission " .. fail_at)
			helpers.assert_eq(state, { [KEY_RIGHTSHIFT] = true },
				"failure at emission " .. fail_at .. " must leave no synthetic key down")
			helpers.assert_true(#calls >= fail_at,
				"the selected failure position must actually have been reached")
		end
	end)

	helpers.it("reports cleanup failure instead of claiming a balanced state", function()
		local Transaction = helpers.load_module("modules.hotstrings.output_transaction")
		local calls = 0
		local tx = Transaction.new({
			is_open = function() return true end,
			emit = function()
				calls = calls + 1
				return calls == 1
			end,
		})
		tx.emit(KEY_A, VALUE_DOWN, "letter down")
		tx.fail("forced body failure")
		local result = tx.finish()

		helpers.assert_true(not result.ok, "body failure cannot commit")
		helpers.assert_true(not result.cleanup_ok,
			"a failed emergency key-up must be visible to the caller")
	end)
end)

--- tests/unit/modules/shortcuts/test_surround_with_parens_transaction.lua

--- ==============================================================================
--- MODULE: Parenthesis Surround Timer Transaction Regression Tests
--- DESCRIPTION:
--- Proves the delayed closing-half timer commits before the action moves the
--- cursor or emits an opening parenthesis. A refused one-shot therefore leaves
--- the document untouched instead of publishing half of the user action.
--- ==============================================================================

local helpers = require("tests.helpers")

local MUTATED = {
	"modules.shortcuts.actions.text", "adapters.synthetic_input",
	"adapters.timer_scheduler", "infra.logger", "infra.paths", "infra.timings",
}

local function fresh_fixture(failure)
	for _, name in ipairs(MUTATED) do package.loaded[name] = nil end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.paths"] = { shared = function() return nil end }
	package.loaded["infra.timings"] = { sec = function() return 0.01 end }

	local emitted = {}
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function(modifiers, key)
			emitted[#emitted + 1] = { kind = "stroke", modifiers = modifiers, key = key }
			return true
		end,
		emit_key_strokes = function(value)
			emitted[#emitted + 1] = { kind = "text", value = value }
			return true
		end,
	}

	local calls = {}
	local scheduler = { cancel_refusals = failure == "debt" and 1 or 0 }
	function scheduler.after(delay, callback)
		local handle = { timer = {}, committed = false, fired = false }
		local call = { delay = delay, callback = callback, handle = handle }
		calls[#calls + 1] = call
		if failure == "settled" then
			handle.timer = nil
			handle.fired = true
			return handle, false
		elseif failure == "debt" then
			return handle, false
		end
		handle.committed = true
		function call.fire()
			handle.committed = false
			handle.fired = true
			handle.timer = nil
			callback()
		end
		return handle, true
	end
	function scheduler.cancel(handle)
		if scheduler.cancel_refusals > 0 then
			scheduler.cancel_refusals = scheduler.cancel_refusals - 1
			return false
		end
		handle.committed = false
		handle.fired = true
		handle.timer = nil
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	local actions = helpers.load_with_stubs("modules.shortcuts.actions.text")
	return actions, emitted, calls
end

helpers.describe("surround_with_parens one-shot ownership", function()
	helpers.it("a refused timer produces no cursor or text output", function()
		local actions, emitted, calls = fresh_fixture("settled")
		helpers.assert_eq(actions.surround_with_parens(), false)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(#emitted, 0,
			"the closing-half capability must commit before the opening half mutates text")
	end)

	helpers.it("a committed timer preserves the exact opening then closing order", function()
		local actions, emitted, calls = fresh_fixture()
		helpers.assert_true(actions.surround_with_parens())
		helpers.assert_eq(#emitted, 2)
		helpers.assert_eq(emitted[1].key, "left")
		helpers.assert_eq(emitted[2].value, "(")
		calls[1].fire()
		helpers.assert_eq(#emitted, 4)
		helpers.assert_eq(emitted[3].key, "right")
		helpers.assert_eq(emitted[4].value, ")")
	end)

	helpers.it("cleanup debt blocks a sibling timer and all text mutation", function()
		local actions, emitted, calls = fresh_fixture("debt")
		helpers.assert_eq(actions.surround_with_parens(), false)
		helpers.assert_eq(actions.surround_with_parens(), false)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(#emitted, 0)
	end)
end)

for _, name in ipairs(MUTATED) do package.loaded[name] = nil end

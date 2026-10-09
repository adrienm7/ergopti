--- tests/unit/modules/shortcuts/test_text_reselection_batch.lua

--- ==============================================================================
--- MODULE: Text Transform Reselection Batch Regression
--- DESCRIPTION:
--- A transformed selection can contain 5,000 characters. Emitting each Left and
--- Shift+Right through the ambient convenience API created 10,000 transactions,
--- broker triggers, and action epochs. This drives the production transform and
--- requires the reselection to be one explicit transaction/batch instead.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("text transform: reselection is one synthetic transaction", function()
	helpers.it("batches every cursor key behind one broker handoff", function()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		local selected = string.rep("a", 32)
		hs_stub.pasteboard = {
			getContents = function() return selected end,
			setContents = function() return true end,
			clearContents = function() return true end,
			readAllData = function()
				return { ["public.utf8-plain-text"] = "USER_CLIPBOARD" }
			end,
			writeAllData = function() return true end,
		}
		_G.hs = hs_stub
		package.loaded.hs = hs_stub

		local calls = {
			implicit = 0,
			begins = 0,
			pairs = 0,
			keys = {},
			dispatches = 0,
			seals = 0,
			cancels = 0,
		}
		local synthetic = {}
		function synthetic.emit_key_stroke()
			calls.implicit = calls.implicit + 1
			return true
		end
		function synthetic.emit_key_strokes() return true end
		function synthetic.begin(owner, effect)
			calls.begins = calls.begins + 1
			return { owner = owner, effect = effect }
		end
		function synthetic.begin_batch(tx)
			return { tx = tx }
		end
		function synthetic.keyStroke(batch, mods, key)
			helpers.assert_not_nil(batch.tx)
			calls.pairs = calls.pairs + 1
			calls.keys[#calls.keys + 1] = { mods = mods, key = key }
			return true
		end
		function synthetic.dispatch()
			calls.dispatches = calls.dispatches + 1
			return true
		end
		function synthetic.seal()
			calls.seals = calls.seals + 1
			return true
		end
		function synthetic.cancel()
			calls.cancels = calls.cancels + 1
			return true
		end

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = nil
		package.loaded["infra.timings"] = nil
		package.loaded["adapters.synthetic_input"] = synthetic
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["modules.shortcuts.actions.text"] = nil
		local actions = require("modules.shortcuts.actions.text")

		actions.toggle_uppercase()
		local timers = hs_stub.timer.__timers
		-- Timer 1 is the 2 s lock failsafe. Drive the real copy/paste/reselect chain.
		helpers.assert_true(#timers >= 2)
		timers[2]:fire()
		timers[3]:fire()
		timers[4]:fire()

		helpers.assert_eq(calls.implicit, 2,
			"only Cmd+C and Cmd+V may use standalone synthetic actions")
		helpers.assert_eq(calls.begins, 1)
		helpers.assert_eq(calls.dispatches, 1)
		helpers.assert_eq(calls.seals, 1)
		helpers.assert_eq(calls.cancels, 0)
		helpers.assert_eq(calls.pairs, #selected * 2,
			"the original Left then Shift+Right selection must stay inside one batch")
		for index, stroke in ipairs(calls.keys) do
			if index <= #selected then
				helpers.assert_eq(stroke.key, "left")
				helpers.assert_eq(#stroke.mods, 0,
					"the first half must move the caret without extending the selection")
			else
				helpers.assert_eq(stroke.key, "right")
				helpers.assert_eq(#stroke.mods, 1)
				helpers.assert_eq(stroke.mods[1], "shift",
					"the second half must select toward the original right-hand caret")
			end
		end
	end)
end)

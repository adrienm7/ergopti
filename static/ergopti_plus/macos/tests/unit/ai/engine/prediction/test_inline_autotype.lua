--- tests/unit/ai/engine/prediction/test_inline_autotype.lua

--- ==============================================================================
--- MODULE: Inline Auto-Type On macOS
--- DESCRIPTION:
--- The Windows inline mode, the most complete driver's (maintainer decision of
--- 2026-11-06): with llm.trigger.inline_autotype on, the finished prediction is
--- typed through the bridge's acceptance (the Tab path) once the paint that
--- showed it has returned, instead of waiting on offer. A prediction that
--- erases typed text keeps its offer, and a superseded request types nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = helpers.load_with_stubs("ai.engine.prediction.engine")

--- Runs `_inline_accept` with a recording scheduler and bridge.
--- @param preds table Final predictions.
--- @param current boolean What the request's currency check answers.
--- @return table seen { scheduled, applied, result }
local function run(preds, current)
	local seen = { scheduled = 0, applied = {} }
	local deps = {
		after = function(delay, fn)
			seen.scheduled = seen.scheduled + 1
			helpers.assert_eq(delay, 0, "typed right after the paint's callback returns")
			seen.callback = fn
			return true
		end,
		bridge = { apply_prediction = function(index) seen.applied[#seen.applied + 1] = index; return true end },
		is_current = function() return current end,
	}
	seen.result = Engine._inline_accept(preds, 7, deps)
	if seen.callback then seen.callback() end
	return seen
end

helpers.describe("prediction inline auto-type (llm-inline-autotype-macos)", function()
	helpers.it("(llm-inline-autotype-macos) types the first finished prediction through the acceptance path", function()
		local seen = run({ { to_type = " est bien faite", deletes = 0 }, { to_type = " va bien", deletes = 0 } }, true)
		helpers.assert_eq(seen.result, true)
		helpers.assert_eq(seen.applied, { 1 }, "prediction 1 goes through apply_prediction, as Tab does")
	end)

	helpers.it("(llm-inline-autotype-macos) leaves an erasing prediction on offer", function()
		local seen = run({ { to_type = "bien", deletes = 3 } }, true)
		helpers.assert_eq(seen.result, false)
		helpers.assert_eq(seen.scheduled, 0, "a correction is never applied without the user's accept")
	end)

	helpers.it("(llm-inline-autotype-macos) types nothing for a request superseded before the deferred call", function()
		local seen = run({ { to_type = " est bien faite", deletes = 0 } }, false)
		helpers.assert_eq(seen.scheduled, 1)
		helpers.assert_eq(#seen.applied, 0)
	end)

	helpers.it("(llm-inline-autotype-macos) the setting reaches the engine and its runtime read-back", function()
		local key = require("settings.engine.keys").COMMAND.LLM_INLINE_AUTOTYPE
		Engine.set_llm_inline_autotype(true)
		local found, value = Engine.get_llm_runtime_setting(key)
		helpers.assert_eq(found, true)
		helpers.assert_eq(value, true)
		Engine.set_llm_inline_autotype(false)
		helpers.assert_eq(select(2, Engine.get_llm_runtime_setting(key)), false)
	end)

	helpers.it("(llm-inline-autotype-macos) the final paint hands its predictions to the inline owner", function()
		local source = assert(helpers.read_driver_unit(
			"if ctx.on_final_predictions then ctx.on_final_predictions(valid_preds) end"))
		local final = source:find("if ctx.on_final_predictions then ctx.on_final_predictions(valid_preds) end", 1, true)
		local terminal = source:find("if ctx.on_request_terminal then ctx.on_request_terminal() end\n\t\t\tLogger.success", 1, true)
		helpers.assert_true(final ~= nil and terminal ~= nil and final > terminal,
			"the inline owner runs after the final commit, once the request is terminal")
	end)
end)

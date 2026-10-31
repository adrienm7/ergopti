--- tests/unit/infra/field_check/test_field_check_typed_steps.lua

--- ==============================================================================
--- MODULE: Field Run Hotstring Round-Trip and Prediction Tooltip Probes
--- DESCRIPTION:
--- The two field run steps that prove the real typing path, over scripted ports:
--- 1. the hotstring round-trip types the first candidate after a Space and
---    with Space as its terminator, and waits for exactly its expansion; a
---    missing keymap, no candidate, Space not a terminator and a trigger left
---    unexpanded each fail with their own code;
--- 2. the prediction step needs predictions on and an installed model, types
---    its own text and waits for the tooltip; each unmet assumption and a
---    tooltip that never showed fail with their own code.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds scripted ports.
--- @param world table Scripted answers.
--- @return table ports
local function make_ports(world)
	return {
		hotstring_candidates = function() return world.candidates end,
		prediction_readiness = function(callback) callback(world.readiness) end,
		scratch_typing = function(keys, callback, options)
			world.keys, world.options = keys, options
			callback(world.typed(keys, options))
		end,
	}
end

--- Runs one check and returns its steps keyed by id.
--- @param check string Check id.
--- @param world table Scripted answers.
--- @return table steps, table result
local function run(check, world)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run(check, make_ports(world), function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

--- A typing outcome that posted every key and left `text` in the field.
--- @param text string|nil Field text.
--- @param effect_ms number|nil Time to the awaited effect.
--- @return function typed
local function typed_as(text, effect_ms)
	return function(keys)
		return { focused = true, posted = #keys, text = text, effect_ms = effect_ms, restored = true }
	end
end

local CANDIDATES = {
	candidates = { { trigger = "axa", expansion = "AXA" }, { trigger = "adn", expansion = "ADN" } },
	space_terminates = true,
	space_consumed = false,
}

helpers.describe("hotstring round-trip probe", function()
	helpers.it("types the first candidate with its terminator and passes on the exact expansion", function()
		local world = { candidates = CANDIDATES, typed = typed_as(" AXA ", 61.7) }
		local steps, result = run("hotstring_roundtrip", world)
		helpers.assert_true(result.passed)
		helpers.assert_eq(table.concat(world.keys, ","), "space,a,x,a,space")
		helpers.assert_eq(world.options.until_text, " AXA ", "the field is awaited for exactly the expansion")
		helpers.assert_eq(steps.hotstring_expanded.value, "exact")
		helpers.assert_eq(steps.terminator_to_text_ms.value, "61")
		helpers.assert_eq(steps.hotstring_trigger.value, "candidates_2")
	end)

	helpers.it("expects no terminator in the field when Space is consumed", function()
		local consumed = { candidates = CANDIDATES.candidates, space_terminates = true, space_consumed = true }
		local world = { candidates = consumed, typed = typed_as(" AXA", 40) }
		local steps, result = run("hotstring_roundtrip", world)
		helpers.assert_true(result.passed)
		helpers.assert_eq(world.options.until_text, " AXA")
		helpers.assert_eq(steps.space_consumed.value, "yes")
	end)

	helpers.it("names a trigger typed but never expanded", function()
		local steps, result = run("hotstring_roundtrip", { candidates = CANDIDATES, typed = typed_as(" axa ") })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.hotstring_expanded.value, "not_expanded")
		helpers.assert_nil(steps.terminator_to_text_ms)
	end)

	helpers.it("fails each unmet assumption with its own code and types nothing", function()
		for _, case in ipairs({
			{ candidates = nil, code = "keymap_absent" },
			{ candidates = { candidates = {}, space_terminates = true }, code = "no_enabled_trigger" },
			{ candidates = { candidates = CANDIDATES.candidates, space_terminates = false }, code = "space_not_terminator" },
		}) do
			local world = { candidates = case.candidates, typed = typed_as(" AXA ") }
			local steps, result = run("hotstring_roundtrip", world)
			helpers.assert_true(not result.passed, case.code)
			helpers.assert_eq(steps.hotstring_trigger.value, case.code)
			helpers.assert_nil(world.keys, "nothing is typed when " .. case.code)
		end
	end)
end)

helpers.describe("prediction tooltip probe", function()
	helpers.it("types its own text and passes when the tooltip shows", function()
		local world = { readiness = { enabled = true, installed = true, backend = "ollama" }, typed = typed_as("le chat", 812.4) }
		local steps, result = run("prediction_tooltip", world)
		helpers.assert_true(result.passed)
		helpers.assert_true(world.options.until_prediction)
		helpers.assert_eq(world.keys[1], "l")
		helpers.assert_eq(world.keys[3], "space")
		helpers.assert_eq(steps.prediction_shown.value, "shown")
		helpers.assert_eq(steps.keystroke_to_tooltip_ms.value, "812")
	end)

	helpers.it("fails a tooltip that never showed", function()
		local world = { readiness = { enabled = true, installed = true, backend = "mlx" }, typed = typed_as("le chat") }
		local steps, result = run("prediction_tooltip", world)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.prediction_shown.value, "tooltip_not_shown")
	end)

	helpers.it("skips predictions the user turned off without typing (llm-disabled-is-skip)", function()
		local world = { readiness = { enabled = false, installed = false, backend = "mlx" }, typed = typed_as("") }
		local steps, result = run("prediction_tooltip", world)
		helpers.assert_true(result.passed, "a user's choice to turn predictions off is not a defect")
		helpers.assert_eq(steps.prediction_ready.state, "skip")
		helpers.assert_eq(steps.prediction_ready.value, "llm_disabled")
		helpers.assert_nil(world.keys, "nothing is typed when predictions are off")
	end)

	helpers.it("fails a model not on this Mac without typing", function()
		for _, case in ipairs({
			{ readiness = { enabled = true, installed = false, backend = "api" }, code = "no_installed_model" },
		}) do
			local world = { readiness = case.readiness, typed = typed_as("") }
			local steps, result = run("prediction_tooltip", world)
			helpers.assert_true(not result.passed, case.code)
			helpers.assert_eq(steps.prediction_ready.value, case.code)
			helpers.assert_nil(world.keys, "nothing is typed when " .. case.code)
		end
	end)
end)

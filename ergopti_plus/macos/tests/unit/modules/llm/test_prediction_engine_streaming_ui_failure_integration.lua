--- tests/unit/modules/llm/test_prediction_engine_streaming_ui_failure_integration.lua

--- ==============================================================================
--- MODULE: Prediction-engine streaming UI failure integration regression
--- DESCRIPTION:
--- Drives the real prediction engine through the real streaming handler while
--- controlling only native timer, tooltip, telemetry, and backend boundaries.
--- A failed prediction-frame commit must propagate back to the engine owner so
--- the loading surface and backend request are revoked as one transaction.
--- ==============================================================================

local helpers = require("tests.helpers")


local load_fixture = require("tests.support.prediction_pipeline").load

helpers.describe("prediction pipeline fixture isolation", function()
	helpers.it("owns fresh nested defaults on each load", function()
		load_fixture()
		local first = package.loaded["modules.llm"].DEFAULT_STATE
		load_fixture()
		local second = package.loaded["modules.llm"].DEFAULT_STATE
		first.llm_val_modifiers[1] = "mutated"
		local observed = second.llm_val_modifiers[1]
		first.llm_val_modifiers[1] = "alt"
		helpers.assert_eq(observed, "alt", "nested modifier defaults must not alias a previous fixture")
		helpers.assert_true(first ~= second)
	end)
end)

--- Delivers a valid final prediction through the real wrapped backend callback.
--- @param fixture table Active pipeline fixture.
local function complete_prediction(fixture)
	fixture.on_success({ {
		to_type = " completion", deletes = 0,
		chunks = { { type = "insert", text = " completion" } }, nw = "",
	} }, 25, true, false)
end


--- Checks one dispatch and the ordered cross-module lifecycle outcome.
--- @param fixture table Active pipeline fixture.
--- @param terminal string Expected lifecycle outcome.
local function assert_request_logs(fixture, terminal)
	helpers.assert_eq(fixture.fetches, 1, "the real engine must dispatch a request")
	helpers.assert_eq(#fixture.logs, 2, "one request must have one truthful lifecycle terminal")
	helpers.assert_eq(fixture.logs[1].level, "start")
	helpers.assert_true(fixture.logs[1].message:find("LLM request", 1, true) ~= nil)
	helpers.assert_eq(fixture.logs[2].level, terminal)
end




-- ==========================================================
-- ==========================================================
-- ======= 1/ Transitive UI-Failure Ownership Gate =========
-- ==========================================================
-- ==========================================================

helpers.describe("prediction_engine + streaming_handler: UI failure ownership", function()
	helpers.it("propagates a failed real handler render into engine cleanup", function()
		local fixture = load_fixture()
		fixture.engine.perform_check(true)

		helpers.assert_eq(fixture.fetches, 1,
			"the negative control must dispatch through the real prediction engine")
		helpers.assert_not_nil(fixture.on_success,
			"the backend boundary must receive the real engine-wrapped success callback")
		fixture.on_success({ {
			to_type = " completion",
			deletes = 0,
			chunks = { { type = "insert", text = " completion" } },
			nw = "",
		} }, 25, true, false)

		helpers.assert_eq(fixture.prediction_renders, 1,
			"the negative control must fail inside the real streaming handler render")
		helpers.assert_eq(fixture.hides, 1,
			"the handler UI failure must reach the engine owner and revoke its surface")
		helpers.assert_eq(fixture.cancels, 1,
			"engine cleanup must cancel the backend request whose UI can no longer commit")
		helpers.assert_eq(fixture.engine.is_visible(), false)
		helpers.assert_true(#fixture.logs >= 2, "render refusal must terminate the dispatched lifecycle")
		helpers.assert_eq(fixture.logs[1].level, "start")
		helpers.assert_eq(fixture.logs[#fixture.logs].level, "error")
		for _, record in ipairs(fixture.logs) do
			helpers.assert_true(record.level ~= "success", "rejected UI output must never log success")
		end
	end)
end)


helpers.describe("prediction_engine + streaming_handler: request lifecycle logs", function()
	helpers.it("pairs engine START with handler SUCCESS only after final rendering", function()
		local fixture = load_fixture({ render_success = true })
		fixture.engine.perform_check(true)
		helpers.assert_eq(#fixture.logs, 1, "dispatch alone must not claim success")
		complete_prediction(fixture)
		assert_request_logs(fixture, "success")
		helpers.assert_eq(fixture.prediction_renders, 1)
		helpers.assert_true(fixture.engine.is_visible())
		helpers.assert_eq(fixture.cancels, 0)
	end)

	for _, outcome in ipairs({ "failure", "empty" }) do
		helpers.it("ends " .. outcome .. " response with WARNING and no false SUCCESS", function()
			local fixture = load_fixture({ render_success = true })
			fixture.engine.perform_check(true)
			if outcome == "failure" then fixture.on_fail() else fixture.on_success({}, 25, true, false) end
			assert_request_logs(fixture, "warn")
			helpers.assert_eq(fixture.prediction_renders, 0)
			helpers.assert_eq(fixture.hides, 1)
			helpers.assert_true(not fixture.engine.is_visible())
		end)
	end

	helpers.it("does not log SUCCESS or render a final callback after reset", function()
		local fixture = load_fixture({ render_success = true })
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.fetches, 1)
		helpers.assert_eq(#fixture.logs, 1)
		helpers.assert_eq(fixture.logs[1].level, "start")
		helpers.assert_true(fixture.engine.reset())
		local logs_before, hides_before = #fixture.logs, fixture.hides
		complete_prediction(fixture)
		helpers.assert_eq(#fixture.logs, logs_before,
			"a revoked request cannot add a lifecycle terminal to its successor")
		helpers.assert_eq(fixture.prediction_renders, 0)
		helpers.assert_eq(fixture.hides, hides_before)
		helpers.assert_true(not fixture.engine.is_visible())
		helpers.assert_eq(fixture.cancels, 1)
	end)
end)

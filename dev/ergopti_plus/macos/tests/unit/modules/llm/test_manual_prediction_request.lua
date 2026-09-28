--- tests/unit/modules/llm/test_manual_prediction_request.lua

--- ==============================================================================
--- MODULE: Manual Prediction Request (llm-manual-prediction-feedback)
--- DESCRIPTION:
--- request_manual_prediction is what the llm_generate_prediction action runs
--- through the keymap bridge. It drives the real engine through the shared
--- prediction pipeline fixture, whose backend and tooltip are observable.
---
--- ROOT CAUSE ENCODED:
--- The manual trigger reached perform_check, whose refusals (paused, AI off,
--- no model or backend warming up, nothing typed) are debug lines meant for the
--- automatic per-keystroke path. A chord the user pressed on purpose did
--- nothing visible and left nothing in the INFO log. Every refusal of a manual
--- request is now logged at INFO with its reason and shown as a tooltip.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")

--- Loads the real engine and records every tooltip notice it shows.
--- @param options table|nil Pipeline options.
--- @return table fixture
local function load_fixture(options)
	options = options or {}
	options.capture_info = true
	options.render_success = true
	local fixture = Pipeline.load(options)
	fixture.notices = {}
	package.loaded["ui.tooltip"].show = function(content)
		fixture.notices[#fixture.notices + 1] = content
		return true
	end
	return fixture
end

--- The INFO records that refuse a manual request for one reason.
--- @param fixture table
--- @param reason string
--- @return number
local function refusals(fixture, reason)
	local count = 0
	for _, record in ipairs(fixture.logs) do
		if record.level == "info"
			and record.message:find("Manual prediction refused (" .. reason .. ")", 1, true) then
			count = count + 1
		end
	end
	return count
end

--- Asserts one refusal: logged once at INFO, shown once, nothing fetched.
--- @param fixture table
--- @param reason string
local function assert_refused(fixture, reason)
	local requested = fixture.engine.request_manual_prediction()
	helpers.assert_eq(requested, false, "a refused request must report that nothing started")
	helpers.assert_eq(refusals(fixture, reason), 1,
		"the refusal must be logged at INFO with its reason '" .. reason .. "'")
	helpers.assert_eq(#fixture.notices, 1, "the user must be shown why nothing happened")
	helpers.assert_eq(fixture.notices[1],
		package.loaded["infra.i18n"].get("llm.manual_prediction." .. reason),
		"the notice must be the localized text of the reason")
	helpers.assert_eq(fixture.fetches, 0, "a refused request must not reach the backend")
end

helpers.describe("manual prediction request (llm-manual-prediction-feedback)", function()
	helpers.it("refuses while the script is paused, and says so", function()
		local fixture = load_fixture()
		package.loaded["modules.shortcuts.script_control"] = {
			is_paused = function() return true end,
		}
		local ok, err = pcall(assert_refused, fixture, "paused")
		package.loaded["modules.shortcuts.script_control"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses while the AI is switched off, and says so", function()
		assert_refused(load_fixture({ llm_enabled = false }), "disabled")
	end)

	helpers.it("refuses while the backend is warming up, and says so", function()
		local fixture = load_fixture()
		package.loaded["modules.llm"].is_backend_ready = function() return false end
		assert_refused(fixture, "backend_not_ready")
	end)

	helpers.it("refuses without a selected model, and says so", function()
		local fixture = load_fixture()
		package.loaded["modules.llm"].get_current_model = function() return "" end
		assert_refused(fixture, "backend_not_ready")
	end)

	helpers.it("refuses when nothing was typed, and says so", function()
		assert_refused(load_fixture({ buffer = "" }), "empty_context")
	end)

	helpers.it("sends a ready request to the backend without a notice", function()
		local fixture = load_fixture()
		local requested = fixture.engine.request_manual_prediction()
		helpers.assert_eq(requested, true, "a ready request must report that it started")
		helpers.assert_eq(fixture.fetches, 1, "a ready request must reach the backend once")
		helpers.assert_eq(#fixture.notices, 0, "an accepted request must not show a refusal")
		local logged = 0
		for _, record in ipairs(fixture.logs) do
			if record.level == "info" and record.message:find("Manual prediction requested", 1, true) then
				logged = logged + 1
			end
		end
		helpers.assert_eq(logged, 1, "an accepted request is logged at INFO too")
	end)
end)

--- tests/unit/modules/llm/prediction/test_prediction_settings_change_retires.lua

--- ==============================================================================
--- MODULE: Prediction Retired By A Settings Change
--- DESCRIPTION:
--- A change of the backend, the API entry, its provider, model, endpoint or
--- key while a request is in flight retires that request, as on Windows and
--- Linux (maintainer decision AID-3 of 11 November 2026): its late answer is
--- never shown, its stream is cancelled, and the next request is sent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")


local function deliver(fixture)
	fixture.on_success({ {
		to_type = " completion", deletes = 0,
		chunks = { { type = "insert", text = " completion" } }, nw = "",
	} }, 25, true, false)
end


helpers.describe("prediction engine — a settings change retires the request in flight", function()
	for _, change in ipairs({
		{ field = "backend", value = "api" }, { field = "entry", value = "entry-2" },
		{ field = "provider", value = "groq" }, { field = "model", value = "other-model" },
		{ field = "endpoint", value = "http://127.0.0.1:11500" }, { field = "key", value = "new-key" },
	}) do
		helpers.it("drops the late answer after its " .. change.field .. " changed (settings-retire-inflight)", function()
			local fixture = Pipeline.load({ render_success = true })
			local core = package.loaded["modules.llm"]
			local sent = { backend = "ollama", model = "test-model" }
			core.request_settings = function() return sent end
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 1)
			local edited = {}
			for key, value in pairs(sent) do edited[key] = value end
			edited[change.field] = change.value
			core.request_settings = function() return edited end
			deliver(fixture)
			helpers.assert_eq(fixture.prediction_renders, 0, "the old settings' answer is never shown")
			helpers.assert_eq(fixture.engine.is_visible(), false)
			helpers.assert_true(fixture.cancels >= 1, "its stream is cancelled")
			helpers.assert_eq(fixture.engine.has_pending_work(), false, "nothing of it stays pending")
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, 2, "the next request is sent with the new settings")
			deliver(fixture)
			helpers.assert_true(fixture.prediction_renders >= 1, "and its answer shows")
		end)
	end

	helpers.it("keeps a request whose settings did not change (settings-retire-inflight)", function()
		local fixture = Pipeline.load({ render_success = true })
		local core = package.loaded["modules.llm"]
		core.request_settings = function() return { backend = "ollama", model = "test-model" } end
		fixture.engine.perform_check(true)
		deliver(fixture)
		helpers.assert_true(fixture.engine.is_visible(), "fresh but equal snapshots are not a change")
		helpers.assert_eq(fixture.cancels, 0)
	end)
end)

helpers.describe("ai.engine.settings.request_settings — the shared snapshot and its change", function()
	local RequestSettings = require("ai.engine.settings.request_settings")

	helpers.it("names the first changed field in FIELDS order (settings-retire-inflight)", function()
		local before = RequestSettings.snapshot({ backend = "api", entry = "a", model = "m", key = "k" })
		helpers.assert_nil(RequestSettings.change(before, RequestSettings.snapshot({ backend = "api", entry = "a",
			model = "m", key = "k" })))
		helpers.assert_eq(RequestSettings.change(before, RequestSettings.snapshot({ backend = "api", entry = "a",
			model = "n", key = "j" })), "model")
		helpers.assert_eq(RequestSettings.change(before, RequestSettings.snapshot({ backend = "api", entry = "a",
			model = "m" })), "key", "a key withdrawn is a change")
	end)

	helpers.it("refuses a field it does not know (settings-retire-inflight)", function()
		helpers.assert_eq(pcall(RequestSettings.snapshot, { temperature = 0.5 }), false)
		helpers.assert_eq(pcall(RequestSettings.change, nil, {}), false)
	end)
end)

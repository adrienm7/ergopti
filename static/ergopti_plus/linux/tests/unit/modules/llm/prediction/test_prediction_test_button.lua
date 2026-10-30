--- tests/unit/modules/llm/prediction/test_prediction_test_button.lua

--- ==============================================================================
--- MODULE: Linux AI Menu Test Prediction (ai-test-prediction)
--- DESCRIPTION:
--- Replays the shared contract and proves the engine feeds it: the sample goes
--- straight to the active backend, the answer is a notice and never an offer the
--- user could accept into a document, and the refusals are those of a manual
--- request, an empty typing buffer aside.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

require("test.test_prediction_contract")(helpers)

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["modules.llm.prediction_engine"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

--- A fresh engine over a recording backend.
--- @param state table { enabled?, paused?, model? }
--- @return table engine, table seen
local function fixture(state)
	local seen = { chats = {}, notices = {} }
	replace("logger.shim", helpers.make_logger_stub())
	replace("modules.llm.profiles", {
		init = function() end,
		is_enabled = function() return state.enabled ~= false end,
		get_current_model = function() return state.model end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
	})
	replace("modules.llm.api_ollama", {
		chat = function(target, model, messages, opts, on_chunk, on_done)
			seen.chats[#seen.chats + 1] = { model = model, messages = messages, opts = opts, on_done = on_done }
		end,
		cancel = function() end,
	})
	package.loaded["modules.llm.prediction_engine"] = nil
	local engine = require("modules.llm.prediction_engine")
	engine.init({ focus_id = function() return "owned-prediction-window" end,
		scheduler = Fakes.timer_scheduler(),
		engine = { reset = function() end },
		context = { text = function() return "" end, replaced = function() end },
		is_paused = function() return state.paused == true end,
		notify = function(text) seen.notices[#seen.notices + 1] = text return true end,
	})
	return engine, seen
end

local function latest(seen) return seen.notices[#seen.notices] end

helpers.describe("Linux test prediction engine", function()
	helpers.it("sends the sample to the active backend and only shows the answer", function()
		local engine, seen = fixture({ model = "local-a" })
		local i18n = require("infra.i18n")
		local ok, err = pcall(function()
			helpers.assert_eq(engine.test_prediction(), true, "an empty typing buffer refuses nothing")
			helpers.assert_eq(#seen.chats, 1, "one request")
			helpers.assert_eq(seen.chats[1].model, "local-a")
			local user = seen.chats[1].messages[#seen.chats[1].messages].content
			helpers.assert_true(user:find(i18n.get("llm.test_prediction.sample"), 1, true) ~= nil, "on the sample")
			seen.chats[1].on_done("  mardi\n")
			helpers.assert_true(latest(seen):find("mardi", 1, true) ~= nil, "the answer is shown")
			helpers.assert_eq(#engine.get_suggestions(), 0, "and it never becomes an offer")
			helpers.assert_eq(engine.is_predicting(), false, "and the engine stayed out of it")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("shows the backend's failure", function()
		local engine, seen = fixture({ model = "local-a" })
		local ok, err = pcall(function()
			engine.test_prediction()
			seen.chats[1].on_done(nil, "quota exceeded")
			helpers.assert_true(latest(seen):find("quota exceeded", 1, true) ~= nil)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses a pause, the AI off and no model with their notices, and withdraws on a pause", function()
		local i18n = require("infra.i18n")
		for _, case in ipairs({
			{ state = { model = "m", paused = true }, key = "llm.manual_prediction.paused" },
			{ state = { model = "m", enabled = false }, key = "llm.manual_prediction.disabled" },
			{ state = {}, key = "llm.manual_prediction.backend_not_ready" },
		}) do
			local engine, seen = fixture(case.state)
			local ok, err = pcall(function()
				helpers.assert_eq(engine.test_prediction(), false)
				helpers.assert_eq(latest(seen), i18n.get(case.key))
				helpers.assert_eq(#seen.chats, 0, "nothing is sent")
			end)
			restore()
			if not ok then error(err, 0) end
		end
		local state = { model = "m" }
		local engine, seen = fixture(state)
		local ok, err = pcall(function()
			engine.test_prediction()
			local before = latest(seen)
			state.paused = true
			seen.chats[1].on_done("late")
			helpers.assert_eq(latest(seen), before, "no result after the pause")
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

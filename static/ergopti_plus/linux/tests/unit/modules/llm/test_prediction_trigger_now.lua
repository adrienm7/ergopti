--- tests/unit/modules/llm/test_prediction_trigger_now.lua

--- ==============================================================================
--- MODULE: Linux Manual Prediction Trigger (llm-manual-prediction-feedback)
--- DESCRIPTION:
--- trigger_now is what the llm_generate_prediction action runs: it feeds the
--- current typing buffer to predict() at once, and says why when it cannot.
---
--- ROOT CAUSE ENCODED:
--- The Linux engine had no manual trigger at all: a prediction could only come
--- from typing (inactivity, word end, the // ;; -- triggers), so the action the
--- other two drivers bind could not exist here. Every refusal (paused, AI off,
--- no Ollama or no model, nothing typed) is logged at INFO with its reason and
--- shown through the injected notice, like the other two drivers.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["modules.llm.prediction_engine"] = nil
	package.preload["modules.llm.api_ollama"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

--- A fresh engine over a typing buffer, a notice recorder and an INFO recorder.
--- @param state table { buffer?, enabled?, paused?, model?, ollama? }
--- @return table engine, table seen
local function fixture(state)
	local seen = { fired = {}, notices = {}, infos = {} }
	local logger = helpers.make_logger_stub()
	logger.info = function(_, fmt, ...) seen.infos[#seen.infos + 1] = string.format(fmt, ...) end
	replace("logger.shim", logger)
	replace("modules.llm.profiles", {
		init = function() end,
		is_enabled = function() return state.enabled ~= false end,
		get_current_model = function() return state.model end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
	})
	if state.ollama == false then
		-- An Ollama client that cannot load: the engine requires it through pcall.
		replace("modules.llm.api_ollama", nil)
		package.preload["modules.llm.api_ollama"] = function() error("no Ollama client in this test") end
	else
		replace("modules.llm.api_ollama", { chat = function() end, cancel = function() end })
	end
	package.loaded["modules.llm.prediction_engine"] = nil
	local engine = require("modules.llm.prediction_engine")
	engine.init({
		scheduler = Fakes.timer_scheduler(),
		engine = { current_buffer = function() return state.buffer or "" end, reset = function() end },
		is_paused = function() return state.paused == true end,
		notify = function(text) seen.notices[#seen.notices + 1] = text return true end,
	})
	engine.predict = function(context, output_context)
		seen.fired[#seen.fired + 1] = { context = context, output_context = output_context }
	end
	return engine, seen
end

--- How many INFO lines refuse for one reason.
--- @param seen table
--- @param reason string
--- @return number
local function refusals(seen, reason)
	local count = 0
	for _, line in ipairs(seen.infos) do
		if line:find("Manual prediction refused (" .. reason .. ")", 1, true) then count = count + 1 end
	end
	return count
end

--- Runs one refusal case and checks its three observable effects.
--- @param state table
--- @param reason string
local function assert_refused(state, reason)
	local engine, seen = fixture(state)
	local ok, err = pcall(function()
		helpers.assert_eq(engine.trigger_now(), false, "a refused request reports that nothing started")
		helpers.assert_eq(refusals(seen, reason), 1,
			"the refusal must be logged at INFO with its reason '" .. reason .. "'")
		helpers.assert_eq(#seen.notices, 1, "the user must be shown why nothing happened")
		helpers.assert_eq(seen.notices[1], require("infra.i18n").get("llm.manual_prediction." .. reason),
			"the notice is the localized text of the reason")
		helpers.assert_eq(#seen.fired, 0, "a refused request must not reach predict()")
	end)
	restore()
	if not ok then error(err, 0) end
end

helpers.describe("Linux manual prediction trigger (llm-manual-prediction-feedback)", function()
	helpers.it("refuses while the daemon is paused", function()
		assert_refused({ buffer = "hello", model = "m", paused = true }, "paused")
	end)

	helpers.it("refuses while the AI is switched off", function()
		assert_refused({ buffer = "hello", model = "m", enabled = false }, "disabled")
	end)

	helpers.it("refuses without a selected model", function()
		assert_refused({ buffer = "hello", model = nil }, "backend_not_ready")
	end)

	helpers.it("refuses without the Ollama client", function()
		assert_refused({ buffer = "hello", model = "m", ollama = false }, "backend_not_ready")
	end)

	helpers.it("refuses when nothing was typed", function()
		assert_refused({ buffer = "", model = "m" }, "empty_context")
	end)

	helpers.it("feeds the current buffer to predict() at once", function()
		local engine, seen = fixture({ buffer = "hello wor", model = "m" })
		local ok, err = pcall(function()
			helpers.assert_eq(engine.trigger_now(), true, "a ready request reports that it started")
			helpers.assert_eq(#seen.fired, 1, "predict() runs once, without waiting for a timer")
			helpers.assert_eq(seen.fired[1].context, "hello wor", "the context is the whole typing buffer")
			helpers.assert_eq(#seen.notices, 0, "an accepted request shows no refusal")
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("answers the llm_generate_prediction action", function()
		local engine, seen = fixture({ buffer = "abc", model = "m" })
		local ok, err = pcall(function()
			local handlers = engine.action_handlers()
			helpers.assert_eq(type(handlers.llm_generate_prediction), "function",
				"the engine provides the handler the daemon injects into the executor")
			handlers.llm_generate_prediction("keyboard__super_space", nil)
			helpers.assert_eq(#seen.fired, 1, "the action runs the manual trigger")
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

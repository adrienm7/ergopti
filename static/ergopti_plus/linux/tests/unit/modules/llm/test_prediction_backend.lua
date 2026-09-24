--- tests/unit/modules/llm/test_prediction_backend.lua

--- ==============================================================================
--- MODULE: Which Backend Answers A Prediction
--- DESCRIPTION:
--- With the API backend selected, a prediction goes to the active API entry
--- (Cerebras, …) instead of Ollama; with no entry it is not sent anywhere and
--- the reason is logged. Sequential variants are paced by the shared minimum
--- interval and each is a little warmer than the last.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

--- Runs predictions against scripted backends.
--- @param backend string "api" or "ollama"
--- @param entry table|nil The active API entry.
--- @return table engine, table calls, table scheduler, function restore
local function load(backend, entry)
	local names = {
		"adapters.secure_field_detector", "modules.llm.api_ollama", "modules.llm.api_remote",
		"modules.llm.api_entries", "modules.llm.profiles", "modules.llm.profile_settings", "adapters.storage",
	}
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local calls = { ollama = {}, remote = {} }
	package.loaded["adapters.secure_field_detector"] = {
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
		isUrlBar = function() return false end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		chat = function(target, model) calls.ollama[#calls.ollama + 1] = { target = target, model = model } end,
		cancel = function() end,
	}
	package.loaded["modules.llm.api_remote"] = {
		provider = function() return { default_model = "qwen-default" } end,
		chat = function(target, model, _, opts, _, on_done)
			calls.remote[#calls.remote + 1] = { target = target, model = model, opts = opts }
			on_done(" que tout le monde aille bien " .. #calls.remote, nil)
		end,
		cancel = function() end,
	}
	package.loaded["modules.llm.api_entries"] = { active = function() return entry end }
	package.loaded["modules.llm.profiles"] = {
		init = function() end,
		is_enabled = function() return true end,
		get_current_model = function() return "ollama-model" end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
	}
	package.loaded["modules.llm.profile_settings"] = {
		get = function(key) if key == "num_predictions" then return 3 end end,
		resolve = function() return { id = "raw", system_single = "{context}" } end,
	}
	local stored = { ["llm.models.selected"] = backend }
	package.loaded["adapters.storage"] = {
		get = function(key, default) if stored[key] ~= nil then return stored[key] end return default end,
		set = function(key, value) stored[key] = value; return true end,
	}
	local scheduler = Fakes.timer_scheduler()
	-- One pass per call, as the real loop does: step through several.
	function scheduler.settle()
		for _ = 1, 10 do scheduler.test.advance(0.6) end
	end
	local engine = helpers.load_module("modules.llm.prediction_engine")
	engine.init({ scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end })
	return engine, calls, scheduler, function()
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		package.loaded["modules.llm.prediction_engine"] = nil
	end
end

helpers.describe("prediction backend: the selected backend answers", function()

	helpers.it("sends to the active API entry, with the provider's default model", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.ollama, 0, "Ollama is not asked")
		helpers.assert_eq(#calls.remote, 3, "one request per requested prediction")
		helpers.assert_eq(calls.remote[1].target, ENTRY)
		helpers.assert_eq(calls.remote[1].model, "qwen-default")
	end)

	helpers.it("sends nothing when the API is selected but no entry is", function()
		local engine, calls, scheduler, restore = load("api", nil)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.remote + #calls.ollama, 0)
	end)

	helpers.it("keeps Ollama as the default", function()
		local engine, calls, scheduler, restore = load(nil, ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_eq(#calls.remote, 0)
		helpers.assert_true(#calls.ollama >= 1)
	end)

end)

helpers.describe("prediction backend: variants are paced and diverse", function()

	helpers.it("waits the shared API interval between two requests", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		local first = #calls.remote
		scheduler.test.advance(0.49)
		local before_interval = #calls.remote
		scheduler.test.advance(0.02)
		local after_interval = #calls.remote
		restore()
		helpers.assert_eq(first, 1, "the first request leaves at once")
		helpers.assert_eq(before_interval, 1, "the second waits for the interval")
		helpers.assert_eq(after_interval, 2)
	end)

	helpers.it("warms each next variant", function()
		local engine, calls, scheduler, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		scheduler.settle()
		restore()
		helpers.assert_true(calls.remote[2].opts.temperature > calls.remote[1].opts.temperature)
		helpers.assert_true(calls.remote[3].opts.temperature > calls.remote[2].opts.temperature)
	end)

	helpers.it("offers the first variant before the next one arrives", function()
		local engine, _, _, restore = load("api", ENTRY)
		engine.predict("Bonjour à tous")
		local offered = #engine.get_suggestions()
		restore()
		helpers.assert_eq(offered, 1)
	end)

end)

helpers.describe("prediction backend: the model the menu shows profiles for", function()

	helpers.it("is the API entry's model when the API answers", function()
		local engine, _, _, restore = load("api", ENTRY)
		local model = engine.get_prediction_model()
		restore()
		helpers.assert_eq(model, "qwen-default")
	end)

	helpers.it("is Ollama's model otherwise", function()
		local engine, _, _, restore = load("ollama", ENTRY)
		local model = engine.get_prediction_model()
		restore()
		helpers.assert_eq(model, "ollama-model")
	end)

	helpers.it("is what the AI menu resolves the automatic profile against", function()
		local fh = assert(io.open("ui/menu/menu_builder.lua", "r"))
		local source = fh:read("*a")
		fh:close()
		local handler = source:match('dynamic_handlers%["llm_profile"%] = function%(target%)(.-)local function refresh')
		helpers.assert_true(handler ~= nil and handler:find("get_prediction_model", 1, true) ~= nil,
			"the profile rows must follow the model predictions use")
	end)

end)

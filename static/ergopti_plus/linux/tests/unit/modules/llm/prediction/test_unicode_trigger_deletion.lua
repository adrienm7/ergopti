--- tests/unit/modules/llm/prediction/test_unicode_trigger_deletion.lua

--- ==============================================================================
--- MODULE: Prediction Trigger Character Deletions
--- DESCRIPTION:
--- Exercises the actual engine and parser from trigger scheduling through accepted
--- output. Prompt slicing uses UTF-8 bytes, whereas physical Backspaces and input
--- character accounting must count the trigger's code points.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local ProfilesFixture = require("tests.support.llm_profiles_fixture")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

--- Runs one trigger against the real prediction parser and an observable text sink.
--- @param trigger string Trigger accepted by the public configuration API.
--- @param characters integer Independently specified physical character count.
--- @param raw_bytes boolean|nil Retains the legacy malformed-byte API accounting.
local function exercise(trigger, characters, raw_bytes)
	local names = {
		"modules.llm.prediction_engine", "modules.llm.api_ollama", "modules.llm.profiles",
		"modules.llm.settings", "modules.llm.trigger_settings", "modules.llm.display_settings",
		"modules.llm.profile_settings", "infra.llm_preferences",
	}
	local previous = {}
	for name, module in pairs(package.loaded) do previous[name] = module end
	for name in pairs(package.loaded) do
		if name:match("^modules%.llm%.") then package.loaded[name] = nil end
	end
	for _, name in ipairs(names) do package.loaded[name] = nil end
	local profiles = ProfilesFixture.without_inventory({
		init = function() return true end,
		is_enabled = function() return true end,
		get_current_model = function() return "fixture-model" end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
	})
	local sent, applied, observed
	package.loaded["infra.llm_preferences"] = PreferencesFixture.new()
	package.loaded["modules.llm.profiles"] = profiles
	package.loaded["modules.llm.settings"] = {
		get = function(key)
			return ({ context_length = 2000, min_words = 1, max_words = 10, temperature = 0.7,
				auto_raise_temp = false })[key]
		end,
	}
	package.loaded["modules.llm.trigger_settings"] = {
		get = function(key) if key == "debounce_ms" then return 0 end; return false end,
	}
	package.loaded["modules.llm.display_settings"] = { get = function() return false end }
	package.loaded["modules.llm.profile_settings"] = {
		get = function(key) if key == "num_predictions" then return 1 end end,
		resolve_for_app = function() return nil end,
		resolve = function() return { id = "basic", system_single = "Continue the typed text." } end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		chat = function(_, _, messages, _, _, done)
			sent = messages[#messages].content
			done(" va très bien", nil)
			return true
		end,
		cancel = function() return true end,
	}
	local scheduler = Fakes.timer_scheduler()
	local document = "Bonjour" .. trigger
	local engine
	local ok, err = pcall(function()
		engine = require("modules.llm.prediction_engine")
		engine.init({
			focus_id = function() return "owned-prediction-window" end,
			scheduler = scheduler,
			engine = { reset = function() end },
			apply_prediction = function(candidate)
				applied = candidate
				local text = {}
				local pattern = raw_bytes and "." or "[%z\1-\127\194-\244][\128-\191]*"
				for character in document:gmatch(pattern) do text[#text + 1] = character end
				for _ = 1, candidate.deletes do table.remove(text) end
				document = table.concat(text) .. candidate.to_type
				return true
			end,
			on_output = function(_, context) observed = context.input_chars end,
		})
		helpers.assert_true(engine.set_triggers({ trigger }))
		engine.on_char(trigger, document, { app_id = "editor" })
		helpers.assert_eq(scheduler.test.advance(0), 1, "the explicit trigger schedules its request")
		helpers.assert_eq(sent, "Bonjour", "remove the complete byte suffix, leaving the prompt intact")
		helpers.assert_true(engine.has_suggestions(), "the real parser publishes an accept-ready prediction")
		helpers.assert_true(engine.accept(1), "the prediction reaches the output sink")
		helpers.assert_eq(applied.deletes, characters, "one Backspace per trigger character, never per byte")
		helpers.assert_eq(document, "Bonjour" .. applied.to_type, "the characters before the trigger survive")
		helpers.assert_eq(observed, characters, "metrics receive the same physical trigger character count")
	end)
	local cleaned, cleanup_error = pcall(function()
		if engine then engine.dismiss() end
		profiles.assert_no_inventory()
	end)
	-- Native ffi/luv libraries are process-wide; unloading a newly imported C
	-- module can initialize it twice when the next scenario needs it. Restore
	-- only this fixture's domain modules and explicitly replaced boundaries.
	for name in pairs(package.loaded) do
		if name:match("^modules%.llm%.") then package.loaded[name] = nil end
	end
	for name, module in pairs(previous) do
		if name:match("^modules%.llm%.") then package.loaded[name] = module end
	end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
	if not cleaned then error(cleanup_error, 0) end
end

helpers.describe("prediction trigger deletion counts UTF-8 characters", function()
	for _, vector in ipairs({
		{ label = "ASCII", trigger = "//", characters = 2 },
		{ label = "two-byte", trigger = "é", characters = 1 },
		{ label = "three-byte", trigger = "漢", characters = 1 },
		{ label = "four-byte", trigger = "🙂", characters = 1 },
		{ label = "mixed Unicode", trigger = "é🙂", characters = 2 },
		{ label = "mixed ASCII", trigger = "é//", characters = 3 },
		{ label = "malformed byte", trigger = string.char(255), characters = 1, raw_bytes = true },
		{ label = "truncated UTF-8", trigger = string.char(226, 130), characters = 2, raw_bytes = true },
	}) do
		helpers.it("unicode-trigger-deletion: preserves the prefix for " .. vector.label, function()
			exercise(vector.trigger, vector.characters, vector.raw_bytes)
		end)
	end
end)

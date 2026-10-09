--- tests/unit/modules/llm/test_prompt_prediction_request.lua

--- ==============================================================================
--- MODULE: Prompt Prediction Request (llm-prompt-prediction)
--- DESCRIPTION:
--- request_prompt_prediction is what the llm_prompt_prediction action and its
--- llm_predict_<profile> presets run through the keymap bridge. It drives the
--- real engine and streaming handler through the shared prediction pipeline
--- fixture, whose backend dispatch and tooltip are observable.
---
--- ROOT CAUSE ENCODED:
--- A prediction always ran the AI menu's global profile with the menu's count.
--- Asking for another prompt meant switching the global profile; a rewrite
--- profile additionally needs the current sentence as its tail and a budget
--- that fits a rewritten sentence, and its answer (a capitalized sentence) was
--- dropped by the continuation noise gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")
local Selector = require("llm.profile_selector")
local Rewrite = require("llm.rewrite")

--- Returns the shipped built-in profile with an id, labelled for the info bar.
--- @param id string
--- @return table profile
local function builtin(id)
	for _, profile in ipairs(Selector.load_built_in_profiles()) do
		if profile.id == id then
			profile.label = "Label " .. id .. " — details"
			return profile
		end
	end
	error("no built-in profile " .. id)
end

--- Loads the real engine with the shipped profiles and records every notice.
--- @param options table|nil Pipeline options (buffer, active_profile, ...).
--- @return table fixture
local function load_fixture(options)
	options = options or {}
	options.capture_info = true
	options.render_success = true
	options.profiles = options.profiles or {
		basic = builtin("basic"), advanced = builtin("advanced"), rewrite = builtin("rewrite"),
	}
	if options.active_profile == nil then options.active_profile = options.profiles.basic end
	local fixture = Pipeline.load(options)
	fixture.notices = {}
	fixture.info_bars = {}
	local tooltip = package.loaded["ui.tooltip"]
	tooltip.show = function(content)
		fixture.notices[#fixture.notices + 1] = content
		return true
	end
	local show_predictions = tooltip.show_predictions
	tooltip.show_predictions = function(predictions, _index, _preview, info_bar, ...)
		fixture.shown = predictions
		fixture.info_bars[#fixture.info_bars + 1] = info_bar
		return show_predictions(predictions, _index, _preview, info_bar, ...)
	end
	-- A prompt action must never touch the global profile
	package.loaded["modules.llm"].set_active_profile = function()
		error("a prompt action changed the global active profile")
	end
	return fixture
end

--- Counts log records of one level holding a text.
--- @param fixture table
--- @param level string
--- @param text string
--- @return number
local function logged(fixture, level, text)
	local count = 0
	for _, record in ipairs(fixture.logs) do
		if record.level == level and record.message:find(text, 1, true) then count = count + 1 end
	end
	return count
end

helpers.describe("prompt prediction request (llm-prompt-prediction)", function()
	helpers.it("runs the chosen profile with the binding's count, leaving the global profile alone", function()
		local fixture = load_fixture()
		fixture.engine.set_llm_num_predictions(1)
		local requested = fixture.engine.request_prompt_prediction("advanced|3")
		helpers.assert_eq(requested, true)
		helpers.assert_eq(fixture.fetches, 1, "the request must reach the backend once")
		helpers.assert_true(rawequal(fixture.last_fetch.profile_override,
			package.loaded["modules.llm"].find_profile("advanced")),
			"the backend must run the chosen profile, not the active one")
		helpers.assert_eq(fixture.last_fetch.num_predictions, 3, "the binding's own count")
		helpers.assert_eq(fixture.last_fetch.force, true, "an explicit request bypasses the freshness guard")
		local found, count = fixture.engine.get_llm_runtime_setting("llm_num_predictions")
		helpers.assert_true(found)
		helpers.assert_eq(count, 1, "the AI menu's count is unchanged")
		helpers.assert_eq(package.loaded["modules.llm"].get_active_profile().id, "basic",
			"the global active profile is unchanged")
		helpers.assert_eq(#fixture.notices, 0)
	end)

	helpers.it("uses the AI menu's count when the binding names none", function()
		local fixture = load_fixture()
		fixture.engine.set_llm_num_predictions(4)
		helpers.assert_eq(fixture.engine.request_prompt_prediction("advanced"), true)
		helpers.assert_eq(fixture.last_fetch.num_predictions, 4)
	end)

	helpers.it("shows the override's label in the info bar", function()
		local fixture = load_fixture()
		fixture.engine.set_llm_show_info_bar(true)
		helpers.assert_eq(fixture.engine.request_prompt_prediction("advanced"), true)
		fixture.on_success({ { to_type = " next words", deletes = 0, chunks = {}, nw = " next words" } }, 5, true)
		local bar = fixture.info_bars[#fixture.info_bars]
		helpers.assert_true(type(bar) == "string" and bar:find("Label advanced", 1, true) ~= nil,
			"the info bar must name the profile that ran, got " .. tostring(bar))
		helpers.assert_true(bar:find("Label basic", 1, true) == nil, "not the global one")
	end)

	helpers.it("refuses a prompt that no longer exists, logs it and says so", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.engine.request_prompt_prediction("custom_deleted|2"), false)
		helpers.assert_eq(fixture.fetches, 0, "no other profile may run in its place")
		helpers.assert_eq(logged(fixture, "warn", "custom_deleted"), 1, "the refusal is logged")
		helpers.assert_eq(#fixture.notices, 1)
		helpers.assert_eq(fixture.notices[1],
			package.loaded["infra.i18n"].get("llm.prompt_prediction.unknown_prompt"))
	end)

	helpers.it("refuses an invalid stored value with the same notice", function()
		local fixture = load_fixture()
		helpers.assert_eq(fixture.engine.request_prompt_prediction("rewrite|0"), false)
		helpers.assert_eq(fixture.fetches, 0)
		helpers.assert_eq(fixture.notices[1],
			package.loaded["infra.i18n"].get("llm.prompt_prediction.unknown_prompt"))
	end)

	helpers.it("keeps the manual refusals: nothing typed", function()
		local fixture = load_fixture({ buffer = "" })
		helpers.assert_eq(fixture.engine.request_prompt_prediction("advanced"), false)
		helpers.assert_eq(fixture.fetches, 0)
		helpers.assert_eq(fixture.notices[1],
			package.loaded["infra.i18n"].get("llm.manual_prediction.empty_context"))
	end)

	helpers.it("keeps the manual refusals: paused outranks an unknown prompt", function()
		local fixture = load_fixture()
		package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end }
		local ok, err = pcall(function()
			helpers.assert_eq(fixture.engine.request_prompt_prediction("custom_deleted"), false)
			helpers.assert_eq(fixture.notices[1],
				package.loaded["infra.i18n"].get("llm.manual_prediction.paused"))
		end)
		package.loaded["modules.shortcuts.script_control"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps the manual refusals: AI off", function()
		local fixture = load_fixture({ llm_enabled = false })
		helpers.assert_eq(fixture.engine.request_prompt_prediction("advanced"), false)
		helpers.assert_eq(fixture.notices[1],
			package.loaded["infra.i18n"].get("llm.manual_prediction.disabled"))
	end)
end)

helpers.describe("rewrite requests (llm-prompt-prediction)", function()
	helpers.it("sends the current sentence as the tail, with the rewrite budget", function()
		local fixture = load_fixture({ buffer = "Bonjour Marc. ok pr jd 14h" })
		helpers.assert_eq(fixture.engine.request_prompt_prediction("rewrite|2"), true)
		helpers.assert_eq(fixture.last_fetch.tail, "ok pr jd 14h", "the tail is the current sentence")
		helpers.assert_eq(fixture.last_fetch.context, "Bonjour Marc. ok pr jd 14h",
			"the context still holds what precedes it")
		helpers.assert_eq(fixture.last_fetch.max_tokens, Rewrite.max_tokens("ok pr jd 14h"),
			"a rewritten sentence needs the rewrite budget, not the continuation one")
		helpers.assert_eq(fixture.last_fetch.num_predictions, 2)
	end)

	helpers.it("extends a capped context so it holds the whole sentence", function()
		local sentence = "voici une phrase bien plus longue que le contexte envoye au modele"
		local fixture = load_fixture({ buffer = "Avant. " .. sentence })
		fixture.engine.set_llm_context_length(20)
		helpers.assert_eq(fixture.engine.request_prompt_prediction("rewrite"), true)
		helpers.assert_eq(fixture.last_fetch.tail, sentence)
		helpers.assert_eq(fixture.last_fetch.context, sentence,
			"the span must stay an exact suffix of the context sent")
	end)

	helpers.it("refuses like 'nothing typed' when no sentence is left", function()
		local fixture = load_fixture({ buffer = "   " })
		helpers.assert_eq(fixture.engine.request_prompt_prediction("rewrite"), false)
		helpers.assert_eq(fixture.fetches, 0)
		helpers.assert_eq(fixture.notices[1],
			package.loaded["infra.i18n"].get("llm.manual_prediction.empty_context"))
	end)

	helpers.it("applies to the global rewrite profile on the automatic path too", function()
		local fixture
		fixture = load_fixture({ buffer = "Salut. c tjs ok pr dm1" })
		package.loaded["modules.llm"].get_active_profile = function() return builtin("rewrite") end
		fixture.engine.perform_check(false)
		helpers.assert_eq(fixture.fetches, 1)
		helpers.assert_eq(fixture.last_fetch.tail, "c tjs ok pr dm1")
		helpers.assert_eq(fixture.last_fetch.max_tokens, Rewrite.max_tokens("c tjs ok pr dm1"))
		helpers.assert_nil(fixture.last_fetch.profile_override,
			"the automatic path runs the active profile itself")
	end)

	helpers.it("lets a rewrite through the continuation noise gate", function()
		local fixture = load_fixture({ buffer = "Bonjour Marc. ok pr jd 14h" })
		helpers.assert_eq(fixture.engine.request_prompt_prediction("rewrite"), true)
		fixture.on_success({
			{ to_type = "Ok pour jeudi : 14 h.", deletes = 12, chunks = {}, nw = "", rewrite = true },
			{ to_type = "Continuation: nope", deletes = 0, chunks = {}, nw = "Continuation: nope" },
		}, 5, true)
		helpers.assert_eq(#fixture.engine.get_predictions(), 1,
			"the capitalized rewrite with a colon is kept, the noisy continuation dropped")
		helpers.assert_eq(fixture.engine.get_predictions()[1].rewrite, true)
		helpers.assert_eq(fixture.engine.get_predictions()[1].deletes, 12)
	end)
end)

helpers.it("runs a per-binding free language through the current sentence pipeline", function()
	local fixture = load_fixture({ buffer = "Bonjour Marc. On se voit demain ?" })
	local Json = require("json")
	local config_file = assert(io.open(helpers.shared("modules/llm/translate.json"), "r"))
	local names_file = assert(io.open(helpers.shared("data/locale_names.json"), "r"))
	local config = assert(Json.decode(config_file:read("*a"))); config_file:close()
	local names = assert(Json.decode(names_file:read("*a"))); names_file:close()
	local previous = package.loaded["modules.llm.selection_translation"]
	package.loaded["modules.llm.selection_translation"] = {
		config = function() return config end, locale_names = function() return names end,
	}
	local ok, detail = pcall(function()
		helpers.assert_eq(fixture.engine.request_prompt_prediction("translate|1|Esperanto"), true)
		helpers.assert_eq(fixture.fetches, 1)
		helpers.assert_eq(fixture.last_fetch.tail, "On se voit demain ?")
		helpers.assert_true(fixture.last_fetch.profile_override.system_single:find("Translate TAIL into Esperanto", 1, true) ~= nil)
		helpers.assert_eq(package.loaded["modules.llm"].get_active_profile().id, "basic")
		helpers.assert_eq(fixture.engine.start_live_prompt("translate|2|ქართული"), true)
		helpers.assert_eq(fixture.engine.get_live_prompt().translation_target, "ქართული")
		helpers.assert_eq(fixture.engine.get_live_prompt().num_predictions, 2)
		helpers.assert_eq(fixture.engine.toggle_live_prompt("invalid|0"), true, "turning off never needs a valid receipt")
	end)
	package.loaded["modules.llm.selection_translation"] = previous
	if not ok then error(detail, 0) end
end)

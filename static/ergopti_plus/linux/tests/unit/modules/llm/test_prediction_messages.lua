--- tests/unit/modules/llm/test_prediction_messages.lua

--- ==============================================================================
--- MODULE: What The Model Is Sent
--- DESCRIPTION:
--- The Linux engine substituted the typed text into the system prompt AND sent
--- it again as the user turn, so the "raw" profile asked the model to continue
--- a conversation made of the same text twice. The "advanced" profiles describe
--- a PREFIX/TAIL user turn, which macOS builds and Linux never did: the model
--- received bare text and the parser waited for TAIL_CORRECTED/NEXT_WORDS
--- lines. Typed text holding "%" was also mangled by the substitution.
--- The messages are now composed once, by the shared prompt builder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local ProfileSelector = require("llm.profile_selector")

--- The built-in profiles, by id, from the shared catalogue.
local function builtin(id)
	local fh = assert(io.open("../_shared/modules/llm/profiles.json", "r"))
	local profiles = Json.decode(fh:read("*a"))
	fh:close()
	for _, profile in ipairs(profiles) do
		if profile.id == id then return profile end
	end
	error("no built-in profile " .. id)
end

--- Runs one prediction with the given profile and returns the messages sent.
--- @param profile table
--- @param context string
--- @return table messages
local function messages_for(profile, context)
	local names = {
		"adapters.secure_field_detector", "modules.llm.api_ollama",
		"modules.llm.profiles", "modules.llm.profile_settings",
	}
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local sent
	package.loaded["adapters.secure_field_detector"] = {
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
		isUrlBar = function() return false end,
	}
	package.loaded["modules.llm.api_ollama"] = {
		chat = function(_, _, messages) sent = messages end,
		cancel = function() end,
	}
	package.loaded["modules.llm.profiles"] = {
		get_current_model = function() return "test-model" end,
		get_base_url = function() return "http://127.0.0.1:11434" end,
		init = function() end,
		is_enabled = function() return true end,
	}
	package.loaded["modules.llm.profile_settings"] = {
		get = function(key) if key == "num_predictions" then return 1 end end,
		resolve = function() return profile end,
	}
	local engine = helpers.load_module("modules.llm.prediction_engine")
	-- Initialised as the daemon does, which once passed a context length that
	-- shadowed the menu's setting.
	engine.init({ max_context = 500, triggers = { "//" } })
	local ok, err = pcall(engine.predict, context)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	package.loaded["modules.llm.prediction_engine"] = nil
	assert(ok, tostring(err))
	return sent
end

--- Every message content joined, to count occurrences of the context.
local function occurrences(messages, needle)
	local count = 0
	for _, message in ipairs(messages) do
		local from = 1
		while true do
			local at = message.content:find(needle, from, true)
			if not at then break end
			count = count + 1
			from = at + #needle
		end
	end
	return count
end

helpers.describe("prediction messages: the typed text is sent once, in the shape the profile expects", function()

	helpers.it("raw: the context alone, once", function()
		local sent = messages_for(builtin("raw"), "Bonjour à tous, je voulais")
		helpers.assert_eq(occurrences(sent, "Bonjour à tous, je voulais"), 1)
		helpers.assert_eq(sent[#sent].role, "user")
	end)

	helpers.it("basic: instructions as the system turn, the context once as the user turn", function()
		local sent = messages_for(builtin("basic"), "Bonjour à tous, je voulais")
		helpers.assert_eq(sent[1].role, "system")
		helpers.assert_eq(occurrences(sent, "Bonjour à tous, je voulais"), 1)
		helpers.assert_eq(sent[#sent].content, "Bonjour à tous, je voulais")
	end)

	helpers.it("advanced: a PREFIX/TAIL user turn", function()
		local sent = messages_for(builtin("advanced"), "Je vous envoie ce mail pour")
		local user = sent[#sent].content
		helpers.assert_true(user:find('^PREFIX: "Je vous envoie ce mail pour"\nTAIL: "') ~= nil,
			"the advanced profile describes PREFIX and TAIL; got " .. user)
	end)

	helpers.it("keeps a percent sign typed by the user", function()
		local sent = messages_for(builtin("raw"), "une remise de 50% sur")
		helpers.assert_eq(occurrences(sent, "une remise de 50% sur"), 1)
	end)

end)

helpers.describe("prediction messages: the context length chosen in the menu applies", function()

	helpers.it("caps the context at the stored setting", function()
		local Settings = require("modules.llm.settings")
		local previous = Settings.get("context_length")
		helpers.assert_true(Settings.set("context_length", 100))
		local long = string.rep("mot ", 150)
		local sent = messages_for(builtin("raw"), long)
		Settings.set("context_length", previous)
		helpers.assert_true(#sent[#sent].content <= 100,
			"the menu's 100 characters must bound the request; sent " .. #sent[#sent].content)
	end)

end)

helpers.describe("prediction messages: the word limits and language the prompt states", function()

	helpers.it("says unlimited when the user chose no maximum", function()
		local Settings = require("modules.llm.settings")
		local previous = Settings.get("max_words")
		helpers.assert_true(Settings.set("max_words", 0))
		local sent = messages_for(builtin("basic"), "Bonjour à tous")
		Settings.set("max_words", previous)
		local system = sent[1].content
		helpers.assert_true(system:find("AT MOST unlimited words", 1, true) ~= nil, system)
		helpers.assert_eq(system:find("AT MOST 0 words", 1, true), nil)
	end)

	helpers.it("falls back to the interface language, not always French", function()
		local I18n = require("infra.i18n")
		local previous = I18n.get_locale
		I18n.get_locale = function() return "de" end
		local sent = messages_for(builtin("basic"), "Hallo zusammen")
		I18n.get_locale = previous
		helpers.assert_true(sent[1].content:find("default to de", 1, true) ~= nil, sent[1].content)
	end)

end)

helpers.describe("profile selector: placeholders are replaced in one pass", function()

	helpers.it("does not expand a placeholder the user typed", function()
		local resolved = ProfileSelector.resolve_system_prompt(
			{ system_single = "ctx={context} n={n}" }, { context = "{n} 100%", n = 3 })
		helpers.assert_eq(resolved.system, "ctx={n} 100% n=3")
	end)

end)

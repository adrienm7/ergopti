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
	}
	package.loaded["modules.llm.profile_settings"] = {
		get = function(key) if key == "num_predictions" then return 1 end end,
		resolve = function() return profile end,
	}
	local engine = helpers.load_module("modules.llm.prediction_engine")
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

helpers.describe("profile selector: placeholders are replaced in one pass", function()

	helpers.it("does not expand a placeholder the user typed", function()
		local resolved = ProfileSelector.resolve_system_prompt(
			{ system_single = "ctx={context} n={n}" }, { context = "{n} 100%", n = 3 })
		helpers.assert_eq(resolved.system, "ctx={n} 100% n=3")
	end)

end)

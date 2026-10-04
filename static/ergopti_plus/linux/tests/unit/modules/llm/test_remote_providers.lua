--- tests/unit/modules/llm/test_remote_providers.lua

--- ==============================================================================
--- MODULE: The Providers Beyond Chat Completions (Linux)
--- DESCRIPTION:
--- The shared catalogue gained OpenRouter, Groq, Together AI and Fireworks AI
--- (OpenAI format), Backboard (an assistant per key, then one message per
--- request, key in X-API-Key) and two Jev providers (TypeSafe's decisions
--- protocol, full endpoint, Bearer key, no chat model). These tests run the
--- real api_remote and vision_request over a scripted HTTP client and pin what
--- each provider is sent, what each list offers, and what the logs say.
---
--- ROOT CAUSE ENCODED:
--- api_remote accepted only the openai, anthropic and gemini formats: the new
--- formats were dropped from every list, and nothing kept a decisions provider
--- (which cannot chat) away from the predictions, or Backboard away from images.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Formats = require("llm.remote_formats")

local MESSAGES = {
	{ role = "system", content = "Continue the text." },
	{ role = "user", content = "Bonjour, je voulais" },
}
local BACKBOARD = { provider = "backboard", token = "bb-key", model = "" }
local TYPESAFE = { provider = "typesafe", token = "ts-key", model = "" }
local QUESTIONS = { intent = { type = "choice", instructions = "Which?", criteria = { none = "Nothing" } } }

--- Reads a shared JSON file.
--- @param relative string Path under _shared/.
--- @return table
local function read_shared(relative)
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/" .. relative, "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw))
end

--- Runs body against the real api_remote over a scripted HTTP client and a
--- logger that keeps every line with its level.
--- @param body function body(remote, calls, logs)
local function with_remote(body)
	local names = { "adapters.http_client", "logger.shim", "modules.llm.api_remote" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local calls, logs = {}, {}
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, request_body, callback, options)
			calls[#calls + 1] = { url = url, headers = headers, body = Json.decode(request_body), callback = callback,
				options = options }
			return true
		end,
		cancel = function() return true end,
	}
	local function recorder(level)
		return function(_, fmt, ...)
			local ok, text = pcall(string.format, fmt, ...)
			logs[#logs + 1] = { level = level, text = ok and text or tostring(fmt) }
		end
	end
	local logger = { set_level = function() end, set_sink = function() end }
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
		logger[level] = recorder(level)
	end
	package.loaded["logger.shim"] = logger
	package.loaded["modules.llm.api_remote"] = nil
	local remote = require("modules.llm.api_remote")
	remote._reset_for_test()
	local ok, err = pcall(body, remote, calls, logs)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Answers call `index` with a JSON body.
local function answer(calls, index, root)
	calls[index].callback({ ok = true, status = 200, body = Json.encode(root) })
end

--- The log lines of a level containing a fragment.
local function logged(logs, level, fragment)
	local found = {}
	for _, line in ipairs(logs) do
		if line.level == level and line.text:find(fragment, 1, true) then found[#found + 1] = line.text end
	end
	return found
end

--- The ids of a descriptor list.
local function ids(list)
	local out = {}
	for index, provider in ipairs(list) do out[index] = provider.id end
	return table.concat(out, ",")
end




-- =========================================
-- =========================================
-- ======= 1/ The lists ====================
-- =========================================
-- =========================================

helpers.describe("New providers: listed in catalogue order, each where it can serve", function()
	local catalogue = read_shared("modules/llm/api_providers.json")
	local local_ids = { "omlx", "lmstudio", "llamacpp", "jan" }
	local expected_order = {}
	for _, id in ipairs(catalogue.provider_order) do expected_order[#expected_order + 1] = id end
	for _, id in ipairs(local_ids) do expected_order[#expected_order + 1] = id end

	helpers.it("every provider of the shared order is loaded, in that order", function()
		with_remote(function(remote)
			helpers.assert_eq(ids(remote.providers()), table.concat(expected_order, ","))
		end)
	end)

	helpers.it("chat lists leave out Jev, image lists leave out Jev and Backboard, System 1 takes all", function()
		with_remote(function(remote)
			local chat, vision = {}, {}
			for _, id in ipairs(catalogue.provider_order) do
				local format = catalogue.providers[id].format
				if format ~= "decisions" then chat[#chat + 1] = id end
				if format ~= "decisions" and format ~= "backboard" then vision[#vision + 1] = id end
			end
			for _, id in ipairs(local_ids) do
				chat[#chat + 1] = id
				vision[#vision + 1] = id
				helpers.assert_true(remote.serves(id, "chat") and remote.serves(id, "vision") and remote.serves(id, "system1"))
			end
			helpers.assert_eq(ids(remote.providers_for("chat")), table.concat(chat, ","))
			helpers.assert_eq(ids(remote.providers_for("vision")), table.concat(vision, ","))
			helpers.assert_eq(ids(remote.providers_for("system1")), table.concat(expected_order, ","))
			helpers.assert_true(not remote.serves("typesafe", "chat") and not remote.serves("openrouter_jev", "chat"))
			helpers.assert_true(remote.serves("backboard", "chat") and not remote.serves("backboard", "vision"))
		end)
	end)

	helpers.it("the screen actions' and the agent's editors follow the same rule", function()
		with_remote(function()
			package.loaded["modules.llm.vision_request"] = nil
			local VisionRequest = require("modules.llm.vision_request")
			local values = {}
			for _, choice in ipairs(VisionRequest.backend_choices()) do values[choice.value] = true end
			helpers.assert_true(values["local"] and values.openrouter and values.fireworks, "the image readers")
			helpers.assert_true(not values.backboard and not values.typesafe and not values.openrouter_jev,
				"never Backboard nor Jev")
			local target, reason = VisionRequest.resolve_target("backboard", "openai/gpt-4o")
			helpers.assert_nil(target, "a binding naming Backboard is refused before any capture")
			helpers.assert_true(reason:find("reads no image", 1, true) ~= nil, reason)
			package.loaded["modules.llm.vision_request"] = nil
		end)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ The OpenAI format ============
-- =========================================
-- =========================================

helpers.describe("New providers: the OpenAI-format ones send to their own base_url", function()
	local catalogue = read_shared("modules/llm/api_providers.json")

	for _, id in ipairs({ "openrouter", "groq", "together", "fireworks" }) do
		helpers.it(id .. ": chat completions under its base_url, with a Bearer key", function()
			with_remote(function(remote, calls)
				local got
				remote.chat({ provider = id, token = "k-" .. id }, nil, MESSAGES, {}, nil, function(text) got = text end)
				helpers.assert_eq(#calls, 1)
				helpers.assert_eq(calls[1].url, catalogue.providers[id].base_url .. "/chat/completions")
				helpers.assert_eq(calls[1].headers.Authorization, "Bearer k-" .. id)
				helpers.assert_eq(calls[1].body.model, catalogue.providers[id].default_model)
				answer(calls, 1, { choices = { { message = { content = " bien" } } } })
				helpers.assert_eq(got, " bien")
			end)
		end)
	end
end)




-- =========================================
-- =========================================
-- ======= 3/ Backboard ====================
-- =========================================
-- =========================================

helpers.describe("Backboard: an assistant per key, then one message per request", function()
	local base = read_shared("modules/llm/api_providers.json").providers.backboard.base_url

	helpers.it("the first request creates the assistant, then sends the message; the next reuses it", function()
		with_remote(function(remote, calls)
			local texts = {}
			remote.chat(BACKBOARD, nil, MESSAGES, { temperature = 0.3, max_tokens = 40 }, nil,
				function(text, err) texts[#texts + 1] = text or err end)
			helpers.assert_eq(#calls, 1, "the assistant first")
			local creation = Formats.backboard_assistant_request(base)
			helpers.assert_eq(calls[1].url, creation.url)
			helpers.assert_eq(calls[1].body, creation.body)
			helpers.assert_eq(calls[1].headers["X-API-Key"], "bb-key")
			helpers.assert_nil(calls[1].headers.Authorization, "no Bearer")
			answer(calls, 1, { assistant_id = "asst-1" })

			helpers.assert_eq(#calls, 2, "then the message")
			local message = Formats.backboard_message_request(base, { assistant_id = "asst-1",
				model = "openai/gpt-4o-mini", system = "Continue the text.", text = "Bonjour, je voulais" })
			helpers.assert_eq(calls[2].url, message.url)
			helpers.assert_eq(calls[2].body, message.body, "the shared shape, no temperature nor max tokens")
			helpers.assert_eq(calls[2].headers["X-API-Key"], "bb-key")
			answer(calls, 2, { content = " vous écrire" })
			helpers.assert_eq(texts[1], " vous écrire")

			remote.chat(BACKBOARD, nil, MESSAGES, {}, nil, function(text) texts[#texts + 1] = text end)
			helpers.assert_eq(#calls, 3, "no second assistant")
			helpers.assert_eq(calls[3].url, message.url)
			helpers.assert_eq(calls[3].body.assistant_id, "asst-1")
		end)
	end)

	helpers.it("a failed creation fails the request with its reason, and the next one retries", function()
		with_remote(function(remote, calls, logs)
			local err1, err2
			remote.chat(BACKBOARD, nil, MESSAGES, {}, nil, function(_, err) err1 = err end)
			calls[1].callback({ ok = false, status = 401, body = "", error_body = '{"message":"Invalid API key"}' })
			helpers.assert_eq(#calls, 1, "no message without an assistant")
			helpers.assert_true(err1:find("HTTP 401: Invalid API key", 1, true) ~= nil, err1)
			helpers.assert_eq(#logged(logs, "warn", "Backboard assistant could not be created: HTTP 401"), 1)
			remote.chat(BACKBOARD, nil, MESSAGES, {}, nil, function(_, err) err2 = err end)
			helpers.assert_eq(calls[2].url, Formats.backboard_assistant_request(base).url, "created again")
			answer(calls, 2, { name = "no id" })
			helpers.assert_true(err2:find("no assistant_id", 1, true) ~= nil, err2)
			remote.chat(BACKBOARD, nil, MESSAGES, {}, nil, function() end)
			helpers.assert_eq(calls[3].url, Formats.backboard_assistant_request(base).url, "and again")
		end)
	end)

	helpers.it("a model without its provider is refused before anything is sent", function()
		with_remote(function(remote, calls, logs)
			local got_err
			remote.chat({ provider = "backboard", token = "k", model = "gpt-4o" }, nil, MESSAGES, {}, nil,
				function(_, err) got_err = err end)
			helpers.assert_eq(#calls, 0)
			helpers.assert_true(got_err:find("names no provider", 1, true) ~= nil, got_err)
			helpers.assert_eq(#logged(logs, "error", "refused before dispatch"), 1)
		end)
	end)

	helpers.it("the key test sends one message with the shared probe", function()
		with_remote(function(remote, calls)
			local spec = remote.test_request_spec()
			local verdict
			remote.test(BACKBOARD, function(ok, detail) verdict = { ok = ok, detail = detail } end)
			answer(calls, 1, { assistant_id = "asst-1" })
			helpers.assert_eq(calls[2].body.system_prompt, spec.system_prompt)
			helpers.assert_eq(calls[2].body.content, spec.user_text)
			answer(calls, 2, { content = "OK" })
			helpers.assert_eq(verdict.ok, true)
			helpers.assert_eq(verdict.detail, "OK")
		end)
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ Decisions (Jev) ==============
-- =========================================
-- =========================================

helpers.describe("Decisions: Jev answers typed questions and never chats", function()
	local catalogue = read_shared("modules/llm/api_providers.json")

	helpers.it("decide() posts the shared body to the full endpoint with a Bearer key", function()
		with_remote(function(remote, calls)
			local got
			remote.decide(TYPESAFE, "App: Mail\nText: jeudi 14h", QUESTIONS, function(answers, err)
				got = { answers = answers, err = err }
			end)
			helpers.assert_eq(calls[1].url, catalogue.providers.typesafe.base_url, "the base_url itself")
			helpers.assert_eq(calls[1].headers.Authorization, "Bearer ts-key")
			helpers.assert_eq(calls[1].body, Formats.decisions_body("jev-latest", "App: Mail\nText: jeudi 14h", QUESTIONS))
			answer(calls, 1, { answers = { intent = { choice = "none", probabilities = { none = 1 } } } })
			helpers.assert_eq(got.answers.intent.choice, "none")
			helpers.assert_nil(got.err)
		end)
		with_remote(function(remote, calls)
			remote.decide({ provider = "openrouter_jev", token = "or" }, "s", QUESTIONS, function() end)
			helpers.assert_eq(calls[1].url, catalogue.providers.openrouter_jev.base_url)
			helpers.assert_eq(calls[1].body.model, "typesafe/jev-1.13")
		end)
	end)

	helpers.it("a chat request to a decisions provider is refused", function()
		with_remote(function(remote, calls)
			local got_err
			remote.chat(TYPESAFE, nil, MESSAGES, {}, nil, function(_, err) got_err = err end)
			helpers.assert_eq(#calls, 0)
			helpers.assert_true(got_err ~= nil)
		end)
	end)

	helpers.it("the key test sends decisions_test and passes when answers come back", function()
		with_remote(function(remote, calls)
			local verdicts = {}
			remote.test(TYPESAFE, function(ok, detail) verdicts[#verdicts + 1] = { ok = ok, detail = detail } end)
			helpers.assert_eq(calls[1].body, Formats.decisions_body("jev-latest", catalogue.decisions_test.state,
				catalogue.decisions_test.questions))
			answer(calls, 1, { answers = { ok = { type = "noul", value = true } } })
			helpers.assert_eq(verdicts[1].ok, true)
			remote.test(TYPESAFE, function(ok, detail) verdicts[#verdicts + 1] = { ok = ok, detail = detail } end)
			answer(calls, 2, { error = "nope" })
			helpers.assert_eq(verdicts[2].ok, false, "no answers is a failure")
		end)
	end)
end)




-- ============================================
-- ============================================
-- ======= 5/ Jev through Backboard ===========
-- ============================================
-- ============================================

helpers.describe("Jev through Backboard: the questions in system_one, the answers found and located", function()
	local base = read_shared("modules/llm/api_providers.json").providers.backboard.base_url
	local JEV = { provider = "backboard", token = "bb", model = "typesafe/jev-1.13" }
	local ANSWERS = { intent = { choice = "calendar", probabilities = { calendar = 0.9, none = 0.1 } } }
	local LOCATIONS = {
		system_one = { system_one = { answers = ANSWERS } },
		answers = { answers = ANSWERS },
		content = { content = Json.encode({ answers = ANSWERS }) },
	}

	for _, where in ipairs({ "system_one", "answers", "content" }) do
		helpers.it("reads the answers from '" .. where .. "' and logs where", function()
			with_remote(function(remote, calls, logs)
				helpers.assert_true(remote.is_decision_entry(JEV), "a TypeSafe model through Backboard")
				local got
				remote.decide(JEV, "App: Mail\nText: jeudi", QUESTIONS, function(answers, err) got = { answers, err } end)
				answer(calls, 1, { assistant_id = "asst-1" })
				local message = Formats.backboard_message_request(base, { assistant_id = "asst-1",
					model = "typesafe/jev-1.13", system = "", text = "App: Mail\nText: jeudi", questions = QUESTIONS })
				helpers.assert_eq(calls[2].body, message.body, "system_one carries the questions")
				answer(calls, 2, LOCATIONS[where])
				helpers.assert_eq(got[1].intent.choice, "calendar")
				helpers.assert_eq(#logged(logs, "info", "Backboard's '" .. where .. "'"), 1, "the location is logged")
			end)
		end)
	end

	helpers.it("without answers: a WARN naming the top-level keys only, never the content", function()
		with_remote(function(remote, calls, logs)
			local got_err
			remote.decide(JEV, "App: Mail\nText: jeudi", QUESTIONS, function(_, err) got_err = err end)
			answer(calls, 1, { assistant_id = "asst-1" })
			answer(calls, 2, { content = "SECRET reply text", thread_id = "t-1" })
			helpers.assert_true(got_err ~= nil)
			local warns = logged(logs, "warn", "top-level keys: content, thread_id")
			helpers.assert_eq(#warns, 1, "the keys are logged")
			for _, line in ipairs(logs) do
				helpers.assert_true(not line.text:find("SECRET", 1, true), "never the content: " .. line.text)
			end
		end)
	end)

	helpers.it("any other Backboard model is not a Jev System 1", function()
		with_remote(function(remote)
			helpers.assert_true(not remote.is_decision_entry(BACKBOARD))
			helpers.assert_true(remote.is_decision_entry(TYPESAFE))
			helpers.assert_true(not remote.is_decision_entry({ provider = "groq", model = "typesafe/x" }))
		end)
	end)
end)

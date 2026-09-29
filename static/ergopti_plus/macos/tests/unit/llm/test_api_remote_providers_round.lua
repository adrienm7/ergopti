--- tests/unit/llm/test_api_remote_providers_round.lua

--- ==============================================================================
--- MODULE: Remote Providers Beyond Chat Completions (macOS)
--- DESCRIPTION:
--- Runs the real remote backend over the real api_providers.json with the HTTP
--- clients faked (requests captured, answered with canned bodies):
--- - every provider of the catalogue loads, in its order, and the lists of the
---   uses leave out what a format cannot serve (Backboard takes no image, a
---   decisions provider is no chat model);
--- - an openai-format newcomer (Groq) is a plain chat provider at its base_url;
--- - Backboard creates one assistant per key, then every message names it, with
---   the key in X-API-Key and the body of the shared vectors; a failed creation
---   fails the request and the next one tries again; a model naming no provider
---   is refused;
--- - the Test-API action probes a decisions provider with decisions_test.
---
--- ROOT CAUSE ENCODED:
--- The catalogue validator knew three formats only: the Backboard and decisions
--- providers were dropped at load, and nothing could send their requests.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local Formats = require("llm.remote_formats")

local function read_json(path)
	local fh = assert(io.open(SHARED .. path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

local CATALOGUE = read_json("modules/llm/api_providers.json")

--- Finds one upvalue, searching nested closures.
--- @param fn function
--- @param target string
--- @param seen table|nil
--- @return any value
local function find_upvalue(fn, target, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
		if type(value) == "function" then
			local found = find_upvalue(value, target, seen)
			if found ~= nil then return found end
		end
	end
	return nil
end

--- Loads the real remote backend and fakes its HTTP clients.
--- @return table api, table posts
local function load_api()
	package.loaded["modules.llm.api_remote"] = nil
	package.loaded["modules.llm.remote_response_classifier"] = nil
	package.loaded["modules.llm.provider_uses"] = nil
	package.loaded["modules.shortcuts.script_control"] = nil
	local api = helpers.load_with_stubs("modules.llm.api_remote", {})
	local posts = {}
	for _, name in ipairs({ "_infer_client", "_vision_client", "_probe_client", "_check_client", "_warmup_client" }) do
		local client = find_upvalue(api.request_backboard, name) or find_upvalue(api.test_request, name)
			or find_upvalue(api.check_availability, name) or find_upvalue(api.warmup, name)
			or find_upvalue(api.cancel_streaming, name)
		assert(type(client) == "table", name .. " must be reachable")
		client.post = function(url, headers, body, callback)
			posts[#posts + 1] = { client = name, url = url, headers = headers, body = json.decode(body), callback = callback }
			return true
		end
		client.get = function(url, headers, callback)
			posts[#posts + 1] = { client = name, url = url, headers = headers, method = "GET", callback = callback }
			return true
		end
	end
	return api, posts
end

local function reply(post, status, body)
	post.callback({ ok = status >= 200 and status < 300, status = status, body = json.encode(body), headers = {} })
end

helpers.describe("remote providers: catalogue and uses (macOS)", function()
	helpers.it("loads every provider of the catalogue, in its order", function()
		local api = load_api()
		helpers.assert_eq(table.concat(api.PROVIDER_ORDER, ","), table.concat(CATALOGUE.provider_order, ","))
		helpers.assert_eq(api.PROVIDERS.backboard.format, "backboard")
		helpers.assert_eq(api.PROVIDERS.typesafe.format, "decisions")
		helpers.assert_eq(api.DECISIONS_TEST.state, CATALOGUE.decisions_test.state)
	end)

	helpers.it("lists each use without the formats that cannot serve it", function()
		local api = load_api()
		local function has(list, id)
			for _, value in ipairs(list) do if value == id then return true end end
			return false
		end
		for _, id in ipairs({ "openrouter", "groq", "together", "fireworks" }) do
			for _, use in ipairs({ "prediction", "system1", "system2", "vision" }) do
				helpers.assert_true(has(api.provider_ids(use), id), id .. " serves " .. use)
			end
		end
		helpers.assert_true(has(api.provider_ids("prediction"), "backboard"))
		helpers.assert_true(has(api.provider_ids("system2"), "backboard"))
		helpers.assert_true(not has(api.provider_ids("vision"), "backboard"), "Backboard takes no image")
		for _, id in ipairs({ "typesafe", "openrouter_jev" }) do
			helpers.assert_true(has(api.provider_ids("system1"), id), id .. " triages")
			for _, use in ipairs({ "prediction", "system2", "vision" }) do
				helpers.assert_true(not has(api.provider_ids(use), id), id .. " is no chat model: not " .. use)
			end
		end
		api.set_entries({ { id = "b", provider = "backboard", token = "k" } })
		local ready, reason = api.vision_provider_status("backboard")
		helpers.assert_true(not ready, "Backboard refuses a vision request")
		helpers.assert_eq(reason, "unsupported")
	end)

	helpers.it("sends an openai-format newcomer's chat to its base_url with a Bearer key", function()
		local api, posts = load_api()
		api.set_entries({ { id = "g", provider = "groq", token = "groq-key", model = "llama-3.3-70b-versatile" } })
		local body = { model = "llama-3.3-70b-versatile", messages = {} }
		local text
		api.request_chat("groq", "llama-3.3-70b-versatile", body, function(t) text = t end, function() end)
		helpers.assert_eq(posts[1].url, CATALOGUE.providers.groq.base_url .. "/chat/completions")
		helpers.assert_eq(posts[1].headers.Authorization, "Bearer groq-key")
		reply(posts[1], 200, { choices = { { message = { content = "salut" } } } })
		helpers.assert_eq(text, "salut")
	end)
end)

helpers.describe("remote providers: Backboard (macOS)", function()
	local BASE = CATALOGUE.providers.backboard.base_url

	helpers.it("creates the key's assistant once, then names it in every message", function()
		local api, posts = load_api()
		api.set_entries({ { id = "b", provider = "backboard", token = "bb-key", model = "openai/gpt-4o-mini" } })
		local answers = {}
		local spec = { model = "openai/gpt-4o-mini", system = "sys", text = "hello" }
		api.request_backboard("backboard", spec, function(a) answers[#answers + 1] = a end, function() end)
		helpers.assert_eq(#posts, 1, "the assistant first")
		local creation = Formats.backboard_assistant_request(BASE)
		helpers.assert_eq(posts[1].url, creation.url)
		helpers.assert_eq(json.encode(posts[1].body), json.encode(creation.body))
		helpers.assert_eq(posts[1].headers["X-API-Key"], "bb-key", "the key in X-API-Key")
		helpers.assert_nil(posts[1].headers.Authorization, "no Bearer")
		reply(posts[1], 200, { assistant_id = "asst-1" })

		helpers.assert_eq(#posts, 2, "then the message")
		local message = Formats.backboard_message_request(BASE,
			{ assistant_id = "asst-1", model = "openai/gpt-4o-mini", system = "sys", text = "hello" })
		helpers.assert_eq(posts[2].url, message.url)
		for key, value in pairs(message.body) do
			helpers.assert_eq(posts[2].body[key], value, "message field " .. key)
		end
		helpers.assert_nil(posts[2].body.temperature, "no invented temperature")
		helpers.assert_nil(posts[2].body.max_tokens, "no invented token budget")
		helpers.assert_eq(posts[2].headers["X-API-Key"], "bb-key")
		reply(posts[2], 200, { content = "réponse" })
		helpers.assert_eq(Formats.backboard_text(answers[1]), "réponse")

		api.request_backboard("backboard", spec, function() end, function() end)
		helpers.assert_eq(#posts, 3, "the second request reuses the assistant")
		helpers.assert_eq(posts[3].url, message.url)
		helpers.assert_eq(posts[3].body.assistant_id, "asst-1")
	end)

	helpers.it("fails the request when the assistant cannot be created, and retries at the next", function()
		local api, posts = load_api()
		api.set_entries({ { id = "b", provider = "backboard", token = "bb-key-2" } })
		local failures = {}
		local spec = { model = "anthropic/claude-haiku-4-5", system = "", text = "x" }
		api.request_backboard("backboard", spec, function() end, function(r) failures[#failures + 1] = r end)
		reply(posts[1], 401, { error = { message = "bad key" } })
		helpers.assert_eq(#posts, 1, "no message without an assistant")
		helpers.assert_eq(failures[1], "assistant_http_401")

		api.request_backboard("backboard", spec, function() end, function(r) failures[#failures + 1] = r end)
		helpers.assert_eq(#posts, 2, "the next request tries the creation again")
		helpers.assert_eq(posts[2].url, BASE .. "/assistants")
		reply(posts[2], 200, { nothing = true })
		helpers.assert_eq(failures[2], "assistant_missing", "an answer without assistant_id fails too")
	end)

	helpers.it("refuses a model that names no provider, before any request", function()
		local api, posts = load_api()
		api.set_entries({ { id = "b", provider = "backboard", token = "bb-key-3" } })
		local failure
		api.request_backboard("backboard", { model = "gpt-4o-mini", text = "x" }, function() end,
			function(r) failure = r end)
		helpers.assert_eq(#posts, 0)
		helpers.assert_eq(failure, "invalid_model")
	end)

	helpers.it("answers predictions through Backboard as the prediction backend", function()
		local api, posts = load_api()
		api.set_entries({ { id = "b", provider = "backboard", token = "bb-key-4", model = "openai/gpt-4o-mini" } })
		api.set_active_entry_id("b")
		local raw
		api.request_raw(nil, "You complete text.", "Bonjour", "", 0.2, 16, function(t) raw = t end, function() end)
		helpers.assert_eq(posts[1].client, "_infer_client")
		helpers.assert_eq(posts[1].url, BASE .. "/assistants")
		reply(posts[1], 200, { assistant_id = "asst-p" })
		helpers.assert_eq(posts[2].url, BASE .. "/threads/messages")
		helpers.assert_eq(posts[2].body.llm_provider, "openai")
		helpers.assert_eq(posts[2].body.model_name, "gpt-4o-mini")
		helpers.assert_eq(posts[2].body.content, "Bonjour")
		reply(posts[2], 200, { content = "tout le monde" })
		helpers.assert_eq(raw, "tout le monde")
	end)

	helpers.it("tests a Backboard entry with one message of the shared test_request", function()
		local api, posts = load_api()
		local entry = { id = "b", provider = "backboard", token = "bb-key-6", model = "openai/gpt-4o-mini" }
		api.set_entries({ entry })
		api.set_active_entry_id("b")
		local verdict
		-- The reply's parsing is the chat path's own (test_api_remote_test_request.lua)
		local parser = find_upvalue(api.test_request, "Parser")
		local original_process = parser.process_prediction
		parser.process_prediction = function(_, _, text) return { to_type = text } end
		local failure
		api.test_request(entry, api.get_test_request_spec(), function(text) verdict = text end,
			function(reason, detail) failure = tostring(reason) .. " " .. json.encode(detail or {}) end)
		reply(posts[1], 200, { assistant_id = "asst-t" })
		helpers.assert_eq(posts[2].body.system_prompt, CATALOGUE.test_request.system_prompt)
		helpers.assert_eq(posts[2].body.content, CATALOGUE.test_request.user_text)
		reply(posts[2], 200, { content = "OK" })
		parser.process_prediction = original_process
		helpers.assert_eq(verdict, "OK", "the reply is the verdict: " .. tostring(failure))
	end)

	helpers.it("warms up by creating the assistant, the Backboard readiness probe", function()
		local api, posts = load_api()
		api.set_entries({ { id = "b", provider = "backboard", token = "bb-key-5", model = "openai/gpt-4o-mini" } })
		api.set_active_entry_id("b")
		api.warmup(nil, nil)
		helpers.assert_eq(posts[1].client, "_warmup_client")
		helpers.assert_eq(posts[1].url, BASE .. "/assistants")
		reply(posts[1], 200, { assistant_id = "asst-w" })
		helpers.assert_eq(api.is_ready(), true)
	end)
end)

helpers.describe("remote providers: decisions (macOS)", function()
	helpers.it("probes a decisions entry with decisions_test at its full endpoint", function()
		local api, posts = load_api()
		local entry = { id = "j", provider = "openrouter_jev", token = "jev-key", model = "typesafe/jev-1.13" }
		local verdict
		helpers.assert_eq(api.test_request(entry, nil, function(text) verdict = { ok = true, text = text } end,
			function(reason) verdict = { ok = false, reason = reason } end), true)
		helpers.assert_eq(posts[1].client, "_probe_client", "never the prediction or agent client")
		helpers.assert_eq(posts[1].url, CATALOGUE.providers.openrouter_jev.base_url, "the full endpoint")
		helpers.assert_eq(posts[1].headers.Authorization, "Bearer jev-key")
		helpers.assert_eq(json.encode(posts[1].body), json.encode(Formats.decisions_body("typesafe/jev-1.13",
			CATALOGUE.decisions_test.state, CATALOGUE.decisions_test.questions)))
		reply(posts[1], 200, { answers = { ok = { choice = "yes" } } })
		helpers.assert_eq(verdict.ok, true)

		api.test_request(entry, nil, function() verdict = { ok = true } end,
			function(reason) verdict = { ok = false, reason = reason } end)
		reply(posts[2], 200, { error = "no" })
		helpers.assert_eq(verdict.ok, false, "an answer without answers fails")
	end)

	helpers.it("never sends a chat request or a prediction to a decisions provider", function()
		local api, posts = load_api()
		api.set_entries({ { id = "j", provider = "typesafe", token = "jev-key", model = "jev-latest" } })
		local failed = false
		api.request_chat("typesafe", "jev-latest", { messages = {} }, function() end, function() failed = true end)
		helpers.assert_true(failed, "no chat request")
		api.set_active_entry_id("j")
		failed = false
		api.request_raw(nil, "sys", "text", "", 0.2, 16, function() end, function() failed = true end)
		helpers.assert_true(failed, "no prediction")
		helpers.assert_eq(api.warmup(nil, nil), false, "never ready as the prediction backend")
		helpers.assert_eq(#posts, 0)
	end)
end)

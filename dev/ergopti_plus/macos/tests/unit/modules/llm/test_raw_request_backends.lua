--- tests/unit/modules/llm/test_raw_request_backends.lua

--- ==============================================================================
--- MODULE: Local backends answer a raw single request (llm-tone)
--- DESCRIPTION:
--- The tone actions send one request with a ladder prompt and read the answer
--- themselves (llm/tone.lua extract): the text is a selection, not the typed
--- buffer the prediction parser aligns against. Ollama and MLX must post that
--- request without streaming, with the text as PREFIX and TAIL, and hand the
--- answer back unparsed. The remote backend is covered end to end by
--- test_tone_rewrite_end_to_end.lua.
---
--- ROOT CAUSE ENCODED:
--- Every backend request ran the prediction parser, which drops a rewrite equal
--- to its tail and measures a rewrite against the typed buffer: an answer that
--- is a valid rewrite of the selection never reached the caller.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Selector = require("llm.profile_selector")

local SOURCE = "Merci pour votre aide."
local ANSWER = "REWRITE: Merci pour votre aide."

--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

--- Returns the shipped system prompt of a built-in profile.
--- @param id string
--- @return string
local function system_prompt(id)
	for _, profile in ipairs(Selector.load_built_in_profiles()) do
		if profile.id == id then return profile.system_single end
	end
	error("no built-in profile " .. id)
end

helpers.describe("raw single request on the local backends (llm-tone)", function()
	helpers.it("Ollama posts one non-streaming chat request and returns the answer unparsed", function()
		package.loaded["modules.llm.api_ollama"] = nil
		local Ollama = helpers.load_with_stubs("modules.llm.api_ollama")
		helpers.assert_type(Ollama.request_raw, "function")
		local post_and_parse = get_upvalue(Ollama.request_raw, "post_and_parse")
		local client = get_upvalue(post_and_parse, "_infer_client")
		helpers.assert_type(client, "table", "the Ollama HTTP owner must be reachable")
		local original_post = client.post
		local captured, raw, failed = nil, nil, false
		client.post = function(url, _headers, body, callback)
			captured = { url = url, payload = json.decode(body), callback = callback }
		end
		local ok, err = pcall(Ollama.request_raw, "fixture-model", system_prompt("tone_formal"),
			SOURCE, SOURCE, 0.1, 64, function(text) raw = text end, function() failed = true end)
		client.post = original_post
		helpers.assert_true(ok, tostring(err))
		helpers.assert_not_nil(captured, "the request must be dispatched")
		helpers.assert_true(captured.url:find("/api/chat", 1, true) ~= nil, "the chat endpoint")
		helpers.assert_eq(captured.payload.stream, false, "no streaming")
		helpers.assert_eq(captured.payload.options.num_predict, 64, "the caller's budget")
		helpers.assert_eq(captured.payload.messages[2].content,
			'PREFIX: "' .. SOURCE .. '"\nTAIL: "' .. SOURCE .. '"')
		-- A rewrite equal to its tail: the prediction parser would drop it
		captured.callback({ status = 200, body = json.encode({ message = { content = ANSWER } }) })
		helpers.assert_eq(raw, ANSWER, "the answer comes back unparsed")
		helpers.assert_eq(failed, false)
	end)

	helpers.it("MLX posts one chat request and returns the answer unparsed", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local Inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		Inference.init({
			stream = { generation = 0 }, cancel_streaming = function() return true end,
			completions_endpoint = function() return "http://fixture/completions" end,
			chat_endpoint = function() return "http://fixture/chat" end,
			read_active_model_arg = function() return "fixture/model" end,
			server_model_id = function() return nil end,
			model_hf_path = function() return nil end,
		})
		local client = get_upvalue(Inference.post_and_parse, "_infer_client")
		local scheduler = get_upvalue(Inference.post_and_parse, "TimerScheduler")
		local original_post, original_after, original_cancel = client.post, scheduler.after, scheduler.cancel
		scheduler.after = function() return { timer = {} }, true end
		scheduler.cancel = function() return true end
		local captured, raw, failed = nil, nil, false
		client.post = function(url, _headers, body, callback)
			captured = { url = url, payload = json.decode(body), callback = callback }
		end
		local ok, err = pcall(Inference.post_and_parse, "fixture", system_prompt("tone_formal"),
			SOURCE, SOURCE, 0.1, 64, 1, false, nil, function() failed = true end, {}, false,
			function(text) raw = text end)
		helpers.assert_true(ok, tostring(err))
		helpers.assert_not_nil(captured, "the request must be dispatched")
		helpers.assert_eq(captured.url, "http://fixture/chat", "the instructions need the chat endpoint")
		helpers.assert_eq(captured.payload.stream, false, "no streaming")
		helpers.assert_true(captured.payload.messages[1].content:find('TAIL: "' .. SOURCE .. '"', 1, true) ~= nil,
			"the text to rewrite is the TAIL")
		captured.callback({ status = 200, body = json.encode({
			choices = { { message = { content = ANSWER } } },
		}) })
		client.post, scheduler.after, scheduler.cancel = original_post, original_after, original_cancel
		helpers.assert_eq(raw, ANSWER, "the answer comes back unparsed")
		helpers.assert_eq(failed, false)
	end)
end)

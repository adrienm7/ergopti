--- tests/unit/modules/llm/test_screen_answer_backends.lua

--- ==============================================================================
--- MODULE: Screen answers run as plain chat turns on every backend (llm-vision)
--- DESCRIPTION:
--- The screen-reading answers (modules/llm/screen_answer.lua) send the
--- vision.json prompts with the transcribed screen as the user turn, and each
--- answer may span several lines. The core dispatches them with { chat = true };
--- Ollama must then drop its line mode (whose stop sequences end the answer at
--- the first newline) and MLX must use the chat endpoint (its line mode posts
--- the bare context to the completions endpoint, without the instructions).
--- The remote backend is covered end to end by test_screen_answer_end_to_end.lua.
---
--- ROOT CAUSE ENCODED:
--- A single raw request picked line mode for any prompt without PREFIX/TAIL
--- markers: an answer prompt lost its instructions on MLX and its second line
--- on Ollama.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Vision = require("llm.vision")

local USER = Vision.answer_user_text("Salut, on se voit demain ?")

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

--- The prompt of the first answer of vision.json.
--- @return string
local function answer_prompt()
	local fh = assert(io.open(helpers.shared("modules/llm/vision.json"), "r"))
	local config = json.decode(fh:read("*a"))
	fh:close()
	return Vision.fill_language(config.answers[1].prompt, "fr")
end

--- Tells whether a stop list ends the answer at a newline.
--- @param stop table|nil
--- @return boolean
local function stops_at_newline(stop)
	for _, sequence in ipairs(stop or {}) do
		if sequence == "\n" then return true end
	end
	return false
end

--- Sends one Ollama raw request, answers it, and returns the captured payload.
--- @param options table|nil request_raw options.
--- @return table payload
--- @return string logged Every debug line the request wrote.
local function ollama_payload(options)
	package.loaded["modules.llm.api_ollama"] = nil
	local Ollama = helpers.load_with_stubs("modules.llm.api_ollama")
	local post_and_parse = get_upvalue(Ollama.request_raw, "post_and_parse")
	local client = get_upvalue(post_and_parse, "_infer_client")
	local logger = get_upvalue(post_and_parse, "Logger")
	local original_post, original_debug = client.post, logger.debug
	local captured, lines = nil, {}
	client.post = function(_url, _headers, body, callback)
		captured = json.decode(body)
		callback({ status = 200, body = json.encode({ message = { content = "ANSWER: " .. USER } }) })
	end
	logger.debug = function(_, message, ...) lines[#lines + 1] = string.format(message, ...) end
	local ok, err = pcall(Ollama.request_raw, "fixture-model", answer_prompt(), USER, "", 0.2, 600,
		function() end, function() end, options)
	client.post, logger.debug = original_post, original_debug
	helpers.assert_true(ok, tostring(err))
	helpers.assert_not_nil(captured, "the request must be dispatched")
	return captured, table.concat(lines, "\n")
end

helpers.describe("screen answers as plain chat turns (llm-vision)", function()
	helpers.it("Ollama keeps every line of a chat answer", function()
		helpers.assert_true(stops_at_newline(ollama_payload(nil).options.stop),
			"without the option, a prompt with no PREFIX/TAIL runs in line mode")
		local payload, logged = ollama_payload({ chat = true })
		helpers.assert_true(logged:find("on se voit", 1, true) == nil,
			"what was read on the screen is never logged: " .. logged)
		helpers.assert_eq(payload.messages[1].content, answer_prompt(), "the answer prompt is the system turn")
		helpers.assert_eq(payload.messages[2].content, USER, "the screen is the user turn, as is")
		helpers.assert_true(not stops_at_newline(payload.options.stop), "a chat answer may span several lines")
		helpers.assert_eq(payload.options.num_predict, 600)
	end)

	helpers.it("MLX sends a chat answer to the chat endpoint with its instructions", function()
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
		local captured = {}
		client.post = function(url, _headers, body) captured[#captured + 1] = { url = url, payload = json.decode(body) } end
		local ok, err = pcall(function()
			for _, force_chat in ipairs({ false, true }) do
				Inference.post_and_parse("fixture", answer_prompt(), USER, "", 0.2, 600, 1, false, nil,
					function() end, {}, false, function() end, force_chat)
			end
		end)
		client.post, scheduler.after, scheduler.cancel = original_post, original_after, original_cancel
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(captured[1].url, "http://fixture/completions",
			"without the option, the instructions would be dropped")
		helpers.assert_eq(captured[2].url, "http://fixture/chat", "a chat answer needs the chat endpoint")
		local content = captured[2].payload.messages[#captured[2].payload.messages].content
		helpers.assert_true(content:find(answer_prompt(), 1, true) ~= nil, "the instructions are sent")
		helpers.assert_true(content:find(USER, 1, true) ~= nil, "with the screen")
		helpers.assert_true(not stops_at_newline(captured[2].payload.stop), "a chat answer may span several lines")
	end)

	helpers.it("the core dispatches a screen answer as a chat turn on the current backend", function()
		package.loaded["modules.llm"] = nil
		local Core = helpers.load_with_stubs("modules.llm")
		local CoreState = get_upvalue(Core.get_active_profile, "CoreState")
		local Ollama = require("modules.llm.api_ollama")
		local original = Ollama.request_raw
		local seen = nil
		Ollama.request_raw = function(model, system, full_text, tail_text, temperature, max_tokens, _, _, options)
			seen = { model = model, system = system, full_text = full_text, tail_text = tail_text,
				temperature = temperature, max_tokens = max_tokens, options = options }
		end
		CoreState.backend = "ollama"
		local ok, err = pcall(Core.fetch_raw_text, answer_prompt(), USER, "fixture-model", 0.2, 600,
			function() end, function() end)
		Ollama.request_raw = original
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(seen.system, answer_prompt(), "the prompt as given, no profile")
		helpers.assert_eq(seen.full_text, USER)
		helpers.assert_eq(seen.tail_text, "", "no TAIL")
		helpers.assert_eq(seen.max_tokens, 600)
		helpers.assert_eq(seen.options and seen.options.chat, true, "a plain chat turn")
	end)
end)

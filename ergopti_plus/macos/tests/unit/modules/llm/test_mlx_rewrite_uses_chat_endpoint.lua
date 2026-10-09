--- tests/unit/modules/llm/test_mlx_rewrite_uses_chat_endpoint.lua

--- ==============================================================================
--- MODULE: MLX sends a rewrite prompt to the chat endpoint (llm-prompt-prediction)
--- DESCRIPTION:
--- The MLX backend posts "line mode" requests (every prompt that is neither
--- batch nor the TAIL_CORRECTED correction prompt) to the completions endpoint
--- with the bare typed context. That drops the system prompt, which a rewrite
--- prompt entirely depends on.
---
--- ROOT CAUSE ENCODED:
--- The rewrite prompt answers "REWRITE: <sentence>" and has no TAIL_CORRECTED,
--- so the classification sent it to the raw completion path, where the model
--- simply continued the text and the parser found no rewrite.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local Selector = require("llm.profile_selector")

local function get_upvalue(fn, target)
	for index = 1, 96 do
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

--- Posts one request through the real MLX inference owner and captures it.
--- @param streaming boolean Whether to use the streaming variant.
--- @param prompt string The resolved system prompt.
--- @return table|nil captured { url, payload }
local function capture(streaming, prompt)
	package.loaded["modules.llm.api_mlx_inference"] = nil
	local Inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
	local captured = nil
	Inference.init({
		stream = { generation = 0 }, cancel_streaming = function() return true end,
		completions_endpoint = function() return "http://fixture/completions" end,
		chat_endpoint = function() return "http://fixture/chat" end,
		read_active_model_arg = function() return "fixture/model" end,
		server_model_id = function() return nil end,
		model_hf_path = function() return nil end,
	})
	if streaming then
		-- The streaming variant hands its payload to curl through a file: capture
		-- it at the encoder and stop there (an encode failure aborts cleanly)
		local codec = get_upvalue(Inference.post_and_parse_streaming, "JsonCodec")
		local original_encode = codec.encode
		codec.encode = function(payload)
			captured = { payload = payload }
			return nil, "captured by the test"
		end
		local ok, err = pcall(Inference.post_and_parse_streaming, "fixture", prompt, "Salut. c ok pr dm1",
			"c ok pr dm1", 0.2, 64, 1, false, function() end, function() end, {}, nil)
		codec.encode = original_encode
		if not ok then error(err, 0) end
		return captured
	end
	local client = get_upvalue(Inference.post_and_parse, "_infer_client")
	local scheduler = get_upvalue(Inference.post_and_parse, "TimerScheduler")
	local original_post, original_after = client.post, scheduler.after
	scheduler.after = function() return { timer = {} }, true end
	client.post = function(url, _headers, body)
		captured = { url = url, payload = json.decode(body) }
	end
	local ok, err = pcall(Inference.post_and_parse, "fixture", prompt, "Salut. c ok pr dm1", "c ok pr dm1",
		0.2, 64, 1, false, function() end, function() end, {}, false)
	client.post, scheduler.after = original_post, original_after
	if not ok then error(err, 0) end
	return captured
end

helpers.describe("MLX rewrite prompt classification (llm-prompt-prediction)", function()
	helpers.it("posts a rewrite to the chat endpoint with its instructions", function()
		local captured = capture(false, system_prompt("rewrite"))
		helpers.assert_not_nil(captured, "the request must be dispatched")
		helpers.assert_eq(captured.url, "http://fixture/chat",
			"the completions endpoint would drop the rewrite instructions")
		local content = captured.payload.messages[1].content
		helpers.assert_true(content:find("REWRITE:", 1, true) ~= nil, "the rewrite instructions are sent")
		helpers.assert_true(content:find('TAIL: "c ok pr dm1"', 1, true) ~= nil,
			"with the sentence to rewrite as TAIL")
	end)

	helpers.it("streams a rewrite as a chat request with its instructions", function()
		local captured = capture(true, system_prompt("rewrite"))
		helpers.assert_not_nil(captured, "the streaming request must be built")
		helpers.assert_nil(captured.payload.prompt, "not a bare completion of the typed text")
		helpers.assert_true(type(captured.payload.messages) == "table"
			and captured.payload.messages[1].content:find("REWRITE:", 1, true) ~= nil,
			"a chat request carrying the rewrite instructions")
	end)

	helpers.it("keeps a plain continuation prompt on the completions endpoint", function()
		local captured = capture(false, system_prompt("basic"))
		helpers.assert_not_nil(captured)
		helpers.assert_eq(captured.url, "http://fixture/completions")
		local streamed = capture(true, system_prompt("basic"))
		helpers.assert_type(streamed.payload.prompt, "string", "streamed as a completion too")
	end)
end)

--- tests/unit/modules/llm/test_mlx_prompt_utf8_boundary.lua

--- ==============================================================================
--- MODULE: MLX Completion Prompt UTF-8 Boundary Regression
--- DESCRIPTION:
--- Completion prompts retain the last 240 Unicode codepoints without slicing
--- through a multibyte character in either transport mode.
--- ==============================================================================

local helpers = require("tests.helpers")

local function get_upvalue(fn, target)
	for index = 1, 96 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

local function new_ctx()
	return {
		stream = { task = nil, timeout = nil, generation = 0, has_chunks = false },
		cancel_streaming = function() return true end,
		completions_endpoint = function() return "http://fixture/completions" end,
		chat_endpoint = function() return "http://fixture/chat" end,
		read_active_model_arg = function() return "fixture/model" end,
		server_model_id = function() return nil end,
		model_hf_path = function() return nil end,
	}
end

helpers.describe("MLX completion prompt preserves UTF-8 boundaries", function()
	helpers.it("captures the same final 240 codepoints in both transport modes", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local Inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		local json_codec = get_upvalue(Inference.post_and_parse, "JsonCodec")
		local stream_json_codec = get_upvalue(Inference.post_and_parse_streaming, "JsonCodec")
		helpers.assert_true(json_codec ~= nil, "non-streaming JSON codec must be reachable")
		helpers.assert_eq(stream_json_codec, json_codec,
			"streaming and non-streaming requests must share the same codec boundary")

		local original_encode = json_codec.encode
		local captures = {}
		json_codec.encode = function(payload)
			captures[#captures + 1] = payload
			return nil, "payload captured"
		end
		Inference.init(new_ctx())

		local accented = string.char(0xC3, 0xA9)
		local suffix = string.rep("b", 239)
		local context = "aa" .. accented .. suffix
		local expected = accented .. suffix
		local failures = 0
		local function on_fail() failures = failures + 1 end

		local ok, err = xpcall(function()
			Inference.post_and_parse(
				"fixture-model", "", context, "", 0.2, 8, 1, false,
				function() error("unexpected non-streaming success") end,
				on_fail, {}, true)
			Inference.post_and_parse_streaming(
				"fixture-model", "", context, "", 0.2, 8, 1, false,
				function() error("unexpected streaming success") end,
				on_fail, {}, function() end)

			helpers.assert_eq(#captures, 2,
				"both request paths must reach the real payload encoder")
			helpers.assert_eq(failures, 2,
				"the capture seam must stop both requests before transport")
			for index, expected_stream in ipairs({ false, true }) do
				local payload = captures[index]
				helpers.assert_eq(payload.stream, expected_stream)
				helpers.assert_eq(payload.prompt, expected,
					"the final 240 codepoints must remain byte-exact")
				local length, bad_byte = utf8.len(payload.prompt)
				helpers.assert_eq(length, 240,
					"the captured prompt must contain exactly 240 Unicode codepoints")
				helpers.assert_eq(bad_byte, nil,
					"the captured prompt must not start on a UTF-8 continuation byte")
			end
		end, debug.traceback)
		json_codec.encode = original_encode
		if not ok then error(err) end
	end)
end)

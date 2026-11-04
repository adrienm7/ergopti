--- tests/unit/modules/llm/mlx/test_mlx_non_stream_timeout_transaction.lua

--- ==============================================================================
--- MODULE: MLX Non-Stream Timeout Transaction Regression
--- DESCRIPTION:
--- A non-streaming request must not leave the process without a hard deadline.
--- Partial timer activation is retained as exact cleanup debt and blocks both
--- the HTTP dispatch and a sibling request until native cancellation settles.
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

helpers.describe("MLX non-stream request requires a committed deadline", function()
	helpers.it("does not dispatch while partial timeout cleanup is unsettled", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local Inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		local scheduler = get_upvalue(Inference.post_and_parse, "TimerScheduler")
		local client = get_upvalue(Inference.post_and_parse, "_infer_client")
		local original_after = scheduler.after
		local original_cancel = scheduler.cancel
		local original_post = client.post
		local exact_handle = { timer = {} }
		local cancel_settled = false
		local posts, failures, after_calls = 0, 0, 0
		scheduler.after = function()
			after_calls = after_calls + 1
			return exact_handle, false
		end
		scheduler.cancel = function(handle)
			helpers.assert_eq(handle, exact_handle)
			if cancel_settled then handle.timer = nil end
			return cancel_settled
		end
		client.post = function() posts = posts + 1 end
		Inference.init({
			stream = {}, cancel_streaming = function() return true end,
			completions_endpoint = function() return "http://fixture/completions" end,
			chat_endpoint = function() return "http://fixture/chat" end,
			read_active_model_arg = function() return "fixture/model" end,
			server_model_id = function() return nil end,
			model_hf_path = function() return nil end,
		})
		local function request()
			Inference.post_and_parse("fixture", "", "typed", "", 0.2, 8, 1, false,
				function() error("unexpected success") end,
				function() failures = failures + 1 end, {}, false)
		end
		local ok, err = pcall(function()
			request()
			request()
			helpers.assert_eq(posts, 0)
			helpers.assert_eq(after_calls, 1,
				"cleanup debt must block a sibling timeout acquisition and HTTP request")
			helpers.assert_eq(failures, 2)
			cancel_settled = true
		end)
		scheduler.after = original_after
		scheduler.cancel = original_cancel
		client.post = original_post
		if not ok then error(err) end
	end)
end)

helpers.describe("MLX inference error privacy", function()
	helpers.it("does not log a provider error body that echoes private text", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		local scheduler = assert(get_upvalue(inference.post_and_parse, "TimerScheduler"))
		local client = assert(get_upvalue(inference.post_and_parse, "_infer_client"))
		local logger = assert(get_upvalue(inference.post_and_parse, "Logger"))
		local after, cancel, post, log_error = scheduler.after, scheduler.cancel, client.post, logger.error
		local messages, failed = {}, 0
		scheduler.after = function() return {}, true end
		scheduler.cancel = function() return true end
		client.post = function(_, _, _, done) done({ status = 500, body = "private-provider-echo" }) end
		logger.error = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
		local ok, err = xpcall(function()
			inference.init({ stream = {}, cancel_streaming = function() return true end,
				completions_endpoint = function() return "http://fixture/completions" end,
				chat_endpoint = function() return "http://fixture/chat" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() return nil end, model_hf_path = function() return nil end })
			inference.post_and_parse("fixture", "", "sensitive", "", 0.2, 8, 1, false,
				function() error("unexpected success") end, function() failed = failed + 1 end, {}, false)
			helpers.assert_eq(failed, 1)
			helpers.assert_true(#messages > 0)
			for _, message in ipairs(messages) do
				helpers.assert_true(not message:find("private-provider-echo", 1, true))
			end
		end, debug.traceback)
		scheduler.after, scheduler.cancel, client.post, logger.error = after, cancel, post, log_error
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("MLX non-stream response schema", function()
	helpers.it("reports failure for a scalar choice instead of abandoning the request", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		local scheduler = assert(get_upvalue(inference.post_and_parse, "TimerScheduler"))
		local client = assert(get_upvalue(inference.post_and_parse, "_infer_client"))
		local codec = assert(get_upvalue(inference.post_and_parse, "JsonCodec"))
		local after, cancel, post, decode = scheduler.after, scheduler.cancel, client.post, codec.decode
		local callback, failed = nil, 0
		scheduler.after = function() return {}, true end
		scheduler.cancel = function() return true end
		client.post = function(_, _, _, done) callback = done end
		codec.decode = function(raw) return require("json").decode(raw), nil end
		local ok, err = xpcall(function()
			inference.init({ stream = {}, cancel_streaming = function() return true end,
				completions_endpoint = function() return "http://fixture/completions" end,
				chat_endpoint = function() return "http://fixture/chat" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() return nil end, model_hf_path = function() return nil end })
			inference.post_and_parse("fixture", "", "typed", "", 0.2, 8, 1, false,
				function() error("unexpected success") end, function() failed = failed + 1 end, {}, false)
			helpers.assert_eq(type(callback), "function")
			local callback_ok = pcall(callback, { status = 200, body = '{"choices":[1]}' })
			helpers.assert_true(callback_ok, "malformed provider data must not escape the callback")
			helpers.assert_eq(failed, 1, "the caller must receive exactly one terminal failure")
		end, debug.traceback)
		scheduler.after, scheduler.cancel, client.post, codec.decode = after, cancel, post, decode
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("MLX non-stream provider errors", function()
	helpers.it("does not publish text alongside a provider error", function()
		package.loaded["modules.llm.api_mlx_inference"] = nil
		local inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
		local scheduler = assert(get_upvalue(inference.post_and_parse, "TimerScheduler"))
		local client = assert(get_upvalue(inference.post_and_parse, "_infer_client"))
		local codec = assert(get_upvalue(inference.post_and_parse, "JsonCodec"))
		local after, cancel, post, decode = scheduler.after, scheduler.cancel, client.post, codec.decode
		local callback, failed, raw = nil, 0, nil
		scheduler.after = function() return {}, true end
		scheduler.cancel = function() return true end
		client.post = function(_, _, _, done) callback = done end
		codec.decode = function(body)
			local value = require("json").decode(body)
			if body:find('"error":null', 1, true) then value.error = nil end
			return value, nil
		end
		local ok, err = xpcall(function()
			inference.init({ stream = {}, cancel_streaming = function() return true end,
				completions_endpoint = function() return "http://fixture/completions" end,
				chat_endpoint = function() return "http://fixture/chat" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() return nil end, model_hf_path = function() return nil end })
			for index, body in ipairs({
				'{"error":{"message":"failed"},"choices":[{"message":{"content":"decoy"}}]}',
				'{"error":null,"choices":[{"message":{"content":"decoy"}}]}',
			}) do
				inference.post_and_parse("fixture", "", "typed", "", 0.2, 8, 1, false,
					function() error("unexpected success") end, function() failed = failed + 1 end, {}, false,
					function(text) raw = text end, true)
				callback({ status = 200, body = body })
				if index == 1 then
					helpers.assert_nil(raw, "an error object cannot deliver a model answer")
				else
					helpers.assert_eq(raw, "decoy", "a null error allows an otherwise valid answer")
				end
				helpers.assert_eq(failed, 1)
			end
		end, debug.traceback)
		scheduler.after, scheduler.cancel, client.post, codec.decode = after, cancel, post, decode
		if not ok then error(err, 0) end
	end)
end)

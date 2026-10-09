--- tests/unit/modules/llm/test_mlx_non_stream_timeout_transaction.lua

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

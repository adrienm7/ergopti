--- tests/unit/modules/llm/test_api_mlx_stream_bound.lua

--- ==============================================================================
--- MODULE: Regression — MLX streaming must stay bounded (F-HIGH-2)
--- DESCRIPTION:
--- The MLX streaming curl had only --connect-timeout (no --max-time), and the
--- in-process hard-timeout watchdog was CANCELLED on the first chunk and never
--- re-armed. So a server that sent >=1 token then stalled left curl blocked
--- forever: on_done never fired, on_fail never fired, the spinner froze, and the
--- single-request MLX connection stayed held open against every later prediction.
--- The Ollama backend never had this because its curl carries --max-time.
---
--- This test pins the root cause structurally (the networked streaming path is
--- deferred to integration testing — it needs a live MLX server + hs.task):
---   1. the streaming curl argv carries --max-time (and keeps --connect-timeout),
---      so curl always exits and on_done runs;
---   2. on_chunk RE-ARMS the idle watchdog (rather than permanently cancelling
---      it), so a mid-stream stall is bounded too.
--- ==============================================================================

local helpers = require("tests.helpers")

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

local function read_src()
	-- The streaming path lives in the request engine.
	-- Selected by a declaration unique to modules/llm/api_mlx_inference.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("function M.post_and_parse_streaming")
	helpers.assert_true(src ~= nil, "modules/llm/api_mlx_inference.lua source must be locatable")
	return src
end

helpers.describe("api_mlx: streaming curl is time-bounded (F-HIGH-2)", function()
	helpers.it("the streaming curl argv passes --max-time and --connect-timeout", function()
		local src = read_src()
		-- Identify the streaming spawn by its no-buffer flag (-s, -N) through the endpoint.
		local stream_args = src:match('"%-s",%s*"%-N".-endpoint,')
		helpers.assert_true(stream_args ~= nil, "streaming curl args block (-s -N … endpoint) must be present")
		helpers.assert_true(stream_args:find('"%-%-max%-time"') ~= nil,
			"streaming curl MUST pass --max-time so it always exits and on_done runs (a mid-stream stall must not block forever)")
		helpers.assert_true(stream_args:find('"%-%-connect%-timeout"') ~= nil,
			"streaming curl must keep --connect-timeout")
	end)

	helpers.it("on_chunk re-arms the idle watchdog instead of permanently cancelling it", function()
		local src = read_src()
		-- on_chunk's body is everything between its definition and the next local
		-- function definition (on_done); flush_lines/arm_stream_idle_watchdog are
		-- defined BEFORE on_chunk, so this window is on_chunk's body alone.
		local on_chunk_body = src:match("local function on_chunk%b()(.-)local function on_done")
		helpers.assert_true(on_chunk_body ~= nil, "on_chunk body must be locatable")
		helpers.assert_true(on_chunk_body:find("arm_stream_idle_watchdog()", 1, true) ~= nil,
			"on_chunk must re-arm the idle watchdog on every chunk so a mid-stream stall is bounded")
	end)
end)


helpers.describe("api_mlx: streaming native ownership is transactional", function()
	package.loaded["modules.llm.api_mlx_inference"] = nil
	local Inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
	local shell_runner = get_upvalue(Inference.post_and_parse_streaming, "ShellRunner")
	local scheduler = get_upvalue(Inference.post_and_parse_streaming, "TimerScheduler")

	local function new_ctx()
		local stream = { task = nil, timeout = nil, generation = 0, has_chunks = false }
		return {
			stream = stream,
			cancel_streaming = function() return true end,
			completions_endpoint = function() return "http://127.0.0.1/v1/completions" end,
			chat_endpoint = function() return "http://127.0.0.1/v1/chat/completions" end,
			read_active_model_arg = function() return "fixture/model" end,
			server_model_id = function() return nil end,
			model_hf_path = function() return nil end,
		}
	end

	local function request(InferenceModule, on_fail)
		InferenceModule.post_and_parse_streaming(
			"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
			function() error("unexpected success") end, on_fail, {}, function() end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "throw", start = function() error("TASK_START_THROW") end },
	}) do
		helpers.it("releases a stream task whose start returns " .. case.name, function()
			local original_spawn = shell_runner.spawn
			local ctx = new_ctx()
			local spawns, failures, terminations = 0, 0, 0
			shell_runner.spawn = function()
				spawns = spawns + 1
				return {
					start = case.start,
					terminate = function() terminations = terminations + 1; return true end,
				}
			end
			Inference.init(ctx)

			local ok, err = pcall(function()
				request(Inference, function() failures = failures + 1 end)
				helpers.assert_eq(ctx.stream.task, nil,
					"a task that never committed must not poison the shared stream slot")
				request(Inference, function() failures = failures + 1 end)
				helpers.assert_eq(spawns, 2, "the next request must retry with a fresh native task")
				helpers.assert_eq(failures, 2)
				if case.name == "throw" then helpers.assert_eq(terminations, 2) end
			end)
			shell_runner.spawn = original_spawn
			if not ok then error(err) end
		end)
	end

	for _, case in ipairs({
		{ name = "uncommitted handle", arm = function() return { fired = true }, false end },
		{ name = "throw", arm = function() error("WATCHDOG_ARM_THROW") end },
	}) do
		helpers.it("terminates a started task when the initial watchdog arm returns " .. case.name, function()
			local original_spawn = shell_runner.spawn
			local original_after = scheduler.after
			local ctx = new_ctx()
			local failures, terminations, schedule_calls = 0, 0, 0
			local cleanup_callback
			shell_runner.spawn = function()
				return {
					start = function() return true end,
					terminate = function() terminations = terminations + 1; return true end,
				}
			end
			scheduler.after = function(_, callback)
				schedule_calls = schedule_calls + 1
				if schedule_calls == 1 then
					cleanup_callback = callback
					return { timer = {} }, true
				end
				return case.arm()
			end
			Inference.init(ctx)

			local ok, err = pcall(function()
				request(Inference, function() failures = failures + 1 end)
				helpers.assert_eq(terminations, 1,
					"a stream without a native deadline must be terminated immediately")
				helpers.assert_eq(ctx.stream.task, nil)
				helpers.assert_eq(failures, 1)
				helpers.assert_eq(type(cleanup_callback), "function",
					"payload cleanup must already be owned before watchdog creation")
				cleanup_callback()
			end)
			shell_runner.spawn = original_spawn
			scheduler.after = original_after
			if not ok then error(err) end
		end)
	end

	helpers.it("retains and retries a task when watchdog termination is refused", function()
		local original_spawn = shell_runner.spawn
		local original_after = scheduler.after
		local ctx = new_ctx()
		local failures, terminations = 0, 0
		local timers = {}
		local task
		task = {
			start = function() return true end,
			terminate = function()
				terminations = terminations + 1
				return terminations > 1
			end,
		}
		shell_runner.spawn = function() return task end
		scheduler.after = function(delay, callback)
			local handle = { timer = {}, delay = delay, callback = callback }
			timers[#timers + 1] = handle
			return handle, true
		end
		Inference.init(ctx)

		local ok, err = pcall(function()
			request(Inference, function() failures = failures + 1 end)
			helpers.assert_eq(#timers, 2, "cleanup and initial watchdog must both be owned")
			timers[2].callback()
			helpers.assert_eq(ctx.stream.task, task,
				"a refused termination must retain the exact task for a later attempt")
			helpers.assert_eq(failures, 0, "failure cannot publish before task teardown commits")
			helpers.assert_eq(#timers, 3, "the failed termination must arm a fresh watchdog")
			timers[3].callback()
			helpers.assert_eq(ctx.stream.task, nil)
			helpers.assert_eq(failures, 1)
			helpers.assert_eq(terminations, 2)
			timers[1].callback()
		end)
		shell_runner.spawn = original_spawn
		scheduler.after = original_after
		if not ok then error(err) end
	end)

	helpers.it("re-arms after a contract-valid void cancellation", function()
		local original_spawn = shell_runner.spawn
		local original_after = scheduler.after
		local original_cancel = scheduler.cancel
		local ctx = new_ctx()
		local failures, terminations = 0, 0
		local timers = {}
		local stream_chunk
		shell_runner.spawn = function(_, _, _, on_chunk)
			stream_chunk = on_chunk
			return {
				start = function() return true end,
				terminate = function() terminations = terminations + 1; return true end,
			}
		end
		scheduler.after = function(delay, callback)
			local handle = { active = true, delay = delay, callback = callback }
			timers[#timers + 1] = handle
			return handle, true
		end
		scheduler.cancel = function(handle)
			handle.active = false
			return nil
		end
		Inference.init(ctx)

		local ok, err = pcall(function()
			request(Inference, function() failures = failures + 1 end)
			helpers.assert_eq(#timers, 2, "cleanup and initial watchdog must both be owned")
			helpers.assert_eq(type(stream_chunk), "function")
			stream_chunk(nil, "data: {}\n", "")
			helpers.assert_eq(timers[2].active, false, "the prior deadline must be cancelled")
			helpers.assert_eq(#timers, 3, "a successful void cancel must still arm a new deadline")
			timers[3].callback()
			helpers.assert_eq(terminations, 1)
			helpers.assert_eq(failures, 1)
		end)
		shell_runner.spawn = original_spawn
		scheduler.after = original_after
		scheduler.cancel = original_cancel
		if not ok then error(err) end
	end)
end)

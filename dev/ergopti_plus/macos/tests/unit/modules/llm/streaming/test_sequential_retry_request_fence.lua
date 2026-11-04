--- tests/unit/modules/llm/streaming/test_sequential_retry_request_fence.lua

--- ==============================================================================
--- MODULE: Sequential LLM Retry Request Fence Regression
--- DESCRIPTION:
--- Proves that every backend revalidates the request identity immediately before
--- dispatching a failed variant's retry or publishing its completed predictions.
--- A superseded chain must neither consume another inference nor publish a late
--- result after the engine advanced to a newer request.
--- ==============================================================================

local helpers = require("tests.helpers")

local function set_upvalue(fn, target, value)
	for index = 1, 80 do
		local name = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then
			debug.setupvalue(fn, index, value)
			return true
		end
	end
	return false
end

local api_common = {
	DEFAULT_TEMPERATURE = 0.5,
	new_dedup_stats = function() return {} end,
	get_diversity_temperature = function(base) return base end,
	insert_prediction = function(results, prediction)
		results[#results + 1] = prediction
		return true
	end,
	log_prediction_summary = function() end,
	protected_call = function(callback, _label, ...)
		if type(callback) == "function" then return callback(...) end
	end,
}

local profiles = {
	resolve_system_prompt = function() return "fixture system prompt" end,
}

local scheduler = {
	now = function() return 0 end,
}

local CASES = {
	{
		name = "Ollama",
		module_name = "modules.llm.api_ollama",
		configure = function(module, post)
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "post_and_parse", post))
			helpers.assert_true(set_upvalue(fetch, "post_and_parse_streaming", post))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_ENABLED", true))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_MAX_MULTIPLIER", 2))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_EXTRA_TOKENS", 5))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_TEMP_STEP", 0.1))
		end,
	},
	{
		name = "Remote",
		module_name = "modules.llm.api_remote",
		configure = function(module, post)
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "post_and_parse", post))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION", true))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_MAX_MULT", 2))
			helpers.assert_true(set_upvalue(fetch, "_R_EXTRA_TOKENS", 5))
			helpers.assert_true(set_upvalue(fetch, "_R_TEMP_STEP", 0.1))
		end,
	},
	{
		name = "MLX",
		module_name = "modules.llm.api_mlx_fetch",
		configure = function(module, post)
			module.init({
				post_and_parse = post,
				post_and_parse_streaming = post,
				dedup_enabled = false,
			})
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_ENABLED", true))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_MAX_MULTIPLIER", 2))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_EXTRA_TOKENS", 5))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_TEMP_STEP", 0.1))
		end,
	},
}

helpers.describe("sequential callbacks revalidate request ownership", function()
	for _, case in ipairs(CASES) do
		helpers.it(case.name .. " drops a retry after the request is superseded", function()
			helpers.with_stub_scope({
				case.module_name, "modules.llm.api_common", "modules.llm.profiles",
				"modules.llm.progressive_reveal", "adapters.http_client",
				"adapters.timer_scheduler", "adapters.shell_runner",
			}, function()
				local module = helpers.load_with_stubs(case.module_name)
				local fetch = module.fetch_sequential
				helpers.assert_true(set_upvalue(fetch, "ApiCommon", api_common))
				helpers.assert_true(set_upvalue(fetch, "Profiles", profiles))
				helpers.assert_true(set_upvalue(fetch, "TimerScheduler", scheduler))

				local dispatches = 0
				local failure_callbacks = {}
				local function post(...)
					local args = { ... }
					dispatches = dispatches + 1
					failure_callbacks[#failure_callbacks + 1] = args[10]
				end
				case.configure(module, post)

				local request_id = 41
				local provider_calls = 0
				local function request_id_provider()
					provider_calls = provider_calls + 1
					return request_id
				end

				module.fetch_sequential(
					"full", "tail", "fixture-model", 0.5, 8, 1, {},
					function() end, function() end, request_id_provider, false, nil)
				helpers.assert_eq(dispatches, 1)
				helpers.assert_type(failure_callbacks[1], "function")

				local calls_before_retry = provider_calls
				request_id = 42
				failure_callbacks[1]()

				helpers.assert_true(provider_calls > calls_before_retry,
					"the retry edge must consult the live request identity")
				helpers.assert_eq(dispatches, 1,
					"a superseded chain must not dispatch its retry transport")

				request_id = 43
				module.fetch_sequential(
					"full", "tail", "fixture-model", 0.5, 8, 1, {},
					function() end, function() end, request_id_provider, false, nil)
				helpers.assert_eq(dispatches, 2)
				helpers.assert_type(failure_callbacks[2], "function")
				failure_callbacks[2]()
				helpers.assert_eq(dispatches, 3,
					"a still-current request must retain its bounded retry")
			end)
		end)

		for _, streaming in ipairs({ false, true }) do
			helpers.it(case.name .. " drops a completed variant after supersession with streaming=" .. tostring(streaming)
				.. " (sequential-result-fence)", function()
				helpers.with_stub_scope({
					case.module_name, "modules.llm.api_common", "modules.llm.profiles",
					"modules.llm.progressive_reveal", "adapters.http_client",
					"adapters.timer_scheduler", "adapters.shell_runner",
				}, function()
					local module = helpers.load_with_stubs(case.module_name)
					local fetch = module.fetch_sequential
					helpers.assert_true(set_upvalue(fetch, "ApiCommon", api_common))
					helpers.assert_true(set_upvalue(fetch, "Profiles", profiles))
					helpers.assert_true(set_upvalue(fetch, "TimerScheduler", scheduler))

					local dispatches, publications = 0, 0
					local success_callbacks = {}
					case.configure(module, function(...)
						local args = { ... }
						dispatches = dispatches + 1
						success_callbacks[#success_callbacks + 1] = args[9]
					end)
					local request_id = 41
					local function request_id_provider() return request_id end
					local function on_success() publications = publications + 1 end
					module.fetch_sequential("full", "tail", "fixture-model", 0.5, 8, 1, {},
						on_success, function() end, request_id_provider, streaming, nil)
					helpers.assert_eq(dispatches, 1)
					helpers.assert_type(success_callbacks[1], "function")

					request_id = 42
					success_callbacks[1]({ { text = "abandoned prediction" } })
					helpers.assert_eq(publications, 0,
						"a completed stale variant must not publish before the next-dispatch fence")
					helpers.assert_eq(dispatches, 1, "a stale result must not continue its chain")

					module.fetch_sequential("full", "tail", "fixture-model", 0.5, 8, 1, {},
						on_success, function() end, request_id_provider, streaming, nil)
					success_callbacks[2]({ { text = "current prediction" } })
					helpers.assert_eq(publications, 2, "a current variant publishes progress and its final result")
					helpers.assert_eq(dispatches, 2, "a successful current variant needs no retry")
				end)
			end)
		end
	end
end)

--- tests/unit/modules/llm/test_sequential_retry_request_fence.lua

--- ==============================================================================
--- MODULE: Sequential LLM Retry Request Fence Regression
--- DESCRIPTION:
--- Proves that every backend revalidates the request identity immediately before
--- dispatching a failed variant's retry. A superseded chain must not consume local
--- GPU time or a paid remote request merely because its first transport callback
--- arrived after the engine advanced to a newer request.
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
	insert_prediction = function() return true end,
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

helpers.describe("sequential retry dispatch revalidates request ownership", function()
	for _, case in ipairs(CASES) do
		helpers.it(case.name .. " drops a retry after the request is superseded", function()
			helpers.with_fresh_modules({ case.module_name }, function()
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
	end
end)

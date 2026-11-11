--- tests/unit/modules/llm/streaming/test_sequential_stream_identity.lua

--- ==============================================================================
--- MODULE: Sequential Stream Identity Regression
--- DESCRIPTION:
--- A sequential local request runs one independent completion per variant. The
--- streaming handler's thinking filter demands that each snapshot extend the
--- previous one, which holds inside one stream only. Sharing it across variants
--- froze token display after the first one, with a cumulative-prefix warning
--- (HS-003 / ML-001). Backends now bind each stream to its own identity, the
--- handler restarts its filter at that boundary only, and a retry does not
--- stream, as the backends always documented.
--- ==============================================================================

local helpers = require("tests.helpers")
local SharedParser = require("llm.parser")





-- ===================================
-- ===================================
-- ======= 1/ Fixture Builders =======
-- ===================================
-- ===================================

--- Replaces one named upvalue of a function.
--- @param fn function Function owning the upvalue.
--- @param target string Upvalue name.
--- @param value any Replacement value.
--- @return boolean replaced
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

local API_COMMON = {
	DEFAULT_TEMPERATURE = 0.5,
	new_dedup_stats = function() return {} end,
	get_diversity_temperature = function(base) return base end,
	insert_prediction = function(results, prediction)
		results[#results + 1] = prediction
		return true
	end,
	log_prediction_summary = function() end,
	is_authentication_failure = function(failure)
		return require("llm.failure_class").is_authentication_failure(failure)
	end,
	protected_call = function(callback, _label, ...)
		if type(callback) == "function" then return callback(...) end
	end,
}

local BACKENDS = {
	{
		name = "Ollama",
		module_name = "modules.llm.api_ollama",
		configure = function(module, plain, stream)
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "post_and_parse", plain))
			helpers.assert_true(set_upvalue(fetch, "post_and_parse_streaming", stream))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_ENABLED", true))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_MAX_MULTIPLIER", 2))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_EXTRA_TOKENS", 5))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_TEMP_STEP", 0.1))
		end,
	},
	{
		name = "MLX",
		module_name = "modules.llm.api_mlx_fetch",
		configure = function(module, plain, stream)
			module.init({ post_and_parse = plain, post_and_parse_streaming = stream, dedup_enabled = false })
			local fetch = module.fetch_sequential
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_ENABLED", true))
			helpers.assert_true(set_upvalue(fetch, "RETRY_FAILED_PREDICTION_MAX_MULTIPLIER", 2))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_EXTRA_TOKENS", 5))
			helpers.assert_true(set_upvalue(fetch, "_RETRY_TEMP_STEP", 0.1))
		end,
	},
}

--- Runs one sequential fetch over recording transports.
--- @param backend table BACKENDS entry.
--- @param requested number Number of predictions requested.
--- @param fail_first boolean True to fail the first dispatch after its partial.
--- @return table dispatches Ordered { kind, raw } records.
--- @return table partials Ordered { raw, identity } records seen by the handler port.
local function run_backend(backend, requested, fail_first)
	local dispatches, partials = {}, {}
	helpers.with_stub_scope({
		backend.module_name, "modules.llm.api_common", "modules.llm.profiles",
		"modules.llm.progressive_reveal", "adapters.http_client",
		"adapters.timer_scheduler", "adapters.shell_runner",
	}, function()
		local module = helpers.load_with_stubs(backend.module_name)
		local fetch = module.fetch_sequential
		helpers.assert_true(set_upvalue(fetch, "ApiCommon", API_COMMON))
		helpers.assert_true(set_upvalue(fetch, "Profiles",
			{ resolve_system_prompt = function() return "system" end }))
		helpers.assert_true(set_upvalue(fetch, "TimerScheduler", { now = function() return 0 end }))
		local function post(kind, ...)
			local args = { ... }
			local raw = "completion " .. tostring(#dispatches + 1)
			dispatches[#dispatches + 1] = { kind = kind, has_partial = type(args[12]) == "function" }
			if type(args[12]) == "function" then args[12](raw) end
			if fail_first and #dispatches == 1 then args[10](); return end
			args[9]({ { to_type = raw } })
		end
		backend.configure(module,
			function(...) return post("plain", ...) end,
			function(...) return post("stream", ...) end)
		module.fetch_sequential("full", "tail", "model", 0.5, 20, requested, {},
			function() end, function() end, function() return 1 end, true,
			function(raw, identity) partials[#partials + 1] = { raw = raw, identity = identity } end)
	end)
	return dispatches, partials
end

--- Builds the real streaming handler's partial callback over recording UI ports.
--- @return function partial The handler's on_partial callback.
--- @return table renders Ordered interim render texts.
--- @return table warnings Logged warnings.
local function build_handler()
	local renders, warnings = {}, {}
	local partial
	helpers.with_stub_scope({ "modules.llm.parser", "modules.llm.streaming_handler", "infra.logger" }, function()
		package.loaded["modules.llm.parser"] = {
			new_thinking_filter = SharedParser.new_thinking_filter,
			process_prediction = function(_, _, raw) return { to_type = raw, deletes = 0, chunks = {}, nw = raw } end,
		}
		local Handler = helpers.load_with_stubs("modules.llm.streaming_handler", {
			application = { frontmostApplication = function()
				return { title = function() return "Fixture" end }
			end },
		})
		package.loaded["infra.logger"].warn = function(_, fmt, ...)
			warnings[#warnings + 1] = string.format(fmt, ...)
		end
		local tooltip = {
			show_predictions = function(preds, _, _, _, _, _, _, _, loading)
				if loading == "…" then renders[#renders + 1] = preds[#preds].to_type end
				return true
			end,
			get_current_index = function() return 1 end,
			make_diff_styled = function() return true end,
			tint = function() return {} end,
			mark_chain_complete = function() return true end,
		}
		helpers.assert_true(Handler.init({
			core_llm = { get_active_profile = function() return {} end, get_current_model = function() return "m" end },
			tooltip = tooltip,
			keystats = { log_llm = function() end, log_llm_suggested = function() end },
		}))
		partial = Handler.build_callbacks({
			buffer = "context", tail = "", my_fetch_id = 1, get_fetch_id = function() return 1 end,
			is_streaming_enabled = true, is_streaming_multi_enabled = true, num_predictions = 2,
			show_info_bar = false, prediction_indent = 0, validation_mods = { "none" },
			navigation_mods = {}, model_to_use = "m", llm_display_name = "m",
			is_noise_pred = function() return false end,
			reset_llm_dismiss_timer = function() return true end,
			pending_predictions_ref = { value = {} }, predictions_visible_ref = { value = false },
			is_ai_preview_enabled = true,
		})
	end)
	helpers.assert_eq(type(partial), "function", "streaming multi must build a partial callback")
	return partial, renders, warnings
end





-- ========================================
-- ========================================
-- ======= 2/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("sequential stream identity", function()
	for _, backend in ipairs(BACKENDS) do
		helpers.it("(sequential-stream-identity) " .. backend.name .. " gives each variant its own stream", function()
			local dispatches, partials = run_backend(backend, 2, false)
			helpers.assert_eq(#dispatches, 2)
			helpers.assert_eq(#partials, 2)
			helpers.assert_true(partials[1].identity ~= nil and partials[2].identity ~= nil,
				"each independent completion must name its stream")
			helpers.assert_true(partials[1].identity ~= partials[2].identity,
				"two variants are two streams; one identity poisons the cumulative filter")
		end)

		helpers.it("(sequential-stream-identity) " .. backend.name .. " retries without streaming", function()
			local dispatches, partials = run_backend(backend, 1, true)
			helpers.assert_eq(#dispatches, 2)
			helpers.assert_eq(dispatches[1].kind, "stream")
			helpers.assert_eq(dispatches[2].kind, "plain",
				"a retry would overwrite the growing preview with an unrelated completion")
			helpers.assert_eq(dispatches[2].has_partial, false)
			-- The failed stream is withdrawn before its retry (stream-retry-withdraw).
			helpers.assert_eq(#partials, 2)
			helpers.assert_eq(partials[2].raw, false)
			helpers.assert_true(partials[2].identity == partials[1].identity, "the failed stream itself is withdrawn")
		end)
	end

	helpers.it("(sequential-stream-identity) handler renders every independent stream", function()
		local partial, renders, warnings = build_handler()
		partial("first independent completion", {})
		partial("second independent completion", {})
		helpers.assert_eq(#warnings, 0, table.concat(warnings, "; "))
		helpers.assert_eq(#renders, 2, "the second variant must keep filling token by token")
		helpers.assert_eq(renders[2], "second independent completion")
	end)

	helpers.it("(stream-retry-withdraw) handler ignores the withdrawal of a stream it no longer shows", function()
		local partial, renders, warnings = build_handler()
		local first, second = {}, {}
		partial("first independent completion", first)
		partial("second independent completion", second)
		partial(false, first)
		helpers.assert_eq(#renders, 2, "the second stream's rows stay as painted")
		partial("second independent completion grows", second)
		helpers.assert_eq(#renders, 3, "and keep streaming")
		helpers.assert_eq(#warnings, 0, table.concat(warnings, "; "))
	end)

	helpers.it("(sequential-stream-identity) handler still rejects a broken prefix inside one stream", function()
		local partial, renders, warnings = build_handler()
		local stream = {}
		partial("first snapshot", stream)
		partial("first snapshot grows", stream)
		partial("unrelated rewrite", stream)
		helpers.assert_eq(#renders, 2)
		helpers.assert_eq(#warnings, 1)
		helpers.assert_true(warnings[1]:find("cumulative-prefix", 1, true) ~= nil)
	end)
end)

return true

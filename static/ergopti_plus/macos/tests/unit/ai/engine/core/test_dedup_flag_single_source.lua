--- tests/unit/ai/engine/core/test_dedup_flag_single_source.lua

--- ==============================================================================
--- MODULE: Regression — the dedup default must come from one place, not three
--- DESCRIPTION:
--- api_ollama and api_remote both read the deduplication default from ApiCommon,
--- which loads it from the shared _shared/ai/data/inference.json. api_mlx_
--- inference hardcoded `M.DEDUPLICATION_ENABLED = false` instead.
---
--- ROOT CAUSE ENCODED:
--- Flipping the shared flag therefore changed Ollama and remote behaviour while
--- MLX silently kept its own answer — and MLX is the default backend, so the
--- setting appeared to do nothing at all for most users. Its comment even claimed
--- the opposite ("keeping the dedup default in exactly one place"), which is the
--- most misleading kind of wrong: the file states the invariant it breaks.
---
--- The guard is written for the CLASS and by behaviour: each backend is loaded
--- over an ApiCommon whose default is a sentinel, one answer is driven through
--- its prediction parser, and the flag each backend hands to
--- ApiCommon.insert_prediction must be that sentinel. A literal in any backend,
--- at load time or at the call, hands over something else.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

-- Neither true nor false: only a value read from ApiCommon can equal it.
local SENTINEL = setmetatable({}, { __tostring = function() return "ApiCommon default" end })

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

--- Loads a backend over a fresh ApiCommon whose default is SENTINEL and a parser
--- that turns any answer into one prediction, then runs the scenario.
--- @param module_name string Backend module.
--- @param scenario function Receives (backend, flags): flags lists every dedup flag
---        handed to ApiCommon.insert_prediction.
local function with_backend(module_name, scenario)
	helpers.with_stub_scope({ "ai.engine.api.common", "ai.engine.api.parser", module_name }, function()
		local ApiCommon = require("ai.engine.api.common")
		local Parser = require("ai.engine.api.parser")
		ApiCommon.DEFAULT_DEDUPLICATION_ENABLED = SENTINEL
		local flags = {}
		local real_insert = ApiCommon.insert_prediction
		ApiCommon.insert_prediction = function(results, pred, stats, dedup_enabled, ...)
			flags[#flags + 1] = dedup_enabled
			return real_insert(results, pred, stats, dedup_enabled == true, ...)
		end
		Parser.process_prediction = function() return { to_type = "fixture prediction" } end
		scenario(helpers.load_with_stubs(module_name), flags)
	end)
end

--- Asserts that exactly the ApiCommon default reached insert_prediction.
--- @param flags table Flags recorded by with_backend.
--- @param backend string Backend name for the message.
local function assert_shared_flag(flags, backend)
	helpers.assert_true(#flags >= 1, backend .. " must run its answer through insert_prediction")
	for _, flag in ipairs(flags) do
		helpers.assert_true(flag == SENTINEL, string.format(
			"%s handed insert_prediction %s instead of ApiCommon.DEFAULT_DEDUPLICATION_ENABLED: "
			.. "flipping the shared inference.json then changes some backends and not others",
			backend, tostring(flag)))
	end
end





-- ================================================
-- ================================================
-- ======= 1/ Every Backend Reads ApiCommon =======
-- ================================================
-- ================================================

helpers.describe("the deduplication default has a single source", function()
	helpers.it("MLX dedups with the ApiCommon default", function()
		with_backend("ai.engine.api.mlx_inference", function(Inference, flags)
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
			helpers.assert_type(client, "table", "the MLX HTTP owner must be reachable")
			local original_post, original_after, original_cancel = client.post, scheduler.after, scheduler.cancel
			scheduler.after = function() return { timer = {} }, true end
			scheduler.cancel = function() return true end
			local callback
			client.post = function(_, _, _, done) callback = done end
			local ok, err = pcall(function()
				Inference.post_and_parse("fixture", "system", "typed context", "", 0.1, 16, 1, false,
					function() end, function() end, {}, false, nil)
				helpers.assert_type(callback, "function", "the request must be dispatched")
				callback({ status = 200, body = json.encode({ choices = { { text = "answer" } } }) })
			end)
			client.post, scheduler.after, scheduler.cancel = original_post, original_after, original_cancel
			if not ok then error(err, 0) end
			assert_shared_flag(flags, "api_mlx_inference")
		end)
	end)

	helpers.it("Ollama dedups with the ApiCommon default", function()
		with_backend("ai.engine.api.ollama", function(Ollama, flags)
			local post_and_parse = get_upvalue(Ollama.request_raw, "post_and_parse")
			local client = get_upvalue(post_and_parse, "_infer_client")
			helpers.assert_type(client, "table", "the Ollama HTTP owner must be reachable")
			local original_post = client.post
			local callback
			client.post = function(_, _, _, done) callback = done end
			local ok, err = pcall(function()
				post_and_parse("fixture-model", "system", "typed context", "", 0.1, 16, 1, false,
					function() end, function() end, {}, nil, false)
				helpers.assert_type(callback, "function", "the request must be dispatched")
				callback({ status = 200, body = json.encode({ message = { content = "answer" } }) })
			end)
			client.post = original_post
			if not ok then error(err, 0) end
			assert_shared_flag(flags, "api_ollama")
		end)
	end)

	helpers.it("the remote backend dedups with the ApiCommon default", function()
		with_backend("ai.engine.api.remote", function(Remote, flags)
			Remote.PROVIDERS.fixture = {
				label = "Fixture", base_url = "https://default.invalid",
				default_model = "fixture-model", format = "openai",
			}
			local client = get_upvalue(Remote.cancel_streaming, "_infer_client")
			helpers.assert_type(client, "table", "the remote HTTP owner must be reachable")
			local original_post = client.post
			local callback
			client.post = function(_, _, _, done) callback = done end
			local ok, err = pcall(function()
				Remote.set_entries({ { id = "entry", provider = "fixture", base_url = "https://a.invalid",
					token = "plain-token", model = "fixture-model" } })
				Remote.set_active_entry_id("entry")
				Remote.fetch_batch("typed context", "", "fixture-model", 0.1, 16, 1, { batch = false },
					function() end, function() end)
				helpers.assert_type(callback, "function", "the request must be dispatched")
				callback({ ok = true, status = 200, headers = {}, body = json.encode({
					choices = { { index = 0, message = { role = "assistant", content = "answer" } } },
				}) })
			end)
			client.post = original_post
			Remote.PROVIDERS.fixture = nil
			if not ok then error(err, 0) end
			assert_shared_flag(flags, "api_remote")
		end)
	end)
end)

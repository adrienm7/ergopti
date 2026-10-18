--- tests/unit/modules/llm/ollama/test_api_ollama_streaming.lua

--- ==============================================================================
--- MODULE: llm.api_ollama Unit Tests
--- DESCRIPTION:
--- Tests the lightweight, side-effect-free public surface of the Ollama
--- controller: model heuristics (is_thinking_model) and the readiness flag.
--- Warmup ownership also executes against the actual HTTP and timer adapters
--- over controlled native ports; network and native macOS receiving stay separate.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.ollama.api_ollama_fixture"] = nil
local Fixture = require("tests.support.modules.llm.ollama.api_ollama_fixture")
local ApiOllama = Fixture.ApiOllama
local get_upvalue = Fixture.get_upvalue
local set_upvalue = Fixture.set_upvalue
local warmup_upvalue = Fixture.warmup_upvalue
local with_pending_warmup = Fixture.with_pending_warmup





helpers.describe("ApiOllama streaming task ownership", function()
	local streaming_impl = get_upvalue(ApiOllama.fetch_batch, "post_and_parse_streaming")
	local shell_runner = streaming_impl and get_upvalue(streaming_impl, "ShellRunner") or nil

	local function request(on_fail)
		streaming_impl(
			"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
			function() error("unexpected success") end, on_fail, {}, function() end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "throw", start = function() error("STREAM_START_THROW") end },
	}) do
		helpers.it("releases a curl task whose start returns " .. case.name, function()
			helpers.assert_not_nil(streaming_impl, "the test must drive the real streaming function")
			helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
			local original_spawn = shell_runner.spawn
			local spawns, failures, terminations = 0, 0, 0
			shell_runner.spawn = function()
				spawns = spawns + 1
				local settled = case.name == "false"
				return {
					start = case.start,
					terminate = function() terminations = terminations + 1; settled = true; return true, "settled" end,
					isSettled = function() return settled end,
				}
			end

			local ok, err = pcall(function()
				request(function() failures = failures + 1 end)
				helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil)
				request(function() failures = failures + 1 end)
				helpers.assert_eq(spawns, 2, "the next prediction must retry after an uncommitted start")
				helpers.assert_eq(failures, 2)
				if case.name == "throw" then helpers.assert_eq(terminations, 2) end
			end)
			shell_runner.spawn = original_spawn
			if not ok then error(err) end
		end)
	end

	helpers.it("does not republish a task that completes inside start", function()
		helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
		local original_spawn = shell_runner.spawn
		local failures = 0
		shell_runner.spawn = function(_, _, on_done)
			return {
				start = function()
					on_done(0, "", "")
					return true
				end,
				terminate = function() return true, "settled" end,
				isSettled = function() return true end,
			}
		end

		local ok, err = pcall(function()
			request(function() failures = failures + 1 end)
			helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil,
				"completion must revoke ownership before start() returns to the caller")
			helpers.assert_eq(failures, 1)
		end)
		shell_runner.spawn = original_spawn
		if not ok then error(err) end
	end)

	helpers.it("(stream-nonzero-exit) rejects parseable partial output when curl exits nonzero", function()
		helpers.assert_true(set_upvalue(streaming_impl, "_active_stream_task", nil))
		local original_spawn = shell_runner.spawn
		local json_codec = get_upvalue(streaming_impl, "JsonCodec")
		local parser = get_upvalue(streaming_impl, "Parser")
		local original_decode = json_codec.decode
		local original_process = parser.process_prediction
		local successes, failures = 0, 0

		json_codec.decode = function()
			return { message = { content = "would-have-been-published" } }
		end
		parser.process_prediction = function(_, _, raw) return raw end
		shell_runner.spawn = function(_, _, on_done)
			return {
				start = function()
					on_done(28, "{}\n", "Operation timed out")
					return true
				end,
				terminate = function() return true, "settled" end,
				isSettled = function() return true end,
			}
		end

		local ok, err = pcall(function()
			streaming_impl(
				"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() successes = successes + 1 end,
				function() failures = failures + 1 end, {}, function() end)
			helpers.assert_eq(successes, 0,
				"curl timeout output is partial transport data, never a prediction")
			helpers.assert_eq(failures, 1)
			helpers.assert_eq(get_upvalue(streaming_impl, "_active_stream_task"), nil)
		end)
		shell_runner.spawn = original_spawn
		json_codec.decode = original_decode
		parser.process_prediction = original_process
		if not ok then error(err) end
	end)
end)


helpers.describe("ApiOllama non-streaming decode contract", function()
	local post_and_parse = get_upvalue(ApiOllama.fetch_batch, "post_and_parse")
	local infer_client = post_and_parse and get_upvalue(post_and_parse, "_infer_client") or nil
	local json_codec = post_and_parse and get_upvalue(post_and_parse, "JsonCodec") or nil
	local logger = post_and_parse and get_upvalue(post_and_parse, "Logger") or nil

	helpers.it("classifies a successful top-level null as an invalid response", function()
		helpers.assert_not_nil(post_and_parse,
			"the regression must drive the production non-streaming parser")
		helpers.assert_not_nil(infer_client)
		helpers.assert_not_nil(json_codec)
		helpers.assert_not_nil(logger)

		local original_post = infer_client.post
		local original_encode = json_codec.encode
		local original_decode = json_codec.decode
		local original_error = logger.error
		local logs = {}
		local successes, failures = 0, 0

		infer_client.post = function(_, _, _, callback)
			callback({ status = 200, body = "null" })
		end
		json_codec.encode = function() return "{}", nil end
		json_codec.decode = function() return nil, nil end
		logger.error = function(_, format_string, ...)
			logs[#logs + 1] = string.format(format_string, ...)
		end

		local ok, err = xpcall(function()
			post_and_parse(
				"fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() successes = successes + 1 end,
				function() failures = failures + 1 end, {})
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(failures, 1)
			local response_invalid, decode_error = 0, 0
			for _, message in ipairs(logs) do
				if message:find("RESPONSE_INVALID", 1, true) then
					response_invalid = response_invalid + 1
				end
				if message:find("JSON_DECODE_ERROR", 1, true) then
					decode_error = decode_error + 1
				end
			end
			helpers.assert_eq(response_invalid, 1,
				"a successful JSON null must reach schema validation exactly once")
			helpers.assert_eq(decode_error, 0,
				"a successful JSON null must not be reported as a decode failure")
		end, debug.traceback)

		infer_client.post = original_post
		json_codec.encode = original_encode
		json_codec.decode = original_decode
		logger.error = original_error
		if not ok then error(err) end
	end)
end)





--- ======================================
--- ======================================
--- ======= 5/ get_base_url (port) =======
--- ======================================
--- ======================================

helpers.describe("ApiOllama.get_base_url (configurable port)", function()
	helpers.it("exposes get_base_url as a function", function()
		helpers.assert_eq(type(ApiOllama.get_base_url), "function")
	end)

	-- With no user override set, the port comes from the single source
	-- (_shared/modules/llm/defaults.json llm_ollama_port = 11434, via DEFAULT_STATE) — not
	-- from a URL hardcoded at each call site. A regression that re-hardcodes a
	-- different port, or drops the llm_ollama_port default, fails here.
	helpers.it("defaults to the canonical loopback URL on port 11434", function()
		helpers.assert_eq(ApiOllama.get_base_url(), "http://127.0.0.1:11434")
	end)

	helpers.it("builds a well-formed loopback http URL", function()
		helpers.assert_true(
			ApiOllama.get_base_url():match("^http://127%.0%.0%.1:%d+$") ~= nil,
			"base url must be http://127.0.0.1:<port>")
	end)
end)


helpers.describe("ApiOllama strict local model listing", function()
	local client = get_upvalue(ApiOllama.request_chat, "_vision_client")

	local function request_with_receipt(receipt)
		local original_get, original_post = client.get, client.post
		local gets, posts, failures, successes = {}, {}, {}, {}
		client.get = function(url, _, callback)
			gets[#gets + 1] = url
			callback(receipt)
		end
		client.post = function(url, _, _, callback)
			posts[#posts + 1] = url
			callback({ status = 200, body = '{"message":{"content":"admitted answer"}}' })
		end
		ApiOllama.forget_local_models()
		local ok, err = xpcall(function()
			ApiOllama.request_chat({ model = "qwen2.5:7b", messages = {} },
				function(text) successes[#successes + 1] = text end,
				function(reason) failures[#failures + 1] = reason end)
		end, debug.traceback)
		local installed = ApiOllama.local_model_installed("qwen2.5:7b")
		client.get, client.post = original_get, original_post
		ApiOllama.forget_local_models()
		if not ok then error(err, 0) end
		return { gets = gets, posts = posts, failures = failures, successes = successes, installed = installed }
	end

	for _, body in ipairs({ '{"models":{}}', '{"models":[{}]}', '{"models":["qwen2.5:7b"]}', '[]', 'not JSON' }) do
		helpers.it("refuses unreadable inventory before chat or a missing-model offer: " .. body, function()
			local seen = request_with_receipt({ status = 200, body = body })
			helpers.assert_eq(#seen.gets, 1)
			helpers.assert_true(seen.gets[1]:match("/api/tags$") ~= nil)
			helpers.assert_eq(#seen.posts, 0, "private chat bytes need a valid inventory receipt")
			helpers.assert_eq(#seen.successes, 0)
			helpers.assert_eq(#seen.failures, 1, "a refused inventory settles the actual request once")
			helpers.assert_eq(seen.failures[1], "unreadable_model_list", "unknown inventory is never a missing model")
			helpers.assert_eq(seen.installed, nil, "an unreadable receipt cannot publish an empty installation cache")
		end)
	end

	helpers.it("keeps a failed tags endpoint distinct from a known empty inventory", function()
		local failed = request_with_receipt({ status = 404, body = '{"models":[]}' })
		helpers.assert_eq(#failed.posts, 0)
		helpers.assert_eq(#failed.failures, 1)
		helpers.assert_eq(failed.failures[1], "http_404")
		helpers.assert_eq(failed.installed, nil)
		local empty = request_with_receipt({ status = 200, body = '{"models":[]}' })
		helpers.assert_eq(#empty.posts, 0)
		helpers.assert_eq(#empty.failures, 1)
		helpers.assert_eq(empty.failures[1], ApiOllama.MODEL_MISSING)
		helpers.assert_eq(empty.installed, false)
	end)

	helpers.it("admits the requested model from either authoritative name field", function()
		for _, body in ipairs({
			'{"models":[{"name":"QWEN2.5:7B"}]}',
			'{"models":[{"model":"qwen2.5:7b"}]}',
		}) do
			local seen = request_with_receipt({ status = 200, body = body })
			helpers.assert_eq(#seen.gets, 1)
			helpers.assert_eq(#seen.posts, 1)
			helpers.assert_true(seen.posts[1]:match("/api/chat$") ~= nil)
			helpers.assert_eq(#seen.failures, 0)
			helpers.assert_eq(#seen.successes, 1)
			helpers.assert_eq(seen.successes[1], "admitted answer")
			helpers.assert_eq(seen.installed, true)
		end
	end)
end)




helpers.describe("Ollama pending warmup retry ownership", function()
	helpers.it("warmup-inflight-retry: retains one pending POST and its original timeout", function()
		with_pending_warmup(function(api, fixture, client)
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_eq(#fixture.requests, 1)
			helpers.assert_eq(#fixture.timers, 1)
			local original_timer = fixture.timers[1]
			local original_delay = original_timer.delay
			helpers.assert_true(client.isActive())
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_eq(#fixture.requests, 1,
				"ordinary repeated warmup must not replace the pending native POST")
			helpers.assert_eq(#fixture.timers, 1, "retry must not rearm the absolute request timeout")
			helpers.assert_eq(original_timer.delay, original_delay)
			helpers.assert_eq(original_timer.stops, 0)
			fixture.requests[1].done(200, "{}", {})
			helpers.assert_true(api.is_ready(), "the retained original response must still establish readiness")
			helpers.assert_eq(client.isActive(), false)
		end)
	end)

	helpers.it("warmup-inflight-retry: terminal failure permits a genuine next POST", function()
		with_pending_warmup(function(api, fixture)
			helpers.assert_true(api.warmup("retained-model"))
			fixture.requests[1].done(500, "{}", {})
			helpers.assert_eq(api.is_ready(), false)
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_eq(#fixture.requests, 2)
			fixture.requests[2].done(200, "{}", {})
			helpers.assert_true(api.is_ready())
		end)
	end)

	helpers.it("warmup-inflight-retry: source replacement cannot reuse the old POST", function()
		with_pending_warmup(function(api, fixture)
			helpers.assert_true(api.warmup("retained-model"))
			fixture.origin = "http://localhost:16108"
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_eq(#fixture.requests, 2)
			fixture.requests[1].done(200, "{}", {})
			helpers.assert_eq(api.is_ready(), false)
			fixture.requests[2].done(200, "{}", {})
			helpers.assert_true(api.is_ready())
		end)
	end)

	helpers.it("warmup-inflight-retry: model replacement cannot reuse the old POST", function()
		with_pending_warmup(function(api, fixture)
			helpers.assert_true(api.warmup("retained-model"))
			helpers.assert_true(api.warmup("replacement-model"))
			helpers.assert_eq(#fixture.requests, 2)
			fixture.requests[1].done(200, "{}", {})
			helpers.assert_eq(api.is_ready(), false)
			fixture.requests[2].done(200, "{}", {})
			helpers.assert_true(api.is_ready())
		end)
	end)

	helpers.it("warmup-inflight-retry: explicit acquisition is never reported by reuse", function()
		with_pending_warmup(function(api, fixture)
			helpers.assert_true(api.warmup("retained-model"))
			local acquired = 0
			helpers.assert_true(api.warmup("retained-model", function(committed)
				helpers.assert_true(committed)
				acquired = acquired + 1
			end))
			helpers.assert_eq(#fixture.requests, 2, "explicit acquisition must own its fresh native POST")
			helpers.assert_eq(acquired, 1)
		end)
	end)
end)

helpers.describe("Ollama warmup acquisition reentry", function()
	helpers.it("warmup-inflight-retry: stop during timeout start cannot claim settlement", function()
		with_pending_warmup(function(api, fixture, client)
			local stopped
			fixture.on_start = function()
				fixture.on_start = nil
				stopped = api.stop_warmup()
			end
			local accepted = api.warmup("retained-model")
			print("OBSERVED stop_during_acquisition=" .. tostring(stopped)
				.. " warmup=" .. tostring(accepted) .. " client_active=" .. tostring(client.isActive()))
			helpers.assert_eq(stopped, false,
				"an on-stack POST acquisition cannot be reported as settled")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(client.isActive(), false,
				"the stale original acquisition must roll its own HTTP owner back")
			helpers.assert_true(client.isSettled())
		end)
	end)
end)

helpers.describe("Ollama pending retry core composition", function()
	helpers.it("warmup-inflight-retry: real controller and core retain pending backoff", function()
		with_pending_warmup(function(api, fixture)
			package.loaded["modules.llm"] = nil
			package.loaded["modules.llm.warmup_controller"] = nil
			local core = require("modules.llm")
			local controller = require("modules.llm.warmup_controller")
			local scheduler = require("adapters.timer_scheduler")
			local state = warmup_upvalue(core.configuration_idle, "CoreState")
			fixture.finalize = function()
				helpers.assert_true(controller.stop(), "the exact controller timer must retire")
				helpers.assert_true(core.set_runtime_llm_enabled(false))
				for _, key in ipairs({ "api_entries_load_timer", "background_bootstrap_timer" }) do
					local owner = state[key]
					local handle = key == "api_entries_load_timer" and owner and owner.handle or owner
					if handle ~= nil then
						helpers.assert_true(scheduler.cancel(handle), "the exact core bootstrap timer must retire")
						if key == "api_entries_load_timer" then owner.committed = false end
						state[key] = nil
					end
				end
			end
			helpers.assert_true(core.set_runtime_llm_enabled(false))
			helpers.assert_true(core.set_backend("ollama"))
			helpers.assert_true(core.set_llm_model_ollama("retained-model"))
			helpers.assert_true(core.set_runtime_llm_enabled(true))
			helpers.assert_true(controller.init({ core_llm = core, get_llm_enabled = core.get_runtime_llm_enabled }))
			local function current_timer()
				local handle = warmup_upvalue(controller.schedule_warmup_with_retry, "_warmup_timer")
				helpers.assert_eq(type(handle), "table")
				helpers.assert_eq(type(handle.timer), "table")
				return handle.timer
			end
			local function deliver()
				local timer = current_timer()
				helpers.assert_true(timer.active, "only the exact currently armed controller timer may deliver")
				timer.done()
				helpers.assert_eq(timer.active, false)
			end
			helpers.assert_true(controller.schedule_warmup_with_retry("controlled pending receiving"))
			deliver()
			helpers.assert_eq(#fixture.requests, 1)
			local original_retry = current_timer()
			local original_delay = original_retry.delay
			local client = warmup_upvalue(api.warmup, "_warmup_client")
			local timeout_handle = warmup_upvalue(warmup_upvalue(client.isSettled, "_fully_settled"), "_timeout_timer")
			helpers.assert_eq(type(timeout_handle), "table")
			local original_timeout = timeout_handle.timer
			for _ = 1, 2 do
				deliver()
				helpers.assert_eq(#fixture.requests, 1, "the composed retry must keep one original POST")
				helpers.assert_eq(current_timer().delay, original_delay,
					"pending observation must cross the real core without consuming backoff")
				helpers.assert_eq(original_timeout.stops, 0)
			end
			fixture.requests[1].done(500, "{}", {})
			helpers.assert_eq(api.is_ready(), false)
			deliver()
			helpers.assert_eq(#fixture.requests, 2, "a completed failure must permit the next actual POST")
			helpers.assert_true(current_timer().delay > original_delay)
		end)
	end)
end)

helpers.describe("Ollama synchronous warmup observers", function()
	for _, withdrawal in ipairs({ "stop", "reset", "origin" }) do
		helpers.it("warmup-inflight-retry: synchronous notification revokes " .. withdrawal, function()
			with_pending_warmup(function(api, fixture, client)
				fixture.synchronous = 200
				fixture.on_notify = function()
					if withdrawal == "stop" then api.stop_warmup()
					elseif withdrawal == "reset" then api.reset_ready()
					else fixture.origin = "http://localhost:16108" end
				end
				local reports, committed = 0, nil
				local accepted, acquired = api.warmup("retained-model", function(value)
					reports, committed = reports + 1, value
				end)
				helpers.assert_eq(accepted, false, "withdrawn POST cannot report acquisition")
				helpers.assert_eq(acquired, false)
				helpers.assert_eq(reports, 1)
				helpers.assert_eq(committed, false)
				helpers.assert_true(client.isSettled())
			end)
		end)
	end
	helpers.it("warmup-inflight-retry: failed finalizer still restores and retires", function()
		local restored, settled = false, false
		local ok, err = pcall(function()
			with_pending_warmup(function(api, fixture, client)
				helpers.assert_true(api.warmup("retained-model"))
				fixture.finalize = function() error("deliberate finalizer failure") end
				fixture.after_cleanup = function(notify_restored)
					restored, settled = notify_restored, client.isSettled()
				end
			end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("deliberate finalizer failure", 1, true) ~= nil)
		helpers.assert_true(restored)
		helpers.assert_true(settled)
	end)
end)

helpers.describe("Ollama pending observation currency", function()
	helpers.it("warmup-inflight-retry: final origin observer can complete the retained request", function()
		with_pending_warmup(function(api, fixture, client)
			helpers.assert_true(api.warmup("retained-model"))
			local reads = 0
			fixture.on_origin_read = function()
				reads = reads + 1
				if reads == 3 then
					fixture.on_origin_read = nil
					fixture.requests[1].done(500, "{}", {})
				end
			end
			local accepted, acquired = api.warmup("retained-model")
			helpers.assert_eq(reads, 3, "the controlled final origin getter must really deliver")
			helpers.assert_eq(client.isActive(), false)
			helpers.assert_eq(accepted, false, "a completed request is no longer a pending observation")
			helpers.assert_eq(acquired, false)
			helpers.assert_eq(#fixture.requests, 1)
		end)
	end)
end)

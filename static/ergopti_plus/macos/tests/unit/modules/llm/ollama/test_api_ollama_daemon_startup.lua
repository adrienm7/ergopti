--- tests/unit/modules/llm/ollama/test_api_ollama_daemon_startup.lua

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





helpers.describe("ApiOllama daemon startup ownership", function()
	-- R15 has one foreground owner, not a stale-process kill and launch timer.
	-- Keep the original refusal families while using the real API, daemon adapter,
	-- shared receiver/lifecycle and ShellRunner over controlled native task ports.
	local function with_startup(starts, callback)
		helpers.with_stub_scope({
			"modules.llm.api_ollama", "adapters.managed_ollama_daemon", "adapters.shell_runner",
			"core.llm.managed_ollama_daemon_receipt", "core.llm.managed_ollama_daemon_lifecycle",
			"modules.llm.ollama_binary", "modules.llm.ollama_server_command",
			"adapters.http_client", "adapters.timer_scheduler", "adapters.json_codec",
			"modules.llm.api_common", "modules.llm.parser", "modules.llm.profiles",
			"modules.llm.progressive_reveal", "infra.logger", "infra.notifications", "infra.i18n",
			"modules.shortcuts.script_control", "modules.llm.prediction_engine",
		}, function()
			local fixture = { tasks = {}, paused = false, nonce_index = 0 }
			local nonces = { "0000000000000000000000000000f001", "0000000000000000000000000000f002" }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = { notify = function() return true end }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["adapters.http_client"] = { new = function()
				return { cancel = function() return true end, isActive = function() return false end,
					isSettled = function() return true end }
			end }
			package.loaded["adapters.timer_scheduler"] = {
				after = function() error("foreground startup must not acquire a launch timer") end,
				cancel = function() return true end,
			}
			package.loaded["adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama", nil, "native_managed" end,
			}
			-- Command/source admission has separate tests. This boundary supplies an
			-- independent fixed command and explicitly binds native kind and nonce.
			package.loaded["modules.llm.ollama_server_command"] = { build = function(path, _, _, kind, nonce)
				helpers.assert_eq(path, "/fixture/ollama")
				helpers.assert_eq(kind, "native_managed")
				helpers.assert_eq(nonce, nonces[fixture.nonce_index])
				return "exec /fixture/native-owner --owned-stdin"
			end }
			package.loaded["modules.llm.parser"] = {}
			package.loaded["modules.llm.profiles"] = {}
			package.loaded["modules.llm.progressive_reveal"] = {}
			package.loaded["modules.llm.api_common"] = { DEFAULT_DEDUPLICATION_ENABLED = true,
				OLLAMA_KEEP_ALIVE = "5m", get_retry_policy = function() return 1, 0, 0 end }
			package.loaded["modules.shortcuts.script_control"] = {
				is_paused = function() return fixture.paused end, get_pause_epoch = function() return 1 end,
			}
			local api = helpers.load_with_stubs("modules.llm.api_ollama", {
				host = { uuid = function()
					fixture.nonce_index = fixture.nonce_index + 1
					local nonce = nonces[fixture.nonce_index]
					helpers.assert_not_nil(nonce, "only the declared original and successor are admitted")
					return nonce:sub(1, 8) .. "-" .. nonce:sub(9, 12) .. "-" .. nonce:sub(13, 16)
						.. "-" .. nonce:sub(17, 20) .. "-" .. nonce:sub(21, 32)
				end },
				task = { new = function(executable, done, chunk, args)
					helpers.assert_eq(executable, "/bin/sh")
					helpers.assert_eq(args[1], "-c")
					helpers.assert_eq(args[2], "exec /fixture/native-owner --owned-stdin")
					helpers.assert_eq(type(chunk), "function", "the same native task must receive retirement frames")
					local index = #fixture.tasks + 1
					local task = { input_closes = 0, start_calls = 0, completed = false,
						running = false, nonce = nonces[fixture.nonce_index] }
					function task:start()
						self.start_calls = self.start_calls + 1
						self.running = true
						local result = true
						if starts[index] then result = starts[index]() end
						if result ~= true then self.running = false end
						return result
					end
					function task:closeInput() self.input_closes = self.input_closes + 1; return true end
					function task:terminate() error("owned protocol cancellation must use original stdin EOF") end
					function task:isRunning() return self.running end
					function task.frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. task.nonce .. " " .. role .. "\n" end
					function task.emit(bytes) return chunk(task, bytes, "") end
					function task.complete(status, remainder)
						task.running, task.completed = false, true
						return done(status, remainder or "", "")
					end
					fixture.tasks[index] = task
					return task
				end },
			})
			local shell = require("adapters.shell_runner")
			fixture.shell = shell
			local ok, err = xpcall(function() callback(api, fixture) end, debug.traceback)
			-- Retire controlled native objects even when an assertion fails; scoped
			-- module restoration must not silently replace an uncompleted task.
			for _, task in ipairs(fixture.tasks) do
				if not task.completed then task.complete(78, task.frame("RETIRED 78")) end
			end
			if not ok then error(err, 0) end
		end)
	end

	-- Real API, shared inventory parser, native lifecycle and ShellRunner; only
	-- native HTTP, JSON and timer boundaries are controlled in this cohort.
	local function with_owned_responses(callback)
		with_startup({}, function(api, fixture)
			fixture.gets, fixture.posts, fixture.logs = {}, {}, {}
			local client = get_upvalue(api.request_chat, "_vision_client")
			local listing = get_upvalue(api.refresh_local_models, "_listing_client")
			local function get(url, _, done)
				fixture.gets[#fixture.gets + 1] = { url = url, done = done }
			end
			client.get, listing.get = get, get
			client.post = function(url, _, body, done)
				fixture.posts[#fixture.posts + 1] = { url = url, body = body, done = done }
			end
			local json = require("json")
			fixture.codec = package.loaded["adapters.json_codec"]
			fixture.codec.encode, fixture.codec.decode = json.encode, json.decode
			package.loaded["adapters.timer_scheduler"].now = function() return 1 end
			package.loaded["modules.llm.parser"].strip_thinking = require("llm.parser").strip_thinking
			package.loaded["modules.llm.api_common"].protected_call = function(fn, _, ...)
				return package.loaded["infra.logger"].callback("fixture", "request callback", fn, ...)
			end
			fixture.logger = package.loaded["infra.logger"]
			for _, kind in ipairs({ "info", "warn", "error" }) do
				fixture.logger[kind] = function(_, text, ...)
					fixture.logs[#fixture.logs + 1] = { kind = kind, text = string.format(text, ...) }
				end
			end
			helpers.assert_true(api.ensure_running())
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			local origin = api.get_base_url()
			function fixture.replace_service()
				helpers.assert_eq(api.stop_owned_server(), false)
				original.complete(0, original.frame("RETIRED 0"))
				helpers.assert_true(api.ensure_running())
				local successor = fixture.tasks[2]
				successor.emit(successor.frame("ACTIVE") .. successor.frame("READY"))
				helpers.assert_eq(api.get_base_url(), origin, "the concrete replacement retains the same URL")
				helpers.assert_true(original.completed)
				helpers.assert_true(successor.running)
			end
			function fixture.request()
				local result = { texts = {}, failures = {} }
				api.request_chat({ model = "qwen2.5:7b", messages = {} },
					function(text) result.texts[#result.texts + 1] = text end,
					function(reason, detail) result.failures[#result.failures + 1] = { reason = reason, detail = detail } end)
				return result
			end
			function fixture.tags(index, names)
				fixture.gets[index].done({ status = 200, body = #names == 0 and '{"models":[]}' or json.encode({ models = names }) })
			end
			callback(api, fixture)
		end)
	end

	-- The original daemon predicate remains the genuine lexical service fence.
	-- Only endpoint reads and the requester callback are instrumented here.
	local function with_reentrant_requester(boundary, outcome, scenario)
		with_owned_responses(function(api, fixture)
			helpers.with_fresh_modules({ "modules.llm.local_model_offer", "infra.dialog_util",
				"infra.notifications", "infra.i18n" }, function()
				local world = { dialogs = 0, notices = 0, installs = 0, replaced = false }
				package.loaded["infra.i18n"] = { get = function(key) return key end,
					format = function(key) return key end }
				package.loaded["infra.dialog_util"] = { block_alert = function(_, _, first)
					world.dialogs = world.dialogs + 1; return first
				end }
				package.loaded["infra.notifications"] = { notify = function()
					world.notices = world.notices + 1; return true
				end }
				local offer = require("modules.llm.local_model_offer")
				offer.set_installer(function() world.installs = world.installs + 1; return true end)
				local original_origin = api.get_base_url
				local reads = 0
				api.get_base_url = function() reads = reads + 1; return original_origin() end
				local function current()
					if reads == boundary and not world.replaced then
						world.replaced = true
						fixture.replace_service()
						if outcome == "throw" then error("private-requester-service-secret") end
						return outcome
					end
					return true
				end
				scenario(offer, current, world)
				helpers.assert_true(world.replaced, "the actual original native service must have been replaced")
				helpers.assert_eq(#fixture.tasks, 2)
				helpers.assert_true(fixture.tasks[1].completed)
				helpers.assert_true(fixture.tasks[2].running)
				for _, row in ipairs(fixture.logs) do
					helpers.assert_true(not row.text:find("private-requester-service-secret", 1, true))
				end
			end)
		end)
	end

	helpers.it("(local-model-requester-service-reentry) refuses dispatch after the final requester predicate retires its captured service", function()
		for _, outcome in ipairs({ true, false, 17, "throw" }) do
			with_reentrant_requester(2, outcome, function(offer, current, world)
				helpers.assert_eq(offer.install("qwen2.5:7b", { current = current }), false)
				helpers.assert_eq(world.installs, 0, "old service consent cannot dispatch to its same-origin successor")
				helpers.assert_true(offer.install("qwen2.5:7b"), "fresh successor ownership remains admitted")
				helpers.assert_eq(world.installs, 1)
			end)
		end
	end)

	helpers.it("(local-model-requester-service-reentry) refuses notification custody after its final requester predicate replaces the service", function()
		with_reentrant_requester(2, true, function(offer, current, world)
			helpers.assert_eq(offer.offer("qwen2.5:7b", { automatic = true, current = current }), false)
			helpers.assert_eq(world.notices + world.dialogs + world.installs, 0)
			helpers.assert_true(offer.offer("qwen2.5:7b", { automatic = true }))
			helpers.assert_eq(world.notices, 1, "fresh automatic notices keep their source policy")
		end)
	end)

	helpers.it("(local-model-requester-service-reentry) refuses a source receipt invalidated inside its final acquisition predicate", function()
		with_reentrant_requester(1, true, function(offer, current, world)
			local capture = get_upvalue(offer.install, "capture_owner")
			helpers.assert_eq(type(capture), "function")
			helpers.assert_eq(capture({ current = current }), nil,
				"actual acquisition must not grant an already retired native owner")
			helpers.assert_eq(world.notices + world.dialogs + world.installs, 0)
			helpers.assert_true(offer.install("qwen2.5:7b"))
		end)
	end)

	helpers.it("(ollama-inventory-withdrawal) rechecks cache custody after its endpoint getter forgets or replaces inventory", function()
		for _, replacement in ipairs({ false, true }) do
			with_owned_responses(function(api, fixture)
				fixture.request()
				fixture.tags(1, { { name = "qwen2.5:7b" } })
				local storage = require("adapters.storage")
				local read_setting = storage.get
				storage.get = function(key)
					if key ~= "llm.ollama_port" then return read_setting(key) end
					storage.get = read_setting
					api.forget_local_models()
					if replacement then
						api.refresh_local_models()
						fixture.tags(2, { { name = "replacement-model" } })
					end
					return read_setting(key)
				end
				local ok, installed = pcall(api.local_model_installed, "qwen2.5:7b")
				helpers.assert_true(ok, "a withdrawn receipt must not dereference a now-nil global cache")
				helpers.assert_eq(installed, nil, "the original observation cannot borrow replacement inventory")
				if replacement then
					helpers.assert_eq(api.local_model_installed("replacement-model"), true,
						"a fresh observation retains the replacement's acknowledged cache")
				else
					helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), nil)
				end
			end)
		end
	end)

	helpers.it("(ollama-inventory-withdrawal) refuses a tags acquisition withdrawn by its first source read", function()
		with_owned_responses(function(api, fixture)
			local read_origin = api.get_base_url
			local reads = 0
			api.get_base_url = function()
				reads = reads + 1
				if reads == 2 then
					api.get_base_url = read_origin
					api.forget_local_models()
				end
				return read_origin()
			end
			local result, reason
			api.refresh_local_models(function(ok, why) result, reason = ok, why end)
			helpers.assert_eq(#fixture.gets, 0, "a withdrawn inventory epoch cannot send a tags acquisition")
			helpers.assert_eq(result, false)
			helpers.assert_eq(reason, "model_list_unavailable")
		end)
	end)

	helpers.it("(ollama-inventory-withdrawal) refuses final tags delivery withdrawn inside its last source read", function()
		for _, operation in ipairs({ "refresh", "verify" }) do
			with_owned_responses(function(api, fixture)
				local results = {}
				if operation == "refresh" then
					api.refresh_local_models(function(value, reason) results[#results + 1] = { value, reason } end)
				else
					api.verify_local_model("qwen2.5:7b", function(value, reason) results[#results + 1] = { value, reason } end)
				end
				local debug_log = fixture.logger.debug
				fixture.logger.debug = function(scope, text, ...)
					if text == "The local server returned a readable model list." then
						fixture.logger.debug = debug_log
						local read_origin = api.get_base_url
						api.get_base_url = function()
							api.get_base_url = read_origin
							api.forget_local_models()
							return read_origin()
						end
					end
					return debug_log(scope, text, ...)
				end
				fixture.tags(1, { { name = "qwen2.5:7b" } })
				helpers.assert_eq(#results, 1)
				local expected = nil
				if operation == "refresh" then expected = false end
				helpers.assert_eq(results[1][1], expected,
					"final delivery cannot publish a withdrawn inventory")
				helpers.assert_eq(results[1][2], "model_list_unavailable")
				helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), nil)
			end)
		end
	end)

	helpers.it("(ollama-response-service-affinity) refuses held tags from a retired same-origin daemon", function()
		for _, names in ipairs({ {}, { { name = "qwen2.5:7b" } } }) do
			with_owned_responses(function(api, fixture)
				local result = fixture.request()
				helpers.assert_eq(#fixture.gets, 1)
				fixture.replace_service()
				fixture.tags(1, names)
				helpers.assert_eq(#fixture.posts, 0, "old inventory cannot admit a successor chat")
				helpers.assert_eq(#result.texts, 0)
				helpers.assert_eq(#result.failures, 1)
				helpers.assert_eq(result.failures[1].reason, "model_list_unavailable", "old empty inventory is not MODEL_MISSING")
				helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), nil)
			end)
		end
	end)

	helpers.it("(ollama-response-service-affinity) captures a refresh owner before its opaque endpoint read", function()
		with_owned_responses(function(api, fixture)
			local read_origin = api.get_base_url
			api.get_base_url = function()
				api.get_base_url = read_origin
				fixture.replace_service()
				return read_origin()
			end
			local refreshed, reason
			api.refresh_local_models(function(ok, why) refreshed, reason = ok, why end)
			helpers.assert_eq(#fixture.gets, 0, "an endpoint read cannot lend the refresh its successor service")
			helpers.assert_eq(refreshed, false)
			helpers.assert_eq(reason, "model_list_unavailable")
		end)
	end)

	helpers.it("(ollama-response-service-affinity) invalidates acknowledged inventory when its real service retires", function()
		with_owned_responses(function(api, fixture)
			fixture.request()
			fixture.tags(1, { { name = "qwen2.5:7b" } })
			helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), true)
			fixture.replace_service()
			helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), nil,
				"a READY successor cannot inherit the old process's acknowledged model cache")
			local fresh = fixture.request()
			helpers.assert_eq(#fixture.gets, 2, "the successor must provide its own actual inventory receipt")
			helpers.assert_eq(#fixture.posts, 1)
			fixture.tags(2, { { name = "qwen2.5:7b" } })
			helpers.assert_eq(#fixture.posts, 2)
			fixture.posts[2].done({ status = 200, body = '{"message":{"content":"fresh source answer"}}' })
			helpers.assert_eq(fresh.texts, { "fresh source answer" })
			helpers.assert_eq(#fresh.failures, 0)
		end)
	end)

	helpers.it("(ollama-response-service-affinity) refuses old chat success and missing-model failure after replacement", function()
		for _, response in ipairs({
			{ status = 200, body = '{"message":{"content":"old private answer"}}' },
			{ status = 404, body = require("json").encode({ error = 'model "qwen2.5:7b" not found' }) },
			{ status = 503, body = '{"error":"old service failure"}' },
		}) do
			with_owned_responses(function(api, fixture)
				local result = fixture.request()
				fixture.tags(1, { { name = "qwen2.5:7b" } })
				fixture.replace_service()
				api.refresh_local_models()
				fixture.tags(2, { { name = "successor-model" } })
				fixture.posts[1].done(response)
				helpers.assert_eq(#result.texts, 0)
				helpers.assert_eq(#result.failures, 1)
				helpers.assert_eq(result.failures[1].reason, "model_list_unavailable")
				helpers.assert_eq(api.local_model_installed("successor-model"), true,
					"an old HTTP404 cannot forget the successor's cache")
				for _, line in ipairs(fixture.logs) do
					helpers.assert_true(not line.text:find("old private answer", 1, true))
					helpers.assert_true(not line.text:find("old service failure", 1, true))
				end
			end)
		end
	end)

	helpers.it("(ollama-response-service-affinity) preserves an issued same-service chat through parallel inventory", function()
		with_owned_responses(function(api, fixture)
			local result = fixture.request()
			fixture.tags(1, { { name = "qwen2.5:7b" } })
			api.refresh_local_models()
			fixture.tags(2, { { name = "newly-listed-model" } })
			fixture.posts[1].done({ status = 200, body = '{"message":{"content":"valid original answer"}}' })
			helpers.assert_eq(result.texts, { "valid original answer" })
			helpers.assert_eq(#result.failures, 0, "global listing epoch is only a dispatch prerequisite")
			helpers.assert_eq(api.local_model_installed("newly-listed-model"), true)
		end)
	end)

	helpers.it("(ollama-response-service-affinity) binds the originating service before JSON encoding", function()
		with_owned_responses(function(_, fixture)
			local encode = fixture.codec.encode
			fixture.codec.encode = function(body)
				fixture.codec.encode = encode
				fixture.replace_service()
				return encode(body)
			end
			local result = fixture.request()
			helpers.assert_eq(#fixture.gets, 0, "encode reentry cannot acquire a successor inventory")
			helpers.assert_eq(#fixture.posts, 0)
			helpers.assert_eq(result.failures[1].reason, "model_list_unavailable")
		end)
	end)

	helpers.it("(ollama-response-service-affinity) rechecks service custody after response decoding and logging", function()
		for _, boundary in ipairs({ "decode", "log" }) do
			with_owned_responses(function(_, fixture)
				local result = fixture.request()
				fixture.tags(1, { { name = "qwen2.5:7b" } })
				if boundary == "decode" then
					local decode = fixture.codec.decode
					fixture.codec.decode = function(body)
						fixture.codec.decode = decode
						fixture.replace_service()
						return decode(body)
					end
				else
					local info = fixture.logger.info
					fixture.logger.info = function(scope, text, ...)
						if text:find("answer of the local server received", 1, true) then
							fixture.logger.info = info
							fixture.replace_service()
						end
						return info(scope, text, ...)
					end
				end
				fixture.posts[1].done({ status = 200, body = '{"message":{"content":"old decoded answer"}}' })
				helpers.assert_eq(#result.texts, 0)
				helpers.assert_eq(result.failures[1].reason, "model_list_unavailable")
			end)
		end
	end)

	helpers.it("(ollama-response-service-affinity) suppresses old error logging when decoding retires its service", function()
		with_owned_responses(function(_, fixture)
			local result = fixture.request()
			fixture.tags(1, { { name = "qwen2.5:7b" } })
			local decode = fixture.codec.decode
			fixture.codec.decode = function(body)
				fixture.codec.decode = decode
				fixture.replace_service()
				return decode(body)
			end
			fixture.posts[1].done({ status = 404, body = '{"error":"model qwen not found OLD-SOURCE-MARKER"}' })
			for _, line in ipairs(fixture.logs) do
				helpers.assert_true(not line.text:find("OLD-SOURCE-MARKER", 1, true), "old response diagnostics cannot describe the successor")
			end
			helpers.assert_eq(result.failures[1].reason, "model_list_unavailable")
		end)
	end)

	helpers.it("(ollama-response-service-affinity) suppresses stale tags diagnostics after decoder or logger reentry", function()
		for _, boundary in ipairs({ "decode", "log" }) do
			with_owned_responses(function(api, fixture)
				local result = fixture.request()
				if boundary == "decode" then
					local decode = fixture.codec.decode
					fixture.codec.decode = function(body)
						fixture.codec.decode = decode
						fixture.replace_service()
						return decode(body)
					end
				else
					local log = fixture.logger.error
					fixture.logger.error = function(scope, text, ...)
						fixture.logger.error = log
						fixture.replace_service()
						return log(scope, text, ...)
					end
				end
				fixture.gets[1].done({ status = 503, body = '{"error":"OLD-TAGS-MARKER"}' })
				helpers.assert_eq(#fixture.posts, 0)
				helpers.assert_eq(result.failures[1].reason, "model_list_unavailable")
				helpers.assert_eq(api.local_model_installed("qwen2.5:7b"), nil)
				if boundary == "decode" then
					for _, line in ipairs(fixture.logs) do
						helpers.assert_true(not line.text:find("OLD-TAGS-MARKER", 1, true))
					end
				end
			end)
		end
	end)

	helpers.it("(ollama-response-request-affinity) rechecks current request before HTTP failure diagnostics", function()
		with_owned_responses(function(_, fixture)
			local original = fixture.request()
			fixture.tags(1, { { name = "qwen2.5:7b" } })
			local successor
			local decode = fixture.codec.decode
			fixture.codec.decode = function(body)
				fixture.codec.decode = decode
				successor = fixture.request()
				return decode(body)
			end
			fixture.posts[1].done({ status = 503, body = '{"error":"OBSOLETE-REQUEST-MARKER"}' })
			helpers.assert_eq(#fixture.posts, 2)
			helpers.assert_eq(original.failures[1].reason, "model_list_unavailable")
			for _, line in ipairs(fixture.logs) do
				helpers.assert_true(not line.text:find("OBSOLETE-REQUEST-MARKER", 1, true))
			end
			fixture.posts[2].done({ status = 200, body = '{"message":{"content":"current answer"}}' })
			helpers.assert_eq(successor.texts, { "current answer" })
		end)
	end)

	helpers.it("(ollama-response-request-affinity) fences reentrant same-service request replacement without borrowing inventory epoch", function()
		with_owned_responses(function(_, fixture)
			local original = fixture.request()
			fixture.tags(1, { { name = "qwen2.5:7b" } })
			local successor
			local decode = fixture.codec.decode
			fixture.codec.decode = function(body)
				fixture.codec.decode = decode
				successor = fixture.request()
				return decode(body)
			end
			fixture.posts[1].done({ status = 200, body = '{"message":{"content":"old answer"}}' })
			helpers.assert_eq(#fixture.posts, 2)
			helpers.assert_eq(#original.texts, 0)
			helpers.assert_eq(original.failures[1].reason, "model_list_unavailable")
			fixture.posts[2].done({ status = 200, body = '{"message":{"content":"successor answer"}}' })
			helpers.assert_eq(successor.texts, { "successor answer" })
			helpers.assert_eq(#successor.failures, 0)
		end)
	end)

	helpers.it("(local-model-service-consent) refuses same-origin daemon replacement during held model consent", function()
		with_startup({}, function(api, fixture)
			helpers.with_stub_scope({ "modules.llm.local_model_offer", "infra.dialog_util" }, function()
				helpers.assert_true(api.ensure_running())
				local original = fixture.tasks[1]
				original.emit(original.frame("ACTIVE") .. original.frame("READY"))
				local origin = api.get_base_url()
				local installs, answered = 0, false
				package.loaded["infra.i18n"].format = function(key) return key end
				package.loaded["infra.dialog_util"] = { block_alert = function(_, _, download)
					if not answered then
						answered = true
						helpers.assert_eq(api.stop_owned_server(), false)
						original.complete(0, original.frame("RETIRED 0"))
						helpers.assert_true(api.ensure_running())
						local successor = fixture.tasks[2]
						successor.emit(successor.frame("ACTIVE") .. successor.frame("READY"))
					end
					return download
				end }
				local offer = require("modules.llm.local_model_offer")
				offer.set_installer(function() installs = installs + 1; return true end)
				helpers.assert_eq(offer.offer("fixture-model"), false,
					"unchanged URL and menu installer do not transfer consent to a successor daemon")
				helpers.assert_eq(installs, 0)
				helpers.assert_eq(api.get_base_url(), origin)
				helpers.assert_eq(#fixture.tasks, 2)
				helpers.assert_true(original.completed)
				helpers.assert_true(fixture.tasks[2].running)
				helpers.assert_true(offer.offer("fixture-model"), "fresh consent names the live successor")
				helpers.assert_eq(installs, 1)
			end)
		end)
	end)

	helpers.it("(local-model-service-consent) retains accepted async consent and fences a replaced daemon's late result", function()
		with_startup({}, function(api, fixture)
			helpers.with_stub_scope({ "modules.llm.local_model_offer" }, function()
				helpers.assert_true(api.ensure_running())
				local original = fixture.tasks[1]
				original.emit(original.frame("ACTIVE") .. original.frame("READY"))
				local offer = require("modules.llm.local_model_offer")
				local done, current, forgets
				forgets = 0
				api.forget_local_models = function() forgets = forgets + 1 end
				offer.set_installer(function(_, callback, is_current)
					done, current = callback, is_current
					return true
				end)
				helpers.assert_true(offer.install("fixture-model"))
				helpers.assert_eq(type(current), "function", "the actual installer receives the captured owner")
				helpers.assert_true(current(), "modal return does not revoke an accepted asynchronous download")
				helpers.assert_eq(api.stop_owned_server(), false)
				helpers.assert_eq(current(), false, "retirement revokes the original consent before exit")
				original.complete(0, original.frame("RETIRED 0"))
				helpers.assert_true(api.ensure_running())
				local successor = fixture.tasks[2]
				successor.emit(successor.frame("ACTIVE") .. successor.frame("READY"))
				helpers.assert_eq(current(), false, "a READY successor cannot revive the old owner")
				done(true)
				helpers.assert_eq(forgets, 0)
				helpers.assert_true(offer.install("fixture-model"))
				helpers.assert_true(current())
				done(true)
				helpers.assert_eq(forgets, 1)
				helpers.assert_eq(current(), true, "terminal publication does not impersonate native retirement")
			end)
		end)
	end)

	helpers.it("(ollama-owned-retirement) closes only its published daemon and retains receipt debt", function()
		with_startup({}, function(api, fixture)
			helpers.assert_true(api.ensure_running())
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			helpers.assert_true(api.is_ready() == false, "daemon readiness is independent of model warmup")
			helpers.assert_eq(api.stop_owned_server(), false,
				"stdin EOF cannot acknowledge a daemon's native retirement")
			helpers.assert_eq(original.input_closes, 1)
			helpers.assert_eq(api.ensure_running(), false, "the exact daemon debt blocks a successor")
			helpers.assert_eq(#fixture.tasks, 1)
			original.emit(original.frame("RETIRED 0"))
			helpers.assert_eq(api.stop_owned_server(), false, "the receipt cannot substitute for physical exit")
			original.complete(0)
			helpers.assert_true(api.stop_owned_server())
			helpers.assert_eq(original.input_closes, 1, "the original EOF remains a once-only request")
			helpers.assert_true(api.migration_idle())
		end)
	end)

	helpers.it("(ollama-owned-retirement) never acquires authority over an external server", function()
		with_startup({}, function(api, fixture)
			package.loaded["modules.llm.ollama_binary"].resolve = function()
				return "/Applications/Ollama.app/Contents/Resources/ollama", nil, "app"
			end
			helpers.assert_eq(api.ensure_running(), false)
			helpers.assert_true(api.stop_owned_server())
			helpers.assert_eq(#fixture.tasks, 0, "an external executable does not grant service ownership")
		end)
	end)

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "nil", start = function() return nil end },
		{ name = "throw", start = function() error("native start raised") end },
	}) do
		helpers.it("retries the stale-process task after start " .. case.name, function()
			with_startup({ case.start }, function(api, fixture)
				helpers.assert_eq(api.ensure_running(), false)
				local original = fixture.tasks[1]
				helpers.assert_not_nil(original)
				helpers.assert_eq(original.input_closes, 1,
					"every non-true start must request original-owner retirement exactly once")
				helpers.assert_eq(fixture.shell._active_tasks[original], true)
				helpers.assert_eq(api.ensure_running(), false, "accepted EOF is not physical retirement")
				helpers.assert_eq(#fixture.tasks, 1, "no successor may overlap retained original custody")
				original.emit(original.frame("RETIRED 78"))
				helpers.assert_eq(api.ensure_running(), false, "RETIRED alone is not physical completion")
				helpers.assert_eq(#fixture.tasks, 1)
				original.complete(78)
				helpers.assert_eq(fixture.shell._active_tasks[original], nil)
				helpers.assert_true(api.startup_idle())
				helpers.assert_eq(api.ensure_running(), true,
					"a retired refused launch must not poison the process-lifetime deduplication latch")
				helpers.assert_eq(#fixture.tasks, 2, "the second demand must construct one fresh foreground task")
				helpers.assert_eq(original.start_calls, 1, "retry never restarts the original task")
			end)
		end)
	end

	for _, case in ipairs({
		{ name = "false", start = function() return false end },
		{ name = "nil", start = function() return nil end },
		{ name = "throw", start = function() error("serve start raised") end },
	}) do
		helpers.it("retries the full transaction after server start " .. case.name, function()
			with_startup({ case.start }, function(api, fixture)
				local settlements = {}
				helpers.assert_eq(api.ensure_running({ is_authorized = function() return true end,
					on_settled = function(committed, reason) settlements[#settlements + 1] = { committed, reason } end,
				}), false)
				helpers.assert_eq(#settlements, 1, "a real start refusal must settle the supervised request once")
				helpers.assert_eq(settlements[1][1], false)
				helpers.assert_true(tostring(settlements[1][2]):find("server task start", 1, true) ~= nil)
				local original = fixture.tasks[1]
				helpers.assert_eq(api.ensure_running(), false, "a failed start retains its exact cleanup owner")
				helpers.assert_eq(#fixture.tasks, 1)
				helpers.assert_eq(original.input_closes, 1)
				original.complete(78, original.frame("RETIRED 78"))
				helpers.assert_eq(#settlements, 1, "late retirement must not settle the waiter twice")
				helpers.assert_eq(api.ensure_running(), true, "joined serve refusal must release the outer in-flight latch")
				helpers.assert_eq(#fixture.tasks, 2, "retry begins one fresh foreground transaction")
			end)
		end)
	end

	helpers.it("settles a supervised start through the real pause boundary", function()
		with_startup({}, function(api, fixture)
			local settlements = {}
			local authorized = true
			helpers.assert_true(api.ensure_running({ is_authorized = function() return authorized end,
				on_settled = function(committed, reason) settlements[#settlements + 1] = { committed, reason } end,
			}))
			helpers.assert_eq(#settlements, 0)
			authorized, fixture.paused = false, true
			helpers.assert_eq(api.pause_warmup(), false, "pause retains original custody until native retirement")
			helpers.assert_eq(#settlements, 1)
			helpers.assert_eq(settlements[1][1], false)
			helpers.assert_eq(settlements[1][2], "startup quiesced")
			local original = fixture.tasks[1]
			helpers.assert_eq(original.input_closes, 1)
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			helpers.assert_eq(#settlements, 1, "stale READY cannot republish the paused request")
			helpers.assert_eq(#fixture.tasks, 1, "pause cannot acquire a successor before exact join")
			original.complete(78, original.frame("RETIRED 78"))
			helpers.assert_eq(fixture.shell._active_tasks[original], nil)
			helpers.assert_true(api.pause_warmup())
			helpers.assert_eq(#fixture.tasks, 1, "a physically retired paused request cannot launch a successor")
		end)
	end)

	helpers.it("settles a supervised start only after native publication", function()
		with_startup({}, function(api, fixture)
			local settled = {}
			helpers.assert_true(api.ensure_running({ is_authorized = function() return true end,
				on_settled = function(committed, reason) settled[#settled + 1] = { committed, reason } end,
			}))
			local original = fixture.tasks[1]
			helpers.assert_eq(#settled, 0, "async admission is not proof that the daemon was published")
			helpers.assert_eq(api.startup_idle(), false)
			original.emit(original.frame("ACTIVE"))
			helpers.assert_eq(#settled, 0)
			local ready = original.frame("READY")
			original.emit(ready:sub(1, 18))
			helpers.assert_eq(#settled, 0, "a partial native frame cannot publish readiness")
			original.emit(ready:sub(19))
			helpers.assert_eq(#settled, 1)
			helpers.assert_eq(settled[1][1], true)
			helpers.assert_eq(#fixture.tasks, 1, "publication belongs to the same sole foreground task")
			helpers.assert_eq(fixture.shell._active_tasks[original], true, "READY does not retire the native task")
			original.complete(0, original.frame("RETIRED 0"))
			helpers.assert_eq(fixture.shell._active_tasks[original], nil)
			helpers.assert_eq(#settled, 1)
		end)
	end)

	helpers.it("fences a supervised start whose runtime authority is superseded", function()
		with_startup({}, function(api, fixture)
			local settled = {}
			local authorized = true
			helpers.assert_true(api.ensure_running({ is_authorized = function() return authorized end,
				on_settled = function(committed, reason) settled[#settled + 1] = { committed, reason } end,
			}))
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE"))
			authorized = false
			original.emit(original.frame("READY"))
			helpers.assert_eq(#fixture.tasks, 1, "a superseded backend cannot acquire a successor serve task")
			helpers.assert_eq(#settled, 1)
			helpers.assert_eq(settled[1][1], false)
			helpers.assert_eq(api.startup_idle(), false)
			helpers.assert_eq(api.ensure_running(), false, "cleanup retains the original superseded owner")
			helpers.assert_eq(original.input_closes, 1)
			original.complete(78, original.frame("RETIRED 78"))
			helpers.assert_true(api.startup_idle())
			helpers.assert_eq(#settled, 1, "stale physical completion cannot republish a business verdict")
			helpers.assert_eq(#fixture.tasks, 1)
		end)
	end)

	helpers.it("invalidates readiness when the current daemon exits", function()
		with_startup({}, function(api, fixture)
			helpers.assert_true(set_upvalue(api.is_ready, "_is_ready", true),
				"the daemon-exit regression must seed the real readiness owner")
			helpers.assert_true(set_upvalue(api.is_ready, "_ready_origin", api.get_base_url()),
				"the ready model belongs to the currently configured endpoint")
			helpers.assert_true(set_upvalue(api.reset_ready, "_warmup_gen", 41),
				"the daemon-exit regression must seed the real warmup generation")
			helpers.assert_true(set_upvalue(api.warmup, "_warmup_active", true),
				"the daemon-exit regression must seed the in-flight warmup owner")
			local recovery_calls = 0
			package.loaded["modules.llm.prediction_engine"] = { on_ollama_daemon_exit = function()
				recovery_calls = recovery_calls + 1; return true
			end }
			helpers.assert_eq(api.ensure_running(), true)
			local original = fixture.tasks[1]
			original.emit(original.frame("ACTIVE") .. original.frame("READY"))
			helpers.assert_eq(api.is_ready(), true)
			original.emit(original.frame("RETIRED 0"))
			helpers.assert_eq(api.is_ready(), true, "RETIRED alone cannot demote a physically live daemon")
			helpers.assert_eq(recovery_calls, 0)
			original.complete(0)
			helpers.assert_eq(api.is_ready(), false, "a dead daemon must invalidate the readiness verdict immediately")
			helpers.assert_eq(get_upvalue(api.reset_ready, "_warmup_gen"), 42,
				"daemon death must fence warmup responses from the dead server")
			helpers.assert_eq(get_upvalue(api.warmup, "_warmup_active"), false,
				"daemon death must release the stale warmup intent")
			helpers.assert_eq(recovery_calls, 1, "the current daemon must delegate exactly one recovery attempt")
			helpers.assert_true(set_upvalue(api.is_ready, "_is_ready", true))
			helpers.assert_true(set_upvalue(api.is_ready, "_ready_origin", api.get_base_url()))
			original.complete(0)
			helpers.assert_eq(api.is_ready(), true, "a duplicate stale completion must not demote a successor readiness verdict")
			helpers.assert_eq(recovery_calls, 1, "a duplicate stale completion must not request sibling recovery")
		end)
	end)
end)

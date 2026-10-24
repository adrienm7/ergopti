--- tests/unit/modules/llm/ollama/test_model_warmup.lua

--- ==============================================================================
--- MODULE: Linux Ollama Model Warmup Tests
--- DESCRIPTION:
--- Drives the warmup chain on a virtual clock: the first load after the shared
--- initial delay, the doubling retry up to its cap, the wait behind a
--- prediction, the end on success or on a missing model, and the stop that
--- every engine teardown path relies on. Also pins the Ollama load request.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Timings = require("infra.timings")
local LocalModelPolicy = require("llm.local_model_policy")

local INITIAL_SEC = Timings.ms("llm", "warmup_initial_delay_ms") / 1000
local BASE_SEC = Timings.ms("llm", "warmup_retry_base_ms") / 1000
local CAP_SEC = Timings.ms("llm", "warmup_retry_cap_ms") / 1000

--- Loads a fresh warmup module over scripted ports and runs one scenario.
--- @param scenario function Receives (Warmup, world).
local function run(scenario)
	package.loaded["modules.llm.warmup"] = nil
	local Warmup = require("modules.llm.warmup")
	local world = { scheduler = Fakes.timer_scheduler(), requests = {}, busy = false,
		target = { origin = "http://127.0.0.1:11434", model = "qwen:2b", receipt = {} } }
	local ok, err = xpcall(function()
		helpers.assert_true(Warmup.init({
			scheduler = world.scheduler,
			target = function() return world.target end,
			busy = function() return world.busy end,
			request = function(target, on_done)
				local operation = { started = true, closed = false }
				function operation:is_settled() return self.closed end
				function operation:cancel() self.cancelled = true; self.closed = not world.hold_cancel; return self.closed end
				world.requests[#world.requests + 1] = { target = target, on_done = on_done, operation = operation }
				return operation
			end,
		}))
		scenario(Warmup, world)
	end, debug.traceback)
	Warmup.shutdown()
	package.loaded["modules.llm.warmup"] = nil
	if not ok then error(err, 0) end
end

--- Answers the latest request and marks its transport retired.
--- @param world table
--- @param loaded boolean
--- @param failure any
local function answer(world, loaded, failure)
	local request = world.requests[#world.requests]
	request.operation.closed = true
	request.on_done(loaded, failure)
end

helpers.describe("Ollama model warmup chain", function()
	helpers.it("linux-model-warmup: loads the model once after the shared initial delay", function()
		run(function(Warmup, world)
			helpers.assert_true(Warmup.schedule("enable"))
			world.scheduler.test.advance(INITIAL_SEC - 0.5)
			helpers.assert_eq(#world.requests, 0)
			world.scheduler.test.advance(0.5)
			helpers.assert_eq(#world.requests, 1)
			helpers.assert_eq(world.requests[1].target.model, "qwen:2b")
			answer(world, true)
			helpers.assert_eq(Warmup.pending(), false, "a loaded model ends the chain")
			helpers.assert_true(Warmup.schedule("again"), "the loaded model is not loaded twice")
			world.scheduler.test.advance(CAP_SEC * 4)
			helpers.assert_eq(#world.requests, 1)
		end)
	end)

	helpers.it("linux-model-warmup: retries a failed load with a doubling interval up to the cap", function()
		run(function(Warmup, world)
			Warmup.schedule("enable")
			world.scheduler.test.advance(INITIAL_SEC)
			local wait = BASE_SEC
			for _ = 1, 6 do
				answer(world, false, "connection refused")
				wait = math.min(wait * 2, CAP_SEC)
				local before = #world.requests
				world.scheduler.test.advance(wait - 0.5)
				helpers.assert_eq(#world.requests, before, "no attempt before its interval")
				world.scheduler.test.advance(0.5)
				helpers.assert_eq(#world.requests, before + 1)
			end
			helpers.assert_eq(wait, CAP_SEC, "the interval stops growing at the shared cap")
		end)
	end)

	helpers.it("linux-model-warmup: waits behind a prediction instead of queueing in Ollama", function()
		run(function(Warmup, world)
			world.busy = true
			Warmup.schedule("enable")
			world.scheduler.test.advance(INITIAL_SEC)
			helpers.assert_eq(#world.requests, 0)
			helpers.assert_true(Warmup.pending())
			world.busy = false
			world.scheduler.test.advance(BASE_SEC)
			helpers.assert_eq(#world.requests, 1)
		end)
	end)

	helpers.it("linux-model-warmup: a model Ollama does not have ends the chain", function()
		run(function(Warmup, world)
			Warmup.schedule("enable")
			world.scheduler.test.advance(INITIAL_SEC)
			answer(world, false, LocalModelPolicy.failure("qwen:2b", world.target.origin))
			world.scheduler.test.advance(CAP_SEC * 4)
			helpers.assert_eq(#world.requests, 1)
			helpers.assert_eq(Warmup.pending(), false)
		end)
	end)

	helpers.it("linux-model-warmup: stop retires the timer and the request, and drops their answer", function()
		run(function(Warmup, world)
			Warmup.schedule("enable")
			helpers.assert_true(Warmup.pending())
			helpers.assert_true(Warmup.stop())
			world.scheduler.test.advance(INITIAL_SEC)
			helpers.assert_eq(#world.requests, 0, "a stopped chain sends nothing")
			Warmup.schedule("resume")
			world.scheduler.test.advance(INITIAL_SEC)
			world.hold_cancel = true
			helpers.assert_eq(Warmup.stop(), false, "an unsettled request is retained as cleanup debt")
			helpers.assert_true(world.requests[1].operation.cancelled)
			helpers.assert_true(Warmup.pending())
			world.requests[1].operation.closed = true
			world.requests[1].on_done(true)
			helpers.assert_eq(Warmup.pending(), false)
			helpers.assert_true(Warmup.schedule("resume"), "a stale answer did not mark the model loaded")
			helpers.assert_true(Warmup.pending())
		end)
	end)

	helpers.it("linux-model-warmup: no target, no chain; a new model restarts it", function()
		run(function(Warmup, world)
			world.target = nil
			helpers.assert_eq(Warmup.schedule("enable"), false, "the AI off or paused loads nothing")
			helpers.assert_eq(Warmup.pending(), false)
			world.target = { origin = "http://127.0.0.1:11434", model = "qwen:2b" }
			Warmup.schedule("enable")
			world.scheduler.test.advance(INITIAL_SEC)
			answer(world, true)
			world.target = { origin = "http://127.0.0.1:11434", model = "gemma:1b" }
			helpers.assert_true(Warmup.schedule("model"))
			world.scheduler.test.advance(INITIAL_SEC)
			helpers.assert_eq(#world.requests, 2)
			helpers.assert_eq(world.requests[2].target.model, "gemma:1b")
		end)
	end)

	helpers.it("linux-model-warmup: one owner binds the ports; an unbound module schedules nothing", function()
		run(function(Warmup)
			helpers.assert_eq(Warmup.init({ scheduler = {}, target = function() end }), false)
		end)
		package.loaded["modules.llm.warmup"] = nil
		local Warmup = require("modules.llm.warmup")
		helpers.assert_eq(Warmup.schedule("enable"), false)
		helpers.assert_true(Warmup.stop())
		helpers.assert_eq(Warmup.pending(), false)
		package.loaded["modules.llm.warmup"] = nil
	end)
end)

helpers.describe("Ollama model warmup request", function()
	helpers.it("linux-model-warmup: asks Ollama to load the model with no message and its keep-alive", function()
		local names = { "adapters.http_client", "modules.llm.api_ollama", "modules.llm.prediction_engine" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = xpcall(function()
			local sent, current = {}, true
			package.loaded["modules.llm.prediction_engine"] = {
				capture_runtime_response = function() return {} end,
				runtime_response_current = function() return current end,
			}
			package.loaded["adapters.http_client"] = {
				post_stream_owned = function(url, headers, body, options, _, on_done)
					sent[#sent + 1] = { url = url, headers = headers, body = body, options = options, on_done = on_done }
					return { started = true }
				end,
			}
			package.loaded["modules.llm.api_ollama"] = nil
			local Api = require("modules.llm.api_ollama")
			local outcomes = {}
			helpers.assert_true(Api.warmup("http://127.0.0.1:11434", "qwen:2b", {},
				function(...) outcomes[#outcomes + 1] = { ... } end).started)
			helpers.assert_eq(sent[1].url, "http://127.0.0.1:11434/api/chat")
			local Json = require("json")
			local payload = Json.decode(sent[1].body)
			helpers.assert_eq(payload.model, "qwen:2b")
			helpers.assert_eq(payload.stream, false)
			helpers.assert_true(sent[1].body:find('"messages":[]', 1, true) ~= nil, "an empty message list only loads the model")
			helpers.assert_eq(type(payload.keep_alive), "string")
			helpers.assert_eq(sent[1].options.owner, "ollama_model_warmup")
			helpers.assert_true(sent[1].options.authorized())
			sent[1].on_done({ ok = true, status = 200, body = "{}" })
			sent[1].on_done({ ok = false, status = 404, body = '{"error":"model \'qwen:2b\' not found"}' })
			helpers.assert_eq(outcomes[1], { true })
			helpers.assert_eq(outcomes[2][1], false)
			helpers.assert_true(LocalModelPolicy.is_missing(outcomes[2][2]))
			current = false
			helpers.assert_eq(Api.warmup("http://127.0.0.1:11434", "qwen:2b", {}, function() end).started, false,
				"a stale runtime receipt sends no load request")
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)

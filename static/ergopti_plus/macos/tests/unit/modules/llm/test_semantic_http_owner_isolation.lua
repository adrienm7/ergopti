--- tests/unit/modules/llm/test_semantic_http_owner_isolation.lua

--- ==============================================================================
--- MODULE: Semantic HTTP Owner Isolation Regression Tests
--- DESCRIPTION:
--- Exercises inference, availability, and warmup through their public backend
--- surfaces while completing or cancelling requests in adversarial order.
---
--- ROOT CAUSE ENCODED:
--- HttpClient intentionally supersedes its own active request. Reusing one
--- instance for unrelated semantic operations therefore turns an innocent
--- warmup into inference loss or a permanently unfinished availability lease.
--- Warmup cancellation also needs an independent generation so it cannot make
--- availability or inference callbacks stale, while identity changes must
--- invalidate every semantic owner together.
--- ==============================================================================

local helpers = require("tests.helpers")

local OLLAMA_TEST_PORT = 11434


--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value Captured value.
local function get_upvalue(fn, target)
	for index = 1, 128 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end


--- Instruments one HttpClient while preserving its supersession contract.
--- @param client table Production client instance.
--- @return table state Request and cancellation observations.
--- @return function restore Restores the production methods.
local function instrument_client(client)
	local original_get = client.get
	local original_post = client.post
	local original_cancel = client.cancel
	local state = {
		requests = {},
		cancel_count = 0,
		active = nil,
	}

	local function capture(method, url, headers, body, callback)
		if state.active then client.cancel() end
		local request = {
			method = method,
			url = url,
			headers = headers,
			body = body,
			callback = callback,
			cancelled = false,
		}
		function request.deliver(response, force_cancelled)
			if request.cancelled and force_cancelled ~= true then return false end
			if state.active == request then state.active = nil end
			callback(response)
			return true
		end
		state.requests[#state.requests + 1] = request
		state.active = request
	end

	client.get = function(url, headers, callback)
		capture("get", url, headers, nil, callback)
		return true
	end
	client.post = function(url, headers, body, callback)
		capture("post", url, headers, body, callback)
		return true
	end
	client.cancel = function()
		state.cancel_count = state.cancel_count + 1
		if state.active then
			state.active.cancelled = true
			state.active = nil
		end
		return true
	end

	return state, function()
		client.get = original_get
		client.post = original_post
		client.cancel = original_cancel
	end
end


--- Instruments a semantic client set and restores every method after a test.
--- @param clients table<string, table> Named production clients.
--- @return table states Named observation states.
--- @return function restore Restores every client.
local function instrument_clients(clients)
	local states = {}
	local restorers = {}
	for label, client in pairs(clients) do
		local state, restore = instrument_client(client)
		states[label] = state
		restorers[#restorers + 1] = restore
	end
	return states, function()
		for index = #restorers, 1, -1 do restorers[index]() end
	end
end


--- Loads a fresh backend under the headless Hammerspoon fixture.
--- @param module_name string Backend module name.
--- @return table backend Fresh backend module.
local function fresh_backend(module_name)
	package.loaded[module_name] = nil
	local backend = helpers.load_with_stubs(module_name)
	if module_name == "modules.llm.api_ollama" then
		package.loaded["modules.llm.init"].DEFAULT_STATE.llm_ollama_port = OLLAMA_TEST_PORT
	end
	return backend
end


--- Configures two plain-token remote entries for synchronous request dispatch.
--- @param api table Fresh remote backend.
local function configure_remote(api)
	api.PROVIDERS.fixture = {
		label = "Fixture",
		base_url = "https://fixture.invalid",
		default_model = "fixture-model",
		format = "openai",
	}
	api.set_entries({
		{
			id = "entry-a",
			provider = "fixture",
			base_url = "https://a.invalid",
			token = "plain-token-a",
			model = "model-a",
		},
		{
			id = "entry-b",
			provider = "fixture",
			base_url = "https://b.invalid",
			token = "plain-token-b",
			model = "model-b",
		},
	})
	api.set_active_entry_id("entry-a")
end


--- Returns the three remote semantic clients and verifies their identity.
--- @param api table Fresh remote backend.
--- @return table clients Named clients.
local function remote_clients(api)
	local clients = {
		inference = get_upvalue(api.cancel_streaming, "_infer_client"),
		availability = get_upvalue(api.check_availability, "_check_client"),
		warmup = get_upvalue(api.warmup, "_warmup_client"),
	}
	helpers.assert_true(clients.inference ~= nil, "remote inference client must be owned")
	helpers.assert_true(clients.availability ~= nil, "remote availability client must be owned")
	helpers.assert_true(clients.warmup ~= nil, "remote warmup client must be owned")
	helpers.assert_true(clients.inference ~= clients.availability,
		"remote inference and availability must not supersede each other")
	helpers.assert_true(clients.inference ~= clients.warmup,
		"remote inference and warmup must not supersede each other")
	helpers.assert_true(clients.availability ~= clients.warmup,
		"remote availability and warmup must not supersede each other")
	return clients
end


helpers.describe("LLM semantic HTTP ownership", function()

	helpers.it("semantic HTTP owner isolation preserves Ollama inference across out-of-order warmup", function()
		local api = fresh_backend("modules.llm.api_ollama")
		local post_and_parse = get_upvalue(api.fetch_batch, "post_and_parse")
		helpers.assert_true(type(post_and_parse) == "function",
			"the non-streaming inference path must remain reachable")
		local inference_client = get_upvalue(post_and_parse, "_infer_client")
		local availability_client = get_upvalue(api.check_availability, "_check_client")
		local warmup_client = get_upvalue(api.warmup, "_warmup_client")
		helpers.assert_true(inference_client ~= nil and availability_client ~= nil and warmup_client ~= nil,
			"Ollama must own all three semantic HTTP clients")
		helpers.assert_true(inference_client ~= warmup_client,
			"Ollama warmup must never supersede inference")
		helpers.assert_true(availability_client ~= warmup_client,
			"Ollama warmup must never supersede availability")

		local states, restore_clients = instrument_clients({
			inference = inference_client,
			availability = availability_client,
			warmup = warmup_client,
		})
		local parser = get_upvalue(post_and_parse, "Parser")
		local profiles = get_upvalue(api.fetch_batch, "Profiles")
		local original_strip = parser.strip_thinking
		local original_process = parser.process_prediction
		local original_prompt = profiles.resolve_system_prompt
		parser.strip_thinking = function(text) return text end
		parser.process_prediction = function(_, _, text) return { to_type = text } end
		profiles.resolve_system_prompt = function() return "" end

		local ok, err = xpcall(function()
			local successes = 0
			local failures = 0
			api.reset_ready()
			api.fetch_batch(
				"typed context", "", "fixture-model", 0.2, 8, 1, { batch = false },
				function() successes = successes + 1 end,
				function() failures = failures + 1 end,
				function() return 1 end,
				false,
				nil)
			helpers.assert_eq(#states.inference.requests, 1,
				"inference must dispatch on its semantic owner")

			api.warmup("fixture-model")
			helpers.assert_eq(#states.warmup.requests, 1,
				"warmup must dispatch on its semantic owner")
			helpers.assert_eq(states.inference.requests[1].cancelled, false,
				"starting warmup must not cancel pending inference")

			states.warmup.requests[1].deliver({
				ok = true, status = 200, body = [[{"data":[]}]],
			})
			states.inference.requests[1].deliver({
				ok = true,
				status = 200,
				body = [[{"message":{"content":"completion"}}]],
			})
			helpers.assert_eq(api.is_ready(), true)
			helpers.assert_eq(successes, 1,
				"inference must complete after a later warmup completes first")
			helpers.assert_eq(failures, 0)
		end, debug.traceback)

		parser.strip_thinking = original_strip
		parser.process_prediction = original_process
		profiles.resolve_system_prompt = original_prompt
		restore_clients()
		if not ok then error(err, 0) end
	end)

	helpers.it("semantic HTTP owner isolation lets remote availability and warmup complete out of order", function()
		local api = fresh_backend("modules.llm.api_remote")
		configure_remote(api)
		local states, restore = instrument_clients(remote_clients(api))

		local ok, err = xpcall(function()
			local available = 0
			local missing = 0
			api.check_availability("model-a",
				function() available = available + 1 end,
				function() missing = missing + 1 end)
			api.warmup()
			helpers.assert_eq(#states.availability.requests, 1)
			helpers.assert_eq(#states.warmup.requests, 1)
			helpers.assert_eq(states.availability.requests[1].cancelled, false,
				"warmup dispatch must not supersede availability")

			states.warmup.requests[1].deliver({
				ok = true, status = 200, body = [[{"data":[]}]],
			})
			states.availability.requests[1].deliver({
				ok = true, status = 200, body = [[{"data":[]}]],
			})
			helpers.assert_eq(api.is_ready(), true)
			helpers.assert_eq(available, 1,
				"availability must complete after warmup even when dispatched first")
			helpers.assert_eq(missing, 0)
		end, debug.traceback)

		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("semantic HTTP owner isolation stops only warmup while availability releases its lease", function()
		local api = fresh_backend("modules.llm.api_remote")
		configure_remote(api)
		local states, restore = instrument_clients(remote_clients(api))

		local ok, err = xpcall(function()
			local lease_releases = 0
			local missing = 0
			api.check_availability("model-a",
				function() lease_releases = lease_releases + 1 end,
				function() missing = missing + 1 end)
			api.warmup()
			local availability_request = states.availability.requests[1]
			local warmup_request = states.warmup.requests[1]

			helpers.assert_eq(api.stop_warmup(), true)
			helpers.assert_eq(warmup_request.cancelled, true,
				"stop_warmup must cancel its exact request")
			helpers.assert_eq(availability_request.cancelled, false,
				"stop_warmup must not cancel pending availability")
			availability_request.deliver({
				ok = true, status = 200, body = [[{"data":[]}]],
			})
			helpers.assert_eq(lease_releases, 1,
				"pending availability must still complete and release its caller lease")
			helpers.assert_eq(missing, 0)

			warmup_request.deliver({ ok = true, status = 200, body = "" }, true)
			helpers.assert_eq(api.is_ready(), false,
				"a queued warmup callback must stay inert after stop_warmup")
		end, debug.traceback)

		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("semantic HTTP owner isolation cancels every owner on a true remote identity change", function()
		local api = fresh_backend("modules.llm.api_remote")
		configure_remote(api)
		local states, restore = instrument_clients(remote_clients(api))

		local ok, err = xpcall(function()
			local inference_success = 0
			local inference_failure = 0
			local available = 0
			local missing = 0
			local availability_cancelled = 0
			api.fetch_batch(
				"typed context", "", "model-a", 0.2, 8, 1, { batch = false },
				function() inference_success = inference_success + 1 end,
				function() inference_failure = inference_failure + 1 end)
			api.check_availability("model-a",
				function() available = available + 1 end,
				function() missing = missing + 1 end,
				function() availability_cancelled = availability_cancelled + 1 end)
			api.warmup()

			local inference_request = states.inference.requests[1]
			local availability_request = states.availability.requests[1]
			local warmup_request = states.warmup.requests[1]
			helpers.assert_true(inference_request ~= nil and availability_request ~= nil and warmup_request ~= nil,
				"all three semantic operations must be pending before identity change")

			api.set_active_entry_id("entry-b")
			helpers.assert_eq(inference_request.cancelled, true)
			helpers.assert_eq(availability_request.cancelled, true)
			helpers.assert_eq(warmup_request.cancelled, true,
				"identity invalidation must cancel the dedicated warmup owner")

			inference_request.deliver({ ok = false, status = 401, body = "stale inference" }, true)
			availability_request.deliver({ ok = true, status = 200, body = "" }, true)
			warmup_request.deliver({ ok = true, status = 200, body = "" }, true)
			helpers.assert_eq(inference_success, 0)
			helpers.assert_eq(inference_failure, 0,
				"stale inference must not fail the new identity")
			helpers.assert_eq(available, 0)
			helpers.assert_eq(missing, 0)
			helpers.assert_eq(availability_cancelled, 1,
				"identity invalidation must terminalize the cancelled availability owner")
			helpers.assert_eq(api.is_ready(), false)
		end, debug.traceback)

		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("remote availability reports a delayed dispatch refusal", function()
		local api = fresh_backend("modules.llm.api_remote")
		configure_remote(api)
		local client = remote_clients(api).availability
		local original_get = client.get
		local original_resolve = api.resolve_active_entry
		local resolver_callback = nil
		api.resolve_active_entry = function(callback)
			resolver_callback = callback
			return { cancel = function() return true end }
		end
		client.get = function() return false end

		local ok, err = xpcall(function()
			local available = 0
			local missing = 0
			local cancelled = 0
			helpers.assert_true(api.check_availability("model-a",
				function() available = available + 1 end,
				function() missing = missing + 1 end,
				function() cancelled = cancelled + 1 end),
				"the async resolver owns the initial acceptance")
			helpers.assert_type(resolver_callback, "function")
			resolver_callback(true, api.get_active_entry())
			helpers.assert_eq(available, 0)
			helpers.assert_eq(missing, 0)
			helpers.assert_eq(cancelled, 1,
				"a late native GET refusal must release the caller's validation lease")
		end, debug.traceback)

		client.get = original_get
		api.resolve_active_entry = original_resolve
		if not ok then error(err, 0) end
	end)

end)

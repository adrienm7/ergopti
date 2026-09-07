--- tests/unit/modules/shortcuts/pause_owners/test_remote_http.lua

--- ==============================================================================
--- MODULE: Pause Owner remote http Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context
local get_upvalue = fixtures.get_upvalue

local function load_remote_native_http()
	local state = {
		cancel_mode = "true",
		cancel_handles = {},
		callbacks = {},
		tasks = {},
		get_calls = 0,
		post_calls = 0,
		sync_get = false,
	}
	local timer_stub = {
		secondsSinceEpoch = function() return 100 end,
		doAfter = function() error("HttpClient must use the exact scheduler adapter") end,
	}
	function timer_stub.new(_, callback)
		local running = false
		local native = { callback = callback }
		function native:start()
			running = true
			return self
		end
		function native:running() return running end
		function native:stop()
			running = false
			return self
		end
		return native
	end

	local function new_task()
		local task = {}
		function task:cancel()
			state.cancel_handles[#state.cancel_handles + 1] = self
			if state.cancel_mode == "throw" then error("native HTTP cancel exploded") end
			if state.cancel_mode == "false" then return false end
			if state.cancel_mode == "nil" then return nil end
			return true
		end
		state.tasks[#state.tasks + 1] = task
		return task
	end
	local http_stub = {
		encodeForQuery = function(value) return tostring(value) end,
		doAsyncRequest = function(_, method, _, _, callback, enable_redirect)
			helpers.assert_eq(enable_redirect, false,
				"credentialed Remote probes must disable native redirect following")
			if method == "GET" then
				state.get_calls = state.get_calls + 1
				state.callbacks[#state.callbacks + 1] = callback
				local task = new_task()
				if state.sync_get == true then callback(200, [[{"data":[]}]], {}) end
				return task
			end
			state.post_calls = state.post_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			return new_task()
		end,
		asyncGet = function(_, _, callback)
			state.get_calls = state.get_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			local task = new_task()
			if state.sync_get == true then callback(200, [[{"data":[]}]], {}) end
			return task
		end,
		asyncPost = function(_, _, _, callback)
			state.post_calls = state.post_calls + 1
			state.callbacks[#state.callbacks + 1] = callback
			return new_task()
		end,
	}
	reset_module("adapters.http_client")
	reset_module("adapters.timer_scheduler")
	helpers.load_with_stubs("adapters.http_client", {
		timer = timer_stub,
		http = http_stub,
	})
	package.loaded["modules.shortcuts.script_control"] = {
		is_paused = function() return false end,
		get_pause_epoch = function() return 0 end,
	}
	reset_module("modules.llm.api_remote")
	local api = helpers.load_with_stubs("modules.llm.api_remote")
	api.PROVIDERS.fixture = {
		label = "Fixture",
		base_url = "https://fixture.invalid",
		default_model = "fixture-model",
		format = "openai",
	}
	api.set_entries({ {
		id = "entry-native",
		provider = "fixture",
		base_url = "https://fixture.invalid",
		token = "plain-token",
		model = "fixture-model",
	} })
	api.set_active_entry_id("entry-native")
	return api, state
end

helpers.describe("HS-012 real Remote HTTP pause ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates inference " .. mode
			.. " cancellation through prediction reset", function()
			local api, native = load_remote_native_http()
			local infer_client = get_upvalue(api.cancel_streaming, "_infer_client")
			helpers.assert_not_nil(infer_client)
			local deliveries = 0
			helpers.assert_true(infer_client.post(
				"https://fixture.invalid/infer", {}, "{}", function()
					deliveries = deliveries + 1
				end))
			helpers.assert_eq(native.post_calls, 1)
			local task = native.tasks[1]
			native.cancel_mode = mode
			local script_control = load_inventory_context({
				remote = api,
				keymap = {
					pause_processing = function() return true end,
					resume_processing = function() return true end,
					reset_predictions = api.cancel_streaming,
					reset_predictions_for_pause = api.cancel_streaming,
				},
			})
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused inference cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task,
				"prediction reset must retain the exact native inference task")

			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(native.cancel_handles[2], task,
				"pause retry must settle the same inference handle")
			native.callbacks[1](200, [[{"data":[]}]], {})
			helpers.assert_eq(deliveries, 0,
				"logical revocation must fence a queued native response")
			helpers.assert_true(script_control.resume_all())
			script_control.stop()
		end)

		helpers.it("accepts late inference terminal proof after " .. mode
			.. " cancellation", function()
			local api, native = load_remote_native_http()
			local infer_client = get_upvalue(api.cancel_streaming, "_infer_client")
			local deliveries = 0
			helpers.assert_true(infer_client.post(
				"https://fixture.invalid/infer", {}, "{}", function()
					deliveries = deliveries + 1
				end))
			local task = native.tasks[1]
			native.cancel_mode = mode
			local script_control = load_inventory_context({
				remote = api,
				keymap = {
					pause_processing = function() return true end,
					resume_processing = function() return true end,
					reset_predictions = api.cancel_streaming,
					reset_predictions_for_pause = api.cancel_streaming,
				},
			})
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused inference cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task)
			native.callbacks[1](200, "late", {})
			helpers.assert_eq(deliveries, 0)
			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all(),
				"natural terminal proof must settle the retained capability")
			helpers.assert_eq(#native.cancel_handles, 1,
				"a naturally settled task needs no second native cancellation")
			helpers.assert_eq(native.post_calls, 1,
				"pause retry cannot dispatch a sibling inference request")
			helpers.assert_true(script_control.resume_all())
			script_control.stop()
		end)

		helpers.it("joins availability " .. mode
			.. " cancellation without restoring stale work", function()
			local api, native = load_remote_native_http()
			local available, missing = 0, 0
			native.sync_get = true
			helpers.assert_true(api.check_availability(nil,
				function() available = available + 1 end,
				function() missing = missing + 1 end))
			helpers.assert_eq(available, 1,
				"positive control must exercise synchronous native completion")
			native.callbacks[1](200, "{}", {})
			helpers.assert_eq(available, 1,
				"duplicate synchronous completion must be one-shot")

			native.sync_get = false
			helpers.assert_true(api.check_availability(nil,
				function() available = available + 1 end,
				function() missing = missing + 1 end))
			local task = native.tasks[2]
			native.cancel_mode = mode
			local script_control = load_inventory_context({ remote = api })
			script_control.pause_all()
			helpers.assert_eq(script_control.is_paused(), false,
				"refused availability cancellation must prevent PAUSED publication")
			helpers.assert_eq(native.cancel_handles[1], task)
			native.callbacks[2](200, [[{"data":[]}]], {})
			helpers.assert_eq(available, 1)
			helpers.assert_eq(missing, 0)

			native.cancel_mode = "true"
			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(native.cancel_handles[#native.cancel_handles], task,
				"availability retry must settle the same native task")
			native.callbacks[2](503, "late", {})
			helpers.assert_eq(available, 1)
			helpers.assert_eq(missing, 0,
				"global pause never restores or publishes a stale availability check")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(native.get_calls, 2,
				"resume must join cleanup debt without restoring an availability request")
			script_control.stop()
		end)
	end
end)

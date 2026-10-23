--- tests/unit/adapters/network/test_http_client_native_request_settlement.lua
--- ==============================================================================
--- MODULE: HttpClient Taskless Native Settlement Regression Tests
--- DESCRIPTION:
--- Native HTTP exchanges outlive logical cancellation when hs.http returns nil.
--- Each case owns the real adapters and held native callback ports through finally.
--- ==============================================================================
local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"adapters.http_client", "adapters.timer_scheduler", "infra.logger",
	"error_description", "number_policy",
}

--- Owns construction, delivery and final cleanup of the real adapters.
--- The native port only captures callbacks; no network or native timer is started.
local function isolated(scenario, options)
	helpers.with_stub_scope(OWNED_MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local state = { requests = {}, timers = {} }
		local function dispatch(url, callback)
			local request = { url = url, callback = callback }
			state.requests[#state.requests + 1] = request
			if state.on_dispatch then return state.on_dispatch(request, #state.requests) end
			return nil
		end
		local timer = { secondsSinceEpoch = function() return 0 end }
		function timer.new(_, callback)
			local native = { _running = false, callback = callback }
			function native:start() self._running = true; return self end
			function native:stop() self._running = false; return self end
			function native:running() return self._running end
			state.timers[#state.timers + 1] = native
			return native
		end
		local HttpClient = helpers.load_with_stubs("adapters.http_client", {
			timer = timer,
			http = {
				asyncGet = function(url, _, callback) return dispatch(url, callback) end,
				asyncPost = function(url, _, _, callback) return dispatch(url, callback) end,
				doAsyncRequest = function(url, _, _, _, callback) return dispatch(url, callback) end,
			},
		})
		local client = HttpClient.new(options)
		local scheduler = package.loaded["adapters.timer_scheduler"]
		local ok, err = xpcall(function() scenario(client, state) end, debug.traceback)
		-- Cleanup also owns the preimage's failing assertion path. New callbacks
		-- cannot escape this native port; drain every captured exact completion.
		client.cancel()
		for _, request in ipairs(state.requests) do request.callback(-1, "owned fixture cleanup") end
		client.cancel()
		helpers.assert_true(client.isSettled(), "fixture retains no HTTP receipt")
		helpers.assert_eq(scheduler.activeCount(), 0, "fixture retains no scheduler handle")
		for _, native in ipairs(state.timers) do
			helpers.assert_eq(native:running(), false, "fixture retains no native timer")
		end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("HttpClient taskless native settlement", function()
	helpers.it("retains taskless HTTP completion after logical cancellation (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results, settlements = 0, 0
			helpers.assert_true(client.get("http://owned.invalid/held", {}, function() results = results + 1 end))
			helpers.assert_true(client.onSettled(function() settlements = settlements + 1 end))
			helpers.assert_eq(client.cancel(), false, "nil native handle supplies no cancellation acknowledgement")
			helpers.assert_eq(client.isActive(), false, "logical cancellation remains synchronous")
			helpers.assert_eq(client.isSettled(), false, "native callback remains retained")
			helpers.assert_eq(settlements, 0, "logical revocation is no physical receipt")
			state.requests[1].callback(-1, "Connection failed: owned fixture")
			helpers.assert_eq(results, 0, "cancelled result stays fenced")
			helpers.assert_true(client.isSettled())
			helpers.assert_eq(settlements, 1)
			state.requests[1].callback(200, "duplicate", {})
			helpers.assert_eq(results, 0)
			helpers.assert_eq(settlements, 1, "exact completion settles once")
		end)
	end)

	helpers.it("keeps superseded taskless native generations independently pending (http-native-request-settlement)", function()
		isolated(function(client, state)
			local first, second, settlements = 0, 0, 0
			helpers.assert_true(client.post("http://owned.invalid/first", {}, "{}", function() first = first + 1 end))
			helpers.assert_true(client.post("http://owned.invalid/second", {}, "{}", function() second = second + 1 end))
			helpers.assert_eq(#state.requests, 2, "logical replacement still dispatches immediately")
			helpers.assert_true(client.onSettled(function() settlements = settlements + 1 end))
			state.requests[2].callback(200, "current", {})
			helpers.assert_eq(second, 1)
			helpers.assert_eq(first, 0)
			helpers.assert_eq(client.isSettled(), false, "current completion cannot retire its predecessor")
			helpers.assert_eq(settlements, 0)
			state.requests[1].callback(200, "stale", {})
			helpers.assert_eq(first, 0, "generation fence still rejects the old result")
			helpers.assert_true(client.isSettled())
			helpers.assert_eq(settlements, 1)
		end)
	end)
end)

helpers.describe("HttpClient native terminal controls", function()
	helpers.it("waits for taskless native terminal after one timeout result (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results, settlements = {}, 0
			client.get("http://owned.invalid/timeout", {}, function(result) results[#results + 1] = result end)
			client.onSettled(function() settlements = settlements + 1 end)
			state.timers[1].callback()
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(results[1].error, "timeout")
			helpers.assert_eq(client.isActive(), false)
			helpers.assert_eq(client.isSettled(), false, "application timeout does not cancel the native connection")
			helpers.assert_eq(settlements, 0)
			state.timers[1].callback()
			state.requests[1].callback(200, "late", {})
			helpers.assert_true(client.isSettled())
			helpers.assert_eq(#results, 1)
			helpers.assert_eq(settlements, 1)
		end)
	end)

	helpers.it("settles normal success with native three-argument headers (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results = {}
			client.get("http://owned.invalid/success", {}, function(result) results[#results + 1] = result end)
			state.requests[1].callback(200, "body", { ETag = '"owned"' })
			helpers.assert_eq(#results, 1)
			helpers.assert_true(results[1].ok)
			helpers.assert_eq(results[1].headers.ETag, '"owned"')
			helpers.assert_true(client.isSettled())
			state.requests[1].callback(500, "duplicate", {})
			helpers.assert_eq(#results, 1)
		end)
	end)

	helpers.it("settles native two-argument network errors without headers (http-native-request-settlement)", function()
		isolated(function(client, state)
			local result
			client.get("http://owned.invalid/error", {}, function(value) result = value end)
			state.requests[1].callback(-1, "Connection failed: owned fixture")
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.status, 0)
			helpers.assert_eq(result.body, "")
			helpers.assert_eq(result.headers, {})
			helpers.assert_true(client.isSettled())
		end)
	end)

	helpers.it("keeps current generation active when its predecessor finishes first (http-native-request-settlement)", function()
		isolated(function(client, state)
			local first, second = 0, 0
			client.get("http://owned.invalid/old", {}, function() first = first + 1 end)
			client.get("http://owned.invalid/new", {}, function() second = second + 1 end)
			state.requests[1].callback(200, "stale", {})
			helpers.assert_eq(first, 0)
			helpers.assert_true(client.isActive())
			helpers.assert_eq(client.isSettled(), false)
			state.requests[2].callback(200, "current", {})
			helpers.assert_eq(second, 1)
			helpers.assert_true(client.isSettled())
		end)
	end)

	helpers.it("does not resurrect a synchronous native completion (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results = 0
			state.on_dispatch = function(request) request.callback(200, "inline", {}); return nil end
			helpers.assert_true(client.get("http://owned.invalid/inline", {}, function() results = results + 1 end))
			helpers.assert_eq(results, 1)
			helpers.assert_true(client.isSettled())
		end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("retires native dispatch " .. mode .. " without phantom receipts (http-native-request-settlement)", function()
			isolated(function(client, state)
				local results = {}
				state.on_dispatch = function()
					if mode == "throw" then error("owned native dispatch refusal") end
					return false
				end
				helpers.assert_eq(client.get("http://owned.invalid/refused", {}, function(result) results[#results + 1] = result end), false)
				helpers.assert_eq(#results, 1)
				helpers.assert_eq(results[1].error_kind, "native_dispatch")
				helpers.assert_true(client.isSettled())
			end)
		end)

		helpers.it("does not redeliver completion before native dispatch " .. mode .. " (http-native-request-settlement)", function()
			isolated(function(client, state)
				local results = 0
				state.on_dispatch = function(request)
					request.callback(200, "inline", {})
					if mode == "throw" then error("owned refusal after completion") end
					return false
				end
				helpers.assert_eq(client.get("http://owned.invalid/inline-refused", {}, function() results = results + 1 end), false)
				helpers.assert_eq(results, 1)
				helpers.assert_true(client.isSettled())
			end)
		end)
	end

	helpers.it("accepts exact returned-task cancel acknowledgement (http-native-request-settlement)", function()
		isolated(function(client, state)
			local cancellations, results = 0, 0
			local task = { cancel = function() cancellations = cancellations + 1; return true end }
			state.on_dispatch = function() return task end
			client.get("http://owned.invalid/task", {}, function() results = results + 1 end)
			helpers.assert_true(client.cancel())
			helpers.assert_eq(cancellations, 1)
			helpers.assert_true(client.isSettled())
			state.requests[1].callback(200, "late", {})
			helpers.assert_eq(results, 0)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact returned-task " .. mode .. " cancellation until terminal (http-native-request-settlement)", function()
			isolated(function(client, state)
				local results = 0
				state.on_dispatch = function()
					return { cancel = function()
						if mode == "throw" then error("owned cancel refusal") end
						if mode == "false" then return false end
						return nil
					end }
				end
				client.get("http://owned.invalid/task-refused", {}, function() results = results + 1 end)
				helpers.assert_eq(client.cancel(), false)
				helpers.assert_eq(client.isSettled(), false)
				state.requests[1].callback(-1, "owned task terminal")
				helpers.assert_eq(results, 0)
				helpers.assert_true(client.isSettled())
			end)
		end)
	end

	helpers.it("owns each redirect hop through its own native completion (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results = 0
			client.get("https://owned.invalid/start", {}, function() results = results + 1 end)
			state.requests[1].callback(302, "", { Location = "/final" })
			helpers.assert_eq(#state.requests, 2)
			helpers.assert_eq(client.isSettled(), false)
			state.requests[2].callback(200, "final", {})
			helpers.assert_eq(results, 1)
			helpers.assert_true(client.isSettled())
		end)
	end)
end)


helpers.describe("HttpClient opaque native handle settlement", function()
	helpers.it("retains an opaque returned handle until its exact terminal and then recovers (http-native-request-settlement)", function()
		isolated(function(client, state)
			local results, settlements, refusals = 0, 0, {}
			state.on_dispatch = function() return {} end
			helpers.assert_true(client.get("http://owned.invalid/opaque", {}, function() results = results + 1 end))
			helpers.assert_true(client.onSettled(function() settlements = settlements + 1 end))
			helpers.assert_eq(client.cancel(), false, "missing cancel method supplies no native acknowledgement")
			helpers.assert_eq(client.isActive(), false)
			helpers.assert_eq(client.isSettled(), false)
			helpers.assert_eq(settlements, 0)
			helpers.assert_eq(client.get("http://owned.invalid/blocked", {}, function(result) refusals[#refusals + 1] = result end), false)
			helpers.assert_eq(#state.requests, 1, "opaque capability cleanup debt blocks dispatch")
			helpers.assert_eq(#refusals, 1)
			helpers.assert_eq(refusals[1].error, "timeout cleanup pending")
			state.requests[1].callback(-1, "owned opaque terminal")
			helpers.assert_eq(results, 0, "logically cancelled result remains fenced")
			helpers.assert_eq(settlements, 1)
			helpers.assert_true(client.isSettled())
			state.requests[1].callback(200, "duplicate", {})
			helpers.assert_eq(settlements, 1)
			state.on_dispatch = function() return nil end
			helpers.assert_true(client.get("http://owned.invalid/recovered", {}, function() results = results + 1 end))
			helpers.assert_eq(#state.requests, 2)
			state.requests[2].callback(200, "current", {})
			helpers.assert_eq(results, 1, "healthy successor completes after exact retirement")
			helpers.assert_true(client.isSettled())
		end)
	end)
end)

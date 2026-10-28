--- tests/unit/adapters/network/test_http_client_cancel_receipt_reentry.lua
--- ==============================================================================
--- MODULE: HttpClient Cancel Receipt Before Observer Reentry
--- DESCRIPTION:
--- An observer may start B after A settles; cancel still reports A's exact receipt.
--- Each case owns the real adapters and held native callback ports through finally.
--- ==============================================================================
local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"adapters.http_client", "adapters.timer_scheduler", "infra.logger",
	"error_description", "number_policy",
}

--- Owns construction, delivery and final cleanup of the real adapters.
--- The native port only captures callbacks; no network or native timer is started.
local function isolated(scenario)
	helpers.with_stub_scope(OWNED_MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local state = { requests = {}, timers = {}, cancellations = 0 }
		local function dispatch(url, callback)
			local request = { url = url, callback = callback }
			state.requests[#state.requests + 1] = request
			if #state.requests == 1 then
				local task = { active = true }
				function task:cancel()
					state.cancellations = state.cancellations + 1
					self.active = false
					return true
				end
				request.task = task
				return task
			end
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
		local client = HttpClient.new()
		local scheduler = package.loaded["adapters.timer_scheduler"]
		local ok, err = xpcall(function() scenario(client, state) end, debug.traceback)
		-- Cleanup also owns the preimage's failing assertion path. New callbacks
		-- cannot escape this native port; drain every captured exact completion.
		client.cancel()
		for _, request in ipairs(state.requests) do request.callback(-1, "owned fixture cleanup") end
		client.cancel()
		for _, request in ipairs(state.requests) do
			if request.task then helpers.assert_eq(request.task.active, false) end
		end
		helpers.assert_true(client.isSettled(), "fixture retains no HTTP receipt")
		helpers.assert_eq(scheduler.activeCount(), 0, "fixture retains no scheduler handle")
		for _, native in ipairs(state.timers) do
			helpers.assert_eq(native:running(), false, "fixture retains no native timer")
		end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("HttpClient cancel receipt survives observer reentry", function()
	helpers.it("returns the revoked request receipt before a settlement observer starts its successor (http-native-cancel-reentry)", function()
		isolated(function(client, state)
			local first, second, observations = 0, 0, 0
			helpers.assert_true(client.get("http://owned.invalid/A", {}, function() first = first + 1 end))
			helpers.assert_true(client.onSettled(function()
				observations = observations + 1
				helpers.assert_true(client.get("http://owned.invalid/B", {}, function() second = second + 1 end))
			end))
			helpers.assert_true(client.cancel(), "the revoked A receipt remains settled after observer B starts")
			helpers.assert_eq(state.cancellations, 1)
			helpers.assert_eq(state.requests[1].task.active, false)
			helpers.assert_eq(observations, 1)
			helpers.assert_eq(#state.requests, 2)
			helpers.assert_true(client.isActive(), "the newer observer request remains active")
			helpers.assert_eq(client.isSettled(), false, "current aggregate sees B pending independently of A receipt")
			state.requests[1].callback(-1, "owned late A terminal")
			helpers.assert_eq(first, 0)
			helpers.assert_true(client.isActive())
			state.requests[2].callback(200, "B", {})
			helpers.assert_eq(second, 1)
			helpers.assert_true(client.isSettled())
			state.requests[2].callback(200, "duplicate B", {})
			helpers.assert_eq(second, 1)
			helpers.assert_eq(observations, 1)
		end)
	end)
end)

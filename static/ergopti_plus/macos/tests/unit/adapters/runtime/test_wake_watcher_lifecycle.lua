--- tests/unit/adapters/runtime/test_wake_watcher_lifecycle.lua

--- ==============================================================================
--- MODULE: Wake Watcher Lifecycle Regression Tests
--- DESCRIPTION:
--- Keeps callbacks revoked across stop, restart, and partial native activation,
--- while failed native teardown retains the exact watcher for retry.
--- ==============================================================================

local helpers = require("tests.helpers")

local WAKE = 1
local OWNERS = { "core.events.wake_watcher", "core.logger.engine.logger" }

--- Runs a fresh wake adapter over independently observable native watcher state.
--- @param callback function Receives the adapter and native watcher inventory.
local function with_adapter(callback, options)
	return helpers.with_stub_scope(OWNERS, function()
		local natives = {}
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		local Adapter = helpers.load_with_stubs("core.events.wake_watcher", {
			caffeinate = { watcher = {
				systemDidWake = WAKE,
				new = function(on_event)
					local native = { deliver = on_event, starts = 0, stops = 0, running = false }
					function native:start()
						self.starts = self.starts + 1
						self.running = true
						if options and options.start_failure then error(options.start_failure) end
						if options and options.start_error then error("start interrupted") end
						return self
					end
					function native:stop()
						self.stops = self.stops + 1
						if options and options.stop_failure then error(options.stop_failure) end
						if self.stop_error then error("stop interrupted") end
						if options and options.stop_refused then return false end
						self.running = false
						return self
					end
					natives[#natives + 1] = native
					return native
				end,
			} },
		})
		return callback(Adapter, natives)
	end)
end

helpers.describe("wake watcher lifecycle", function()
	helpers.it("retains cleanup when a native error cannot be formatted (wake-error-object)", function()
		local hostile = setmetatable({}, { __tostring = function() error("formatter failed") end })
		local options = { start_failure = hostile, stop_failure = hostile }
		with_adapter(function(Adapter, natives)
			local watcher = Adapter.new(function() error(hostile) end)
			helpers.assert_eq(watcher.start(), false)
			helpers.assert_eq(natives[1].stops, 1, "a failed start must still attempt rollback")
			options.start_failure, options.stop_failure = nil, nil
			helpers.assert_true(watcher.stop(), "the exact watcher must remain retryable")
			helpers.assert_true(watcher.start())
			helpers.assert_true(pcall(natives[2].deliver, WAKE), "callback error reporting must not escape")
			helpers.assert_true(watcher.stop())
		end, options)
	end)

	helpers.it("retains partial activation until its exact rollback succeeds (wake-start-rollback)", function()
		local options = { start_error = true, stop_refused = true }
		with_adapter(function(Adapter, natives)
			local calls = 0
			local watcher = Adapter.new(function() calls = calls + 1 end)
			helpers.assert_eq(watcher.start(), false)
			helpers.assert_eq(natives[1].stops, 1, "a failed start must roll back the exact watcher")
			helpers.assert_eq(watcher.start(), false, "a refused stop must block a replacement")
			helpers.assert_eq(#natives, 1)
			natives[1].deliver(WAKE)
			helpers.assert_eq(calls, 0)
			options.stop_refused = false
			helpers.assert_eq(watcher.stop(), true)
			helpers.assert_eq(natives[1].running, false)
			options.start_error = false
			helpers.assert_eq(watcher.start(), true)
			helpers.assert_eq(#natives, 2)
			helpers.assert_eq(watcher.stop(), true)
		end, options)
	end)

	helpers.it("revokes queued callbacks before stop and restart (wake-watcher-revocation)", function()
		with_adapter(function(Adapter, natives)
			local calls = 0
			local watcher = Adapter.new(function() calls = calls + 1 end)
			helpers.assert_eq(watcher.start(), true)
			local first = natives[1]
			first.deliver(WAKE)
			helpers.assert_eq(calls, 1)
			first.stop_error = true
			helpers.assert_eq(watcher.stop(), false)
			helpers.assert_eq(watcher.start(), false, "retained cleanup debt cannot masquerade as active")
			helpers.assert_eq(#natives, 1, "cleanup debt blocks replacement")
			first.deliver(WAKE)
			helpers.assert_eq(calls, 1, "refused teardown must already revoke business callbacks")
			first.stop_error = false
			helpers.assert_eq(watcher.stop(), true)
			helpers.assert_eq(first.running, false)
			helpers.assert_eq(first.stops, 2, "stop retries the exact native watcher")
			first.deliver(WAKE)
			helpers.assert_eq(calls, 1, "a queued callback remains inert after successful stop")
			helpers.assert_eq(watcher.start(), true)
			first.deliver(WAKE)
			helpers.assert_eq(calls, 1, "retired watcher cannot borrow its successor's authority")
			natives[2].deliver(WAKE)
			helpers.assert_eq(calls, 2, "only the committed successor delivers")
			helpers.assert_eq(watcher.stop(), true)
		end)
	end)
end)

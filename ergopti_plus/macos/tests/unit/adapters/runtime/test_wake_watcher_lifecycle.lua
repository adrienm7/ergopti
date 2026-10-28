--- tests/unit/adapters/runtime/test_wake_watcher_lifecycle.lua

--- ==============================================================================
--- MODULE: Wake Watcher Lifecycle Regression Tests
--- DESCRIPTION:
--- Keeps callbacks revoked across stop, restart, and partial native activation,
--- while failed native teardown retains the exact watcher for retry.
--- ==============================================================================

local helpers = require("tests.helpers")

local WAKE = 1
local OWNERS = { "adapters.wake_watcher", "infra.logger" }

--- Runs a fresh wake adapter over independently observable native watcher state.
--- @param callback function Receives the adapter and native watcher inventory.
local function with_adapter(callback)
	return helpers.with_stub_scope(OWNERS, function()
		local natives = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local Adapter = helpers.load_with_stubs("adapters.wake_watcher", {
			caffeinate = { watcher = {
				systemDidWake = WAKE,
				new = function(on_event)
					local native = { deliver = on_event, starts = 0, stops = 0, running = false }
					function native:start()
						self.starts = self.starts + 1
						self.running = true
						return self
					end
					function native:stop()
						self.stops = self.stops + 1
						if self.stop_error then error("stop interrupted") end
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

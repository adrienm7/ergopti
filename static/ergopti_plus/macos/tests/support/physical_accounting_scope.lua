--- tests/support/physical_accounting_scope.lua

--- Isolates the real physical aggregator for accounting and delivery tests.
local helpers = require("tests.helpers")
local M = {}

--- Runs a callback with fresh aggregate state and a physical press helper.
---@param callback function Receives events, state, core and press.
function M.run(callback)
	helpers.with_stub_scope({
		"hs", "tests.stubs.hs", "infra.logger", "modules.keystats.aggregator.events",
		"modules.keystats.aggregator.core", "modules.keystats.aggregator.state",
		"modules.keystats.aggregator.physical",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local events = helpers.load_with_stubs("modules.keystats.aggregator.events")
		local state = require("modules.keystats.aggregator.state")
		local core = require("modules.keystats.aggregator.core")
		state.initialized = true
		state.device_id = "physical-accounting-test"
		core.reset_batch()
		core.reset_ngram_ctx()
		local function press(kc, capture, device)
			events.walk_system_event({ action = "physical_press", keycode = kc,
				capture = capture or "lease-a", device = device or "41",
				timestamp = "2026-09-12 10:00:00.000", app = "TestApp" })
		end
		callback(events, state, core, press)
	end)
end

return M

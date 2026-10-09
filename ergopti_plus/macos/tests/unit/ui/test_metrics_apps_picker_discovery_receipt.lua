--- tests/unit/ui/test_metrics_apps_picker_discovery_receipt.lua

--- ==============================================================================
--- MODULE: Metrics Application Discovery Receipts
--- DESCRIPTION:
--- A failed scan is not evidence that the system has no installed applications.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

helpers.describe("metrics_apps: discovery outcome", function()
	for _, mode in ipairs({ "failed_nil", "failed_table", "empty_success" }) do
		helpers.it("distinguishes " .. mode .. " from an empty successful scan", function()
			with_window("ui.metrics_apps", function(dashboard, state)
				helpers.with_fresh_modules({ "infra.app_picker" }, function()
					local pending, alerts, logs = {}, {}, {}
					local complete
					package.loaded["infra.app_picker"] = { discover_apps = function(callback) complete = callback end }
					package.loaded["infra.dialog_util"].alert = function(_, message) alerts[#alerts + 1] = message end
					package.loaded["infra.logger"].debug = function(_, message, ...)
						logs[#logs + 1] = string.format(message, ...)
					end
					package.loaded["adapters.timer_scheduler"].after = function(_, callback)
						local handle = { timer = {} }
						pending[#pending + 1] = function() handle.timer = nil; callback() end
						return handle, true
					end
					helpers.assert_true(dashboard.show())
					state.receiver({ body = { action = "pick" } })
					pending[#pending]()
					helpers.assert_type(complete, "function")
					local success = mode == "empty_success"
					local rows
					if mode ~= "failed_nil" then rows = {} end
					complete(rows, success)
					helpers.assert_eq(alerts, success and { "metrics_apps.no_app_detected" } or {})
					local stopped = 0
					for _, message in ipairs(logs) do
						if message == "Application metrics picker stopped after discovery failure." then stopped = stopped + 1 end
					end
					helpers.assert_eq(stopped, success and 0 or 1)
				end)
			end)
		end)
	end
end)

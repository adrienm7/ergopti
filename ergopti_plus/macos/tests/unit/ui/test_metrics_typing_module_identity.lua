--- tests/unit/ui/test_metrics_typing_module_identity.lua

--- ==============================================================================
--- MODULE: Typing Dashboard Module Identity Tests
--- DESCRIPTION:
--- Restoration and direct opening must share one dashboard and ingest subscription.
--- ==============================================================================

local helpers = require("tests.helpers")
local Restore = require("tests.support.ui_restore_fixture")
local load_dashboard = require("tests.support.metrics_typing_fixture")

helpers.describe("typing dashboard identity (typing-dashboard-single-owner)", function()
	for _, opened_first in ipairs({ false, true }) do
		helpers.it("shares the restored owner when direct opening comes " .. (opened_first and "first" or "last"), function()
			helpers.with_stub_scope({ "adapters.file_system", "modules.keylogger.sqlite_reader",
				"modules.keylogger.log_manager", "ui.ui_builder", "hs.fs", "hs.json" }, function()
				Restore.with_fixture({ settings = { ["ergopti.ui_restore_state"] = { "metrics_typing" } } },
					function(restore, scheduler)
						package.loaded["adapters.file_system"] = { read_with_status = function() return nil, "absent" end }
						package.loaded["modules.keylogger.sqlite_reader"] = {}
						local subscriptions = 0
						local dashboard, context = load_dashboard(scheduler, function()
							subscriptions = subscriptions + 1
							return true
						end)
						if opened_first then helpers.assert_eq(dashboard.show(), true) end
						local before = #scheduler.after_handles
						helpers.assert_eq(restore.restore(), true)
						helpers.assert_eq(#scheduler.after_handles, before + 1)
						scheduler.after_handles[before + 1].callback()
						helpers.assert_eq(require("ui.metrics_typing").show(), true)
						helpers.assert_eq(context.webviews_created, 1, "restoration must reuse the canonical WebView owner")
						helpers.assert_eq(subscriptions, 1, "one dashboard must subscribe only once")
						helpers.assert_eq(dashboard._wv, context.webview)
						helpers.assert_nil(package.loaded["ui.metrics_typing.init"], "no alternate runtime may be constructed")
						helpers.assert_eq(dashboard.close(), true)
						helpers.assert_eq(context.deleted, 1)
					end)
			end)
		end)
	end
end)

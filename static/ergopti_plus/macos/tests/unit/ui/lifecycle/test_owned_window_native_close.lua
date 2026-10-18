--- tests/unit/ui/lifecycle/test_owned_window_native_close.lua

--- ==============================================================================
--- MODULE: Owned Native Window Close Regression
--- DESCRIPTION:
--- Real controllers must release native references on user close, preserve
--- still-open singleton reuse, and keep explicit deferred deletion exact.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.ui.owned_window_close_fixture")

helpers.describe("owned windows release native references on user close", function()
	for _, module_name in ipairs({ "ui.config_cleanup", "ui.onboarding", "ui.metrics_apps",
		"ui.model_browser", "ui.changelog" }) do
		helpers.it(module_name .. " releases a user-closed window and preserves its successor", function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				helpers.assert_true(h.show())
				helpers.assert_eq(#h.windows, 1, "an open host reuses its current native window")
				first:user_close()
				helpers.assert_nil(h.retained[first], "closed native userdata must not remain pinned")
				helpers.assert_eq(first.deletes, 0, "native close must retire without another Lua delete")
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				successor:user_close()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		helpers.it(module_name .. " preserves explicit deferred deletion while reopening", function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				helpers.assert_true(h.close())
				helpers.assert_eq(#h.deferred, 1, "explicit deletion retains native fade completion")
				helpers.assert_true(h.retained[first])
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[first])
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_true(h.retained[successor], "old native completion cannot delete a successor")
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		helpers.it(module_name .. " refuses a window whose native close policy throws", function()
			with_window(module_name, function(_, h)
				h.policy_refuses = "throw"
				helpers.assert_eq(h.show(), false)
				h.drain()
				helpers.assert_nil(next(h.retained), "failed publication must settle its exact native candidate")
			end)
		end)
	end
end)

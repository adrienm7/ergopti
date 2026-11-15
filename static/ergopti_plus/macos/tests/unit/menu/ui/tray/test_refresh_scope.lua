--- tests/unit/menu/ui/tray/test_refresh_scope.lua

--- ==============================================================================
--- MODULE: Menu Refresh Scope
--- DESCRIPTION:
--- hs.menubar has no per-row update, so every macOS toggle rebuilt the whole
--- tree. A refresh asked only from clicks in one branch now rebuilds that
--- branch; these cases pin that anything else still rebuilds everything.
--- ==============================================================================

local helpers = require("tests.helpers")

local RefreshScope = require("menu.ui.transactions.refresh_scope")

helpers.describe("menu refresh scope", function()
	helpers.it("(menu-refresh-scope) clicks in one branch keep the refresh to that branch", function()
		local scope = RefreshScope.new()
		local previous = scope.enter_click("tap_holds")
		scope.request()
		scope.request()
		scope.leave_click(previous)
		helpers.assert_eq(scope.take(), "tap_holds")
		helpers.assert_nil(scope.take(), "take() resets the scope")
	end)

	helpers.it("(menu-refresh-scope) a request outside a click, from a global row or two branches is all", function()
		local scope = RefreshScope.new()
		scope.request()
		helpers.assert_eq(scope.take(), RefreshScope.ALL, "a watcher or a timer asked")
		local previous = scope.enter_click(nil)
		scope.request()
		scope.leave_click(previous)
		helpers.assert_eq(scope.take(), RefreshScope.ALL, "a row no branch owns")
		previous = scope.enter_click("gestures")
		scope.request()
		scope.leave_click(previous)
		previous = scope.enter_click("shortcuts")
		scope.request()
		scope.leave_click(previous)
		helpers.assert_eq(scope.take(), RefreshScope.ALL, "two branches")
	end)

	helpers.it("(menu-refresh-scope) a request after the click returned widens the scope", function()
		local scope = RefreshScope.new()
		local previous = scope.enter_click("metrics")
		scope.request()
		scope.leave_click(previous)
		scope.request()
		helpers.assert_eq(scope.take(), RefreshScope.ALL, "an asynchronous completion may touch any branch")
	end)
end)

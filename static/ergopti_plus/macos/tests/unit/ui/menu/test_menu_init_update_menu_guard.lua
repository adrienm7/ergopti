--- tests/unit/ui/menu/test_menu_init_update_menu_guard.lua

--- ==============================================================================
--- MODULE: ui.menu.init — updateMenu early-call guard regression
--- DESCRIPTION:
--- Locks down the boot crash where ui/menu/init.lua wired
--- `update_menu = function() updateMenu() end` (and the hotstring-editor
--- equivalent) as a ctx callback. `updateMenu` is a forward-declared upvalue
--- assigned LATER in the file, but the LLM startup path calls ctx.update_menu()
--- during boot BEFORE that assignment runs — so the unguarded closure threw
--- "attempt to call a nil value (upvalue 'updateMenu')". The throw was swallowed
--- (it ran inside the startup path) and silently killed the entire LLM boot: no
--- MLX server was ever started, leaving a permanent red dot.
---
--- Every OTHER updateMenu() call site in the file already guards with
--- `type(updateMenu) == "function"`; these two had diverged. This test encodes
--- the invariant as a source assertion (the same style as the
--- DYN_HOTSTRINGS_DEFAULT_DELAY placement guard) because the create()→ctx wiring
--- is integration-tier and not exercised by the unit harness.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the ui/menu/init.lua source via the active package.path so the test is
--- independent of the runner's working directory.
local function read_menu_init_source()
	local path = package.searchpath("ui.menu.init", package.path)
	helpers.assert_true(type(path) == "string" and path ~= "", "could not resolve ui.menu.init on package.path")
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "could not open ui/menu/init.lua")
	local src = fh:read("*a")
	fh:close()
	return src
end




-- ===========================================================
-- ===========================================================
-- ======= 1/ No unguarded early updateMenu() closure ========
-- ===========================================================
-- ===========================================================

helpers.describe("ui.menu.init — updateMenu early-call guard", function()
	helpers.it("never wires a bare `function() updateMenu() end` ctx callback", function()
		local src = read_menu_init_source()
		-- The exact buggy form that fired before `updateMenu` was assigned. Both the
		-- ctx.update_menu wiring and the hotstring-editor set_update_menu callback
		-- used it; either can fire during boot, so neither may go unguarded.
		helpers.assert_true(
			not src:find("function() updateMenu() end", 1, true),
			"a ctx callback that can fire during boot must guard with " ..
			"type(updateMenu) == 'function' — an unguarded updateMenu() crashed LLM startup"
		)
	end)
end)

--- tests/unit/ui/test_menu_shortcuts_sandbox.lua

--- ==============================================================================
--- MODULE: menu_shortcuts extension sandbox (regression)
--- DESCRIPTION:
--- Guards against the regression where the extension menu.lua sandbox table had
--- no __index fallback to _G. Any call to a standard Lua builtin (string, math,
--- table, pairs, ipairs, type, tostring…) from an extension menu.lua would raise
--- "attempt to call a nil value", silently dropping the extension from the menu.
--- Fix: setmetatable(sandbox, { __index = _G }) before the chunk is executed.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =====================================================================
-- =====================================================================
-- ======= 1/ Sandbox __index fallback =================================
-- =====================================================================
-- =====================================================================

helpers.describe("menu_shortcuts: extension sandbox has __index fallback to _G", function()

	helpers.it("source calls setmetatable(sandbox, { __index = _G }) before setfenv", function()
		-- Selected by a declaration unique to ui/menu/menu_shortcuts.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_wrap_symbols_submenu")
		helpers.assert_true(src ~= nil, "ui/menu/menu_shortcuts.lua source must be locatable")

		-- The fix adds a setmetatable call with __index = _G inside the sandbox block.
		helpers.assert_true(
			src:find("__index", 1, true) ~= nil,
			"menu_shortcuts.lua must set __index on the sandbox metatable")
		helpers.assert_true(
			src:find("setmetatable(sandbox", 1, true) ~= nil,
			"menu_shortcuts.lua must call setmetatable(sandbox, ...) to expose _G builtins")
	end)

	helpers.it("setmetatable call appears before setfenv in source", function()
		-- Selected by a declaration unique to ui/menu/menu_shortcuts.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_wrap_symbols_submenu")
		helpers.assert_true(src ~= nil, "ui/menu/menu_shortcuts.lua source must be locatable")

		local meta_pos  = src:find("setmetatable(sandbox", 1, true)
		local fenv_pos  = src:find("setfenv(chunk_or_err", 1, true)
		helpers.assert_true(meta_pos ~= nil, "setmetatable(sandbox) must exist")
		helpers.assert_true(fenv_pos ~= nil, "setfenv(chunk_or_err) must exist")
		helpers.assert_true(meta_pos < fenv_pos,
			"setmetatable must appear before setfenv so builtins are available when the chunk runs")
	end)

end)

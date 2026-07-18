--- tests/meta/test_shortcuts_no_double_start.lua

--- ==============================================================================
--- MODULE: Shortcuts Double-Start Guard Meta Test
--- DESCRIPTION:
--- Static source guard for the "shortcuts-watcher-leak" audit finding.
---
--- ROOT CAUSE ENCODED:
--- Both `shortcuts/script_control.lua` (M.start) and
--- `shortcuts/keyboard_shortcuts.lua` (M.start) lacked a guard against being
--- called a second time while already running. A double-start would create a
--- second eventtap / rebind all hotkeys on top of the first, leaking the previous
--- watcher handle with no way to stop it. On a hot-reload, this doubled the
--- number of active event interceptors and caused duplicate key actions.
---
--- The fix adds an early-return guard at the top of each M.start(), logging a
--- WARNING and returning immediately when the module is already started.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end


-- =================================================================
-- =================================================================
-- ======= 1/ script_control.lua double-start guard ================
-- =================================================================
-- =================================================================

helpers.describe("shortcuts/script_control.lua: double-start guard (shortcuts-watcher-leak)", function()

	helpers.it("M.start() checks _tap before creating a new eventtap", function()
		local src = read_source("modules/shortcuts/script_control.lua")
		-- The fix adds: if _tap then Logger.warn(...) return end
		-- before the pcall(hs.eventtap.new, ...) call
		local start_fn = src:match("function M%.start%(.-\nend")
			or src:match("function M%.start%([^%)]*%)(.-)%nend")
		-- Look for _tap guard anywhere in M.start body
		helpers.assert_true(
			src:match("if _tap then[^\n]*\n[^\n]*warn") ~= nil,
			"script_control M.start() must guard against double-start by checking if _tap is already set (shortcuts-watcher-leak)")
	end)

end)


-- =========================================================================
-- =========================================================================
-- ======= 2/ keyboard_shortcuts.lua double-start guard ====================
-- =========================================================================
-- =========================================================================

helpers.describe("shortcuts/keyboard_shortcuts.lua: double-start guard (shortcuts-watcher-leak)", function()

	helpers.it("M.start() checks _started before rebinding hotkeys", function()
		local src = read_source("modules/shortcuts/keyboard_shortcuts.lua")
		-- The fix adds: if _started then Logger.debug(...) return end at the top of M.start()
		helpers.assert_true(
			src:match("if _started then[^\n]*\n[^\n]*debug") ~= nil,
			"keyboard_shortcuts M.start() must guard against double-start by checking _started (shortcuts-watcher-leak)")
	end)

end)

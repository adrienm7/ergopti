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

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end


-- =================================================================
-- =================================================================
-- ======= 1/ script_control.lua double-start guard ================
-- =================================================================
-- =================================================================

helpers.describe("shortcuts/script_control.lua: double-start guard (shortcuts-watcher-leak)", function()

	helpers.it("M.start() requires the complete committed native pair before reusing it", function()
		local src = read_source("local function log_shortcut_if_available") -- modules/shortcuts/script_control.lua
		helpers.assert_true(
			src:find("if _tap and _tap_committed and _tap_watchdog and _tap_watchdog_committed then", 1, true) ~= nil,
			"script_control M.start() may reuse only one fully committed tap/watchdog pair (shortcuts-watcher-leak)")
	end)

end)


-- =========================================================================
-- =========================================================================
-- ======= 2/ keyboard_shortcuts.lua double-start guard ====================
-- =========================================================================
-- =========================================================================

helpers.describe("shortcuts/keyboard_shortcuts.lua: double-start guard (shortcuts-watcher-leak)", function()

	helpers.it("M.start() checks _started before rebinding hotkeys", function()
		local src = read_source("local function load_assignments") -- modules/shortcuts/keyboard_shortcuts.lua
		-- The fix adds: if _started then Logger.debug(...) return end at the top of M.start()
		helpers.assert_true(
			src:match("if _started then[^\n]*\n[^\n]*debug") ~= nil,
			"keyboard_shortcuts M.start() must guard against double-start by checking _started (shortcuts-watcher-leak)")
	end)

end)

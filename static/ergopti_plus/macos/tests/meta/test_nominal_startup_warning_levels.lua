--- tests/meta/test_nominal_startup_warning_levels.lua

--- ==============================================================================
--- MODULE: Nominal Startup Warning-Level Regression Test
--- DESCRIPTION:
--- Prevents expected startup states from polluting the warning/error diagnostic.
--- The affected paths are deliberate fallbacks or idempotent lifecycle calls,
--- not failures requiring user intervention.
---
--- FEATURES & RATIONALE:
--- 1. Clean Diagnostic: Expected version, configuration, and synchronization
--- states must stay below WARNING so actual operational faults remain visible.
--- 2. Root-Cause Guard: Each assertion pins the source-level lifecycle branch
--- that emitted one of the warnings reported in error.txt.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================================
-- =====================================================
-- ======= 1/ Expected Startup States ==================
-- =====================================================
-- =====================================================

--- Reads a production Lua source file from the driver root.
--- @param relative_path string Path relative to the macOS driver root.
--- @return string The source contents.
-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local source = helpers.read_driver_source(selector)
	return source
end

helpers.describe("meta: nominal startup diagnostics stay warning-free", function()
	helpers.it("unavailable optional primer event names are debug-only", function()
		local source = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		helpers.assert_true(source:find("primer event type '%%s' is unavailable", 1, false) ~= nil)
		helpers.assert_true(source:find("Logger.debug(LOG, \"  primer event type", 1, true) ~= nil)
	end)

	helpers.it("deferred Karabiner suppression configuration is debug-only", function()
		local source = read_source("local function build_managed_output_set") -- modules/keylogger/kc_bridge.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"Tap/hold configuration is deferred", 1, true) ~= nil)
		helpers.assert_true(source:find("No tap_hold_config or available_actions", 1, true) == nil)
	end)

	helpers.it("the bundled hotstring fallback is informational", function()
		local source = read_source("local function has_common_hotstring_groups") -- init.lua
		helpers.assert_true(source:find("Logger.info(LOG, \"No shared hotstring groups", 1, true) ~= nil)
	end)

	helpers.it("the normal dynamic-hotstring boot order is debug-only", function()
		local source = read_source("local function register_prefix_entries") -- modules/dynamic_hotstrings/rules_engine.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"Personal data received before keymap wiring", 1, true) ~= nil)
		helpers.assert_true(source:find("personal data present but keymap not wired yet", 1, true) == nil)
	end)

	helpers.it("idempotent keyboard shortcut startup is debug-only", function()
		local source = read_source("local function load_assignments") -- modules/shortcuts/keyboard_shortcuts.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"M.start() called again after menu-state synchronization", 1, true) ~= nil)
		helpers.assert_true(source:find("M.start() called more than once", 1, true) == nil)
	end)

	helpers.it("automatic gesture recovery stays debug-only", function()
		local source = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"schedule_emergency_recycle: SCHEDULED", 1, true) ~= nil)
		helpers.assert_true(source:find("Logger.debug(LOG, \"EMERGENCY RECYCLE executing now", 1, true) ~= nil)
	end)

	helpers.it("automatic CapsWord probe cleanup stays debug-only", function()
		local source = read_source("local function read_current_layout_from_hitoolbox") -- platform/remap/watchers.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"CapsWord probe timed out", 1, true) ~= nil)
	end)

	helpers.it("gesture lift-off drift rejection stays debug-only", function()
		local source = read_source("local function triggerLiveAxisIfNeeded") -- modules/gestures/engine.lua
		helpers.assert_true(source:find("Logger.debug(LOG, \"commitGesture: dir=%s does not match gesture lockedDir", 1, true) ~= nil)
	end)

	helpers.it("passive mouse-tap recovery does not pollute warnings", function()
		local source = read_source("local function invalidate_observed_context") -- modules/keymap/init.lua
		helpers.assert_true(source:find("name == \"mouse\" and Logger.debug or Logger.warn", 1, true) ~= nil)
	end)
end)

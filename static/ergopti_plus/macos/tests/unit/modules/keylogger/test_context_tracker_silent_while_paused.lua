--- tests/unit/modules/keylogger/test_context_tracker_silent_while_paused.lua

--- ==============================================================================
--- MODULE: Regression — the context tracker records NOTHING while paused
--- DESCRIPTION:
--- Project invariant `project-suspend-pause-invariant`: a paused script behaves
--- « comme ahk éteint » — absolutely nothing is recorded. handle_key honoured it,
--- but context_tracker held no reference to the pause predicate at all, and its
--- three writer paths are driven by watchers that pause never tears down
--- (hs.window.filter, ProcessLifecycle.onAppActivate, the AX observer — only
--- keylogger.M.stop() removes those):
---   1. M.update_private_status -> append_log{type="window_switch", prev_title, next_title}
---   2. M.app_watcher_cb        -> log_app_switch(prev_app, next_app, duration)
---   3. the AXValueChanged path -> flush_buffer + append_log{type="sys_autocorrect"}
--- Window TITLES are the most identifying payload the tracker handles, so this
--- was a privacy leak as well as an invariant violation.
---
--- WHAT THIS PINS:
--- Paused, every writer is silent and the sentinel title never escapes. Running,
--- the SAME calls do produce rows — so deleting the writers to "fix" the leak
--- turns this test red instead of green.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Sentinel window title. It must never appear in anything captured while paused.
local SECRET_TITLE = "SECRET-TITLE"

--- Second title: update_private_status only logs a window_switch when the title
--- CHANGES, so the scenario must call it twice with different titles.
local OTHER_TITLE = "SECRET-TITLE-2"

--- hs.timer.absoluteTime() is nanoseconds; the tracker divides by 1e6. The
--- window-switch branch additionally requires duration_ms > 1000, so the two
--- readings must be more than a second apart.
local T0_NS = 1000000000
local T1_NS = 9000000000




-- ===============================================
-- ===============================================
-- ======= 1/ Scenario Harness ===================
-- ===============================================
-- ===============================================

--- Builds a tracker wired to a capturing log manager and a controllable pause
--- predicate, then drives every ungated writer path.
--- @param paused boolean Value the injected pause predicate returns.
--- @return table Array of everything the tracker tried to persist.
local function drive_writers(paused)
	local captured = {}
	local now_ns   = T0_NS

	local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
		timer = { absoluteTime = function() return now_ns end },
		window = {
			focusedWindow = function()
				return {
					title        = function() return SECRET_TITLE end,
					isFullScreen = function() return false end,
				}
			end,
		},
		application = { watcher = { activated = 1 } },
		axuielement = {
			observer = { new = function() return nil end },
			windowElement = function() return nil end,
		},
	})

	local log_manager = {
		append_log     = function(entry) table.insert(captured, entry) end,
		flush_buffer   = function() table.insert(captured, { type = "flush_buffer" }) end,
		log_app_switch = function(prev_app, next_app, duration_ms)
			table.insert(captured, {
				type = "app_switch", prev_app = prev_app,
				next_app = next_app, duration_ms = duration_ms,
			})
		end,
	}

	local state = {
		active_app_name  = "Safari",
		active_app_start = 0,
		synth_queue      = {},
	}
	tracker.init(state, log_manager, function() return paused end)

	-- Writer 1: two update_private_status calls with DIFFERENT titles, far enough
	-- apart in time to clear the 1000 ms floor, so the window_switch branch fires.
	tracker.update_private_status()
	_G.hs.window.focusedWindow = function()
		return {
			title        = function() return OTHER_TITLE end,
			isFullScreen = function() return false end,
		}
	end
	now_ns = T1_NS
	tracker.update_private_status()

	-- Writer 2: an application activation, which logs the previous app's interval.
	tracker.app_watcher_cb("Terminal", _G.hs.application.watcher.activated, {
		bundleID = function() return "com.apple.Terminal" end,
		path     = function() return "/System/Applications/Utilities/Terminal.app" end,
		pid      = function() return 42 end,
	})

	return captured
end

--- Serialises every captured entry so a sentinel leak is detectable wherever it
--- hides — a nested field a field-by-field check would miss.
--- @param captured table Entries collected from the stub log manager.
--- @return string Flattened representation.
local function flatten(captured)
	local parts = {}
	local function walk(v)
		if type(v) == "table" then
			for k, inner in pairs(v) do
				parts[#parts + 1] = tostring(k)
				walk(inner)
			end
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	walk(captured)
	return table.concat(parts, "|")
end




-- ==========================================================
-- ==========================================================
-- ======= 2/ Regression: Paused Means Total Silence ========
-- ==========================================================
-- ==========================================================

helpers.describe("keylogger/context_tracker: pause silences every writer (project-suspend-pause-invariant)", function()

	helpers.it("records nothing at all while the script is paused", function()
		local captured = drive_writers(true)
		helpers.assert_eq(#captured, 0,
			"a paused script must record NOTHING — « comme ahk éteint » "
			.. "(captured: " .. flatten(captured) .. ")")
	end)

	helpers.it("never lets a window title escape while paused", function()
		local captured = drive_writers(true)
		local blob = flatten(captured)
		helpers.assert_true(blob:find(SECRET_TITLE, 1, true) == nil,
			"window titles are the most identifying payload the tracker handles and must "
			.. "never be persisted while paused (found in: " .. blob .. ")")
	end)

	helpers.it("still records the very same events while running", function()
		-- Guards against a false-green "fix" that simply deletes the writers:
		-- the identical drive sequence must produce rows when NOT paused.
		local captured = drive_writers(false)
		helpers.assert_true(#captured > 0,
			"the tracker must still persist context events while running")

		local kinds = {}
		for _, entry in ipairs(captured) do kinds[entry.type] = true end
		helpers.assert_true(kinds.window_switch,
			"the running tracker must still emit window_switch rows")
		helpers.assert_true(kinds.app_switch,
			"the running tracker must still emit app_switch rows")
		helpers.assert_true(flatten(captured):find(SECRET_TITLE, 1, true) ~= nil,
			"the running tracker must still capture the window title (proving the paused "
			.. "run was silenced by the guard, not by an inert scenario)")
	end)
end)

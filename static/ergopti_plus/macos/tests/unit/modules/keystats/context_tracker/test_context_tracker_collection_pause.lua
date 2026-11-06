--- tests/unit/modules/keystats/context_tracker/test_context_tracker_collection_pause.lua

--- ==============================================================================
--- MODULE: Regression — the user's metrics pause silences window activity (HS-004)
--- DESCRIPTION:
--- "Pause collection" sets CoreState.collection_suspended while hotstrings keep
--- running, so the global script-pause predicate stays false. The tracker gated
--- its writers on that global predicate only: a title change or app switch made
--- during the metrics pause still reached the log, and the first window switch
--- after resume carried the paused title as prev_title (audit MM-001).
---
--- WHAT THIS PINS:
--- While suspended, no window_switch, app_switch or autocorrect row is written
--- and no paused title escapes, even through the first post-resume switch. The
--- context itself keeps tracking the foreground app, so privacy classification
--- is current on resume. The same sequence still records rows while collecting.
--- ==============================================================================

local helpers = require("tests.helpers")

local SECRET_TITLE = "PAUSED-SECRET"
local OTHER_SECRET = "PAUSED-SECRET-2"
local AFTER_TITLE  = "AFTER-RESUME"
local LATER_TITLE  = "AFTER-RESUME-2"




-- ===============================================
-- ===============================================
-- ======= 1/ Scenario Harness ===================
-- ===============================================
-- ===============================================

--- Drives title changes and an app switch, optionally inside a metrics pause.
--- @param suspended boolean True to suspend collection around the middle part.
--- @return table captured Every entry the tracker tried to persist.
--- @return table state Shared core state after the scenario.
local function drive(suspended)
	local captured = {}
	local now_ns = 1000000000
	local title = "BEFORE"
	local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
		timer = { absoluteTime = function() return now_ns end },
		window = {
			focusedWindow = function()
				return {
					title        = function() return title end,
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
		append_log     = function(entry) captured[#captured + 1] = entry end,
		flush_buffer   = function() end,
		log_app_switch = function(prev_app, next_app, duration_ms)
			captured[#captured + 1] = { type = "app_switch", prev_app = prev_app,
				next_app = next_app, duration_ms = duration_ms }
		end,
	}
	local state = { active_app_name = "Safari", active_app_start = 0 }
	tracker.init(state, log_manager, function() return false end)

	tracker.update_private_status()
	if suspended then
		tracker.suspend_collection_context()
		state.collection_suspended = true
	end
	for _, next_title in ipairs({ SECRET_TITLE, OTHER_SECRET }) do
		now_ns = now_ns + 5000000000
		title = next_title
		tracker.update_private_status()
	end
	now_ns = now_ns + 5000000000
	tracker.app_watcher_cb("Notes", _G.hs.application.watcher.activated, {
		bundleID = function() return "com.apple.Notes" end,
		path     = function() return "/System/Applications/Notes.app" end,
		pid      = function() return 7 end,
	})
	now_ns = now_ns + 5000000000
	if suspended then
		state.collection_suspended = false
		tracker.resume_collection_context()
	end
	for _, next_title in ipairs({ AFTER_TITLE, LATER_TITLE }) do
		now_ns = now_ns + 5000000000
		title = next_title
		tracker.update_private_status()
	end
	return captured, state
end

--- Flattens captured entries so a sentinel is found wherever it hides.
--- @param captured table Captured entries.
--- @return string blob Flattened representation.
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




-- ==============================================
-- ==============================================
-- ======= 2/ Metrics Pause Regression ==========
-- ==============================================
-- ==============================================

helpers.describe("keystats/context_tracker: metrics pause silences window activity (HS-004)", function()
	helpers.it("never persists a title seen during the metrics pause", function()
		local captured = drive(true)
		local blob = flatten(captured)
		helpers.assert_true(blob:find(SECRET_TITLE, 1, true) == nil,
			"a paused title must not escape, even as the next prev_title: " .. blob)
	end)

	helpers.it("records no app switch made during the pause and keeps the context current", function()
		local captured, state = drive(true)
		for _, entry in ipairs(captured) do
			helpers.assert_true(entry.next_app ~= "Notes",
				"the app switch made while paused must not be logged")
		end
		helpers.assert_eq(state.active_app_name, "Notes",
			"the foreground context keeps tracking so privacy is current on resume")
	end)

	helpers.it("closes the pre-pause interval and restarts timing at resume", function()
		local captured, state = drive(true)
		local closed, switches = nil, 0
		for _, entry in ipairs(captured) do
			if entry.type == "app_switch" and entry.prev_app == "Safari" then closed = entry end
			if entry.type == "window_switch" then switches = switches + 1 end
		end
		helpers.assert_true(closed ~= nil and closed.next_app == nil,
			"the interval owned before the pause is closed at the boundary")
		helpers.assert_eq(closed.duration_ms, 1000)
		helpers.assert_eq(switches, 1, "only the post-resume title change is a window switch")
		helpers.assert_eq(state.active_app_start, 21000,
			"the resumed foreground interval starts at resume, not at the paused switch")
	end)

	helpers.it("still records the same sequence while collecting", function()
		local captured = drive(false)
		local blob = flatten(captured)
		helpers.assert_true(blob:find(SECRET_TITLE, 1, true) ~= nil,
			"the running tracker still captures titles (the paused run is not inert)")
		local app_switch = false
		for _, entry in ipairs(captured) do
			if entry.type == "app_switch" and entry.next_app == "Notes" then app_switch = true end
		end
		helpers.assert_true(app_switch, "the running tracker still logs app switches")
	end)
end)

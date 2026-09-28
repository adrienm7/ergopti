--- tests/unit/modules/gestures/test_system_gesture_conflicts.lua

--- ==============================================================================
--- MODULE: Cached System Gesture Conflicts
--- DESCRIPTION:
--- Proves reads are asynchronous, snapshots publish atomically, and new conflict
--- families use current settings rather than assuming every gesture conflicts.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads real conflict policy over controlled process boundaries.
--- @param body function Receives the module and queued native completions.
local function fixture(body)
	local names = { "modules.gestures.conflicts", "infra.logger", "infra.i18n", "ui.gesture_conflict_notice" }
	local saved, pending = {}, {}
	local saved_shell = package.loaded["adapters.shell_runner"]
	local notices = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["ui.gesture_conflict_notice"] = { show = function(warning) notices[#notices + 1] = warning end }
	package.loaded["adapters.shell_runner"] = {
		exec = function() error("blocking defaults probe") end,
		spawn = function(bin, args, callback)
			local task = { bin = bin, args = args, done = callback, cancelled = false }
			pending[#pending + 1] = task
			return { isSettled = function() return task.cancelled end,
				terminate = function() task.cancelled = true; callback(1, "", "cancelled") end }
		end,
	}
	local ok, err = xpcall(function() body(require("modules.gestures.conflicts"), pending, notices) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved_shell
	if not ok then error(err, 0) end
end

helpers.describe("system gesture snapshots (gesture-conflicts)", function()
	helpers.it("cancels owned tasks and refuses late completion after shutdown", function()
		fixture(function(subject, pending)
			local callbacks = 0
			subject.refresh(function() callbacks = callbacks + 1 end)
			subject.restore_all_overrides()
			for _, task in ipairs(pending) do
				helpers.assert_true(task.cancelled)
				task.done(0, "TrackpadRightClick = 0;", "")
			end
			helpers.assert_eq(callbacks, 0)
			helpers.assert_type(subject.on_action_changed("tap_2", "lookup"), "table")
			subject.refresh()
			helpers.assert_eq(#pending, 6)
		end)
	end)
	helpers.it("checks the live enabled posture at boot completion and warns once per group", function()
		fixture(function(subject, pending, notices)
			local enabled = false
			local actions = { tap_2 = "lookup", swipe_3_left = "word_prev", swipe_3_right = "word_next" }
			subject.apply_all_overrides(actions, function() return enabled end)
			helpers.assert_eq(#notices, 0)
			enabled = true
			for _, task in ipairs(pending) do task.done(0, "TrackpadRightClick = 1; TrackpadThreeFingerDrag = 1;", "") end
			helpers.assert_eq(#notices, 2)
			subject.apply_all_overrides(actions, function() return enabled end)
			for _, task in ipairs(pending) do task.done(0, "TrackpadRightClick = 1;", "") end
			helpers.assert_eq(#notices, 2)
		end)
	end)
	helpers.it("does not warn when gesture startup was refused", function()
		fixture(function(subject, pending, notices)
			subject.apply_all_overrides({ tap_2 = "lookup" }, function() return false end)
			for _, task in ipairs(pending) do task.done(0, "TrackpadRightClick = 1;", "") end
			helpers.assert_eq(#notices, 0)
		end)
	end)
	helpers.it("never probes while evaluating an assignment", function()
		fixture(function(subject, pending)
			local warning = subject.on_action_changed("tap_3", "lookup")
			helpers.assert_type(warning, "table")
			helpers.assert_eq(#pending, 0)
		end)
	end)
	helpers.it("publishes only after every asynchronous defaults probe settles", function()
		fixture(function(subject, pending)
			local completions = 0
			subject.refresh(function() completions = completions + 1 end)
			helpers.assert_eq(#pending, 3)
			for i = 1, 2 do pending[i].done(0, "TrackpadThreeFingerTapGesture = 0;", "") end
			helpers.assert_eq(completions, 0)
			pending[3].done(0, "", "")
			helpers.assert_eq(completions, 1)
			helpers.assert_nil(subject.on_action_changed("tap_3", "lookup"))
		end)
	end)
	helpers.it("detects secondary click and three-finger dragging", function()
		fixture(function(subject, pending)
			subject.refresh()
			for _, task in ipairs(pending) do task.done(0,
				"TrackpadRightClick = 1; TrackpadThreeFingerDrag = 1; TrackpadThreeFingerHorizSwipeGesture = 0;", "") end
			helpers.assert_type(subject.on_action_changed("tap_2", "lookup"), "table")
			helpers.assert_type(subject.on_action_changed("swipe_3_left", "word_prev"), "table")
		end)
	end)
	helpers.it("requires both swipe and drag policies before calling three-finger motion conflict-free", function()
		for _, output in ipairs({ "TrackpadThreeFingerDrag = 0;", "TrackpadThreeFingerHorizSwipeGesture = 0;" }) do
			fixture(function(subject, pending)
				subject.refresh()
				for _, task in ipairs(pending) do task.done(0, output, "") end
				helpers.assert_type(subject.on_action_changed("swipe_3_left", "word_prev"), "table")
			end)
		end
		fixture(function(subject, pending)
			subject.refresh()
			for _, task in ipairs(pending) do task.done(0, "TrackpadThreeFingerDrag = 0; TrackpadThreeFingerHorizSwipeGesture = 0;", "") end
			helpers.assert_nil(subject.on_action_changed("swipe_3_left", "word_prev"))
		end)
	end)
	helpers.it("keeps failed probes unknown rather than calling them disabled", function()
		fixture(function(subject, pending)
			subject.refresh()
			for _, task in ipairs(pending) do task.done(1, "", "unavailable") end
			helpers.assert_type(subject.on_action_changed("tap_2", "lookup"), "table")
			helpers.assert_nil(subject.native_pinch_enabled())
		end)
	end)
	helpers.it("reports native pinch without manufacturing an assigned pinch conflict", function()
		fixture(function(subject, pending)
			subject.refresh()
			for _, task in ipairs(pending) do task.done(0, "TrackpadPinch = 1;", "") end
			helpers.assert_true(subject.native_pinch_enabled())
			helpers.assert_eq(#subject.active_conflicts({}), 0)
		end)
	end)
	helpers.it("coalesces concurrent refreshes and ignores duplicate completions", function()
		fixture(function(subject, pending)
			local count = 0
			subject.refresh(function() count = count + 1 end)
			subject.refresh(function() count = count + 1 end)
			helpers.assert_eq(#pending, 3)
			for _, task in ipairs(pending) do task.done(0, "TrackpadRightClick = 0;", ""); task.done(1, "", "") end
			helpers.assert_eq(count, 2)
			helpers.assert_nil(subject.on_action_changed("tap_2", "lookup"))
		end)
	end)
end)

--- tests/unit/modules/gestures/engine/test_gesture_slot_report.lua

--- ==============================================================================
--- MODULE: Gesture Slots a Touchpad Cannot Fire, Named
--- DESCRIPTION:
--- The menu greys the slots a touchpad cannot count, but a binding written by
--- hand, or carried from another machine, never passes through the menu. On a
--- three-finger pad such a swipe_4_up stayed bound and silent forever. Starting
--- the reader now names every unreachable slot, every bound one among them, and
--- every bound two-finger slot, which the ungrabbed desktop also acts on.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")
local Finder = helpers.load_module("modules.gestures.touchpad_finder")
local SlotReport = helpers.load_module("modules.gestures.slot_report")




-- =================================================================
-- =================================================================
-- ======= 1/ The pure report ======================================
-- =================================================================
-- =================================================================

local SLOTS = { "swipe_2_up", "tap_2", "swipe_3_left", "swipe_4_up", "swipe_4_horiz", "tap_5" }

helpers.describe("gesture slot report: what the hardware cannot reach", function()

	helpers.it("names each unreachable slot on a three-finger pad, sorted", function()
		local report = SlotReport.report(SLOTS, {}, 3)
		helpers.assert_eq(table.concat(report.unreachable, ","), "swipe_4_horiz,swipe_4_up,tap_5")
		helpers.assert_eq(#report.bound_unreachable, 0, "nothing is bound")
	end)

	helpers.it("separates the bound unreachable slots", function()
		local report = SlotReport.report(SLOTS, { swipe_4_up = true, swipe_3_left = true }, 3)
		helpers.assert_eq(table.concat(report.bound_unreachable, ","), "swipe_4_up")
	end)

	helpers.it("reports nothing unreachable when the count is unknown", function()
		for _, unknown in ipairs({ 0, false }) do
			local report = SlotReport.report(SLOTS, { tap_5 = true }, unknown or nil)
			helpers.assert_eq(#report.unreachable, 0, "an unread capability must never take a gesture away")
		end
	end)

	helpers.it("names the bound two-finger slots and only those", function()
		local report = SlotReport.report(SLOTS, { swipe_2_up = true, tap_2 = true, swipe_3_left = true }, 5)
		helpers.assert_eq(table.concat(report.bound_two_finger, ","), "swipe_2_up,tap_2")
	end)

	helpers.it("knows the nine two-finger slots by name", function()
		for _, slot in ipairs({ "swipe_2_left_up", "swipe_2_right", "tap_2" }) do
			helpers.assert_true(SlotReport.slot_is_two_finger(slot), slot)
		end
		for _, slot in ipairs({ "swipe_3_up", "tap_3", "swipe_20_up", "tap_22" }) do
			helpers.assert_true(not SlotReport.slot_is_two_finger(slot), slot)
		end
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ The reader start says it =============================
-- =================================================================
-- =================================================================

--- Starts the manager's reader on a faked touchpad and records the log lines.
--- @param max_fingers integer
--- @param bindings table slot -> action
--- @return table lines { level, text }
local function start_with(max_fingers, bindings)
	local lines = {}
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "info", "warn", "error", "success" }) do
		logger[level] = function(_, fmt, ...) lines[#lines + 1] = { level = level, text = string.format(fmt, ...) } end
	end
	local saved = {
		logger = package.loaded["logger.shim"],
		reader = package.loaded["adapters.evdev_reader"],
		finder = package.loaded["modules.gestures.touchpad_finder"],
	}
	package.loaded["logger.shim"] = logger
	package.loaded["adapters.evdev_reader"] = Fakes.evdev_reader({ events = {} })
	-- Only find(), as the other gesture tests fake it: the report must not need the finder.
	package.loaded["modules.gestures.touchpad_finder"] = { find = function()
		return { path = "/dev/input/event-fake", name = "Fake Pad", max_fingers = max_fingers, semi_mt = false }
	end }
	local ok, err = pcall(function()
		local M = helpers.load_module("modules.gestures.manager")
		M.init({ enabled = false, persist = false })
		for slot, action in pairs(bindings) do
			helpers.assert_true(M.set_action(slot, action), "binding " .. slot)
		end
		lines = {}
		helpers.assert_true(M.start_reading(), "the faked touchpad opens")
		M.stop_reading()
	end)
	package.loaded["logger.shim"] = saved.logger
	package.loaded["adapters.evdev_reader"] = saved.reader
	package.loaded["modules.gestures.touchpad_finder"] = saved.finder
	package.loaded["modules.gestures.manager"] = nil
	assert(ok, err)
	return lines
end

--- Returns the lines of one level that contain a text.
--- @param lines table
--- @param level string
--- @param needle string
--- @return table
local function matching(lines, level, needle)
	local found = {}
	for _, line in ipairs(lines) do
		if line.level == level and line.text:find(needle, 1, true) then found[#found + 1] = line.text end
	end
	return found
end

helpers.describe("gesture slot report: starting the reader names the slots", function()

	helpers.it("(gesture-slot-report) a bound four-finger swipe on a three-finger pad is named", function()
		local lines = start_with(3, { swipe_4_up = "enter" })
		helpers.assert_eq(#matching(lines, "warn", "Gesture swipe_4_up is bound"), 1,
			"the unreachable binding must be named, not left silent")
		local info = matching(lines, "info", "can never fire")
		helpers.assert_eq(#info, 1, "one line lists every unreachable slot")
		helpers.assert_true(info[1]:find("swipe_5_up", 1, true) ~= nil and info[1]:find("tap_4", 1, true) ~= nil,
			"the list names the slots: " .. tostring(info[1]))
		helpers.assert_true(info[1]:find("swipe_3_up", 1, true) == nil, "a reachable slot is not listed")
	end)

	helpers.it("(gesture-slot-report) a bound two-finger swipe is named as competing with scrolling", function()
		local lines = start_with(5, { swipe_2_left = "enter", swipe_3_up = "enter" })
		local warned = matching(lines, "warn", "Two-finger gesture(s) bound: swipe_2_left.")
		helpers.assert_eq(#warned, 1, "the two-finger binding must be named")
		helpers.assert_eq(#matching(lines, "info", "can never fire"), 0, "a five-finger pad reaches every slot")
	end)

	helpers.it("(gesture-slot-report) nothing bound and every slot reachable says nothing more", function()
		local lines = start_with(5, {})
		helpers.assert_eq(#matching(lines, "warn", "bound"), 0)
		helpers.assert_eq(#matching(lines, "info", "can never fire"), 0)
	end)
end)

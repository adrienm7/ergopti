--- tests/unit/gestures/engine/actions/test_pointer_spotlight.lua

--- ==============================================================================
--- MODULE: Pointer Spotlight on X11 (Linux)
--- DESCRIPTION:
--- `spotlight_mouse` was Windows/macOS only. On an X11 session Linux now draws
--- a ring around the pointer and a cross on every other monitor, through the
--- real gesture executor, and dismisses it after its duration or a pointer
--- move of more than 5 px, as Windows does; Wayland refuses without drawing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("core.process.adapters.shell_runner")
local Display = require("core.ui.engine.display_server")

local TWO_MONITORS = "Monitors: 2\n"
	.. " 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1\n"
	.. " 1: +HDMI-1 2560/597x1440/336+1920+0  HDMI-1\n"

--- A scheduler whose timers fire only when the test says so.
local function manual_scheduler()
	local scheduler = { timers = {} }
	function scheduler.after(delay, fn)
		local handle = { delay = delay, fn = fn, kind = "after" }
		scheduler.timers[#scheduler.timers + 1] = handle
		return handle
	end
	function scheduler.every(interval, fn)
		local handle = { delay = interval, fn = fn, kind = "every" }
		scheduler.timers[#scheduler.timers + 1] = handle
		return handle
	end
	function scheduler.cancel(handle) handle.cancelled = true end
	function scheduler.fire(delay, kind)
		for _, handle in ipairs(scheduler.timers) do
			if handle.delay == delay and handle.kind == kind and not handle.cancelled then
				handle.fn()
				return true
			end
		end
		return false
	end
	return scheduler
end

--- An overlay that records the shapes and serves a settable pointer.
local function recording_overlay()
	local overlay = { shown = nil, hides = 0, x = 10, y = 10 }
	function overlay.is_available() return true end
	function overlay.show(shapes) overlay.shown = shapes; return true end
	function overlay.hide() overlay.shown = nil; overlay.hides = overlay.hides + 1 end
	function overlay.pointer() return overlay.x, overlay.y end
	return overlay
end

--- Runs spotlight_mouse through the real executor.
local function run(session, location, overlay, scheduler)
	local Spotlight = require("gestures.engine.pointer_spotlight")
	Spotlight._set_deps_for_test({ overlay = function() return overlay end, scheduler = function() return scheduler end })
	Display._set_for_test(session, "")
	local commands = {}
	Shell._set_runner(function(cmd)
		commands[#commands + 1] = cmd
		if cmd:find("xrandr --listactivemonitors", 1, true) then return TWO_MONITORS end
		if cmd:find("getmouselocation", 1, true) then return location end
		return true
	end)
	local ok, err = pcall(function()
		helpers.load_module("gestures.engine.manager").execute_action("spotlight_mouse", "test__slot")
	end)
	Shell._reset_runner()
	Display._set_for_test(nil, nil)
	if not ok then error(err, 0) end
	return Spotlight, commands
end

helpers.describe("linux pointer spotlight on X11 (linux-x11-pointer-spotlight)", function()
	helpers.it("pointer-spotlight: a ring at the pointer and a cross at the other monitor's centre", function()
		local overlay, scheduler = recording_overlay(), manual_scheduler()
		local Spotlight = run(Display.X11, "X=100\nY=200\n", overlay, scheduler)
		helpers.assert_true(overlay.shown ~= nil, "the overlay is drawn")
		helpers.assert_eq(#overlay.shown, 2)
		helpers.assert_eq({ overlay.shown[1].kind, overlay.shown[1].x, overlay.shown[1].y }, { "ring", 100, 200 })
		helpers.assert_eq({ overlay.shown[2].kind, overlay.shown[2].x, overlay.shown[2].y }, { "cross", 3200, 720 })
		helpers.assert_eq(overlay.shown[1].size, 144, "ring radius 60 plus padding 12, as on Windows and macOS")
		helpers.assert_true(scheduler.fire(Spotlight.DURATION_S, "after"), "the duration timer is armed")
		helpers.assert_eq(overlay.shown, nil, "the duration dismisses the spotlight")
		helpers.assert_eq(Spotlight.is_active(), false)
		Spotlight._set_deps_for_test(nil)
	end)

	helpers.it("pointer-spotlight: a move above 5 px dismisses it, a smaller one does not", function()
		local overlay, scheduler = recording_overlay(), manual_scheduler()
		overlay.x, overlay.y = 100, 200
		local Spotlight = run(Display.X11, "X=100\nY=200\n", overlay, scheduler)
		helpers.assert_true(scheduler.fire(Spotlight.ARM_DELAY_S, "after"), "the move watch arms after its delay")
		overlay.x = 105
		helpers.assert_true(scheduler.fire(Spotlight.POLL_S, "every"))
		helpers.assert_true(overlay.shown ~= nil, "a 5 px move keeps it")
		overlay.x = 106
		scheduler.fire(Spotlight.POLL_S, "every")
		helpers.assert_eq(overlay.shown, nil, "a 6 px move dismisses it")
		for _, handle in ipairs(scheduler.timers) do
			helpers.assert_true(handle.cancelled == true or handle.kind == "after", "no poll survives the dismissal")
		end
		Spotlight._set_deps_for_test(nil)
	end)

	helpers.it("pointer-spotlight: Wayland refuses and draws nothing", function()
		local overlay, scheduler = recording_overlay(), manual_scheduler()
		local Spotlight, commands = run(Display.WAYLAND, "X=100\nY=200\n", overlay, scheduler)
		helpers.assert_eq(overlay.shown, nil)
		helpers.assert_eq(#scheduler.timers, 0)
		for _, cmd in ipairs(commands) do helpers.assert_true(not cmd:find("xrandr", 1, true), cmd) end
		Spotlight._set_deps_for_test(nil)
	end)

	helpers.it("pointer-spotlight: the catalogue offers it on Linux, requiring an X11 session", function()
		local entry = require("_generated.action_catalogue").actions.spotlight_mouse
		helpers.assert_true(entry ~= nil, "spotlight_mouse is in the Linux catalogue")
		helpers.assert_eq(entry.requires, { "session:x11", "tool:xdotool", "tool:xrandr" })
		helpers.assert_true(helpers.load_module("gestures.engine.manager").is_assignable("spotlight_mouse"))
	end)
end)

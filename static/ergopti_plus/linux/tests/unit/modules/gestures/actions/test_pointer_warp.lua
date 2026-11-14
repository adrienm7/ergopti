--- tests/unit/modules/gestures/actions/test_pointer_warp.lua

--- ==============================================================================
--- MODULE: Pointer Centring and Teleport on X11 (Linux)
--- DESCRIPTION:
--- `center_mouse` and `teleport_mouse` were Windows/macOS only. On an X11
--- session Linux now moves the pointer to the centre of the monitor under it,
--- or of the next RandR monitor, as macOS does; a single monitor shows the
--- shared notice, and Wayland refuses without running anything.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("core.process.adapters.shell_runner")
local Display = require("infra.display_server")

local TWO_MONITORS = "Monitors: 2\n"
	.. " 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1\n"
	.. " 1: +HDMI-1 2560/597x1440/336+1920+0  HDMI-1\n"
local ONE_MONITOR = "Monitors: 1\n 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1\n"

--- Runs an action through the real executor with recorded shell output.
--- @param action string
--- @param session string Display server kind.
--- @param monitors string xrandr output.
--- @param location string xdotool output.
--- @return table commands Everything that ran, background moves included.
--- @return table notices Notification texts.
local function run(action, session, monitors, location)
	local commands, notices = {}, {}
	local real_execute = os.execute
	Display._set_for_test(session, "")
	Shell._set_runner(function(cmd)
		commands[#commands + 1] = cmd
		if cmd:find("xrandr --listactivemonitors", 1, true) then return monitors end
		if cmd:find("getmouselocation", 1, true) then return location end
		return true
	end)
	os.execute = function(cmd) commands[#commands + 1] = tostring(cmd) return true end
	local saved_notifier = package.loaded["adapters.application_notifier"]
	package.loaded["adapters.application_notifier"] = { send = function(text) notices[#notices + 1] = text return true end }
	local ok, err = pcall(function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		Gestures.execute_action(action, "test__slot")
	end)
	package.loaded["adapters.application_notifier"] = saved_notifier
	os.execute = real_execute
	Shell._reset_runner()
	Display._set_for_test(nil, nil)
	if not ok then error(err, 0) end
	return commands, notices
end

local function moves(commands)
	local out = {}
	for _, cmd in ipairs(commands) do
		local x, y = cmd:match("xdotool mousemove (%-?%d+) (%-?%d+)")
		if x then out[#out + 1] = x .. "," .. y end
	end
	return table.concat(out, " ")
end

helpers.describe("linux pointer warp on X11 (linux-x11-pointer-warp)", function()
	helpers.it("pointer-warp: RandR monitors and the xdotool location are read exactly", function()
		local Warp = require("modules.gestures.pointer_warp")
		local monitors = Warp.parse_monitors(TWO_MONITORS)
		helpers.assert_eq(#monitors, 2)
		helpers.assert_eq(monitors[2], { name = "HDMI-1", x = 1920, y = 0, w = 2560, h = 1440 })
		helpers.assert_eq({ Warp.parse_location("X=2000\nY=300\nSCREEN=0\nWINDOW=123\n") }, { 2000, 300 })
		helpers.assert_eq(#Warp.parse_monitors(""), 0)
	end)

	helpers.it("pointer-warp: center_mouse centres the pointer on the monitor under it", function()
		local commands = run("center_mouse", Display.X11, TWO_MONITORS, "X=2000\nY=300\n")
		helpers.assert_eq(moves(commands), "3200,720")
		commands = run("center_mouse", Display.X11, TWO_MONITORS, "X=10\nY=10\n")
		helpers.assert_eq(moves(commands), "960,540")
	end)

	helpers.it("pointer-warp: teleport_mouse goes to the next monitor and wraps to the first", function()
		helpers.assert_eq(moves(run("teleport_mouse", Display.X11, TWO_MONITORS, "X=10\nY=10\n")), "3200,720")
		helpers.assert_eq(moves(run("teleport_mouse", Display.X11, TWO_MONITORS, "X=2000\nY=10\n")), "960,540")
	end)

	helpers.it("pointer-warp: a single monitor shows the shared notice and moves nothing", function()
		local commands, notices = run("teleport_mouse", Display.X11, ONE_MONITOR, "X=10\nY=10\n")
		helpers.assert_eq(moves(commands), "")
		helpers.assert_eq(#notices, 1)
	end)

	helpers.it("pointer-warp: Wayland refuses and runs no tool", function()
		for _, action in ipairs({ "center_mouse", "teleport_mouse" }) do
			local commands = run(action, Display.WAYLAND, TWO_MONITORS, "X=10\nY=10\n")
			helpers.assert_eq(moves(commands), "", action)
			for _, cmd in ipairs(commands) do
				helpers.assert_true(not cmd:find("xrandr", 1, true), action .. ": " .. cmd)
			end
		end
	end)

	helpers.it("pointer-warp: the catalogue offers both actions on Linux, requiring an X11 session", function()
		local Catalogue = require("_generated.action_catalogue")
		local Gestures = helpers.load_module("modules.gestures.manager")
		for _, id in ipairs({ "center_mouse", "teleport_mouse" }) do
			local entry = Catalogue.actions[id]
			helpers.assert_true(entry ~= nil, id .. " is in the Linux catalogue")
			helpers.assert_eq(entry.requires, { "session:x11", "tool:xdotool", "tool:xrandr" }, id)
			helpers.assert_true(Gestures.is_assignable(id), id .. " is assignable on Linux")
		end
	end)
end)

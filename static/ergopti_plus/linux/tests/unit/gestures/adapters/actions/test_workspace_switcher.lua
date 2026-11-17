--- tests/unit/gestures/adapters/actions/test_workspace_switcher.lua

--- ==============================================================================
--- MODULE: Workspace switching, plain and wrapping (Linux)
--- DESCRIPTION:
--- Drives modules/gestures/workspace_switcher against a scripted session: the
--- display server and desktop identity, the tools on the PATH, and what each
--- tool answers. Every command the switcher runs is recorded through the shell
--- runner's test seam, so the assertions name the exact workspace switched to.
---
--- ROOT CAUSES ENCODED:
--- 1. desktop_prev and desktop_next always wrapped on this driver (the wmctrl
---    pick was modulo), while Windows and macOS stop at the edge: one action
---    id, two behaviours. The plain pair now stops at the first and last
---    workspace, and the wrap is its own pair.
--- 2. Only X11 could switch: under Wayland wmctrl lists nothing, so the action
---    fell back to a keystroke that stops at the edge whatever was asked. KDE
---    Plasma, sway and Hyprland are now driven through their own interfaces,
---    and a desktop with none (GNOME) says so instead of pretending to wrap.
--- 3. space_switches was never measured under Wayland: only the X11 EWMH
---    desktop fed it. current_workspace_source reads the same sway, Hyprland
---    and KWin interfaces, once a second at most, and keeps GNOME unmeasured.
--- ==============================================================================

local helpers = require("tests.helpers")

local SWITCHER = "gestures.adapters.workspace_switcher"

--- Runs `body` against one scripted session.
--- @param session table { kind, desktop, env = {}, tools = {name = true},
---   answers = { [needle] = output string, or false for a failing query },
---   refuse_switch = boolean }
--- @param body function Receives (switcher, commands, pressed).
local function in_session(session, body)
	local Display = require("core.ui.engine.display_server")
	local Shell = require("core.process.adapters.shell_runner")
	local commands, pressed = {}, {}
	local real_getenv = os.getenv
	Display._set_for_test(session.kind, session.desktop or "")
	os.getenv = function(name)
		if name == "HYPRLAND_INSTANCE_SIGNATURE" or name == "SWAYSOCK" then
			return (session.env or {})[name]
		end
		return real_getenv(name)
	end
	Shell._set_runner(function(cmd)
		local tool = cmd:match("^command %-v '([^']+)'")
		if tool then return (session.tools or {})[tool] == true end
		commands[#commands + 1] = cmd
		for needle, answer in pairs(session.answers or {}) do
			if cmd:find(needle, 1, true) then return answer end
		end
		if session.on_switch then session.on_switch(cmd) end
		return session.refuse_switch ~= true
	end)
	package.loaded[SWITCHER] = nil
	local ok, err = pcall(function()
		local Switcher = require(SWITCHER)
		body(Switcher, commands, pressed, function(combo) pressed[#pressed + 1] = combo end)
	end)
	Shell._reset_runner()
	os.getenv = real_getenv
	Display._set_for_test(nil, nil)
	if not ok then error(err, 0) end
end

--- The switch commands among the recorded ones (the queries excluded).
--- @param commands table
--- @param needle string Text every switch command of the backend holds.
--- @return table
local function switches(commands, needle)
	local out = {}
	for _, cmd in ipairs(commands) do
		if cmd:find(needle, 1, true) then out[#out + 1] = cmd end
	end
	return out
end

local WMCTRL_THREE = "0  - DG: 1920x1080  VP: 0,0  WA: 0,0 1920x1080  One\n"
	.. "1  - DG: 1920x1080  VP: 0,0  WA: 0,0 1920x1080  Two\n"
	.. "2  * DG: 1920x1080  VP: 0,0  WA: 0,0 1920x1080  Three\n"

local function x11(listing, extra)
	local session = {
		kind = "x11", desktop = "xfce", tools = { wmctrl = true },
		answers = { ["wmctrl -d"] = listing },
	}
	for key, value in pairs(extra or {}) do session[key] = value end
	return session
end





-- ===========================================
-- ===========================================
-- ======= 1/ X11 through wmctrl =============
-- ===========================================
-- ===========================================

helpers.describe("workspace switcher: X11 through wmctrl", function()
	helpers.it("wraps from the last workspace to the first, and the plain step stays", function()
		in_session(x11(WMCTRL_THREE), function(Switcher, commands, pressed, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "stayed")
			helpers.assert_eq(switches(commands, "wmctrl -s"), {}, "the plain step must not wrap")
			helpers.assert_eq(Switcher.switch("next", true, press), "switched")
			helpers.assert_eq(switches(commands, "wmctrl -s"), { "timeout 1 wmctrl -s '0' >/dev/null 2>&1" })
			helpers.assert_eq(pressed, {}, "a switched workspace presses nothing on top")
		end)
	end)

	helpers.it("wraps from the first workspace to the last and steps plainly inside the row", function()
		local first = WMCTRL_THREE:gsub("0  %-", "0  *"):gsub("2  %*", "2  -")
		in_session(x11(first), function(Switcher, commands, _, press)
			helpers.assert_eq(Switcher.switch("prev", false, press), "stayed")
			helpers.assert_eq(Switcher.switch("prev", true, press), "switched")
			helpers.assert_eq(Switcher.switch("next", false, press), "switched")
			helpers.assert_eq(switches(commands, "wmctrl -s"), {
				"timeout 1 wmctrl -s '2' >/dev/null 2>&1",
				"timeout 1 wmctrl -s '1' >/dev/null 2>&1",
			})
		end)
	end)

	helpers.it("presses the desktop shortcut when wmctrl cannot list, but not after an unconfirmed switch", function()
		in_session(x11(false), function(Switcher, _, pressed, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "pressed")
			helpers.assert_eq(pressed, { "ctrl+alt+Right" })
		end)
		in_session(x11(WMCTRL_THREE, { refuse_switch = true }), function(Switcher, _, pressed, press)
			helpers.assert_eq(Switcher.switch("prev", false, press), "unconfirmed")
			helpers.assert_eq(pressed, {})
		end)
	end)

	helpers.it("does not walk after an unconfirmed wrap command", function()
		local FOUR = WMCTRL_THREE:gsub("2  %*", "2  -") .. "3  * DG: 1920x1080  Four\n"
		in_session(x11(FOUR, { refuse_switch = true }), function(Switcher, _, pressed, press)
			helpers.assert_eq(Switcher.switch("next", true, press), "unconfirmed")
			helpers.assert_eq(pressed, {})
		end)
	end)

	helpers.it("does not emit a second switch when native execution moved before failing", function()
		local active = 2
		in_session(x11(WMCTRL_THREE, { refuse_switch = true, on_switch = function(cmd)
			if cmd:find("wmctrl -s", 1, true) then active = 1 end
		end }), function(Switcher, _, pressed, press)
			local result = Switcher.switch("prev", false, function(combo)
				press(combo)
				active = active - 1
			end)
			helpers.assert_eq(result, "unconfirmed")
			helpers.assert_eq(pressed, {})
			helpers.assert_eq(active, 1, "one requested step must not become two")
		end)
	end)

	helpers.it("names wmctrl as the missing tool on X11 without it", function()
		in_session({ kind = "x11", desktop = "xfce", tools = {} }, function(Switcher, commands, pressed, press)
			local backend, reason = Switcher.detect()
			helpers.assert_nil(backend)
			helpers.assert_eq(reason, "tool:wmctrl")
			helpers.assert_eq(Switcher.switch("next", true, press), "pressed",
				"without a listing the wrap degrades to the plain step, and says so")
			helpers.assert_eq(pressed, { "ctrl+alt+Right" })
			helpers.assert_eq(commands, {})
		end)
	end)

	helpers.it("refuses a listing it cannot place instead of guessing a workspace", function()
		local Switcher = helpers.load_module(SWITCHER)
		helpers.assert_eq(Switcher.parse_wmctrl(WMCTRL_THREE), { ids = { "0", "1", "2" }, index = 2 })
		for _, case in ipairs({
			{ "", "listed no desktop" },
			{ "0  - DG\n1  - DG\n", "marks no current desktop" },
			{ "0  * a\n1  * b\n", "marks two current desktops" },
			{ "Cannot get desktops\n", "unexpected wmctrl -d line" },
		}) do
			local ok, err = pcall(Switcher.parse_wmctrl, case[1])
			helpers.assert_eq(ok, false, "must refuse: " .. case[1])
			helpers.assert_contains(tostring(err), case[2])
		end
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 2/ Wayland compositors ============
-- ===========================================
-- ===========================================

helpers.describe("workspace switcher: Wayland compositors", function()
	helpers.it("drives KDE Plasma through KWin's D-Bus interface", function()
		in_session({
			kind = "wayland", desktop = "kde", tools = { ["qdbus6"] = true },
			answers = {
				["org.kde.KWin.currentDesktop"] = "4\n",
				["VirtualDesktopManager.count"] = "4\n",
			},
		}, function(Switcher, commands, pressed, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "stayed")
			helpers.assert_eq(Switcher.switch("next", true, press), "switched")
			helpers.assert_eq(switches(commands, "setCurrentDesktop"),
				{ "timeout 1 qdbus6 org.kde.KWin /KWin org.kde.KWin.setCurrentDesktop '1' >/dev/null 2>&1" })
			helpers.assert_eq(pressed, {})
		end)
	end)

	helpers.it("rejects an excessive KWin workspace count before allocating it", function()
		in_session({ kind = "wayland", desktop = "kde", tools = { ["qdbus6"] = true } }, function(Switcher)
			local ok = pcall(Switcher.parse_kwin, "1", "1000000")
			helpers.assert_eq(ok, false, "an implausible count must not allocate one million entries")
		end)
	end)

	helpers.it("falls back once when KWin's workspace count is excessive", function()
		in_session({ kind = "wayland", desktop = "kde", tools = { ["qdbus6"] = true }, answers = {
			["org.kde.KWin.currentDesktop"] = "1", ["VirtualDesktopManager.count"] = "1000000",
		} }, function(Switcher, commands, pressed, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "pressed")
			helpers.assert_eq(pressed, { "ctrl+alt+Right" })
			helpers.assert_eq(switches(commands, "setCurrentDesktop"), {})
		end)
	end)

	helpers.it("names qdbus when KDE has no D-Bus client on the PATH", function()
		in_session({ kind = "wayland", desktop = "kde", tools = {} }, function(Switcher)
			local backend, reason = Switcher.detect()
			helpers.assert_nil(backend)
			helpers.assert_eq(reason, "tool:qdbus")
		end)
	end)

	helpers.it("drives sway on the focused output only", function()
		local workspaces = '[{"num":1,"name":"1:web","focused":false,"output":"eDP-1"},'
			.. '{"num":2,"name":"2","focused":false,"output":"HDMI-A-1"},'
			.. '{"num":3,"name":"3 \\"code\\"","focused":true,"output":"eDP-1"}]'
		in_session({
			kind = "wayland", desktop = "sway", tools = { swaymsg = true },
			answers = { ["get_workspaces"] = workspaces },
		}, function(Switcher, commands, _, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "stayed",
				"the last workspace of the focused output is an edge")
			helpers.assert_eq(Switcher.switch("next", true, press), "switched")
			helpers.assert_eq(Switcher.switch("prev", false, press), "switched")
			helpers.assert_eq(switches(commands, "swaymsg --"), {
				"timeout 1 swaymsg -- 'workspace \"1:web\"' >/dev/null 2>&1",
				"timeout 1 swaymsg -- 'workspace \"1:web\"' >/dev/null 2>&1",
			}, "both land on the other workspace of eDP-1, never on HDMI-A-1's")
		end)
	end)

	helpers.it("quotes a sway workspace name that holds a quote and a backslash", function()
		-- A name reaches sway's own command parser: an unescaped quote would end
		-- the argument early, and whatever followed would run as a command.
		local workspaces = '[{"num":1,"name":"1","focused":true,"output":"eDP-1"},'
			.. '{"num":2,"name":"2 \\"a\\\\b\\"","focused":false,"output":"eDP-1"}]'
		in_session({
			kind = "wayland", desktop = "sway", tools = { swaymsg = true },
			answers = { ["get_workspaces"] = workspaces },
		}, function(Switcher, commands, _, press)
			helpers.assert_eq(Switcher.switch("next", false, press), "switched")
			helpers.assert_eq(switches(commands, "swaymsg --"),
				{ [[timeout 1 swaymsg -- 'workspace "2 \"a\\b\""' >/dev/null 2>&1]] })
		end)
	end)

	helpers.it("drives Hyprland over the active monitor's regular workspaces", function()
		in_session({
			kind = "wayland", desktop = "", env = { HYPRLAND_INSTANCE_SIGNATURE = "abc" },
			tools = { hyprctl = true },
			answers = {
				["activeworkspace"] = '{"id":1,"name":"1","monitor":"DP-1"}',
				["-j workspaces"] = '[{"id":5,"monitor":"DP-1"},{"id":1,"monitor":"DP-1"},'
					.. '{"id":2,"monitor":"HDMI-A-1"},{"id":-98,"monitor":"DP-1"}]',
			},
		}, function(Switcher, commands, _, press)
			helpers.assert_eq(Switcher.switch("prev", false, press), "stayed")
			helpers.assert_eq(Switcher.switch("prev", true, press), "switched")
			helpers.assert_eq(switches(commands, "dispatch workspace"),
				{ "timeout 1 hyprctl dispatch workspace '5' >/dev/null 2>&1" },
				"the special workspace (-98) and another monitor's are not in the row")
		end)
	end)

	helpers.it("presses GNOME's own shortcut, which stops at the edges, and cannot wrap", function()
		in_session({ kind = "wayland", desktop = "ubuntu:gnome", tools = {} },
			function(Switcher, commands, pressed, press)
				local backend, reason = Switcher.detect()
				helpers.assert_nil(backend)
				helpers.assert_eq(reason, "unsupported")
				helpers.assert_eq(Switcher.switch("prev", false, press), "pressed")
				helpers.assert_eq(Switcher.switch("next", true, press), "pressed")
				helpers.assert_eq(pressed, { "ctrl+alt+Left", "ctrl+alt+Right" })
				helpers.assert_eq(commands, {})
			end)
	end)

	helpers.it("does not claim to know an unidentified session", function()
		in_session({ kind = "unknown", tools = { wmctrl = true } }, function(Switcher)
			local backend, reason = Switcher.detect()
			helpers.assert_nil(backend)
			helpers.assert_eq(reason, "unknown")
		end)
	end)

	helpers.it("refuses an unknown direction before touching the session", function()
		in_session(x11(WMCTRL_THREE), function(Switcher, commands, pressed, press)
			local ok, err = pcall(Switcher.switch, "up", false, press)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "unknown direction 'up'")
			ok, err = pcall(Switcher.switch, "next", "yes", press)
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "boolean wrap")
			helpers.assert_eq(commands, {})
			helpers.assert_eq(pressed, {})
		end)
	end)

	helpers.it("linux-space-change: reads sway's focused workspace name once a second at most", function()
		local focused = "1:web"
		local answers = {}
		local function listing()
			return '[{"num":1,"name":"1:web","focused":' .. tostring(focused == "1:web")
				.. ',"output":"eDP-1"},{"num":2,"name":"2","focused":' .. tostring(focused == "2")
				.. ',"output":"eDP-1"}]'
		end
		answers["get_workspaces"] = listing()
		in_session({ kind = "wayland", desktop = "sway", tools = { swaymsg = true }, answers = answers },
			function(Switcher, commands)
				local now = 0
				local read, reason = Switcher.current_workspace_source(function() return now end)
				helpers.assert_nil(reason)
				helpers.assert_eq(read(), "1:web")
				focused = "2"; answers["get_workspaces"] = listing()
				now = 999
				helpers.assert_eq(read(), "1:web", "an answer is reused within the interval")
				helpers.assert_eq(#commands, 1, "no second fork within the interval")
				now = 1000
				helpers.assert_eq(read(), "2")
				answers["get_workspaces"] = false
				now = 2000
				helpers.assert_nil(read(), "a failed query is no answer, never a workspace")
			end)
	end)

	helpers.it("linux-space-change: reads Hyprland's active id and KWin's desktop number", function()
		in_session({
			kind = "wayland", desktop = "", env = { HYPRLAND_INSTANCE_SIGNATURE = "abc" },
			tools = { hyprctl = true },
			answers = { ["activeworkspace"] = '{"id":4,"name":"4","monitor":"DP-1"}' },
		}, function(Switcher, commands)
			local read = Switcher.current_workspace_source(function() return 0 end)
			helpers.assert_eq(read(), 4)
			helpers.assert_eq(commands, { "timeout 1 hyprctl -j activeworkspace 2>/dev/null" },
				"one query, not the workspace listing")
		end)
		in_session({
			kind = "wayland", desktop = "KDE", tools = { qdbus6 = true },
			answers = { ["currentDesktop"] = "3\n" },
		}, function(Switcher)
			helpers.assert_eq(Switcher.current_workspace_source(function() return 0 end)(), 3)
		end)
	end)

	helpers.it("linux-space-change: names why GNOME Wayland and X11 get no workspace reader", function()
		in_session({ kind = "wayland", desktop = "ubuntu:gnome", tools = {} }, function(Switcher, commands)
			local read, reason = Switcher.current_workspace_source(function() return 0 end)
			helpers.assert_nil(read)
			helpers.assert_eq(reason, "unsupported")
			helpers.assert_eq(commands, {})
		end)
		in_session(x11(WMCTRL_THREE), function(Switcher, commands)
			local read, reason = Switcher.current_workspace_source(function() return 0 end)
			helpers.assert_nil(read, "X11 is read in-process by x11_focus, never by a wmctrl fork per tick")
			helpers.assert_eq(reason, "x11")
			helpers.assert_eq(commands, {})
		end)
	end)
end)

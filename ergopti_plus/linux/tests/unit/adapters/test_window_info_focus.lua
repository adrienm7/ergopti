--- tests/unit/adapters/test_window_info_focus.lua

--- ==============================================================================
--- MODULE: WindowInfo — which window has focus
--- DESCRIPTION:
--- The focused-window query, driven per display server through the shell seam,
--- with the tools' real output as fixtures.
---
--- WHY THIS REPLACED WHAT WAS HERE:
--- The previous suite asserted that getFocused() returns a table with four
--- non-nil fields, that it does so twice, and that it does so a hundred times. It
--- passed against an implementation that returned four empty strings forever,
--- which is exactly what the adapter did on every Wayland session in existence —
--- its docstring promised a swaymsg fallback and its body contained an xdotool
--- call and a TODO. A test that cannot tell "answered" from "gave up" is not
--- coverage of a query.
---
--- WHAT IS ACTUALLY AT STAKE:
--- This identity gates password-field suppression and every per-application
--- rule. A wrong answer applies the wrong rules; an empty one applies none. So
--- every case below names the value it expects, and the empty answers are
--- asserted as deliberate outcomes of a stated situation rather than as the
--- absence of a crash.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Real `swaymsg -t get_tree` shape, cut to the nodes the walk visits: a nested
-- container tree with the focused leaf several levels down, one unfocused
-- sibling, and one floating node — the three shapes the walk has to handle.
local SWAY_TREE = [[
{"type":"root","name":"root","focused":false,"nodes":[
  {"type":"output","name":"HDMI-1","focused":false,"nodes":[
    {"type":"workspace","name":"1","focused":false,
     "nodes":[
       {"type":"con","name":"vim","app_id":"foot","pid":4242,"focused":false},
       {"type":"con","name":"Ergopti — Mozilla Firefox","app_id":"firefox","pid":1337,"focused":true}
     ],
     "floating_nodes":[
       {"type":"floating_con","name":"Calculator","app_id":"gnome-calculator","pid":99,"focused":false}
     ]}
  ]}
]}
]]

local HYPRLAND_WINDOW = [[
{"address":"0x55","class":"kitty","title":"nvim ~/src","pid":2468}
]]

local NIRI_WINDOW = [[
{"id":7,"app_id":"org.gnome.Nautilus","title":"Documents","pid":31337}
]]

--- Installs a shell seam answering from a table of command patterns.
---
--- Matching on a pattern rather than replaying a fixed list, because the adapter
--- probes for binaries before it queries them: a positional script would silently
--- feed a probe's answer to a query the moment the probe order changed.
--- @param routes table Array of { pattern, reply } — reply is a string or boolean.
--- @return table log Commands in the order they were run.
local function stub_shell(routes)
	local Shell = helpers.load_module("adapters.shell_runner")
	local log = {}
	Shell._set_runner(function(cmd)
		log[#log + 1] = cmd
		for _, route in ipairs(routes) do
			if cmd:find(route[1], 1, true) then return route[2] end
		end
		-- Unrouted `command -v` probes answer "absent"; unrouted queries answer
		-- nothing. Both are the honest default for a tool that is not installed.
		if cmd:find("command -v", 1, true) then return false end
		return ""
	end)
	return log
end

--- Loads window_info with a forced display server and a stubbed shell.
--- @param kind string DisplayServer constant.
--- @param desktop string|nil
--- @param routes table Shell routes.
--- @return table wi, table log
local function under(kind, desktop, routes)
	local ds = helpers.load_module("infra.display_server")
	ds._set_for_test(kind, desktop or "")
	package.loaded["infra.display_server"] = ds
	local log = stub_shell(routes)
	local wi = helpers.load_module("adapters.window_info")
	wi._reset_state()
	return wi, log
end

--- Drops the shell seam so a later module never inherits it.
local function restore()
	local Shell = helpers.load_module("adapters.shell_runner")
	Shell._reset_runner()
end





-- =================================================================
-- =================================================================
-- ======= 1/ X11 ==================================================
-- =================================================================
-- =================================================================

helpers.describe("window_info: X11", function()

	helpers.it("reports the title and the owning process", function()
		local wi = under("x11", "xfce", {
			{ "getactivewindow getwindowname", "Ergopti — Mozilla Firefox\n" },
			{ "getwindowpid", "1337\n" },
			{ "/proc/1337/comm", "firefox\n" },
			{ "xdotool getactivewindow 2", "0x3400007\n" },
		})
		local info = wi.getFocused()
		helpers.assert_eq(info.windowTitle, "Ergopti — Mozilla Firefox",
			"the title is what the private-window rule is matched against")
		helpers.assert_eq(info.appId, "firefox",
			"the identity is the process name, which is what stored keystroke "
				.. "attribution and every per-app rule already use")
		restore()
	end)

	helpers.it("costs one subprocess while the focus does not change", function()
		local wi, log = under("x11", "xfce", {
			{ "getactivewindow getwindowname", "Same Window\n" },
			{ "getwindowpid", "1337\n" },
			{ "/proc/1337/comm", "firefox\n" },
			{ "xdotool getactivewindow 2", "0x3400007\n" },
		})
		wi.getFocused()
		local after_first = #log
		for _ = 1, 5 do wi.getFocused() end
		-- This runs on the focus poll, four times a second. Re-resolving the
		-- application every time would be twelve subprocesses a second to learn
		-- something that changes a few times a minute.
		helpers.assert_eq(#log - after_first, 5,
			"an unchanged title must cost exactly one probe per call, got "
				.. tostring(#log - after_first) .. " for five calls")
		restore()
	end)

	helpers.it("re-resolves the identity when the title changes", function()
		local title = "First Window"
		local Shell = helpers.load_module("adapters.shell_runner")
		local ds = helpers.load_module("infra.display_server")
		ds._set_for_test("x11", "xfce")
		package.loaded["infra.display_server"] = ds
		local comm = "firefox"
		Shell._set_runner(function(cmd)
			if cmd:find("getactivewindow getwindowname", 1, true) then return title .. "\n" end
			if cmd:find("getwindowpid", 1, true) then return "1337\n" end
			if cmd:find("/proc/1337/comm", 1, true) then return comm .. "\n" end
			if cmd:find("xdotool getactivewindow 2", 1, true) then return "0x1\n" end
			if cmd:find("command -v", 1, true) then return false end
			return ""
		end)
		local wi = helpers.load_module("adapters.window_info")
		wi._reset_state()

		helpers.assert_eq(wi.getFocused().appId, "firefox", "first window resolves")
		title, comm = "A Terminal", "foot"
		helpers.assert_eq(wi.getFocused().appId, "foot",
			"a changed title must invalidate the cached identity — otherwise the "
				.. "first application of the session owns every keystroke that follows")
		restore()
	end)

	helpers.it("answers empty when there is no focused window", function()
		local wi = under("x11", "xfce", {
			{ "getactivewindow getwindowname", "" },
		})
		local info = wi.getFocused()
		helpers.assert_eq(info.windowTitle, "", "no window means no title")
		helpers.assert_eq(info.appId, "",
			"and no identity — an empty appId must mean unknown, never a real app")
		restore()
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Wayland compositors ==================================
-- =================================================================
-- =================================================================

helpers.describe("window_info: Wayland", function()

	helpers.it("walks the sway tree to the focused leaf", function()
		local wi = under("wayland", "sway", {
			{ "command -v 'swaymsg'", true },
			{ "swaymsg -t get_tree", SWAY_TREE },
		})
		local info = wi.getFocused()
		-- The focused node is three levels down, after an unfocused sibling. A walk
		-- that stopped at the first container, or that took the first leaf, would
		-- return "vim"/"foot" and be wrong in a way that still looks like an answer.
		helpers.assert_eq(info.windowTitle, "Ergopti — Mozilla Firefox",
			"the focused leaf, not the first one")
		helpers.assert_eq(info.appId, "firefox", "app_id is the Wayland-native identity")
		restore()
	end)

	helpers.it("does not stop at an unfocused floating window", function()
		local wi = under("wayland", "sway", {
			{ "command -v 'swaymsg'", true },
			{ "swaymsg -t get_tree", SWAY_TREE },
		})
		helpers.assert_true(wi.getFocused().appId ~= "gnome-calculator",
			"floating nodes are searched, not preferred")
		restore()
	end)

	helpers.it("reads Hyprland", function()
		local wi = under("wayland", "Hyprland", {
			{ "command -v 'swaymsg'", false },
			{ "command -v 'hyprctl'", true },
			{ "hyprctl activewindow", HYPRLAND_WINDOW },
		})
		local info = wi.getFocused()
		helpers.assert_eq(info.appId, "kitty", "Hyprland calls the identity `class`")
		helpers.assert_eq(info.windowTitle, "nvim ~/src", "and the title `title`")
		restore()
	end)

	helpers.it("reads niri", function()
		local wi = under("wayland", "niri", {
			{ "command -v 'swaymsg'", false },
			{ "command -v 'hyprctl'", false },
			{ "command -v 'niri'", true },
			{ "niri msg", NIRI_WINDOW },
		})
		local info = wi.getFocused()
		helpers.assert_eq(info.appId, "org.gnome.Nautilus", "niri reports app_id")
		helpers.assert_eq(info.windowTitle, "Documents", "and title")
		restore()
	end)

	helpers.it("answers empty on a compositor with no query interface", function()
		local wi = under("wayland", "GNOME", {})
		local info = wi.getFocused()
		-- GNOME removed Shell.Eval in 41 and KDE exposes no equivalent. There is
		-- nothing to fall back to, and XWayland would answer for X11 clients only —
		-- so per-app rules would work in half a desktop, which reads as flaky
		-- rather than as unsupported.
		helpers.assert_eq(info.appId, "",
			"an unsupported compositor must produce no identity rather than a partial one")
		helpers.assert_eq(info.windowTitle, "", "and no title")
		helpers.assert_eq(type(info), "table", "and still a full WindowInfo table")
		restore()
	end)

	helpers.it("never reaches for xdotool on a Wayland session", function()
		local wi, log = under("wayland", "GNOME", {})
		wi.getFocused()
		for _, cmd in ipairs(log) do
			helpers.assert_true(cmd:find("xdotool", 1, true) == nil,
				"xdotool under Wayland answers for XWayland clients only, so it would "
					.. "identify some windows and not others: " .. cmd)
		end
		restore()
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ No display server at all =============================
-- =================================================================
-- =================================================================

helpers.describe("window_info: no session", function()

	helpers.it("asks nothing when there is no display server", function()
		local wi, log = under("unknown", "", {})
		local info = wi.getFocused()
		helpers.assert_eq(info.appId, "", "a TTY service has no focused window")
		helpers.assert_eq(#log, 0,
			"and must not spawn a probe to discover that; this runs on the focus poll")
		restore()
	end)

	helpers.it("returns an empty list from getAll rather than nil", function()
		local wi = under("unknown", "", {})
		local all = wi.getAll()
		helpers.assert_eq(type(all), "table", "the caller iterates the result")
		helpers.assert_eq(#all, 0, "and there is nothing to iterate")
		restore()
	end)

end)

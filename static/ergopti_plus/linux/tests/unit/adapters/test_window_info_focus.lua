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

	helpers.it("(linux-focus-coherent-poll) retains one window's metadata and identity while focus changes", function()
		local shell = helpers.load_module("adapters.shell_runner")
		local display = helpers.load_module("infra.display_server")
		display._set_for_test(display.X11, "coherent focus fixture")
		local queries, id = 0, "1"
		shell._set_runner(function(command)
			if command:find("getactivewindow", 1, true) then
				queries = queries + 1
				local captured = id
				id = "2"
				return captured .. "\n"
			end
			if command:find("getwindowname '1'", 1, true) then return "Private window\n" end
			if command:find("getwindowname '2'", 1, true) then return "Public window\n" end
			if command:find("getwindowpid", 1, true) then return "1337\n" end
			if command:find("/proc/1337/comm", 1, true) then return "browser\n" end
			return ""
		end)
		local ok, failure = pcall(function()
			local window = helpers.load_module("adapters.window_info")
			local metadata, identity = window.focused_snapshot()
			helpers.assert_eq(metadata, { appId = "browser", windowTitle = "Private window", bundleId = "", executablePath = "" })
			helpers.assert_eq(identity, "x11:1337:1")
			helpers.assert_eq(queries, 1, "the snapshot must not mix a later window with the first title")
			local current = window.focused_identity()
			helpers.assert_eq(current, "x11:1337:2", "asynchronous output must query fresh focus after an earlier snapshot")
			helpers.assert_eq(queries, 2)
		end)
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	helpers.it("(linux-focus-window-identity) distinguishes identically titled windows of one process", function()
		local id = "0x1"
		local Shell = helpers.load_module("adapters.shell_runner")
		local ds = helpers.load_module("infra.display_server")
		ds._set_for_test("x11", "xfce")
		package.loaded["infra.display_server"] = ds
		Shell._set_runner(function(cmd)
			if cmd:find("getwindowname", 1, true) then return "Untitled\n" end
			if cmd:find("getwindowpid", 1, true) then return "1337\n" end
			if cmd:find("/proc/1337/comm", 1, true) then return "firefox\n" end
			if cmd:find("xdotool getactivewindow 2", 1, true) then return id .. "\n" end
			return ""
		end)
		local wi = helpers.load_module("adapters.window_info")
		local original = wi.focused_identity()
		id = "0x2"
		local switched = wi.focused_identity()
		id = "0x1"
		local restored = wi.focused_identity()
		restore()
		helpers.assert_eq(original, "x11:1337:0x1")
		helpers.assert_eq(switched, "x11:1337:0x2")
		helpers.assert_eq(restored, original, "returning to the original window preserves its identity")
	end)

	helpers.it("(linux-focus-window-identity) distinguishes applications with the same window title", function()
		local id, comm = "0x1", "firefox"
		local Shell = helpers.load_module("adapters.shell_runner")
		local ds = helpers.load_module("infra.display_server")
		ds._set_for_test("x11", "xfce")
		package.loaded["infra.display_server"] = ds
		Shell._set_runner(function(cmd)
			if cmd:find("getwindowname", 1, true) then return "Untitled\n" end
			if cmd:find("getwindowpid", 1, true) then return "1337\n" end
			if cmd:find("/proc/1337/comm", 1, true) then return comm .. "\n" end
			if cmd:find("xdotool getactivewindow 2", 1, true) then return id .. "\n" end
			return ""
		end)
		local wi = helpers.load_module("adapters.window_info")
		helpers.assert_eq(wi.getFocused().appId, "firefox")
		id, comm = "0x2", "keepassxc"
		local second = wi.getFocused()
		restore()
		helpers.assert_eq(second.windowTitle, "Untitled")
		helpers.assert_eq(second.appId, "keepassxc",
			"a title shared by two applications cannot identify the focused process")
	end)

	helpers.it("(linux-focus-window-identity) retries an unavailable process identity", function()
		local comm = ""
		local Shell = helpers.load_module("adapters.shell_runner")
		local ds = helpers.load_module("infra.display_server")
		ds._set_for_test("x11", "xfce")
		package.loaded["infra.display_server"] = ds
		Shell._set_runner(function(cmd)
			if cmd:find("getwindowname", 1, true) then return "Untitled\n" end
			if cmd:find("getwindowpid", 1, true) then return "1337\n" end
			if cmd:find("/proc/1337/comm", 1, true) then return comm end
			if cmd:find("xdotool getactivewindow 2", 1, true) then return "0x1\n" end
			return ""
		end)
		local wi = helpers.load_module("adapters.window_info")
		helpers.assert_eq(wi.getFocused().appId, "")
		comm = "firefox\n"
		local recovered = wi.getFocused()
		restore()
		helpers.assert_eq(recovered.appId, "firefox",
			"a transient process query failure must not poison an unchanged window's identity")
	end)

	helpers.it("reports the title and the owning process", function()
		local wi = under("x11", "xfce", {
			{ "xdotool getwindowname", "Ergopti — Mozilla Firefox\n" },
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

	helpers.it("avoids repeated process lookups while the focus does not change", function()
		local wi, log = under("x11", "xfce", {
			{ "xdotool getwindowname", "Same Window\n" },
			{ "getwindowpid", "1337\n" },
			{ "/proc/1337/comm", "firefox\n" },
			{ "xdotool getactivewindow 2", "0x3400007\n" },
		})
		wi.getFocused()
		local after_first = #log
		for _ = 1, 5 do wi.getFocused() end
		-- The window ID and title must stay current; the owning process needs
		-- resolving only when either changes or its identity is still unknown.
		helpers.assert_eq(#log - after_first, 10,
			"an unchanged window needs only the identity and title probes, got "
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
			if cmd:find("xdotool getwindowname", 1, true) then return title .. "\n" end
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
			{ "xdotool getwindowname", "" },
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

	helpers.it("(linux-focus-native-query-error) refuses unexpected compositor errors before accessible fallback", function()
		local name = "adapters.user_hotstring_destination"
		local saved, captures = package.loaded[name], 0
		package.loaded[name] = {
			capture_current = function()
				captures = captures + 1
				return { bus = ":1.42", path = "/controlled-fallback" }
			end,
		}
		local ok, failure = pcall(function()
			local window = under("wayland", "sway", {})
			require("adapters.shell_runner")._set_runner(function() error("controlled unexpected compositor query error") end)
			helpers.assert_nil(window.focused_identity(), "an unexpected native query failure cannot authorize output through a different lookup")
			helpers.assert_eq(captures, 0)
			local metadata, identity = window.focused_snapshot()
			helpers.assert_eq(metadata, { appId = "", windowTitle = "", bundleId = "", executablePath = "" })
			helpers.assert_nil(identity)
			helpers.assert_eq(captures, 0, "periodic snapshot errors also remain free of accessible fallback")
		end)
		package.loaded[name] = saved
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	helpers.it("(linux-focus-coherent-poll) reserves accessible focus lookup for fresh native targeting", function()
		local name = "adapters.user_hotstring_destination"
		local saved, captures = package.loaded[name], 0
		local saved_lifecycle = package.loaded["adapters.process_lifecycle"]
		package.loaded[name] = {
			capture_current = function()
				captures = captures + 1
				return { bus = ":1.42", path = "/control/" .. captures }
			end,
		}
		local ok, failure = pcall(function()
			local window = under("wayland", "GNOME", {})
			helpers.assert_eq(window.getFocused(), { appId = "", windowTitle = "", bundleId = "", executablePath = "" })
			helpers.assert_eq(captures, 0, "metadata consumers must not acquire an unnecessary accessible destination")
			local metadata, identity = window.focused_snapshot()
			helpers.assert_eq(metadata.appId, "")
			helpers.assert_nil(identity, "unsupported compositors retain unknown native identity during metadata polling")
			local lifecycle = helpers.load_module("adapters.process_lifecycle")
			lifecycle.start()
			for tick = 1, 5 do lifecycle.tick(tick) end
			lifecycle.stop()
			helpers.assert_eq(captures, 0, "periodic lifecycle polling must not spawn an additional accessible helper")
			helpers.assert_eq(window.focused_identity(), "atspi::1.42:/control/1")
			helpers.assert_eq(window.focused_identity(), "atspi::1.42:/control/2", "asynchronous targeting cannot reuse a previous accessible snapshot")
			helpers.assert_eq(captures, 2)
		end)
		package.loaded[name] = saved
		package.loaded["adapters.process_lifecycle"] = saved_lifecycle
		restore()
		helpers.assert_true(ok, tostring(failure))
	end)

	for _, case in ipairs({
		{ desktop = "sway", probe = "command -v 'swaymsg'", query = "swaymsg -t get_tree",
			payload = '{"focused":true,"id":7,"pid":1337,"name":"Untitled","app_id":"editor"}', identity = "sway:1337:7" },
		{ desktop = "Hyprland", probe = "command -v 'hyprctl'", query = "hyprctl activewindow",
			payload = '{"address":"0x55","pid":1337,"title":"Untitled","class":"editor"}', identity = "hyprland:1337:0x55" },
		{ desktop = "niri", probe = "command -v 'niri'", query = "niri msg",
			payload = '{"id":7,"title":"Untitled","app_id":"editor"}', identity = "niri::7" },
	}) do
		helpers.it("(linux-focus-window-identity) reads native identity from " .. case.desktop, function()
			local wi = under("wayland", case.desktop, { { case.probe, true }, { case.query, case.payload } })
			local identity = wi.focused_identity()
			restore()
			helpers.assert_eq(identity, case.identity)
		end)
	end

	helpers.it("(linux-focus-window-identity) refuses unknown compositor window identity", function()
		local wi = under("wayland", "GNOME", {})
		local identity = wi.focused_identity()
		restore()
		helpers.assert_eq(identity, nil, "application metadata cannot replace a native window identity")
	end)

	helpers.it("(linux-focus-window-identity) rejects Hyprland's no-active-window sentinel", function()
		local wi = under("wayland", "Hyprland", {
			{ "command -v 'hyprctl'", true },
			{ "hyprctl activewindow", '{"address":"0x0","pid":0,"title":"","class":""}' },
		})
		local identity = wi.focused_identity()
		restore()
		helpers.assert_eq(identity, nil, "a compositor sentinel does not name an output target")
	end)

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

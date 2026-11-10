--- tests/unit/adapters/system/test_tap_to_click_setting.lua

--- ==============================================================================
--- MODULE: The Desktop's Tap-To-Click Setting
--- DESCRIPTION:
--- A touch is a click only while the desktop has libinput tap: these cases
--- feed each desktop's own answer (xinput, KWin's D-Bus object, swaymsg,
--- hyprctl, gsettings) to the reader and pin what it concludes, and that an
--- answer it cannot read is unknown, never "off".
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE = "adapters.tap_to_click_setting"
local PAD = { path = "/dev/input/event7", name = "SYNA8004:00 06CB:CD8B Touchpad" }

--- Runs body against the reader in a scripted session.
--- @param session table { kind, desktop, env, tools, answers = { [needle] = output|false } }
--- @param body function (Setting, commands)
local function in_session(session, body)
	local Display = require("infra.display_server")
	local Shell = require("adapters.shell_runner")
	local commands, real_getenv = {}, os.getenv
	Display._set_for_test(session.kind, session.desktop or "")
	os.getenv = function(name)
		if name == "HYPRLAND_INSTANCE_SIGNATURE" or name == "SWAYSOCK" then return (session.env or {})[name] end
		return real_getenv(name)
	end
	Shell._set_runner(function(cmd)
		local tool = cmd:match("^command %-v '([^']+)'")
		if tool then return (session.tools or {})[tool] == true end
		commands[#commands + 1] = cmd
		for needle, answer in pairs(session.answers or {}) do
			if cmd:find(needle, 1, true) then
				if answer == false then return { ok = false, output = "", error = "exit 1" } end
				return { ok = true, output = answer }
			end
		end
		return { ok = false, output = "", error = "unexpected command" }
	end)
	package.loaded[MODULE] = nil
	local ok, err = pcall(function() body(require(MODULE), commands) end)
	Shell._reset_runner()
	os.getenv = real_getenv
	Display._set_for_test(nil, nil)
	if not ok then error(err, 0) end
end

-- Two devices of `xinput list-props`, the touchpad second.
local XINPUT = [[
Device 'AT Translated Set 2 keyboard':
	Device Enabled (147):	1
	Device Node (270):	"/dev/input/event3"
Device 'SYNA8004:00 06CB:CD8B Touchpad':
	Device Enabled (147):	1
	Coordinate Transformation Matrix (149):	1.000000, 0.000000, 0.000000, 0.000000, 1.000000, 0.000000, 0.000000, 0.000000, 1.000000
	libinput Tapping Enabled (302):	1
	libinput Tapping Enabled Default (303):	0
	libinput Tapping Drag Enabled (304):	1
	libinput Tapping Button Mapping Enabled (308):	1, 0
	libinput Tapping Button Mapping Default (309):	1, 0
	Device Node (270):	"/dev/input/event7"
	Device Product ID (271):	1739, 52619
]]

helpers.describe("tap-to-click setting: each desktop's answer", function()
	helpers.it("(tap-click) X11: the touchpad's own libinput properties, matched by event node", function()
		in_session({ kind = "x11", desktop = "gnome", tools = { xinput = true }, answers = { ["xinput"] = XINPUT } },
			function(Setting, commands)
				helpers.assert_eq(Setting.read(PAD), { known = true, enabled = true, map = "lrm", source = "xinput" })
				helpers.assert_true(commands[1]:find("^timeout 1 ") ~= nil, "every query is bounded")
			end)
		local Setting = require(MODULE)
		helpers.assert_eq(Setting.parse_xinput(XINPUT:gsub("Enabled %(302%):\t1", "Enabled (302):\t0"), PAD.path).enabled, false)
		helpers.assert_eq(Setting.parse_xinput(XINPUT:gsub("%(308%):\t1, 0", "(308):\t0, 1"), PAD.path).map, "lmr")
		helpers.assert_eq(Setting.parse_xinput(XINPUT, "/dev/input/event9").known, false, "another node is no answer")
		local synaptics = XINPUT:gsub("\tlibinput Tapping[^\n]*\n", "")
		helpers.assert_eq(Setting.parse_xinput(synaptics, PAD.path).known, false, "a non-libinput X driver is unknown")
	end)

	helpers.it("(tap-click) KDE Plasma Wayland: KWin's InputDevice object of the event node", function()
		in_session({ kind = "wayland", desktop = "kde", tools = { qdbus6 = true }, answers = {
			["event7 org.kde.KWin.InputDevice.tapToClick"] = "true\n",
			["event7 org.kde.KWin.InputDevice.lmrTapButtonMap"] = "true\n",
			["event7 org.kde.KWin.InputDevice.enabled"] = "true\n",
		} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD), { known = true, enabled = true, map = "lmr", source = "kwin" })
		end)
		in_session({ kind = "wayland", desktop = "kde", tools = { qdbus6 = true }, answers = {
			["tapToClick"] = false, ["lmrTapButtonMap"] = "false\n", ["enabled"] = "true\n",
		} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD).known, false, "a failed query is unknown, never off")
		end)
	end)

	helpers.it("(tap-click) sway: the libinput block of the touchpad of that name", function()
		local inputs = [=[[{"identifier":"1:1:AT_Translated_Set_2_keyboard","name":"AT Translated Set 2 keyboard","type":"keyboard"},
			{"identifier":"1739:52619:SYNA8004:00_06CB:CD8B_Touchpad","name":"SYNA8004:00 06CB:CD8B Touchpad","type":"touchpad",
			"libinput":{"send_events":"enabled","tap":"enabled","tap_button_map":"lmr","tap_drag":"enabled"}}]]=]
		in_session({ kind = "wayland", env = { SWAYSOCK = "/run/user/1000/sway-ipc.sock" }, tools = { swaymsg = true },
			answers = { ["swaymsg -t get_inputs"] = inputs } }, function(Setting)
			helpers.assert_eq(Setting.read(PAD), { known = true, enabled = true, map = "lmr", source = "sway" })
		end)
		local Setting = require(MODULE)
		helpers.assert_eq(Setting.parse_sway(inputs:gsub('"tap":"enabled"', '"tap":"disabled"'), PAD.name).enabled, false)
		helpers.assert_eq(Setting.parse_sway(inputs:gsub('"send_events":"enabled"', '"send_events":"disabled"'), PAD.name).enabled,
			false, "a disabled pad taps nothing")
		helpers.assert_eq(Setting.parse_sway(inputs, "Other Touchpad").known, false)
	end)

	helpers.it("(tap-click) Hyprland: the global touchpad options", function()
		in_session({ kind = "wayland", env = { HYPRLAND_INSTANCE_SIGNATURE = "abc" }, tools = { hyprctl = true }, answers = {
			["tap-to-click"] = '{"option": "input:touchpad:tap-to-click", "int": 1, "set": false}',
			["tap_button_map"] = '{"option": "input:touchpad:tap_button_map", "str": "", "set": false}',
		} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD), { known = true, enabled = true, map = "lrm", source = "hyprland" })
		end)
		local Setting = require(MODULE)
		helpers.assert_eq(Setting.parse_hyprland('{"int": 0}', '{"str": "lmr"}'), { known = true, enabled = false,
			map = "lmr", source = "hyprland" })
		helpers.assert_eq(Setting.parse_hyprland('{"int": 1}', '{"str": "rml"}').known, false)
		helpers.assert_eq(Setting.parse_hyprland("not json", '{"str": ""}').known, false)
	end)

	helpers.it("(tap-click) GNOME Wayland: gsettings, with or without the tap-button-map key", function()
		local keys = "accel-profile\nsend-events\ntap-and-drag\ntap-button-map\ntap-to-click\n"
		in_session({ kind = "wayland", desktop = "gnome", tools = { gsettings = true }, answers = {
			["list-keys"] = keys, [" tap-to-click"] = "true\n", [" tap-button-map"] = "'lmr'\n", [" send-events"] = "'enabled'\n",
		} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD), { known = true, enabled = true, map = "lmr", source = "gnome" })
		end)
		in_session({ kind = "wayland", desktop = "gnome", tools = { gsettings = true }, answers = {
			["list-keys"] = "send-events\ntap-to-click\n", [" tap-to-click"] = "true\n", [" send-events"] = "'enabled'\n",
		} }, function(Setting, commands)
			helpers.assert_eq(Setting.read(PAD).map, "lrm", "a GNOME without the key leaves libinput's map")
			for _, cmd in ipairs(commands) do helpers.assert_true(not cmd:find("tap-button-map", 1, true)) end
		end)
		in_session({ kind = "wayland", desktop = "gnome", tools = { gsettings = true }, answers = {
			["list-keys"] = keys, [" tap-to-click"] = "true\n", [" tap-button-map"] = false, [" send-events"] = "'enabled'\n",
		} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD).known, false, "a key that exists and fails is unknown")
		end)
		local Setting = require(MODULE)
		helpers.assert_eq(Setting.parse_gnome("true", "'default'", "'disabled'").enabled, false)
		helpers.assert_eq(Setting.parse_gnome("false", "'default'", "'enabled'").enabled, false)
		helpers.assert_eq(Setting.parse_gnome("true", nil, "'disabled-on-external-mouse'").known, false)
	end)

	helpers.it("(tap-click) any other session is unknown with the menu's reason", function()
		in_session({ kind = "wayland", desktop = "weston" }, function(Setting, commands)
			helpers.assert_eq(Setting.read(PAD).known, false)
			helpers.assert_eq(Setting.read(PAD).reason, "platform_reason.tap_to_click_setting_unreadable")
			helpers.assert_eq(#commands, 0, "nothing is run where nothing can answer")
		end)
		in_session({ kind = "x11", tools = {} }, function(Setting)
			helpers.assert_eq(Setting.read(PAD).detail, "xinput is not installed")
		end)
	end)
end)

--- tests/unit/modules/test_action_handlers_declared.lua
---
--- ==============================================================================
--- MODULE: Regression — actions the shared catalogue declares for Linux must
---         actually do something (linux-declared-actions-unhandled)
--- DESCRIPTION:
--- `_shared/modules/actions/actions.toml` declared 79 actions for Linux and the
--- driver implemented 40 of them. The other 39 were not broken in a way anyone
--- could see: the picker offers every DECLARED action as bindable, so the user
--- bound one, the assignment was stored, the chord fired — and `_execute_action`
--- fell through to `Logger.debug("Unknown action")`. No error at bind time, none
--- at fire time, and DEBUG is not where a user looks.
---
--- ROOT CAUSE ENCODED: a catalogue is a promise. Ten of the first eleven closed
--- were not missing code at all — the shared row described the chord for
--- AutoHotkey and Hammerspoon and had no `emit_linux` column, so the generator
--- emitted no row for it. A driver-shaped gap is worth checking in the DATA
--- before it is checked in the driver.
---
--- These tests drive the REAL dispatcher with a recording shell so what is
--- asserted is the command that would run, not the presence of a table key.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Recording the shell ==========
-- =========================================
-- =========================================

--- Runs `body` with os.execute recording instead of running, and restores it.
---
--- The manager shells out through one local `_run`, so intercepting os.execute
--- catches every command whatever branch produced it — a stub on the module's
--- own helper would only see the branches that call the helper.
--- @param body function Receives the recorded command table.
local function with_recorded_shell(body)
	local commands = {}
	local real = os.execute
	os.execute = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		return true
	end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

--- Every recorded command joined, for a substring hunt across all of them.
local function joined(commands)
	return table.concat(commands, "\n")
end





--- Runs every action in `ids` through the real dispatcher, with the shell, the
--- uinput emitter and the webview recorded, and returns the ids that reached
--- the "Unknown action" branch.
--- @param Gestures table The gestures manager.
--- @param ids table Action ids.
--- @param configure function|nil Installs daemon handlers after native doubles.
--- @return table unknown, table pressed Chords sent, by action id.
local function run_every_action(Gestures, ids, configure)
	local Logger = require("logger.shim")
	local saved = {
		debug = Logger.debug, warn = Logger.warn,
		emitter = package.loaded["modules.gestures.combo_emitter"],
		shortcuts = package.loaded["modules.shortcuts.manager"],
		webview = package.loaded["ui.webview_manager"], popen = io.popen,
	}
	-- Loaded again under the recording emitter below, since it keeps its own.
	package.loaded["modules.shortcuts.manager"] = nil
	local unknown, pressed, current = {}, {}, nil
	local function spy(fmt)
		if type(fmt) == "string" and fmt:find("Unknown action", 1, true) then unknown[#unknown + 1] = current end
	end
	Logger.debug = function(_, fmt) spy(fmt) end
	Logger.warn = function(_, fmt) spy(fmt) end
	package.loaded["modules.gestures.combo_emitter"] = {
		press = function(combo) pressed[current] = combo; return true end,
	}
	package.loaded["ui.webview_manager"] = { show = function() return true end }
	io.popen = function()
		return { read = function() return "selection" end, close = function() return true end }
	end
	local ok, err = pcall(with_recorded_shell, function()
		if configure then configure() end
		for _, id in ipairs(ids) do
			current = id
			Gestures.execute_action(id, "test__slot")
		end
	end)
	Logger.debug, Logger.warn = saved.debug, saved.warn
	package.loaded["modules.gestures.combo_emitter"] = saved.emitter
	package.loaded["modules.shortcuts.manager"] = saved.shortcuts
	package.loaded["ui.webview_manager"] = saved.webview
	io.popen = saved.popen
	if not ok then error(err, 0) end
	return unknown, pressed
end

helpers.describe("linux actions: every action this driver declares runs", function()

	helpers.it("runs every action the catalogue declares for Linux, and every one it offers", function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		local ids = Gestures.get_executable_action_names()
		helpers.assert_true(#Gestures.LINUX_DECLARED_ACTIONS > 70,
			"the shared catalogue must be read, or this loop proves nothing")
		helpers.assert_true(#ids >= #Gestures.LINUX_DECLARED_ACTIONS)
		local unknown = run_every_action(Gestures, ids, function()
			local noop = function() end
			local script = require("modules.shortcuts.script_actions").new({ reset = noop, reload = noop, quit = noop })
			local handlers = require("modules.shortcuts.action_handlers").compose(script.handlers,
				require("modules.shortcuts.manager"), require("modules.llm.prediction_engine"))
			Gestures.init({ enabled = false, persist = false, action_handlers = handlers })
		end)
		helpers.assert_eq(unknown, {},
			"declared or offered for Linux, and nothing runs: a tap, gesture or shortcut that does nothing")
	end)

	helpers.it("sends the edit chords Windows had alone", function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		local chords = { select_all = "ctrl+a", undo = "ctrl+z", redo = "ctrl+shift+z", find = "ctrl+f" }
		local ids = {}
		for id in pairs(chords) do ids[#ids + 1] = id end
		local unknown, pressed = run_every_action(Gestures, ids)
		helpers.assert_eq(unknown, {})
		helpers.assert_eq(pressed, chords, "each one is its chord, pressed on the virtual keyboard")
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		for id, chord in pairs(chords) do
			helpers.assert_not_nil(Emitter.parse(chord), id .. ": the emitter can press " .. chord)
		end
	end)

	helpers.it("warns, not in DEBUG, when an action has nothing to run", function()
		local Gestures = helpers.load_module("modules.gestures.manager")
		local Logger = require("logger.shim")
		local real_warn, warned = Logger.warn, {}
		Logger.warn = function(_, fmt, ...) warned[#warned + 1] = string.format(fmt, ...) end
		local ok, err = pcall(Gestures.execute_action, "microsoft_bold", "tap_hold")
		Logger.warn = real_warn
		if not ok then error(err, 0) end
		helpers.assert_eq(#warned, 1, "one warning")
		helpers.assert_contains(warned[1], "microsoft_bold")
	end)

end)




-- =========================================================
-- =========================================================
-- ======= 2/ The driver's own windows and files ===========
-- =========================================================
-- =========================================================

helpers.describe("linux actions: the driver's own surfaces", function()

	local Gestures = helpers.load_module("modules.gestures.manager")

	helpers.it("opening a config file reaches xdg-open with a real path", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_config", "test__slot")
			local text = joined(commands)
			helpers.assert_true(text:find("xdg-open", 1, true) ~= nil,
				"open_config must actually open something — it used to reach the 'Unknown action' branch and log at DEBUG")
			helpers.assert_true(text:find("config.toml", 1, true) ~= nil,
				"and the thing it opens must be the config file, not a directory or an empty string")
		end)
	end)

	helpers.it("opening the script source resolves the Linux driver entry point", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_script_source", "test__slot")
			local text = joined(commands)
			helpers.assert_true(text:find("xdg-open", 1, true) ~= nil,
				"open_script_source must reach the desktop opener")
			helpers.assert_true(text:find("ergopti_hotstrings.lua", 1, true) ~= nil,
				"the action must open the actual Linux entry point")
		end)
	end)

	helpers.it("daemon-owned actions call their injected lifecycle handlers", function()
		local calls = {}
		Gestures.init({
			enabled = false,
			action_handlers = {
				script_pause_toggle = function() calls[#calls + 1] = "pause" end,
				script_reload = function() calls[#calls + 1] = "reload" end,
				script_save_reload = function() calls[#calls + 1] = "save_reload" end,
				script_quit = function() calls[#calls + 1] = "quit" end,
			},
		})
		for _, id in ipairs({
			"script_pause_toggle", "script_reload", "script_save_reload", "script_quit",
		}) do
			Gestures.execute_action(id, "test__slot")
		end
		helpers.assert_eq(calls, { "pause", "reload", "save_reload", "quit" },
			"each lifecycle action must reach exactly one daemon-owned callback")
	end)

	helpers.it("today's log path comes from the sink, not from a second copy of the name", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_today_log", "test__slot")
			local Sink = require("infra.logger_sink")
			local expected = Sink.main_log_path()
			helpers.assert_true(joined(commands):find(expected, 1, true) ~= nil,
				"the action must open exactly the file the sink is writing to. Rebuilding the name from a local copy of the 'ErgoptiPlus_' prefix opens the wrong file the day the constant changes — and xdg-open on a missing path fails silently")
		end)
	end)

	helpers.it("the three personal files each resolve to their own path", function()
		with_recorded_shell(function(commands)
			for _, id in ipairs({ "open_personal_info", "open_personal_hotstrings", "open_personal_shortcuts" }) do
				Gestures.execute_action(id, "test__slot")
			end
			local text = joined(commands)
			helpers.assert_true(text:find("personal_info.toml", 1, true) ~= nil, "personal_info.toml")
			helpers.assert_true(text:find("personal_hotstrings.toml", 1, true) ~= nil, "personal_hotstrings.toml")
			helpers.assert_true(text:find("personal_shortcuts.toml", 1, true) ~= nil, "personal_shortcuts.toml")
		end)
	end)

	helpers.it("a window action shells out to nothing — it asks the webview", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("open_metrics_typing", "test__slot")
			helpers.assert_true(not joined(commands):find("xdg-open", 1, true),
				"the metrics window is a webview this driver owns, not a file for the desktop to open. Routing it through xdg-open would open the HTML in a browser instead of the driver's own window")
		end)
	end)

	helpers.it("the paths action opens the dedicated paths editor", function()
		local previous_webview = package.loaded["ui.webview_manager"]
		local opened = nil
		package.loaded["ui.webview_manager"] = {
			show = function(app_name)
				opened = app_name
				return true
			end,
		}

		local ok, err = pcall(Gestures.execute_action, "open_paths_editor", "test__slot")
		package.loaded["ui.webview_manager"] = previous_webview

		helpers.assert_true(ok, "opening the paths editor must not throw: " .. tostring(err))
		helpers.assert_eq(opened, "paths_editor",
			"open_paths_editor must not redirect to the unrelated hotstring settings page")
	end)

end)





-- =========================================================
-- =========================================================
-- ======= 3/ Screenshots, which no one binary takes =======
-- =========================================================
-- =========================================================

helpers.describe("linux actions: screenshots", function()

	local Gestures = helpers.load_module("modules.gestures.manager")

	helpers.it("tries a Wayland tool before an X11 one", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("screenshot_fullscreen_clipboard", "test__slot")
			local text = joined(commands)
			local grim = text:find("grim", 1, true)
			local maim = text:find("maim", 1, true)
			helpers.assert_true(grim ~= nil, "a Wayland candidate must be in the cascade")
			helpers.assert_true(maim ~= nil, "and an X11 one, for sessions that have no grim")
			helpers.assert_true(grim < maim,
				"Wayland FIRST. Under Wayland the X11 tools talk to nothing and exit ZERO, so a cascade that tried them first would report success and capture nothing — on exactly the desktops this driver targets")
		end)
	end)

	helpers.it("a save variant names a real destination file", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("screenshot_region_save", "test__slot")
			local text = joined(commands)
			helpers.assert_true(text:find("%.png") ~= nil,
				"the save variants write a file, so the command must carry a path")
			helpers.assert_true(text:find("ergopti_reg_", 1, true) ~= nil,
				"stamped with the capture kind and the time: two captures in the same minute must not overwrite each other, and the file that vanishes is the one the user wanted")
		end)
	end)

	helpers.it("a clipboard variant names no destination file", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("screenshot_region_clipboard", "test__slot")
			helpers.assert_true(not joined(commands):find("ergopti_reg_", 1, true),
				"a clipboard capture writes no file — passing one would leave a stray screenshot on disk every time the user copied a region")
		end)
	end)

	helpers.it("every screenshot action produces a command", function()
		local ids = {
			"screenshot_window_clipboard", "screenshot_window_save",
			"screenshot_region_clipboard", "screenshot_region_save",
			"screenshot_fullscreen_clipboard", "screenshot_fullscreen_save",
		}
		for _, id in ipairs(ids) do
			with_recorded_shell(function(commands)
				Gestures.execute_action(id, "test__slot")
				helpers.assert_true(#commands > 0,
					id .. " must run something. Five of six working is the shape this whole file exists to prevent")
			end)
		end
	end)

end)




-- =========================================================
-- =========================================================
-- ======= 4/ Click toggles, which must let go =============
-- =========================================================
-- =========================================================

helpers.describe("linux actions: click toggles", function()

	helpers.it("click-toggle: the second fire releases what the first held", function()
		-- Regression: both branches ran `xdotool mousedown` with no state and
		-- no mouseup, so firing twice held the button twice and never let go —
		-- a stuck drag selecting everything until a manual mouseup.
		local G = helpers.load_module("modules.gestures.manager")
		with_recorded_shell(function(commands)
			G.execute_action("left_click_toggle", "test__slot")
			G.execute_action("left_click_toggle", "test__slot")
			helpers.assert_eq(#commands, 2,
				"two fires must run exactly two commands")
			helpers.assert_true(commands[1]:find("mousedown 1", 1, true) ~= nil,
				"the first fire holds the left button down")
			helpers.assert_true(commands[2]:find("mouseup 1", 1, true) ~= nil,
				"the second fire must release it — repeating mousedown sticks the button down in a drag")
		end)
	end)

	helpers.it("click-toggle: left and right buttons toggle independently", function()
		local G = helpers.load_module("modules.gestures.manager")
		with_recorded_shell(function(commands)
			G.execute_action("left_click_toggle", "test__slot")
			G.execute_action("right_click_toggle", "test__slot")
			G.execute_action("left_click_toggle", "test__slot")
			G.execute_action("right_click_toggle", "test__slot")
			helpers.assert_eq(#commands, 4,
				"four fires must run exactly four commands")
			helpers.assert_true(commands[1]:find("mousedown 1", 1, true) ~= nil,
				"left goes down first")
			helpers.assert_true(commands[2]:find("mousedown 3", 1, true) ~= nil,
				"right goes down independently of left")
			helpers.assert_true(commands[3]:find("mouseup 1", 1, true) ~= nil,
				"left goes back up on its own second fire")
			helpers.assert_true(commands[4]:find("mouseup 3", 1, true) ~= nil,
				"and so does right")
		end)
	end)

end)




-- =========================================================
-- =========================================================
-- ======= 5/ Modifier chords go through uinput ============
-- =========================================================
-- =========================================================

-- Every modifier chord the shared catalogue offers (Ctrl+A, the only Select
-- All on Linux, down to Super+.) ran as a background `xdotool key`, which is
-- X11 only: under Wayland it talks to nothing and exits zero, so the chord did
-- nothing and nothing said so. They go through the uinput combo emitter like
-- the catalogue's own combos (modifier-chord-uinput-2026-09-25).
helpers.describe("linux actions: modifier chords", function()

	-- Kernel ABI values (input-event-codes.h) at their US positions, spelled
	-- here so a wrong table in the emitter cannot agree with itself.
	local MODIFIER_CODE = { ctrl = 29, shift = 42, alt = 56, super = 125 }
	local KEY_CODE = {
		a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35, i = 23, j = 36, k = 37, l = 38,
		m = 50, n = 49, o = 24, p = 25, q = 16, r = 19, s = 31, t = 20, u = 22, v = 47, w = 17, x = 45,
		y = 21, z = 44,
		["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5, ["5"] = 6, ["6"] = 7, ["7"] = 8, ["8"] = 9,
		["9"] = 10, ["0"] = 11,
		space = 57, enter = 28, period = 52, comma = 51,
	}

	--- Every chord the shared catalogue declares for Linux, read from the
	--- catalogue itself: { id, mods = {combo names}, key = key id }.
	local function declared_chords()
		local path = require("infra.paths").shared("modules/actions/modifier_chords.json")
		local fh = assert(io.open(path, "r"), "the shared modifier chords must be readable")
		local catalogue = require("json").decode(fh:read("*a"))
		fh:close()
		local modifiers = catalogue.platforms.linux.modifiers
		local chords = {}
		for mask = 1, 2 ^ #modifiers - 1 do
			local ids, names = {}, {}
			for index, modifier in ipairs(modifiers) do
				if math.floor(mask / 2 ^ (index - 1)) % 2 == 1 then
					ids[#ids + 1] = modifier.id
					names[#names + 1] = modifier.xdotool
				end
			end
			for _, key in ipairs(catalogue.keys) do
				chords[#chords + 1] = { id = table.concat(ids, "_") .. "_" .. key.id, mods = names, key = key.id }
			end
		end
		return chords
	end

	--- Runs `body` with a fake open uinput device, a hook holding nothing and
	--- a layout answering `shortcut_keycode`, and restores all three.
	local function with_fake_device(shortcut_keycode, body)
		local names = { "adapters.uinput_writer", "adapters.keyboard_hook", "adapters.keyboard_layout" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local writer = helpers.load_module("tests.fakes").uinput_writer()
		writer.open()
		package.loaded["adapters.uinput_writer"] = writer
		package.loaded["adapters.keyboard_hook"] = {
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end,
		}
		package.loaded["adapters.keyboard_layout"] = { shortcut_keycode = shortcut_keycode }
		local ok, err = pcall(body, writer)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end

	local function us_position(_, us_code) return us_code end

	local function trail(events)
		local parts = {}
		for _, ev in ipairs(events) do parts[#parts + 1] = ev.code .. ":" .. ev.value end
		return table.concat(parts, " ")
	end

	helpers.it("emits every declared chord through uinput, never xdotool (modifier-chord-uinput)", function()
		local chords = declared_chords()
		helpers.assert_true(#chords >= 15 * 40, string.format(
			"only %d chord(s) read from the catalogue; this check would prove nothing", #chords))
		local Gestures = helpers.load_module("modules.gestures.manager")
		for _, chord in ipairs(chords) do
			with_fake_device(us_position, function(writer)
				with_recorded_shell(function(commands)
					Gestures.execute_action(chord.id, "tap_hold")
					helpers.assert_eq(#commands, 0, chord.id .. " must not shell out: `xdotool key` "
						.. "does nothing under Wayland; ran " .. joined(commands))
				end)
				local down, up = {}, {}
				for _, name in ipairs(chord.mods) do down[#down + 1] = MODIFIER_CODE[name] .. ":1" end
				for index = #chord.mods, 1, -1 do up[#up + 1] = MODIFIER_CODE[chord.mods[index]] .. ":0" end
				local key = KEY_CODE[chord.key]
				helpers.assert_true(key ~= nil, "no expected code for the catalogue key " .. chord.key)
				helpers.assert_eq(trail(writer.events),
					table.concat(down, " ") .. " " .. key .. ":1 " .. key .. ":0 " .. table.concat(up, " "),
					chord.id .. " must hold its modifiers across the key on the uinput device")
			end)
		end
	end)

	helpers.it("falls back to xdotool with keysym names it accepts (modifier-chord-uinput)", function()
		-- Only when the uinput device cannot be written. `xdotool key ctrl+.`
		-- fails: xdotool takes X keysym names, and "." is `period`.
		local Logger = require("logger.shim")
		local Gestures = helpers.load_module("modules.gestures.manager")
		local real_error = Logger.error
		Logger.error = function() end
		local ok, err = pcall(function()
			for _, chord in ipairs(declared_chords()) do
				local writer = helpers.load_module("tests.fakes").uinput_writer()
				local saved = package.loaded["adapters.uinput_writer"]
				package.loaded["adapters.uinput_writer"] = writer
				with_recorded_shell(function(commands)
					Gestures.execute_action(chord.id, "tap_hold")
					package.loaded["adapters.uinput_writer"] = saved
					helpers.assert_eq(#commands, 1, chord.id .. " with no uinput device runs xdotool once")
					local keys = commands[1]:match("^xdotool key (%S+)")
					helpers.assert_not_nil(keys, chord.id .. " falls back to `xdotool key`: " .. commands[1])
					local parts = 0
					for part in keys:gmatch("[^+]+") do
						parts = parts + 1
						helpers.assert_true(part:match("^[%w_]+$") ~= nil, string.format(
							"%s: '%s' is no X keysym name, xdotool rejects it", chord.id, part))
					end
					helpers.assert_true(parts >= 2, chord.id .. " sends a modifier and a key: " .. keys)
				end)
			end
		end)
		Logger.error = real_error
		if not ok then error(err, 0) end
	end)

	helpers.it("presses a chord's character where the live layout types it (modifier-chord-uinput)", function()
		-- Applications match Ctrl+A by the symbol the key types, so on Ergopti,
		-- where KEY_V types a comma, Ctrl+, is Ctrl+KEY_V.
		local LIVE = { a = 101, ["1"] = 102, ["."] = 103, [","] = 104 }
		local Gestures = helpers.load_module("modules.gestures.manager")
		for _, case in ipairs({ { "ctrl_a", "a" }, { "ctrl_1", "1" }, { "ctrl_period", "." }, { "ctrl_comma", "," } }) do
			with_fake_device(function(char, us_code) return LIVE[char] or us_code end, function(writer)
				Gestures.execute_action(case[1], "tap_hold")
				helpers.assert_eq(trail(writer.events), string.format("29:1 %d:1 %d:0 29:0", LIVE[case[2]],
					LIVE[case[2]]), case[1] .. " must press the key the layout types " .. case[2] .. " on")
			end)
		end
	end)

end)




-- =========================================================
-- =========================================================
-- ======= 6/ Workspaces: wmctrl, then the keyboard ========
-- =========================================================
-- =========================================================

helpers.describe("linux actions: workspace switch", function()

	--- Runs a workspace action with wmctrl and the uinput emitter each
	--- succeeding or not.
	--- @return table commands The shell commands run.
	--- @return table pressed The combos pressed on the virtual keyboard.
	local function switch(action, wmctrl_ok, uinput_ok)
		local saved = package.loaded["modules.gestures.combo_emitter"]
		local pressed, commands = {}, {}
		package.loaded["modules.gestures.combo_emitter"] = {
			press = function(combo) pressed[#pressed + 1] = combo; return uinput_ok end,
		}
		local real = os.execute
		os.execute = function(cmd)
			commands[#commands + 1] = tostring(cmd)
			if tostring(cmd):find("wmctrl", 1, true) and not wmctrl_ok then return nil, "exit", 1 end
			return true
		end
		local ok, err = pcall(function()
			helpers.load_module("modules.gestures.manager").execute_action(action, "tap_hold")
		end)
		os.execute = real
		package.loaded["modules.gestures.combo_emitter"] = saved
		if not ok then error(err, 0) end
		return commands, pressed
	end

	local COMBO = { desktop_prev = "ctrl+alt+Left", desktop_next = "ctrl+alt+Right" }

	helpers.it("asks wmctrl first, and presses nothing when it switched (workspace-uinput)", function()
		for action in pairs(COMBO) do
			local commands, pressed = switch(action, true, true)
			helpers.assert_eq(#commands, 1, action .. " runs wmctrl alone")
			helpers.assert_contains(commands[1], "wmctrl -s")
			helpers.assert_nil(commands[1]:find("xdotool", 1, true), action .. ": " .. commands[1])
			helpers.assert_eq(pressed, {}, action .. ": wmctrl switched, no keystroke on top")
		end
	end)

	helpers.it("presses the desktop's combo through uinput when wmctrl cannot switch (workspace-uinput)", function()
		-- Under Wayland wmctrl has no desktop to ask, and `xdotool key` talks to
		-- nothing: the uinput device is the one path that reaches the compositor.
		for action, combo in pairs(COMBO) do
			local commands, pressed = switch(action, false, true)
			helpers.assert_eq(pressed, { combo }, action .. " presses " .. combo .. " on the virtual keyboard")
			for _, command in ipairs(commands) do
				helpers.assert_nil(command:find("xdotool", 1, true), action .. " ran " .. command)
			end
		end
	end)

	helpers.it("uses xdotool only when the uinput device cannot be written either (workspace-uinput)", function()
		for action, combo in pairs(COMBO) do
			local commands = switch(action, false, false)
			helpers.assert_contains(commands[#commands], "xdotool key " .. combo)
		end
	end)

	helpers.it("fails the wmctrl command when wmctrl cannot list the desktops (workspace-uinput)", function()
		-- The command used to end in `| xargs -r wmctrl -s`, which exits 0 on
		-- empty input: a wmctrl that could not list anything reported success
		-- and nothing ran after it. Run for real against stand-in wmctrls.
		local commands = switch("desktop_prev", true, true)
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir " .. dir)
		local log = dir .. "/switched"
		--- Writes an executable shell script.
		local function script(path, body)
			local fh = assert(io.open(path, "w"))
			fh:write("#!/bin/sh\n", body, "\n")
			fh:close()
			os.execute("chmod +x " .. path)
		end
		local function stand_in(body) script(dir .. "/wmctrl", body) end
		-- The command may rely on wmctrl and timeout only: no package declares
		-- anything else (it used awk, which a minimal openSUSE lacks). So the
		-- PATH it runs under holds the stand-in wmctrl and a timeout that execs
		-- the real one, and nothing more. The real timeout is looked up by the
		-- shell itself, on the PATH the script started with.
		script(dir .. "/timeout", "real=$(PATH=$HOST_PATH; command -v timeout) || exit 127\n"
			.. "exec \"$real\" \"$@\"")
		-- Run as a script file, the way the daemon's shell runs it: a quoted
		-- script path is also what the Windows test mode hands to sh.
		local function run()
			script(dir .. "/switch.sh", "HOST_PATH=$PATH; export HOST_PATH; PATH=" .. dir
				.. "; export PATH\n" .. commands[1])
			local result = os.execute("'" .. dir .. "/switch.sh'")
			return result == true or result == 0
		end
		stand_in("echo 'Cannot get current desktop properties.' >&2; exit 1")
		helpers.assert_true(not run(), "wmctrl -d failing must fail the command, so the combo is pressed")
		stand_in('if [ "$1" = -d ]; then printf "0  * DG: x\\n1  - DG: x\\n2  - DG: x\\n"; '
			.. 'else echo "$2" > "${0%/*}/switched"; fi')
		helpers.assert_true(run(), "a listed desktop is switched to with only wmctrl and timeout on the PATH")
		local fh = assert(io.open(log, "r"))
		helpers.assert_eq(fh:read("*l"), "2", "the previous desktop of the first one wraps to the last")
		fh:close()
		os.remove(log)
		stand_in('if [ "$1" = -d ]; then printf "0  - DG: x\\n1  - DG: x\\n"; '
			.. 'else echo "$2" > "${0%/*}/switched"; fi')
		helpers.assert_true(not run(), "a listing with no current desktop must fail, so the combo is pressed")
		os.execute("rm -rf " .. dir)
	end)

end)





-- ===========================================================
-- ===========================================================
-- ======= 6b/ Media keys: the tool, then the keyboard =======
-- ===========================================================
-- ===========================================================

-- Volume, brightness and track fell back to `xdotool key XF86...` when
-- pactl, brightnessctl or playerctl was missing or refused, and under Wayland
-- that exits zero and presses nothing: the action did nothing and no error
-- said so. They fall back to the same key on the uinput device instead
-- (media-keys-uinput-2026-09-26).
helpers.describe("linux actions: media and brightness keys", function()

	-- Kernel ABI values (input-event-codes.h), spelled here so a wrong table
	-- in the emitter cannot agree with itself.
	local MEDIA = {
		vol_up = { tool = "pactl", key = "XF86AudioRaiseVolume", code = 115 },
		vol_down = { tool = "pactl", key = "XF86AudioLowerVolume", code = 114 },
		mute = { tool = "pactl", key = "XF86AudioMute", code = 113 },
		brightness_up = { tool = "brightnessctl", key = "XF86MonBrightnessUp", code = 225 },
		brightness_down = { tool = "brightnessctl", key = "XF86MonBrightnessDown", code = 224 },
		track_play = { tool = "playerctl", key = "XF86AudioPlay", code = 164 },
		track_next = { tool = "playerctl", key = "XF86AudioNext", code = 163 },
		track_prev = { tool = "playerctl", key = "XF86AudioPrev", code = 165 },
	}

	--- Runs a media action with its tool and the uinput emitter each
	--- succeeding or not.
	--- @return table commands The shell commands run.
	--- @return table pressed The combos pressed on the virtual keyboard.
	local function run(action, tool_ok, uinput_ok)
		local saved = package.loaded["modules.gestures.combo_emitter"]
		local pressed, commands = {}, {}
		package.loaded["modules.gestures.combo_emitter"] = {
			press = function(combo) pressed[#pressed + 1] = combo; return uinput_ok end,
		}
		local real = os.execute
		os.execute = function(cmd)
			commands[#commands + 1] = tostring(cmd)
			if tostring(cmd):find(MEDIA[action].tool, 1, true) and not tool_ok then return nil, "exit", 1 end
			return true
		end
		local ok, err = pcall(function()
			helpers.load_module("modules.gestures.manager").execute_action(action, "tap_hold")
		end)
		os.execute = real
		package.loaded["modules.gestures.combo_emitter"] = saved
		if not ok then error(err, 0) end
		return commands, pressed
	end

	helpers.it("runs the tool alone and presses nothing when it worked (media-keys-uinput)", function()
		for action, media in pairs(MEDIA) do
			local commands, pressed = run(action, true, true)
			helpers.assert_eq(#commands, 1, action .. " runs " .. media.tool .. " alone")
			helpers.assert_contains(commands[1], media.tool)
			helpers.assert_nil(commands[1]:find("xdotool", 1, true), action .. ": " .. commands[1])
			helpers.assert_eq(pressed, {}, action .. ": the tool worked, no keystroke on top")
		end
	end)

	helpers.it("presses the media key through uinput when the tool fails (media-keys-uinput)", function()
		for action, media in pairs(MEDIA) do
			local commands, pressed = run(action, false, true)
			helpers.assert_eq(pressed, { media.key }, action .. " presses " .. media.key .. " on the virtual keyboard")
			for _, command in ipairs(commands) do
				helpers.assert_nil(command:find("xdotool", 1, true), action .. " ran " .. command)
			end
		end
	end)

	helpers.it("uses xdotool only when the uinput device cannot be written either (media-keys-uinput)", function()
		for action, media in pairs(MEDIA) do
			local commands = run(action, false, false)
			helpers.assert_contains(commands[#commands], "xdotool key " .. media.key)
		end
	end)

	helpers.it("knows the evdev key of every media keysym (media-keys-uinput)", function()
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		for action, media in pairs(MEDIA) do
			local parsed, unknown = Emitter.parse(media.key)
			helpers.assert_true(parsed ~= nil, action .. ": " .. tostring(unknown))
			helpers.assert_eq(parsed.keys, { media.code }, media.key .. " is evdev code " .. media.code)
			helpers.assert_eq(parsed.mods, {}, media.key .. " is a lone key")
		end
	end)

end)




-- =========================================================
-- =========================================================
-- ======= 7/ Search needs something to search =============
-- =========================================================
-- =========================================================

helpers.describe("linux actions: web search", function()

	--- Runs body with xclip absent (io.popen returns nil).
	local function without_xclip(body)
		local real_popen = io.popen
		io.popen = function() return nil end
		local ok, err = pcall(body)
		io.popen = real_popen
		if not ok then error(err, 0) end
	end

	--- Runs body with xclip returning `selection`.
	local function with_selection(selection, body)
		local real_popen = io.popen
		io.popen = function()
			return {
				read = function() return selection end,
				close = function() return true end,
			}
		end
		local ok, err = pcall(body)
		io.popen = real_popen
		if not ok then error(err, 0) end
	end

	helpers.it("search-web: refuses an empty selection instead of opening a blank search", function()
		-- Regression: with xclip missing (notably every Wayland session
		-- without it), primary_selection() answered "" and the gesture opened
		-- the engine with an empty query ÔÇö a wasted tab that answers nothing.
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		helpers.assert_true(
			G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s"),
			"the parameter must store before the gesture can run")
		without_xclip(function()
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 0,
					"with no selection there is no query ÔÇö opening the engine on "
						.. "an empty q= wastes a tab and answers nothing")
			end)
		end)
	end)

	helpers.it("search-web: searches the selected text when there is some", function()
		-- Lock-in against over-correction: refusing everything would also make
		-- this green, while breaking the action's entire purpose.
		local G = helpers.load_module("modules.gestures.manager")
		G.init({ enabled = false })
		G.set_action_parameter("tap_3", "search_web", "https://duckduckgo.com/?q=%s")
		with_selection("hello world", function()
			with_recorded_shell(function(commands)
				G.execute_action("search_web", "tap_3")
				helpers.assert_eq(#commands, 1, "a real selection must open exactly one search")
				helpers.assert_true(commands[1]:find("q=hello%20world", 1, true) ~= nil,
					"the selection must reach the engine URL-encoded")
			end)
		end)
	end)

end)

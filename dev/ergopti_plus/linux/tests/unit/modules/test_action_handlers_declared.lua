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

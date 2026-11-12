--- tests/unit/modules/hotstrings/injector/test_injector_erase_pacing.lua

--- ==============================================================================
--- MODULE: The Pause Between An Erase And Its Text
--- DESCRIPTION:
--- Every expansion used to pause 20 ms between erasing its trigger and typing
--- its replacement, in every application, and the pause blocked the daemon's
--- loop. Windows and macOS pace the erase only for a terminal or TUI prompt
--- ([debounce] terminal_hotstring_key_delay_ms); the injector now asks the
--- daemon's pacing port, which answers true for a terminal or an unknown
--- application. Without a port every erase still pauses.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAYOUT = {
	["B"] = { keycode = 48, level = 2, mods = { "shift" } },
	["o"] = { keycode = 24, level = 1, mods = {} },
}

--- Loads the injector over a recording channel and a recording pause.
--- @return table injector, table pauses
local function load()
	package.loaded["adapters.xkb_capture"] = nil
	local Capture = require("adapters.xkb_capture")
	Capture.caps_locked = function() return false end
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(LAYOUT)
	local channel = { emitted = {} }
	channel.is_open = function() return true end
	channel.emit = function(code, value)
		channel.emitted[#channel.emitted + 1] = { code = code, value = value }
		return true
	end
	channel.sync = function() return true end
	package.loaded["modules.hotstrings.injector"] = nil
	local injector = require("modules.hotstrings.injector")
	injector._set_uinput(channel)
	local pauses = {}
	injector._set_nanosleep_for_test(function(seconds) pauses[#pauses + 1] = seconds end)
	return injector, pauses
end

local function done()
	package.loaded["adapters.xkb_capture"] = nil
	package.loaded["modules.hotstrings.injector"] = nil
end

helpers.describe("injector: the erase pause follows the pacing port", function()
	helpers.it("pauses after every erase while no pacing port is installed", function()
		local injector, pauses = load()
		helpers.assert_true(injector.inject(2, "Bo").ok)
		helpers.assert_eq(#pauses, 1)
		done()
	end)

	helpers.it("types the text at once when the target needs no pause", function()
		local injector, pauses = load()
		helpers.assert_true(injector.set_erase_pacing(function() return false end))
		helpers.assert_true(injector.inject(2, "Bo").ok)
		helpers.assert_eq(#pauses, 0, "an editor reads the virtual keyboard's events in order")
		done()
	end)

	helpers.it("(hse-001-terminal-erase-pacing) waits after each Backspace for a target that needs it", function()
		local injector, pauses = load()
		injector.set_erase_pacing(function() return true end)
		helpers.assert_true(injector.inject(2, "Bo").ok)
		local delay = require("infra.timings").ms("debounce", "terminal_hotstring_key_delay_ms") / 1000
		helpers.assert_eq(pauses, { delay, delay },
			"a terminal reads each deletion against its own render, as Windows and macOS pace it")
		done()
	end)

	helpers.it("paces each Backspace when the pacing port fails", function()
		local injector, pauses = load()
		injector.set_erase_pacing(function() error("focus unreadable") end)
		helpers.assert_true(injector.inject(2, "Bo").ok)
		helpers.assert_eq(#pauses, 2)
		done()
	end)

	helpers.it("never pauses an expansion with nothing to erase", function()
		local injector, pauses = load()
		injector.set_erase_pacing(function() return true end)
		helpers.assert_true(injector.inject(0, "Bo").ok)
		helpers.assert_eq(#pauses, 0)
		done()
	end)

	helpers.it("refuses a pacing port that is not a function", function()
		local injector = load()
		helpers.assert_eq(injector.set_erase_pacing("terminal"), false)
		done()
	end)
end)

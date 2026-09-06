--- tests/unit/meta/test_tap_hold_writer.lua

--- ==============================================================================
--- MODULE: The Tap-Hold Menu Can Actually Change A Tap-Hold
--- DESCRIPTION:
--- This driver could READ its tap-hold configuration and not change it. The menu
--- listed every key's tap action and hold modifier greyed out, with a comment
--- explaining that a clickable row which cannot change anything is worse than a
--- greyed one — true of the row, and the wrong conclusion for the driver:
--- Windows has edited tap-holds from its tray since the feature existed, from
--- this same file format, and a Linux user had to open a TOML by hand and restart
--- the daemon.
---
--- WHAT THESE PIN:
---   1. a change reaches the user's file in the SHARED schema — `[tap_hold.keys.
---      <id>]` with tap_action / hold_modifier / hold_layer — because all three
---      drivers read that file and a private spelling would be invisible to two
---      of them;
---   2. only the keys the user changed are written, so every other key keeps
---      inheriting the shared default rather than being silently frozen;
---   3. hold_modifier and hold_layer never coexist, since the loader treats them
---      as mutually exclusive and the winner would otherwise depend on the reader;
---   4. the change is APPLIED — kanata's config is regenerated — because a menu
---      row that saves without reloading reads as a setting that did not take.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A manager stub recording what the writer asked it to do.
--- @param path string Where the override file should be written.
--- @return table manager, table calls
local function make_manager(path)
	local calls = { write_kbd = 0, restart = 0 }
	return {
		tap_hold_config_path = function() return path end,
		write_kbd = function() calls.write_kbd = calls.write_kbd + 1; return true end,
		restart   = function()
			calls.restart = calls.restart + 1
			calls.write_kbd = calls.write_kbd + 1
			return true
		end,
		owns_process = function() return true end,
	}, calls
end

--- A writer bound to a throwaway file.
--- @return table writer, string path, table calls
local function fresh_writer()
	local path = os.tmpname()
	os.remove(path)
	local manager, calls = make_manager(path)
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({ manager = manager })
	return writer, path, calls
end

--- The whole override file as text ("" when it does not exist).
--- @param path string
--- @return string
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return "" end
	local content = fh:read("*a")
	fh:close()
	return content
end

helpers.describe("tap-hold writer: the Linux menu can change a tap-hold", function()

	helpers.it("writes the change in the schema all three drivers read", function()
		local writer, path = fresh_writer()
		helpers.assert_true(writer.set_field("caps_lock", "hold_modifier", "shift"),
			"set_field must report success")

		local content = read_file(path)
		helpers.assert_true(content:find("[tap_hold.keys.caps_lock]", 1, true) ~= nil,
			"the section must be the shared one — a private spelling is invisible to the other two drivers")
		helpers.assert_true(content:find('hold_modifier = "shift"', 1, true) ~= nil,
			"the value must be written as the loader reads it")
		os.remove(path)
	end)

	helpers.it("writes ONLY the keys the user changed", function()
		local writer, path = fresh_writer()
		writer.set_field("caps_lock", "hold_modifier", "shift")

		local content = read_file(path)
		helpers.assert_true(content:find("left_shift", 1, true) == nil,
			"a key the user never touched must not appear: the driver merges this file OVER the shared "
			.. "defaults key by key, so naming a key here freezes it at whatever was written")
		os.remove(path)
	end)

	helpers.it("keeps an earlier change when a second one lands", function()
		local writer, path = fresh_writer()
		writer.set_field("caps_lock", "hold_modifier", "shift")
		writer.set_field("left_shift", "tap_action", "copy")

		local content = read_file(path)
		helpers.assert_true(content:find('hold_modifier = "shift"', 1, true) ~= nil,
			"the first change must survive the second — the file is re-read before every write")
		helpers.assert_true(content:find('tap_action = "copy"', 1, true) ~= nil,
			"and the second must be there too")
		os.remove(path)
	end)

	helpers.it("never leaves a hold_modifier and a hold_layer on the same key", function()
		local writer, path = fresh_writer()
		writer.set_field("caps_lock", "hold_modifier", "ctrl")
		writer.set_field("caps_lock", "hold_layer", "nav")

		local content = read_file(path)
		helpers.assert_true(content:find("hold_layer", 1, true) ~= nil, "the layer must be written")
		helpers.assert_true(content:find("hold_modifier", 1, true) == nil,
			"the modifier must be gone: the loader treats the two as mutually exclusive, so leaving both "
			.. "makes which one wins depend on the reader")
		os.remove(path)
	end)

	helpers.it("regenerates kanata's config so the change is in force", function()
		local writer, path, calls = fresh_writer()
		writer.set_field("caps_lock", "hold_modifier", "shift")

		helpers.assert_true(calls.write_kbd >= 1,
			"write_kbd must run: a row that saves without regenerating reads as a setting that did not take")
		helpers.assert_true(calls.restart >= 1,
			"and kanata must be reloaded, since this driver owns the process here")
		os.remove(path)
	end)

	helpers.it("reports failure when the supervisor cannot apply the saved change", function()
		local path = os.tmpname()
		os.remove(path)
		local manager = {
			tap_hold_config_path = function() return path end,
			write_kbd = function() return true end,
			restart = function() return false end,
			owns_process = function() return false end,
		}
		local writer = helpers.load_module("platform.remap.tap_hold_writer")
		writer.init({ manager = manager })

		helpers.assert_true(not writer.set_field("caps_lock", "hold_modifier", "shift"),
			"a persisted but unapplied binding must not be reported as live")
		helpers.assert_true(read_file(path):find('hold_modifier = "shift"', 1, true) ~= nil,
			"the durable choice remains available for a later successful reload")
		os.remove(path)
	end)

	helpers.it("clearing a key removes it and leaves the others alone", function()
		local writer, path = fresh_writer()
		writer.set_field("caps_lock", "hold_modifier", "shift")
		writer.set_field("left_shift", "tap_action", "copy")
		writer.clear_key("caps_lock")

		local content = read_file(path)
		helpers.assert_true(content:find("caps_lock", 1, true) == nil,
			"the cleared key must go back to the shared default, which is what its absence means")
		helpers.assert_true(content:find("left_shift", 1, true) ~= nil,
			"and the other key must be untouched")
		os.remove(path)
	end)

	helpers.it("reports whether a key is overridden, for the menu's checkmark", function()
		local writer, path = fresh_writer()
		helpers.assert_true(writer.is_overridden("caps_lock") == false,
			"nothing is overridden before anything is written")
		writer.set_field("caps_lock", "hold_modifier", "shift")
		helpers.assert_true(writer.is_overridden("caps_lock") == true,
			"and the key reads as overridden once it is")
		os.remove(path)
	end)

	helpers.it("refuses a field that is not part of the shared schema", function()
		local writer, path = fresh_writer()
		helpers.assert_true(writer.set_field("caps_lock", "colour", "red") == false,
			"an unknown field must be refused: it would be written into a file all three drivers read")
		os.remove(path)
	end)
end)

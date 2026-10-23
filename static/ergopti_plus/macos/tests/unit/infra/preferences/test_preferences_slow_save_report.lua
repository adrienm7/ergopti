-- tests/unit/infra/preferences/test_preferences_slow_save_report.lua

--- ==============================================================================
--- MODULE: Regression - a slow whole-snapshot save names its phase (issue #101)
--- DESCRIPTION:
--- The AI-off startup path saves the whole snapshot (about 300 operations) and
--- held the main thread for 1.7 s, delaying event taps and the Karabiner lease
--- heartbeat. Measured in plain Lua, the batch writer takes the same time for
--- one row as for 326, so the batch size is not the lever; the save reports its
--- prepare and write phases when it is slow so the next log names the owner.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture"] = nil
local Fixture = require("tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture")

local MS = 1000000

--- Saves once under a scripted clock and returns the slow-save lines logged.
local function save_with_clock(reads_ms)
	local index = 0
	local original = hs.timer.absoluteTime
	hs.timer.absoluteTime = function()
		index = index + 1
		return (reads_ms[index] or reads_ms[#reads_ms]) * MS
	end
	local disk = { [Fixture.PATH] = Fixture.SOURCE }
	local preferences = Fixture.load_preferences(disk)
	preferences.load(Fixture.PATH)
	local Logger = require("infra.logger")
	local original_warn = Logger.warn
	local lines = {}
	Logger.warn = function(_, format, ...)
		lines[#lines + 1] = string.format(format, ...)
	end
	index = 0
	local ok, err = pcall(preferences.save, Fixture.PATH, {}, {}, {})
	Logger.warn = original_warn
	hs.timer.absoluteTime = original
	assert(ok, err)
	return lines
end

helpers.describe("Preferences.save reports a slow save by phase", function()
	helpers.it("names prepare and write when the save is slow", function()
		-- clock reads: save start, prepare done, write done
		local lines = save_with_clock({ 0, 100, 1700 })
		local slow = {}
		for _, line in ipairs(lines) do
			if line:find("Slow preferences save", 1, true) then slow[#slow + 1] = line end
		end
		helpers.assert_eq(#slow, 1, "one slow-save line")
		helpers.assert_true(slow[1]:find("1700 ms", 1, true) ~= nil, slow[1])
		helpers.assert_true(slow[1]:find("prepare=100", 1, true) ~= nil, slow[1])
		helpers.assert_true(slow[1]:find("write=1600", 1, true) ~= nil, slow[1])
	end)

	helpers.it("stays silent for a fast save", function()
		local lines = save_with_clock({ 0, 5, 12 })
		for _, line in ipairs(lines) do
			helpers.assert_true(line:find("Slow preferences save", 1, true) == nil, line)
		end
	end)
end)

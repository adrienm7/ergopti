--- linux/tests/unit/meta/test_timings_reader.lua

local helpers = require("tests.helpers")

helpers.describe("linux/lib/timings.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "lib.timings")
		helpers.assert_true(ok, "require('lib.timings') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
	end)

	helpers.it("Timings.ms returns known keylogger values", function()
		local Timings = require("lib.timings")
		local session = Timings.ms("keylogger", "session_timeout_ms")
		helpers.assert_true(type(session) == "number", "session_timeout_ms is number")
		helpers.assert_true(session > 0, "session_timeout_ms > 0")

		local wpm = Timings.ms("keylogger", "wpm_window_ms")
		helpers.assert_true(type(wpm) == "number", "wpm_window_ms is number")
		helpers.assert_true(wpm > 0, "wpm_window_ms > 0")
	end)

	helpers.it("Timings.ms returns known tap_hold values", function()
		local Timings = require("lib.timings")
		local one_shot = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")
		helpers.assert_true(type(one_shot) == "number", "one_shot_shift_timeout_ms is number")
		helpers.assert_eq(one_shot, 2000, "one_shot_shift_timeout_ms = 2000")
	end)

	helpers.it("Timings.sec converts ms to seconds", function()
		local Timings = require("lib.timings")
		local sec = Timings.sec("keylogger", "session_timeout_ms")
		local ms = Timings.ms("keylogger", "session_timeout_ms")
		helpers.assert_true(math.abs(sec - ms/1000) < 0.001, "sec = ms/1000")
	end)

	helpers.it("missing section raises error (fail-fast contract)", function()
		local Timings = require("lib.timings")
		local ok, err = pcall(function() Timings.ms("nonexistent", "key") end)
		helpers.assert_true(not ok, "should raise error for missing section")
		helpers.assert_true(type(err) == "string" and err:find("missing"), "error message should mention 'missing'")
	end)

	helpers.it("missing key raises error (fail-fast contract)", function()
		local Timings = require("lib.timings")
		local ok, err = pcall(function() Timings.ms("keylogger", "nonexistent_key") end)
		helpers.assert_true(not ok, "should raise error for missing key")
	end)
end)

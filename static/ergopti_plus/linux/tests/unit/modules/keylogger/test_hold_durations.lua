--- tests/unit/modules/keylogger/test_hold_durations.lua

--- ==============================================================================
--- MODULE: How Long A Key Was Held
--- DESCRIPTION:
--- The per-key hold statistics, and the layout figures recorded beside them.
---
--- WHAT WAS MISSING, AND THE REASON IT WAS BELIEVED UNREACHABLE:
--- agg_app_day_kc_hold was written off as out of reach because "the capture loop
--- throws releases away". It does — for the TEXT path, where a release carries
--- no meaning. It was never true for the metrics: the release passes through the
--- hook before that early return, and measuring it there is four lines.
---
--- On a keyboard whose whole design is dual-role keys, how long a key was held
--- is the difference between the two things it can mean. The table that answers
--- that was empty.
---
--- WHY THE TAP/HOLD SPLIT CAN DECLINE TO ANSWER:
--- The threshold is read from the tap-hold configuration the remap daemon
--- actually runs, so this driver calls something a hold exactly when kanata
--- does. When the keys disagree, or nothing can be read, there IS no single
--- answer — and the split is skipped rather than made on a number nobody chose.
--- The duration, the count and the maximum need no threshold and are recorded
--- either way.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

--- Runs a body against a fresh keylogger over the shared writer double.
--- @param body function Receives the keylogger.
--- @return table The double.
local function with_writer(body)
	local writer_name = "modules.keylogger.sqlite_writer"
	local logger_name = "modules.keylogger.keylogger"
	local previous_writer = package.loaded[writer_name]
	local previous_logger = package.loaded[logger_name]

	local writer = Fakes.sqlite_writer()
	package.loaded[writer_name] = writer
	package.loaded[logger_name] = nil

	local ok, err = pcall(function()
		local keylogger = require(logger_name)
		keylogger.init({ sqlite_path = "/tmp/ergopti_hold_probe.sqlite" })
		keylogger.reset_session()
		body(keylogger)
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return writer
end

--- The rows written for one evdev code.
--- @param writer table
--- @param code number
--- @return table|nil
local function row_for(writer, code)
	local total = nil
	for _, entry in ipairs(writer.kc_hold) do
		if entry.row.keycode == code then
			total = total or { sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }
			total.sum_ms = total.sum_ms + entry.row.sum_ms
			total.count = total.count + entry.row.count
			total.max_ms = math.max(total.max_ms, entry.row.max_ms)
			total.tap_count = total.tap_count + entry.row.tap_count
			total.hold_count = total.hold_count + entry.row.hold_count
		end
	end
	return total
end




-- =================================================================
-- =================================================================
-- ======= 1/ The durations ========================================
-- =================================================================
-- =================================================================

helpers.describe("hold durations: what is recorded", function()

	helpers.it("accumulates the time a key spent down", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 120)
			keylogger.record_hold("code", 30, 80)
			keylogger.flush()
		end)

		local row = row_for(writer, 30)
		helpers.assert_not_nil(row,
			"this table was written off as unreachable because the capture loop "
				.. "throws releases away — true for the text path, never true for the "
				.. "metrics, where the release passes through the hook first")
		helpers.assert_eq(row.sum_ms, 200)
		helpers.assert_eq(row.count, 2)
	end)

	helpers.it("keeps the longest hold as a record", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 400)
			keylogger.record_hold("code", 30, 90)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).max_ms, 400,
			"the longest hold of the day does not get shorter because a quick tap "
				.. "followed it")
	end)

	helpers.it("keeps two keys apart", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.record_hold("code", 31, 500)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).sum_ms, 100)
		helpers.assert_eq(row_for(writer, 31).sum_ms, 500,
			"the table is per key because the question is which keys are being "
				.. "held, and one average over the board answers nothing")
	end)

	helpers.it("writes only the increment on a second flush", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
		end)
		helpers.assert_eq(row_for(writer, 30).count, 2,
			"the row sums on conflict, so writing the cumulative total again would "
				.. "count every earlier press once more per flush")
	end)

	helpers.it("records nothing while metrics are switched off", function()
		local writer = with_writer(function(keylogger)
			keylogger.set_enabled(false)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, 100)
			keylogger.flush()
			keylogger.set_enabled(true)
		end)
		helpers.assert_eq(#writer.kc_hold, 0,
			"a hold is a keystroke seen from the other side, and it passes the same "
				.. "filters")
	end)

	helpers.it("ignores a negative or absent duration", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, -5)
			keylogger.record_hold("code", 30, nil)
			keylogger.flush()
		end)
		helpers.assert_eq(#writer.kc_hold, 0,
			"a clock that went backwards across a suspend would otherwise put a "
				.. "negative number into an average nobody could then explain")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The threshold ========================================
-- =================================================================
-- =================================================================

helpers.describe("hold durations: tap or hold", function()

	helpers.it("takes the threshold from the configuration kanata runs", function()
		local Remap = helpers.load_module("platform.remap.manager")
		local threshold = Remap.tap_hold_threshold_ms()
		-- nil is a legitimate answer — it means the declared keys disagree — so
		-- both branches are stated rather than one being assumed.
		helpers.assert_true(threshold == nil or type(threshold) == "number",
			"the threshold is either one number the whole layout agrees on, or "
				.. "there is no single answer and the split must be declined")
		if type(threshold) == "number" then
			helpers.assert_true(threshold > 0,
				"a threshold of zero would call every press a hold")
		end
	end)

	helpers.it("splits on that threshold when there is one", function()
		local Remap = helpers.load_module("platform.remap.manager")
		local threshold = Remap.tap_hold_threshold_ms()
		if type(threshold) ~= "number" then
			-- Not a skip: the case above already asserted this is a legitimate
			-- state, and asserting the split here would be asserting against a
			-- configuration the product says has no answer.
			helpers.assert_true(threshold == nil, "nothing to split on")
			return
		end

		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_hold("code", 30, threshold + 50)
			keylogger.record_hold("code", 30, math.max(0, threshold - 50))
			keylogger.flush()
		end)

		local row = row_for(writer, 30)
		helpers.assert_eq(row.hold_count, 1,
			"reading the threshold from what kanata runs is what stops the "
				.. "dashboard calling something a tap that the keyboard treated as a "
				.. "hold")
		helpers.assert_eq(row.tap_count, 1)
	end)

end)

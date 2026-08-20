--- tests/unit/modules/keylogger/test_app_switch_aggregate.lua

--- ==============================================================================
--- MODULE: Where The User Went, And On Which Day
--- DESCRIPTION:
--- The per-day application-transition counts, and the calendar day every row of
--- this driver is filed under.
---
--- THE TWO DEFECTS THIS PINS:
--- The transitions were never counted. The raw switch events were persisted and
--- the aggregate the dashboard reads was not, so the panel showing which
--- application the user leaves to reach another had nothing behind it.
---
--- And the switch rows were dated in UTC while every other table in this driver
--- dates in local time. The convention throughout is that a TIMESTAMP is UTC —
--- it has to be comparable across machines — and a DAY is the user\'s day.
--- For anyone east of Greenwich, an evening application switch was therefore
--- filed under tomorrow while the keystrokes either side of it were filed under
--- today, and the two never lined up again.
---
--- WHY THE COUNTING HAPPENS BEFORE THE HANDOVER:
--- Persisting the raw events clears the buffer. Deriving the aggregate after
--- that call would count an empty list on every flush, and the failure would
--- look exactly like the defect above: an empty panel.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

--- Runs a flush over the shared writer double.
--- @param body function Receives the loaded keylogger.
--- @return table The double, with everything it was handed.
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
		keylogger.init({ sqlite_path = "/tmp/ergopti_switch_probe.sqlite" })
		keylogger.reset_session()
		body(keylogger)
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return writer
end




-- =================================================================
-- =================================================================
-- ======= 1/ The transitions are counted ==========================
-- =================================================================
-- =================================================================

helpers.describe("app switches: the aggregate behind the flow panel", function()

	helpers.it("writes one row per ordered pair", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("firefox", 1000)
			keylogger.on_app_focus("code", 5000)
			keylogger.on_app_focus("firefox", 9000)
			keylogger.on_app_focus("code", 12000)
			keylogger.flush()
		end)

		helpers.assert_true(#writer.switches_to > 0,
			"the raw events were persisted and this aggregate was not, so the panel "
				.. "asking which application the user leaves to reach another had "
				.. "nothing behind it")

		local counts = {}
		for _, entry in ipairs(writer.switches_to) do
			counts[entry.row.app_from .. ">" .. entry.row.app_to] = entry.row.count
		end
		helpers.assert_eq(counts["firefox>code"], 2,
			"two transitions in the same direction are one row with a count of two")
		helpers.assert_eq(counts["code>firefox"], 1,
			"and the reverse direction is a different row — the pair is the key, "
				.. "because a count keyed on the destination alone cannot say where "
				.. "the user came from")
	end)

	helpers.it("counts before the raw events are handed over", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("a", 1000)
			keylogger.on_app_focus("b", 2000)
			keylogger.flush()
		end)
		helpers.assert_true(#writer.switches_to > 0,
			"persisting the raw events clears the buffer, so deriving the aggregate "
				.. "afterwards counts an empty list every time — and an empty panel "
				.. "looks the same as never having counted at all")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Which day they land on ===============================
-- =================================================================
-- =================================================================

helpers.describe("app switches: the calendar day", function()

	helpers.it("files a switch under the same day as the keystrokes around it", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("firefox", 1000)
			keylogger.on_keydown("a", 1100, "firefox")
			keylogger.on_app_focus("code", 2000)
			keylogger.flush()
		end)

		local today = os.date("%Y-%m-%d")
		helpers.assert_true(#writer.switches_to > 0, "there must be a row to check")
		for _, entry in ipairs(writer.switches_to) do
			helpers.assert_eq(entry.row.date, today,
				"every other table in this driver dates in local time. A UTC day here "
					.. "means that for anyone east of Greenwich an evening switch is "
					.. "filed under tomorrow while the keystrokes either side of it are "
					.. "filed under today, and the two never line up again.")
		end
	end)

end)

--- tests/unit/modules/keylogger/test_window_titles.lua

--- ==============================================================================
--- MODULE: Which Window The Work Happened In
--- DESCRIPTION:
--- The per-application-day window-title counters, and the filters that decide
--- whether a title is recorded at all.
---
--- WHAT WAS MISSING:
--- The focus-change callback received the window title and discarded it. The
--- apps dashboard groups a day by window — the difference between "four hours in
--- the editor" and "four hours across three files" — and this driver had nothing
--- to group by, so agg_app_day_titles was one more table empty by construction.
---
--- WHY THE GATE MATTERS MORE HERE THAN FOR KEYSTROKES:
--- A title is often MORE revealing than the text typed under it: a browser tab
--- names the page. So it passes exactly the filters a keystroke does — a private
--- window, a secure field, a disabled application, metrics switched off — and a
--- weaker gate would leak past every filter the user set on the text itself.
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
		keylogger.init({ sqlite_path = "/tmp/ergopti_titles_probe.sqlite" })
		keylogger.reset_session()
		body(keylogger)
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return writer
end

--- Every title row the writer was handed.
--- @param writer table
--- @return table title → { c, ms }
local function written_titles(writer)
	local out = {}
	for _, entry in ipairs(writer.titles) do
		local row = entry.row
		local prior = out[row.title] or { c = 0, ms = 0 }
		out[row.title] = { c = prior.c + (row.c or 0), ms = prior.ms + (row.ms or 0) }
	end
	return out
end




-- =================================================================
-- =================================================================
-- ======= 1/ The counters =========================================
-- =================================================================
-- =================================================================

helpers.describe("window titles: what is counted", function()

	helpers.it("counts a keystroke against the window it was typed into", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "main.lua — projet", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.on_keydown("b", 1200, "code")
			keylogger.flush()
		end)

		local titles = written_titles(writer)
		helpers.assert_not_nil(titles["main.lua — projet"],
			"this table was empty by construction: the title arrived at the daemon "
				.. "and was discarded, so the apps panel had nothing to group by")
		helpers.assert_eq(titles["main.lua — projet"].c, 2)
	end)

	helpers.it("keeps two windows of one application apart", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "premier.lua", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.set_window_title("code", "second.lua", 1200)
			keylogger.on_keydown("b", 1300, "code")
			keylogger.on_keydown("c", 1400, "code")
			keylogger.flush()
		end)

		local titles = written_titles(writer)
		helpers.assert_eq(titles["premier.lua"].c, 1)
		helpers.assert_eq(titles["second.lua"].c, 2,
			"grouping by application alone is the number that already existed; the "
				.. "whole point of this table is the finer one")
	end)

	helpers.it("credits the time spent under a title when it changes", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "premier.lua", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.set_window_title("code", "second.lua", 6000)
			keylogger.flush()
		end)

		local titles = written_titles(writer)
		helpers.assert_true(titles["premier.lua"].ms >= 5000,
			"the interval is closed when the NEXT title arrives, because the time "
				.. "already spent under it was earned before the switch")
	end)

	helpers.it("writes only the increment on a second flush", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "main.lua", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.flush()
			keylogger.on_keydown("b", 1200, "code")
			keylogger.flush()
		end)

		helpers.assert_eq(written_titles(writer)["main.lua"].c, 2,
			"the rows add on conflict, so flushing the cumulative total again would "
				.. "count every earlier keystroke once more per flush — and the daemon "
				.. "flushes every few seconds")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ And when it must not be recorded =====================
-- =================================================================
-- =================================================================

helpers.describe("window titles: the gate", function()

	helpers.it("records nothing while metrics are switched off", function()
		local writer = with_writer(function(keylogger)
			keylogger.set_enabled(false)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "quelque chose de privé", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.flush()
			keylogger.set_enabled(true)
		end)

		helpers.assert_eq(#writer.titles, 0,
			"a title is often more revealing than the text typed under it — a "
				.. "browser tab names the page — so it must pass exactly the filters a "
				.. "keystroke passes, not a weaker one")
	end)

	helpers.it("ignores an empty title rather than storing a blank row", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.set_window_title("code", "", 1000)
			keylogger.on_keydown("a", 1100, "code")
			keylogger.flush()
		end)
		helpers.assert_eq(#writer.titles, 0,
			"a window with no title is a window the panel cannot name, and a blank "
				.. "row would collect every such window under one heading")
	end)

end)

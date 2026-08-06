--- tests/unit/modules/keylogger/test_suggestion_counters.lua

--- ==============================================================================
--- MODULE: The Denominator Of The Acceptance Rate
--- DESCRIPTION:
--- That suggestions OFFERED are counted and persisted, alongside the triggers
--- that count the ones TAKEN.
---
--- THE DEFECT THIS PINS:
--- Only the accepted half was ever recorded. The acceptance rate is the ratio of
--- the two, so the dashboard divided by nothing and reported 0% on a driver
--- whose suggestions were being accepted all day — indistinguishable from a
--- feature nobody uses, which is exactly the conclusion the number invites.
---
--- Two things had to change, and either alone would have left it at zero: the
--- counters had to be incremented, and the writer had to accept them. The
--- writer\'s allow-list silently drops a field it does not name, so the count
--- could have been perfect in memory and still never reached the database — the
--- same shape the three LLM counters had before them.
---
--- WHAT IS DELIBERATELY NOT STORED:
--- What was offered. A suggestion the user did NOT take is the strongest signal
--- in the database about what they were about to type, and it has none of the
--- justification the accepted ones have.
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
		keylogger.init({ sqlite_path = "/tmp/ergopti_suggested_probe.sqlite" })
		keylogger.reset_session()
		body(keylogger)
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return writer
end

--- The total written for one app-day field across every upsert.
--- @param writer table
--- @param field string
--- @return number
local function total_written(writer, field)
	local sum = 0
    for _, entry in ipairs(writer.app_days) do
		sum = sum + (tonumber(entry.fields[field]) or 0)
	end
	return sum
end




-- =================================================================
-- =================================================================
-- ======= 1/ Offered is counted ===================================
-- =================================================================
-- =================================================================

helpers.describe("suggestion counters: what reaches the database", function()

	helpers.it("persists the hotstring suggestions that were offered", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("firefox", 1000)
			keylogger.record_suggestion("firefox", "hotstring", 1100)
			keylogger.record_suggestion("firefox", "hotstring", 1200)
			keylogger.flush()
		end)

		helpers.assert_true(#writer.app_days > 0, "an app-day row must be written at all")
		helpers.assert_eq(total_written(writer, "hs_suggested"), 2,
			"the acceptance rate is taken against this. Never writing it made the "
				.. "dashboard report 0% on a driver whose suggestions were being "
				.. "accepted all day.")
	end)

	helpers.it("keeps the LLM suggestions on their own counter", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("code", 1000)
			keylogger.record_suggestion("code", "llm", 1100)
			keylogger.flush()
		end)
		helpers.assert_eq(total_written(writer, "llm_suggested"), 1)
		helpers.assert_eq(total_written(writer, "hs_suggested"), 0,
			"the two features are measured separately; folding one into the other "
				.. "would make a good hotstring corpus look like a good model")
	end)

	helpers.it("writes only the increment on a second flush", function()
		local writer = with_writer(function(keylogger)
			keylogger.on_app_focus("firefox", 1000)
			keylogger.record_suggestion("firefox", "hotstring", 1100)
			keylogger.flush()
			keylogger.record_suggestion("firefox", "hotstring", 1200)
			keylogger.flush()
		end)
		helpers.assert_eq(total_written(writer, "hs_suggested"), 2,
			"the app-day rows add on conflict, so flushing the cumulative total "
				.. "again would count every earlier suggestion once more per flush — "
				.. "and the daemon flushes every few seconds")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ And the writer accepts it ============================
-- =================================================================
-- =================================================================

helpers.describe("suggestion counters: the writer's allow-list", function()

	helpers.it("names both fields", function()
		local handle = assert(io.open(
			helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua", "r"))
		local source = handle:read("*a")
		handle:close()
		-- The allow-list silently drops a field it does not name, so the count
		-- could be perfect in memory and never reach the database. That is exactly
		-- how the three LLM counters spent their existence.
		helpers.assert_true(source:find("hs_suggested", 1, true) ~= nil,
			"a field the writer does not name is dropped without a word")
		helpers.assert_true(source:find("llm_suggested", 1, true) ~= nil)
	end)

end)

--- tests/unit/hotstrings/engine/dynamic/rules_engine/test_date_snapshot.lua

local helpers = require("tests.helpers")
local Engine = require("hotstrings.engine.dynamic.core")

-- The first clock read occurs immediately before midnight; later reads see
-- New Year's Day. This drives the same date formatter used by the rule/UI.
local function across_midnight(callback)
	local old_date, reads = os.date, 0
	local logger = require("core.logger.engine.shim")
	local old_debug = logger.debug
	-- The clock double belongs to the date resolver, not the shared logger.
	logger.debug = function() end
	local before = { year = 2025, month = 12, day = 31, wday = 4, hour = 23, min = 59, sec = 59 }
	local after = { year = 2026, month = 1, day = 1, wday = 5, hour = 0, min = 0, sec = 0 }
	os.date = function(format)
		reads = reads + 1
		local day = reads == 1 and before or after
		if format == "*t" then return day end
		if format == "%w" then return tostring(day.wday - 1) end
		if format == "%d" then return string.format("%02d", day.day) end
		if format == "%m" then return string.format("%02d", day.month) end
		if format == "%Y" then return tostring(day.year) end
		if format == "%Y_%m_%d" then return string.format("%04d_%02d_%02d", day.year, day.month, day.day) end
		if format == "%d/%m/%Y" then return string.format("%02d/%02d/%04d", day.day, day.month, day.year) end
		error("unexpected date format")
	end
	local ok, result = xpcall(callback, debug.traceback)
	os.date = old_date
	logger.debug = old_debug
	if not ok then error(result, 0) end
end

helpers.describe("dynamic date snapshot", function()
	helpers.it("expands a coherent long date at midnight", function()
		Engine.reset_rules()
		Engine.register_date_rules("★")
		across_midnight(function()
			local match = Engine.match_buffer("date", "dynamic", nil, true)
			helpers.assert_eq(match.result, "mercredi 31 décembre 2025")
		end)
	end)
	helpers.it("builds all date previews from the same instant", function()
		across_midnight(function()
			local dates = Engine.today_date_strings()
			helpers.assert_eq(dates.iso, "2025_12_31")
			helpers.assert_eq(dates.fr, "31/12/2025")
			helpers.assert_eq(dates.long_fr, "mercredi 31 décembre 2025")
		end)
	end)
end)

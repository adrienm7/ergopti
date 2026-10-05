--- tests/unit/modules/keylogger/test_reader_kc_hold_contract.lua

--- ==============================================================================
--- MODULE: Reader Modifier-Hold Manifest Contract (Linux)
--- DESCRIPTION:
--- Declared SQLite response adapters exercise the real Reader projection. The
--- dashboard's shared contract requires s/n/m/tap/hold, while SQL column names
--- must remain private to persistence. Native SQLite admission is separate.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local ReaderName = "modules.keylogger.sqlite_reader"

--- Returns one real Reader record using a declared CLI response adapter.
--- @param fields table Native row fields before projection.
--- @return table Projected modifier-hold record.
local function projected(fields)
	local previous_reader, previous_popen = package.loaded[ReaderName], io.popen
	local row = { date = "2026-10-03", app = "editor", keycode = 29 }
	for key, value in pairs(fields) do row[key] = value end
	local dispatched = 0
	io.popen = function(command)
		local body = "[]"
		if command:find("FROM agg_app_day_kc_hold", 1, true) then
			dispatched = dispatched + 1
			body = Json.encode({ row })
		end
		return {
			read = function() return body .. "\nERGOPTI_SQL_EXIT_STATUS=0\n" end,
			close = function() return true end,
		}
	end
	package.loaded[ReaderName] = nil
	local ok, result = xpcall(function()
		local Reader = require(ReaderName)
		return Reader.read_manifest("/owned/metrics.sqlite", "2026-10-03", "2026-10-03", { "editor" })
	end, debug.traceback)
	package.loaded[ReaderName], io.popen = previous_reader, previous_popen
	if not ok then error(result, 0) end
	helpers.assert_eq(dispatched, 1, "the native-column row must cross the actual Reader projection")
	return result["2026-10-03"].editor.kc_hold["29"]
end

--- Checks exact canonical names and numeric values without legacy aliases.
--- @param record table Reader record.
--- @param expected table Independent expected canonical values.
local function assert_record(record, expected)
	helpers.assert_true(helpers.deep_equal(record, expected), "record must match the existing shared vocabulary exactly")
	for field, value in pairs(record) do
		helpers.assert_type(value, "number", "canonical value must remain numeric: " .. field)
	end
end

helpers.describe("linux-sqlite-kc-hold-contract", function()
	local source = { sum_ms = 1500, count = 5, max_ms = 600, tap_count = 3, hold_count = 2 }
	for _, item in ipairs({ { "s", 1500 }, { "n", 5 }, { "m", 600 }, { "tap", 3 }, { "hold", 2 } }) do
		helpers.it("linux-sqlite-kc-hold-contract: projects native " .. item[1] .. " with the exact canonical value", function()
			local record = projected(source)
			helpers.assert_eq(record[item[1]], item[2])
			helpers.assert_type(record[item[1]], "number")
		end)
	end

	helpers.it("linux-sqlite-kc-hold-contract: excludes every SQL-only alias", function()
		assert_record(projected(source), { s = 1500, n = 5, m = 600, tap = 3, hold = 2 })
	end)

	helpers.it("linux-sqlite-kc-hold-contract: preserves legitimate zero values", function()
		assert_record(projected({ sum_ms = 0, count = 0, max_ms = 0, tap_count = 0, hold_count = 0 }),
			{ s = 0, n = 0, m = 0, tap = 0, hold = 0 })
	end)

	helpers.it("linux-sqlite-kc-hold-contract: retains existing numeric zero defaults", function()
		assert_record(projected({}), { s = 0, n = 0, m = 0, tap = 0, hold = 0 })
	end)
end)

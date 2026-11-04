--- tests/unit/modules/keystats/storage/test_reader_manifest_catalogue.lua

--- ==============================================================================
--- MODULE: macOS manifest SQL comes from the shared query catalogue
--- DESCRIPTION:
--- The manifest projection runs the named queries of
--- `_shared/data/db/queries.sql` in the in-process dialect, the statements the
--- Windows and Linux readers run too. The reader must issue exactly those
--- renderings, each once, so a statement retyped here cannot drift again
--- (keystats SQL census, PAR-67). Their results are proven against a SQLite
--- fixture by tools/test/test-keystats-query-catalogue.cjs.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads a manifest with a database that records every statement it is asked.
--- @param start_date string|nil
--- @param end_date string|nil
--- @return table statements
local function manifest_statements(start_date, end_date)
	package.loaded["infra.logger"] = {
		debug = function() end, trace = function() end, done = function() end,
		info = function() end, start = function() end, success = function() end,
		warn = function() end, error = function() end,
	}
	local statements = {}
	local sqlite = { OK = 0, open = function()
		return { exec = function() return 0 end, close = function() end,
			nrows = function(_, sql)
				statements[#statements + 1] = sql
				return function() return nil end
			end }
	end }
	local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite })
	local _, complete = reader.read_manifest("/declared/db.sqlite", start_date, end_date)
	helpers.assert_true(complete, "every manifest statement must be accepted")
	return statements
end

helpers.describe("macOS manifest: SQL from the shared catalogue", function()
	local Queries = require("keystats.queries")
	for _, case in ipairs({
		{ label = "unfiltered", where = "" },
		{ label = "date-filtered", first = "2026-10-01", last = "2026-10-02",
			where = " WHERE date >= '2026-10-01' AND date <= '2026-10-02'" },
	}) do
		helpers.it("the " .. case.label .. " manifest issues the catalogue renderings", function()
			local statements = manifest_statements(case.first, case.last)
			local expected = {}
			for _, name in ipairs(Queries.names()) do
				if name:match("^manifest%.") then
					expected[#expected + 1] = Queries.render(name, "native", { where = case.where })
				end
			end
			table.sort(expected)
			table.sort(statements)
			helpers.assert_eq(statements, expected)
		end)
	end
end)

--- _shared/lua/test/keystats_queries_contract.lua

--- Exercises the generated named-query renderer (`keystats.queries`) that the
--- macOS and Linux keystats readers render their SQL through: every query
--- renders in both dialects, the two dialects differ only in how a TEXT column
--- is projected, and a misuse fails instead of producing other SQL. The query
--- RESULTS are proven against a SQLite fixture by the JS catalogue test.
--- Registered by the macOS and Linux suites.
local M = {}

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
function M.register(helpers)
	local Queries = require("keystats.queries")
	local WHERE = " WHERE date >= '2026-10-01'"

	helpers.describe("keystats named queries (shared contract)", function()
		helpers.it("renders every query in both dialects with the caller's filter spliced once", function()
			local names = Queries.names()
			helpers.assert_true(#names > 0, "the catalogue must declare queries")
			for _, name in ipairs(names) do
				for _, dialect in ipairs(Queries.DIALECTS) do
					local sql = Queries.render(name, dialect, { where = WHERE })
					helpers.assert_true(sql:sub(1, 7) == "SELECT ", name .. " renders a SELECT")
					helpers.assert_true(sql:sub(-1) == ";", name .. " renders one terminated statement")
					local count, at = 0, 1
					while true do
						local found = sql:find(WHERE, at, true)
						if not found then break end
						count, at = count + 1, found + #WHERE
					end
					helpers.assert_eq(count, 1, name .. " splices the filter exactly once")
					helpers.assert_true(not sql:find("{{", 1, true), name .. " leaves no placeholder")
				end
			end
		end)

		helpers.it("projects TEXT columns raw in-process and through json_quote for the CLI", function()
			for _, name in ipairs(Queries.names()) do
				local native = Queries.render(name, "native", { where = "" })
				local cli = Queries.render(name, "cli_json", { where = "" })
				for _, column in ipairs(Queries.text_columns(name)) do
					helpers.assert_true(cli:find(" AS " .. column .. "_json", 1, true) ~= nil,
						name .. " CLI dialect names " .. column .. "_json")
					helpers.assert_true(not native:find(column .. "_json", 1, true),
						name .. " in-process dialect keeps " .. column)
				end
				if #Queries.text_columns(name) == 0 then
					helpers.assert_eq(cli, native, name .. " has no text column, so one spelling")
				end
			end
		end)

		helpers.it("refuses an unknown name, an unknown dialect and a wrong parameter set", function()
			local function refused(...)
				return not pcall(Queries.render, ...)
			end
			helpers.assert_true(refused("manifest.unknown", "native", { where = "" }), "unknown name")
			helpers.assert_true(refused("manifest.app_day", "templates", { where = "" }), "unknown dialect")
			helpers.assert_true(refused("manifest.app_day", "native", {}), "missing parameter")
			helpers.assert_true(refused("manifest.app_day", "native", { where = 1 }), "non-string parameter")
			helpers.assert_true(refused("manifest.app_day", "native", { where = "", extra = "" }), "undeclared parameter")
		end)

		helpers.it("splices a filter holding pattern characters verbatim", function()
			local tricky = " WHERE app = '%1 {{where}} %%'"
			local sql = Queries.render("manifest.titles", "native", { where = tricky })
			helpers.assert_true(sql:find(tricky, 1, true) ~= nil, "the filter reaches the SQL unchanged")
		end)
	end)
end

return M

--- tests/unit/modules/keylogger/test_reader_manifest_suggestions.lua

--- ============================================================================
--- MODULE: Regression — suggestion counters reach the typing dashboard
--- DESCRIPTION:
--- `agg_app_day` persisted hs_suggested and llm_suggested, but sqlite_reader
--- omitted both columns. The UI therefore rendered every acceptance denominator
--- as zero even when suggestion events were correctly logged.
--- ============================================================================

local helpers = require("tests.helpers")

local function rows(items)
	local index = 0
	return function()
		index = index + 1
		return items[index]
	end
end

helpers.describe("sqlite_reader: manifest suggestion counters", function()
	helpers.it("projects hotstring and LLM suggestion counts from agg_app_day", function()
		package.loaded["infra.logger"] = {
			debug = function() end, trace = function() end, done = function() end,
			info = function() end, start = function() end, success = function() end,
			warn = function() end, error = function() end,
		}
		local reader = helpers.load_with_stubs("modules.keylogger.sqlite_reader", {
			sqlite3 = {
				OK = 0,
				open = function()
					return {
						exec = function() return 0 end,
						close = function() end,
						nrows = function(_self, sql)
							if sql:find("FROM agg_app_day ", 1, true) then
								return rows({ {
									date = "2026-07-18", app = "Editor",
									hs_suggested = 4, llm_suggested = 7,
								} })
							end
							return rows({})
						end,
					}
				end,
			},
		})
		local manifest = reader.read_manifest("/fake/db.sqlite")
		local app = manifest["2026-07-18"]["Editor"]
		helpers.assert_eq(app.hs_suggested, 4)
		helpers.assert_eq(app.llm_suggested, 7)
	end)
end)

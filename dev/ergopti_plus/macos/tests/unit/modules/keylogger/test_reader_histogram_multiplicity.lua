--- tests/unit/modules/keylogger/test_reader_histogram_multiplicity.lua
--- Grouped-row merge contract; the companion native SQLite test proves grouping.

local helpers = require("tests.helpers")

local function with_reader(body)
	helpers.with_stub_scope({ "modules.keylogger.sqlite_reader", "infra.logger" }, function()
		package.loaded["infra.logger"] = {
			error = function(_, message) error(message) end,
		}
		local reader = helpers.load_with_stubs("modules.keylogger.sqlite_reader", {
			sqlite3 = {
				open = function()
					return {
						exec = function() return 0 end,
						close = function() end,
						nrows = function(_, sql)
							local emitted = false
							return function()
								if emitted then return nil end
								emitted = true
								if sql:find("FROM agg_app_day_burst", 1, true)
									or sql:find("FROM agg_app_day_hourly", 1, true)
									or sql:find("FROM ngram_chars", 1, true) then
									return {
										date = "2020-01-01", app = "Editor", hour = "12", slot = "12:05",
										token = "a", c = 28, count_total = 28, source_rows = 2,
										length_buckets_json = '{"20":3}', e_buckets_json = '{"20":3}',
										esrc_json = '{"hotstring":3,"llm":4,"other":5,"none":99}',
									}
								end
							end
						end,
					}
				end,
			},
		})
		body(reader)
	end)
end

helpers.describe("reader histogram multiplicity (histogram-source-rows)", function()
	for _, field in ipairs({ "burst", "hourly", "min5" }) do
		helpers.it("counts identical " .. field .. " blobs once per source row", function()
			with_reader(function(reader)
				local entry = reader.read_manifest("/fake/db.sqlite")["2020-01-01"].Editor
				local buckets = entry.burst_length_buckets
				if field == "hourly" then buckets = entry.hourly["12"].e_buckets end
				if field == "min5" then buckets = entry.hourly_min5["12:05"].e_buckets end
				helpers.assert_eq(entry.burst_count_total, 28)
				helpers.assert_eq(buckets["20"], 6)
			end)
		end)
	end
	for _, part in ipairs({ "historical", "today" }) do
		helpers.it("counts identical " .. part .. " source distributions once per source row", function()
			with_reader(function(reader)
				local split = reader.read_range_split_today("/fake/db.sqlite")
				local item = part == "today" and split.today.Editor.c.a or split.historical.c.a
				helpers.assert_eq(item.c, 28)
				helpers.assert_eq(item.hs, 6)
				helpers.assert_eq(item.llm, 8)
				helpers.assert_eq(item.o, 10)
			end)
		end)
	end
end)

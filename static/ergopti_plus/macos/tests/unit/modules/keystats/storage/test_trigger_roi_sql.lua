--- tests/unit/modules/keystats/storage/test_trigger_roi_sql.lua

--- ==============================================================================
--- MODULE: Trigger ROI SQL Admission
--- DESCRIPTION:
--- Exercises the real event dispatcher and JSON failure boundary. The common
--- catalogue corpus separately executes these statements on real SQLite.
--- ==============================================================================

local helpers = require("tests.helpers")
local Queries = require("keystats.queries")
local Json = require("json")

helpers.describe("trigger ROI SQLite events", function()
	helpers.it("routes each ROI event with the exact Windows metadata fields", function()
		helpers.with_stub_scope({ "modules.keystats.sqlite_writer", "infra.logger", "hs.json" }, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
			local json = require("hs.json")
			local original_encode = json.encode
			local okay, failure = xpcall(function()
				json.encode = Json.encode
				local events = {
					{ type = "roi_snapshot", session_saved = 20, session_fired = 10 },
					{ type = "new_trigger_candidate", word = "d'apostrophe\r\n\0é", occurrences = 5 },
					{ type = "trigger_halflife", trigger = "public", days_since_use = 30.2 },
				}
				for index, event in ipairs(events) do
					event.app, event.timestamp = "Editor's app", "2026-11-07 10:00:00.000"
					local meta = {}
					for key, value in pairs(event) do
						if key ~= "type" and key ~= "timestamp" and key ~= "app" then meta[key] = value end
					end
					local encoded = Json.encode(meta)
					helpers.assert_eq(Json.decode(encoded), meta)
					-- Stored in UTC with the offset in force then (KMD-1).
					local utc, offset = require("keystats.local_time").from_local(event.timestamp)
					local expected = Queries.render("events.roi", "native", {
						device_id = "nil", id = index, ts = utc, date = "2026-11-07",
						kind = event.type, app = event.app, meta_json = encoded, utc_offset_min = offset,
					})
					helpers.assert_eq(writer.build_inserts(event), { expected })
				end
				json.encode = function() return nil end
				helpers.assert_eq(pcall(writer.build_inserts, events[1]), false,
					"a failed JSON encoding must not acknowledge or omit the ROI payload")
			end, debug.traceback)
			json.encode = original_encode
			if not okay then error(failure, 0) end
		end)
	end)
end)

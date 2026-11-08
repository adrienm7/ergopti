--- tests/unit/modules/keystats/storage/test_sqlite_writer_json_encode_failure.lua

--- ==============================================================================
--- MODULE: sqlite_writer json.encode failure surfacing
--- DESCRIPTION:
--- Regression guard for the JSON metadata column of the keystats SQLite writer.
---
--- A failed metadata encoding must refuse the raw event so ingestion keeps
--- the journal cursor and retries, rather than persisting an empty object.
--- ==============================================================================

local helpers = require("tests.helpers")

-- lib.logger must load first so every subsequent require can resolve it.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local DEVICE_ID = "deadbeef-cafe-1234-5678-aabbccddeeff"

helpers.describe("sqlite_writer — system metadata encoding failure", function()
	helpers.it("refuses the system event when json.encode raises on metadata", function()
		local sw = helpers.load_with_stubs("modules.keystats.sqlite_writer")
		sw.init({
			paths      = { sqlite_path = "/tmp/test_sw_json.sqlite" },
			device_obj = {
				device_id      = DEVICE_ID,
				name           = "TestMac",
				os             = "macOS",
				os_version     = "14.0",
				host_signature = "sig",
				created_at     = "2024-01-01 00:00:00",
			},
			device_id  = DEVICE_ID,
		})

		-- Force hs.json.encode to raise for the sentinel metadata. require returns
		-- the exact table the writer captured, so mutating encode reaches _sql_json.
		local hsjson      = require("hs.json")
		local orig_encode = hsjson.encode
		hsjson.encode = function(v)
			if type(v) == "table" and v.sentinel == "BOOM" then
				error("simulated json.encode failure")
			end
			return orig_encode(v)
		end


		local ok, failure = pcall(sw.build_inserts, {
			type      = "system_event",
			timestamp = "2024-01-01 12:00:00.000",
			action    = "wake",
			sentinel  = "BOOM",
		})

		-- Restore before asserting so nothing leaks into later test files.
		hsjson.encode = orig_encode
		helpers.assert_eq(ok, false, "a failed encoding must not produce a raw event")
		helpers.assert_eq(failure, "system event JSON encoding failed")
	end)
end)

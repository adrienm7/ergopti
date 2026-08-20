--- tests/unit/modules/keylogger/test_sqlite_writer_json_encode_failure.lua

--- ==============================================================================
--- MODULE: sqlite_writer json.encode failure surfacing
--- DESCRIPTION:
--- Regression guard for the JSON metadata column of the keylogger SQLite writer.
---
--- ROOT CAUSE ENCODED:
--- _sql_json() encodes event metadata into the metadata_json / events_json
--- columns. A json.encode failure used to be swallowed and stored as '{}' with
--- NO log, silently corrupting the stored metadata/predictions and leaving no
--- trace to diagnose. The writer must instead log a Logger.warn while still
--- falling back to a valid '{}' literal so the INSERT stays syntactically valid.
---
--- The test forces hs.json.encode to raise for a sentinel metadata value and
--- asserts (a) build_inserts does not propagate the failure, (b) the SQL still
--- carries a '{}' literal, and (c) a warn was emitted.
--- ==============================================================================

local helpers = require("tests.helpers")

-- lib.logger must load first so every subsequent require can resolve it.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local DEVICE_ID = "deadbeef-cafe-1234-5678-aabbccddeeff"

helpers.describe("sqlite_writer — json.encode failure is surfaced, not swallowed", function()
	helpers.it("logs a warn and stores '{}' when json.encode raises on metadata", function()
		local sw = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
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

		-- Spy the warn channel on the logger the writer already holds.
		local logger    = require("infra.logger")
		local orig_warn = logger.warn
		local warns     = {}
		logger.warn = function(_tag, fmt, ...)
			warns[#warns + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
		end

		local ok, stmts = pcall(sw.build_inserts, {
			type      = "system_event",
			timestamp = "2024-01-01 12:00:00.000",
			action    = "wake",
			sentinel  = "BOOM",
		})

		-- Restore BEFORE asserting so nothing leaks into later test files.
		hsjson.encode = orig_encode
		logger.warn   = orig_warn

		helpers.assert_true(ok, "build_inserts must not propagate the json.encode failure")
		helpers.assert_eq(#stmts, 1)
		helpers.assert_true(stmts[1]:find("'{}'", 1, true) ~= nil,
			"the metadata column must fall back to a valid '{}' literal")
		local warned = false
		for _, m in ipairs(warns) do
			if m:find("json.encode failed", 1, true) then warned = true end
		end
		helpers.assert_true(warned,
			"a failed json.encode must be surfaced via Logger.warn, not swallowed")
	end)
end)

--- tests/unit/modules/keystats/storage/test_clipboard_events.lua

--- ==============================================================================
--- MODULE: Clipboard Copy/Paste Bursts In The macOS Metrics Database
--- DESCRIPTION:
--- Windows writes events_clipboard and macOS wrote none: build_inserts had no
--- builder for clipboard_copy, clipboard_paste or paste_burst and discarded
--- them. These tests replay the shared contract, drive the real build_inserts
--- and apply its statements to the shared schema through the sqlite3 CLI.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.clipboard_events_contract").register(helpers)

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

local TIMESTAMP = "2026-11-10 10:00:00.000"

local function writer()
	package.loaded["modules.keystats.sqlite_writer"] = nil
	local Writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
	Writer.init({
		paths = { db = "/tmp/ergopti_clipboard_test.db" },
		device_obj = { id = "test-device" },
		device_id = "00000000-0000-4000-8000-000000000001",
	})
	return Writer
end

helpers.describe("macOS clipboard rows reach events_clipboard", function()
	helpers.it("macos-clipboard-build-inserts: each kind is one events_clipboard INSERT with its metadata", function()
		local Writer = writer()
		for _, entry in ipairs({
			{ type = "clipboard_copy", timestamp = TIMESTAMP, app = "TextEdit", content_type = "unknown" },
			{ type = "clipboard_paste", timestamp = TIMESTAMP, app = "Notes", copy_lag_ms = 40, source_app = "TextEdit" },
			{ type = "paste_burst", timestamp = TIMESTAMP, app = "Notes", count = 5, window_ms = 10000 },
		}) do
			local statements = Writer.build_inserts(entry)
			helpers.assert_eq(#statements, 1, entry.type)
			helpers.assert_true(statements[1]:find("INSERT OR IGNORE INTO events_clipboard", 1, true) == 1, statements[1])
			helpers.assert_true(statements[1]:find("'" .. entry.type .. "'", 1, true) ~= nil, statements[1])
		end
	end)

	helpers.it("macos-clipboard-schema: the statements land in the shared schema", function()
		if not HAS_SQLITE then return end
		local Writer = writer()
		local inserts = {}
		for _, entry in ipairs({
			{ type = "clipboard_paste", timestamp = TIMESTAMP, app = "l'app", copy_lag_ms = 12, source_app = "kate" },
			{ type = "paste_burst", timestamp = TIMESTAMP, app = "kate", count = 5, window_ms = 10000 },
		}) do
			inserts[#inserts + 1] = Writer.build_inserts(entry)[1]
		end
		local schema = assert(io.open(require("infra.paths").shared("data/db/schema.sql"), "rb"))
		local db, script = os.tmpname(), os.tmpname()
		local handle = assert(io.open(script, "wb"))
		handle:write(".output /dev/null\n", schema:read("*a"), "\n.output stdout\n", table.concat(inserts, "\n"),
			"\nSELECT kind || '|' || app || '|' || coalesce(json_extract(meta_json, '$.copy_lag_ms'), '') || '|'"
			.. " || coalesce(json_extract(meta_json, '$.count'), '') FROM events_clipboard ORDER BY id;\n")
		schema:close()
		handle:close()
		local pipe = assert(io.popen("sqlite3 -bail -noheader '" .. db .. "' < '" .. script .. "' 2>&1"))
		local output = pipe:read("*a")
		pipe:close()
		os.remove(script)
		os.remove(db)
		helpers.assert_eq(output, "clipboard_paste|l'app|12|\npaste_burst|kate||5\n")
	end)
end)

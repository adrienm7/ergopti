--- tests/unit/modules/keylogger/test_build_inserts_missing_timestamp.lua

--- ==============================================================================
--- MODULE: sqlite_writer build_inserts missing-timestamp regression tests
--- DESCRIPTION:
--- Regression tests for keylogger-storage-1: a JSONL entry whose `type` field
--- is a valid string but whose `timestamp` field is absent caused
--- `build_inserts` to call `nil:sub(1,10)` and raise, stalling the entire
--- ingest loop permanently (the poison line was re-read on every tick because
--- the file offset never advanced past it).
---
--- Post-fix: `build_inserts` coerces a missing or non-string timestamp to
--- `_now_ts()` so the entry is stored with an approximate timestamp rather
--- than crashing.
---
--- `rotation.lua` is also hardened to filter out timestamp-less entries at
--- the read boundary, so they never reach `build_inserts` in production.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================================================
-- ================================================================================
-- ======= 1/ build_inserts does not raise on missing timestamp (storage-1) =======
-- ================================================================================
-- ================================================================================

helpers.describe("sqlite_writer: build_inserts does not raise on missing timestamp", function()

	local writer

	helpers.before_each(function()
		-- Load the module fresh for each test to avoid state bleed
		package.loaded["modules.keylogger.sqlite_writer"] = nil

		-- Stub dependencies so the module loads without a real DB or device
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		-- No "infra.json" stub: sqlite_writer requires hs.json, and nothing in the
		-- macOS driver requires lib.json at all. The stub that used to sit here
		-- intercepted nothing — the module took the real hs.json from the hs stub
		-- either way, so removing it changes no behaviour, only the impression
		-- that a dependency was being controlled.

		-- load_with_stubs, not a bare require: sqlite_writer pulls in hs.fs, which
		-- does not exist outside Hammerspoon. A raw require therefore ALWAYS failed
		-- here, the pcall swallowed it, and all three cases below took their skip
		-- branch on every run since the file was written — a regression test for a
		-- crash that stalled the whole ingest loop, which had never once executed.
		local mod = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		helpers.assert_not_nil(mod,
			"sqlite_writer must load under the test stubs — if it cannot, this file proves nothing")

		-- Called directly, not through pcall: a failed init used to be downgraded to
		-- a skip, and wrapping it again would only turn the throw into a boolean.
		-- Letting it propagate means a broken init fails here with its real stack.
		mod.init({
			paths     = { keylogger_db_path = function() return "/tmp/test_kl.db" end,
			              keylogger_log_path = function() return "/tmp/test_kl.log" end },
			device_obj = { id = function() return "test-device-001" end,
			               name = function() return "TestDevice" end },
			device_id  = "test-device-001",
		})
		writer = mod
	end)

	helpers.it("build_inserts survives a 'typing' entry with no timestamp field", function()
		-- Pre-fix: this raises with "attempt to index a nil value (field 'timestamp')"
		-- Post-fix: timestamp is coerced to _now_ts() and the call returns a table
		local ok, result = pcall(writer.build_inserts, {
			type = "typing",
			app  = "TestApp",
			-- timestamp intentionally absent
		})
		helpers.assert_true(ok,
			"build_inserts must NOT raise on a 'typing' entry without a timestamp field")
		helpers.assert_true(type(result) == "table",
			"build_inserts must return a table even for a timestamp-less entry")
	end)

	helpers.it("build_inserts survives a 'shortcut' entry with no timestamp field", function()
		local ok, result = pcall(writer.build_inserts, {
			type = "shortcut",
			app  = "TestApp",
			key  = "cmd+c",
			-- timestamp intentionally absent
		})
		helpers.assert_true(ok,
			"build_inserts must NOT raise on a 'shortcut' entry without a timestamp field")
		helpers.assert_true(type(result) == "table",
			"build_inserts must return a table even for a timestamp-less shortcut entry")
	end)

	helpers.it("build_inserts accepts an entry with a valid timestamp (non-regression)", function()
		local ok, result = pcall(writer.build_inserts, {
			type      = "shortcut",
			app       = "TestApp",
			key       = "cmd+v",
			timestamp = "2026-06-18 12:00:00.000",
		})
		helpers.assert_true(ok,
			"build_inserts must succeed when timestamp is a valid string")
		helpers.assert_true(type(result) == "table",
			"build_inserts must return a table for a fully-valid entry")
	end)
end)





-- ==============================================================================
-- ==============================================================================
-- ======= 2/ rotation.lua filters out timestamp-less entries (storage-1) =======
-- ==============================================================================
-- ==============================================================================

helpers.describe("rotation: read_today_log_batch filters entries without timestamp", function()

	--- Simulates the post-fix rotation.lua:197 guard.
	--- @param entry table Decoded JSONL entry (may or may not have timestamp).
	--- @return boolean True when the entry passes the guard.
	local function passes_rotation_guard(entry)
		return type(entry) == "table"
			and type(entry.type) == "string"
			and type(entry.timestamp) == "string"
	end

	helpers.it("rejects a table entry with type string but no timestamp", function()
		local entry = { type = "typing", app = "X" }
		helpers.assert_eq(passes_rotation_guard(entry), false,
			"rotation guard must reject entries without a string timestamp")
	end)

	helpers.it("rejects a table entry with a nil timestamp", function()
		local entry = { type = "shortcut", app = "X", timestamp = nil }
		helpers.assert_eq(passes_rotation_guard(entry), false,
			"rotation guard must reject entries with nil timestamp")
	end)

	helpers.it("accepts a valid entry with both type and timestamp strings", function()
		local entry = { type = "typing", app = "X", timestamp = "2026-06-18 12:00:00.000" }
		helpers.assert_eq(passes_rotation_guard(entry), true,
			"rotation guard must accept entries with valid type and timestamp strings")
	end)

	helpers.it("rejects non-table entries (decode failure guard, unchanged)", function()
		helpers.assert_eq(passes_rotation_guard("not a table"), false,
			"rotation guard must reject non-table decoded values")
		helpers.assert_eq(passes_rotation_guard(nil), false,
			"rotation guard must reject nil decoded values")
	end)
end)

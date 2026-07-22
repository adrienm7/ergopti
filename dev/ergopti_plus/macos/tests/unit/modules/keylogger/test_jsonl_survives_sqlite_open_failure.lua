--- tests/unit/modules/keylogger/test_jsonl_survives_sqlite_open_failure.lua

--- ==============================================================================
--- MODULE: Regression — JSONL logging survives a db.sqlite open failure (G1+G2)
--- DESCRIPTION:
--- log_manager.M.init() initialises Rotation only inside the branch guarded by
--- `SqliteWriter.open_db()`. The intended fallback for the failure path read
--- `if not Rotation.get_offset then Rotation.init(…) end` — a probe on the
--- EXISTENCE of an accessor function. get_offset is defined unconditionally at
--- require time, so the condition was a constant false and the branch was dead
--- code that never once executed.
---
--- Consequence: when db.sqlite cannot be opened (unwritable or full TMPDIR),
--- Rotation stayed uninitialised, its _require_init guard rejected EVERY
--- append_log, and not a single keystroke was recorded — flatly contradicting
--- the "log manager will only write JSONL" contract the very same function logs.
--- The one ERROR emitted per keystroke was collapsed by the logger's dedup, so
--- the user only saw empty metrics with nothing pointing at the real cause.
---
--- WHAT THIS PINS:
--- 1. Root cause: Rotation.is_initialized() is true after init even when SQLite
---    is down — i.e. the fallback branch genuinely RAN.
--- 2. Behaviour: an append_log() issued afterwards lands as exactly one JSONL
---    line on disk. Pre-fix today.log is empty.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================
-- ===================================
-- ======= 1/ Test Environment =======
-- ===================================
-- ===================================

--- Fixed device identity so the resolved by_device/ path is deterministic and
--- the test can read today.log back without reaching into log_manager privates.
local DEVICE_ID = "00000000-0000-4000-8000-000000000001"

--- Fixed host signature: _resolve_device() only reuses a device.json whose
--- host_signature matches what the (stubbed) ioreg call returns.
local HOST_SIGNATURE = "TEST-HOST-SQLITE-FAILURE"

local SCRATCH_DIR  = helpers.driver_root() .. "tests/scratch_test_dir/jsonl_sqlite_open_failure/"
local BY_DEVICE_DIR = SCRATCH_DIR .. "by_device/" .. DEVICE_ID .. "/"
local TODAY_LOG     = BY_DEVICE_DIR .. "today.log"

--- Creates a directory tree with the host shell (the production _mkdir_p goes
--- through hs.execute, which is stubbed in unit tests).
--- @param path string Absolute directory path.
local function mkdir_p(path)
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format("cmd /c mkdir \"%s\" 2>nul", (path:gsub("/", "\\"))))
	else
		os.execute(string.format("mkdir -p \"%s\"", path))
	end
end

--- Reads every non-empty line of a file.
--- @param path string Absolute file path.
--- @return table Array of lines (empty when the file is missing).
local function read_lines(path)
	local fh = io.open(path, "r")
	if not fh then return {} end
	local out = {}
	for line in fh:lines() do
		if line ~= "" then out[#out + 1] = line end
	end
	fh:close()
	return out
end





-- ========================================
-- ========================================
-- ======= 2/ Module Wiring (stubs) =======
-- ========================================
-- ========================================

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")
package.loaded["lib.timings"] = {
	ms  = function() return 1000 end,
	sec = function() return 1 end,
}

-- The whole point of the scenario: SQLite is unavailable. open_db reports the
-- failure and get_db yields nil, so log_manager takes the JSONL-only path.
package.loaded["modules.keylogger.sqlite_writer"] = {
	init = function() end,
	open_db = function() return false end,
	close_db = function() end,
	get_db = function() return nil end,
	build_inserts = function() return {} end,
	get_next_event_id = function() return 1 end,
	set_next_event_id = function() end,
	persist_next_event_id = function() end,
}
package.loaded["modules.keylogger.aggregator"] = {
	init = function() end, set_device_id = function() end, get_device_id = function() return nil end,
	reset_batch = function() end, reset_ngram_ctx = function() end, get_ngram_ctx = function() return {} end,
	set_ngram_ctx = function() end, walk_typing = function() end, walk_app_switch = function() end,
	walk_window_switch = function() end, walk_system_event = function() end, flush = function() end,
}
package.loaded["modules.keylogger.export"] = {
	init = function() end, sync_foreign_data_sql = function() end,
	get_native_app_category = function() return "other" end,
	get_device_short_id = function() return "test" end,
	get_sqlite_path = function() return nil end, get_db_rev = function() return 0 end,
}

-- Rotation is deliberately NOT stubbed — it is the module under test.
package.loaded["modules.keylogger.rotation"] = nil

-- Start from a clean today.log so the "exactly one line" assertion cannot be
-- satisfied (or defeated) by residue from an earlier run.
mkdir_p(BY_DEVICE_DIR)
os.remove(TODAY_LOG)

local device_fh = io.open(BY_DEVICE_DIR .. "device.json", "w")
if device_fh then
	device_fh:write(string.format(
		"{\"device_id\":\"%s\",\"name\":\"Test\",\"os\":\"darwin\",\"os_version\":\"14\","
		.. "\"host_signature\":\"%s\",\"created_at\":\"2026-07-20 00:00:00.000\",\"schema_version\":1}",
		DEVICE_ID, HOST_SIGNATURE))
	device_fh:close()
end

local LM = helpers.load_with_stubs("modules.keylogger.log_manager", {
	execute = function(cmd)
		-- _host_signature() shells out to ioreg; pin it so device.json is reused.
		if cmd:find("ioreg", 1, true) then return HOST_SIGNATURE end
		local dir = cmd:match("mkdir %-p \"(.-)\"")
		if dir then mkdir_p(dir) end
		return ""
	end,
	fs = {
		-- nil attributes = "db.sqlite and data.sql do not exist yet".
		attributes = function() return nil end,
		dir = function()
			local entries = { ".", "..", DEVICE_ID }
			local i = 0
			return function()
				i = i + 1
				return entries[i]
			end
		end,
	},
})
local Rotation = require("modules.keylogger.rotation")





-- ==================================================
-- ==================================================
-- ======= 3/ Regression: JSONL Still Records =======
-- ==================================================
-- ==================================================

helpers.describe("keylogger/log_manager: a db.sqlite open failure must not silence JSONL logging", function()

	helpers.it("initialises rotation through the fallback branch when SQLite is unavailable", function()
		LM.init({
			LOG_DIR = SCRATCH_DIR,
			buffer_events = {}, buffer_text = "", rich_chunks = {},
			session_mouse_clicks = 0, session_mouse_scrolls = 0,
			mouse_distance_px = 0, last_flush_time = 0,
			last_time = 0, pending_keyup = {},
			today_idx = {}, manifest = {},
		})

		-- ROOT CAUSE pin: the old probe tested an accessor's existence, so this
		-- flag stayed false and every later append_log was rejected by the guard.
		helpers.assert_true(Rotation.is_initialized(),
			"rotation must be initialised on the SQLite-failure path (dead fallback branch regression)")
	end)

	helpers.it("writes the appended event to today.log as exactly one JSONL line", function()
		LM.append_log({ type = "typing", text = "x" })

		local lines = read_lines(TODAY_LOG)
		helpers.assert_eq(#lines, 1,
			"today.log must hold exactly one JSONL line — pre-fix the file stays empty because "
			.. "rotation was never initialised and _require_init rejected every append")

		local decoded = hs.json.decode(lines[1])
		helpers.assert_eq(type(decoded), "table", "the written line must be valid JSON")
		helpers.assert_eq(decoded.type, "typing")
		helpers.assert_eq(decoded.text, "x")
	end)
end)

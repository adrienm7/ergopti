--- tests/unit/modules/keylogger/test_rotation.lua

--- ==============================================================================
--- MODULE: keylogger.rotation Unit Tests
--- DESCRIPTION:
--- Verifies the offset/date state accessors, the init validation guard, and the
--- rollover logic of the rotation module. All filesystem and hs.* calls are
--- intercepted by the standard hs stub so no real files are created.
---
--- FEATURES & RATIONALE:
--- 1. Offset Accessors: get_offset / set_offset / get_date must form a coherent
---    round-trip and persist across repeated reads.
--- 2. Init Guard: walkers called before M.init() must be safe no-ops.
--- 3. Init Validation: nil / bad deps must be rejected without crashing.
--- 4. Rollover: M.rollover() must reset the offset to 0 and update the date.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local ROT = helpers.load_with_stubs("modules.keylogger.rotation")




-- =============================================
-- =============================================
-- ======= 2/ Module Surface Invariants ========
-- =============================================
-- =============================================

helpers.describe("rotation — public surface", function()
	helpers.it("exposes init, append_log, read_new_entries, rollover, get_offset, set_offset, get_date", function()
		helpers.assert_eq(type(ROT.init),             "function")
		helpers.assert_eq(type(ROT.append_log),       "function")
		helpers.assert_eq(type(ROT.read_new_entries), "function")
		helpers.assert_eq(type(ROT.rollover),         "function")
		helpers.assert_eq(type(ROT.get_offset),       "function")
		helpers.assert_eq(type(ROT.set_offset),       "function")
		helpers.assert_eq(type(ROT.get_date),         "function")
	end)
end)




-- =============================================
-- =============================================
-- ======= 3/ Pre-init State Defaults ==========
-- =============================================
-- =============================================

helpers.describe("rotation — pre-init defaults", function()
	helpers.it("get_offset returns 0 before init", function()
		helpers.assert_eq(ROT.get_offset(), 0)
	end)

	helpers.it("get_date returns nil before init", function()
		helpers.assert_nil(ROT.get_date())
	end)
end)





-- =============================================
-- =============================================
-- ======= 4/ Pre-init Guard Enforcement =======
-- =============================================
-- =============================================

helpers.describe("rotation — pre-init guard", function()
	helpers.it("append_log before init does not crash", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		-- Called directly. An append before init must write NOTHING: the offset is
		-- still zero, and a line written past it is a line the next flush replays.
		r.append_log({ type = "typing", text = "hello" })
		helpers.assert_eq(r.get_offset(), 0,
			"an append before init must not advance the offset")
	end)

	helpers.it("read_new_entries before init returns a failed status at offset 0", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		local entries, off, status = r.read_new_entries()
		helpers.assert_eq(type(entries), "table")
		helpers.assert_eq(#entries, 0)
		helpers.assert_eq(off, 0)
		helpers.assert_eq(status, r.READ_STATUS_FAILED)
	end)

	helpers.it("rollover before init does not crash", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.rollover("/tmp/data.sql")
		helpers.assert_eq(r.get_offset(), 0,
			"a rollover before init must leave the offset where it was")
	end)
end)




-- =============================================
-- =============================================
-- ======= 5/ Init Validation ==================
-- =============================================
-- =============================================

helpers.describe("rotation — init validation", function()
	helpers.it("rejects nil deps", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init(nil)
		-- offset must remain 0 — module did not initialize
		helpers.assert_eq(r.get_offset(), 0)
	end)

	helpers.it("rejects deps with missing paths table", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({ state = {} })
		helpers.assert_eq(r.get_offset(), 0)
	end)

	helpers.it("rejects deps with missing state table", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({ paths = { today_log_path = "/tmp/today.log" } })
		helpers.assert_eq(r.get_offset(), 0)
	end)

	helpers.it("accepts valid deps and restores provided offset", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({
			paths              = { today_log_path = "/tmp/today.log" },
			state              = {},
			today_log_offset   = 1024,
			today_log_date     = "2024-06-01",
		})
		helpers.assert_eq(r.get_offset(), 1024)
		helpers.assert_eq(r.get_date(), "2024-06-01")
	end)

	helpers.it("defaults offset to 0 when not provided in deps", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({
			paths  = { today_log_path = "/tmp/today.log" },
			state  = {},
		})
		helpers.assert_eq(r.get_offset(), 0)
	end)

	helpers.it("ignores a duplicate init call", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({
			paths  = { today_log_path = "/tmp/today.log" },
			state  = {},
			today_log_offset = 512,
		})
		-- Second call with a different offset must be silently ignored.
		r.init({
			paths  = { today_log_path = "/tmp/today.log" },
			state  = {},
			today_log_offset = 9999,
		})
		helpers.assert_eq(r.get_offset(), 512)
	end)

	-- Rotation owns file offsets and day boundaries, not the decision to record.
	-- Both claims below used to be assert_true(true) with the sentence attached;
	-- both are checkable against the module's own source.
	helpers.it("holds no pause state of its own (project_suspend_pause_invariant)", function()
		-- The gate is the keystroke path's early return. A second check here would
		-- mean two modules decide whether a keystroke is recorded, and the one
		-- that loses silently advances an offset past bytes nobody wrote.
		local src = helpers.read_driver_source("function M.set_offset")
		helpers.assert_true(src ~= nil, "modules/keylogger/rotation.lua source must be locatable")
		helpers.assert_true(src:find("paus") == nil,
			"rotation must not gate on pause — the ingest path early-returns before reaching it")
		helpers.assert_true(src:find("suspend") == nil, "same for suspend")
	end)

	helpers.it("the offset state it exposes carries no keystroke content", function()
		-- The privacy claim is narrow and precise: rotation's public state is an
		-- integer and a date. If a future change parked the pending buffer here
		-- so a rollover could re-emit it, this module would start holding raw
		-- keys — in a table that is written to disk on every rotation.
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({ paths = { today_log_path = "/tmp/today.log" }, state = {} })
		r.set_offset(4096, "2024-06-15")
		helpers.assert_eq(type(r.get_offset()), "number", "the offset must stay a byte count")
		helpers.assert_eq(type(r.get_date()), "string", "the date must stay a date")
		helpers.assert_eq(r.get_date(), "2024-06-15",
			"and it must be the date that was set, not a value derived from what was typed")
	end)
end)




-- =============================================
-- =============================================
-- ======= 6/ Offset Accessors =================
-- =============================================
-- =============================================

helpers.describe("rotation — set_offset / get_offset / get_date", function()
	local r

	helpers.it("setup: init with zero offset", function()
		r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({
			paths = { today_log_path = "/tmp/today.log" },
			state = {},
		})
		-- The setup case earns its place by asserting the starting point the cases
		-- below depend on: they all measure a CHANGE from zero, and read as passing
		-- if init silently left a stale offset behind.
		helpers.assert_eq(r.get_offset(), 0, "a fresh init must start at offset zero")
	end)

	helpers.it("set_offset updates both offset and date", function()
		r.set_offset(4096, "2024-06-15")
		helpers.assert_eq(r.get_offset(), 4096)
		helpers.assert_eq(r.get_date(), "2024-06-15")
	end)

	helpers.it("set_offset can advance the offset multiple times", function()
		r.set_offset(100, "2024-07-01")
		r.set_offset(200, "2024-07-01")
		r.set_offset(350, "2024-07-01")
		helpers.assert_eq(r.get_offset(), 350)
	end)

	helpers.it("get_offset always reflects the last set value", function()
		r.set_offset(0, "2024-07-02")
		helpers.assert_eq(r.get_offset(), 0)
	end)
end)




-- =============================================
-- =============================================
-- ======= 7/ Rollover Resets Offset ===========
-- =============================================
-- =============================================

helpers.describe("rotation — rollover", function()
	helpers.it("rollover resets offset to 0 and updates the date to today", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		r.init({
			paths = { today_log_path = "/tmp/today.log" },
			state = {},
			today_log_offset = 8192,
			today_log_date   = "2024-06-30",
		})
		helpers.assert_eq(r.get_offset(), 8192)

		-- rollover writes a comment line to data_sql_path; the hs stub intercepts io.
		-- We use a non-existent path — io.open in append mode will silently fail or
		-- succeed depending on the OS; either way, rollover must not throw.
		-- Called directly. A rollover RESETS the offset — that is what it is for, and
		-- an offset left where it was means the next read replays a whole day.
		r.rollover("/tmp/test_data.sql", r.READ_STATUS_EOF)
		helpers.assert_eq(r.get_offset(), 0, "a rollover must reset the offset to zero")

		-- Offset must be 0 after rollover regardless of io success.
		helpers.assert_eq(r.get_offset(), 0)
	end)
end)

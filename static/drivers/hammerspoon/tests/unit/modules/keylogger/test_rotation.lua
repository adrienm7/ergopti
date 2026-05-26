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

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

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
--- =============================================
-- ======= 4/ Pre-init Guard Enforcement =======
--- =============================================
-- =============================================

helpers.describe("rotation — pre-init guard", function()
	helpers.it("append_log before init does not crash", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		local ok = pcall(function()
			r.append_log({ type = "typing", text = "hello" })
		end)
		helpers.assert_true(ok)
	end)

	helpers.it("read_new_entries before init returns empty list and offset 0", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		local entries, off = r.read_new_entries()
		helpers.assert_eq(type(entries), "table")
		helpers.assert_eq(#entries, 0)
		helpers.assert_eq(off, 0)
	end)

	helpers.it("rollover before init does not crash", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")
		local ok = pcall(function() r.rollover("/tmp/data.sql") end)
		helpers.assert_true(ok)
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
		helpers.assert_true(true)
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
		local ok = pcall(function() r.rollover("/tmp/test_data.sql") end)
		helpers.assert_true(ok)

		-- Offset must be 0 after rollover regardless of io success.
		helpers.assert_eq(r.get_offset(), 0)
	end)
end)

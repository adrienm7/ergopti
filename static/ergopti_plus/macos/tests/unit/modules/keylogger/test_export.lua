--- tests/unit/modules/keylogger/test_export.lua

--- ==============================================================================
--- MODULE: keylogger.export Unit Tests
--- DESCRIPTION:
--- Verifies the pure accessor helpers of the export module: device short-id
--- formatting, sqlite path forwarding, and the init validation guard. The
--- get_native_app_category function depends on live macOS OS calls (hs.application)
--- and is therefore only covered for its guard behaviour on nil / empty input.
---
--- FEATURES & RATIONALE:
--- 1. Init Validation: nil / bad deps must be rejected without crashing.
--- 2. Device Short-id: The 8-char + "…" format must be exact.
--- 3. SQLite Path: get_sqlite_path() must forward paths.sqlite_path verbatim.
--- 4. Category Fallback: get_native_app_category on empty / nil input must
---    return a non-empty string (the i18n general-category fallback).
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

-- lib.logger must load first.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- lib.i18n is required at module load time by export.lua. We provide a minimal
-- stub that returns the key itself so tests are locale-independent.
package.loaded["lib.i18n"] = {
	get = function(key) return key end,
}

local EXP = helpers.load_with_stubs("modules.keylogger.export")




-- =============================================
-- =============================================
-- ======= 2/ Module Surface Invariants ========
-- =============================================
-- =============================================

helpers.describe("export — public surface", function()
	helpers.it("exposes init, get_native_app_category, get_device_short_id, get_sqlite_path, get_db_rev, sync_foreign_data_sql", function()
		helpers.assert_eq(type(EXP.init),                    "function")
		helpers.assert_eq(type(EXP.get_native_app_category), "function")
		helpers.assert_eq(type(EXP.get_device_short_id),     "function")
		helpers.assert_eq(type(EXP.get_sqlite_path),         "function")
		helpers.assert_eq(type(EXP.get_db_rev),              "function")
		helpers.assert_eq(type(EXP.sync_foreign_data_sql),   "function")
	end)
end)




-- =============================================
-- =============================================
-- ======= 3/ Pre-init Defaults ================
-- =============================================
-- =============================================

helpers.describe("export — pre-init defaults", function()
	helpers.it("get_device_short_id returns empty string before init", function()
		helpers.assert_eq(EXP.get_device_short_id(), "")
	end)

	helpers.it("get_sqlite_path returns nil before init", function()
		helpers.assert_nil(EXP.get_sqlite_path())
	end)

	helpers.it("get_db_rev returns 0 before init", function()
		helpers.assert_eq(EXP.get_db_rev(), 0)
	end)
end)




-- =============================================
-- =============================================
-- ======= 4/ Init Validation ==================
-- =============================================
-- =============================================

helpers.describe("export — init validation", function()
	helpers.it("rejects nil deps", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init(nil)
		helpers.assert_eq(e.get_device_short_id(), "")
	end)

	helpers.it("rejects deps without paths table", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({ device_id = "uuid-x", get_db = function() return nil end })
		helpers.assert_eq(e.get_device_short_id(), "")
	end)

	helpers.it("rejects deps without device_id string", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({ paths = {}, get_db = function() return nil end })
		helpers.assert_eq(e.get_device_short_id(), "")
	end)

	helpers.it("rejects deps without get_db function", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({ paths = {}, device_id = "uuid-y" })
		helpers.assert_eq(e.get_device_short_id(), "")
	end)

	helpers.it("accepts valid deps", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({
			paths     = { sqlite_path = "/tmp/db.sqlite" },
			device_id = "abcdef01-0000-0000-0000-000000000000",
			get_db    = function() return nil end,
		})
		helpers.assert_eq(e.get_device_short_id(), "abcdef01\xe2\x80\xa6")
	end)

	helpers.it("ignores a duplicate init call", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({
			paths     = { sqlite_path = "/tmp/first.sqlite" },
			device_id = "first-uuid-0000-0000-000000000001",
			get_db    = function() return nil end,
		})
		-- Second init with a different device_id must be ignored.
		e.init({
			paths     = { sqlite_path = "/tmp/second.sqlite" },
			device_id = "second-uuid-000-0000-000000000002",
			get_db    = function() return nil end,
		})
		-- Short-id must still reflect the first init.
		helpers.assert_eq(e.get_device_short_id(), "first-uu\xe2\x80\xa6")
	end)
end)




-- =============================================
-- =============================================
-- ======= 5/ Device Short-id Format ===========
-- =============================================
-- =============================================

helpers.describe("export — get_device_short_id", function()
	local function make_export(uuid)
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({
			paths     = { sqlite_path = "/tmp/db.sqlite" },
			device_id = uuid,
			get_db    = function() return nil end,
		})
		return e
	end

	helpers.it("returns exactly first 8 chars followed by ellipsis (U+2026)", function()
		local e = make_export("12345678-abcd-0000-0000-000000000000")
		-- UTF-8 encoding of U+2026 HORIZONTAL ELLIPSIS is 0xE2 0x80 0xA6.
		helpers.assert_eq(e.get_device_short_id(), "12345678\xe2\x80\xa6")
	end)

	helpers.it("works correctly for a 32-char UUID without hyphens", function()
		local e = make_export("aabbccdd1122334455667788")
		helpers.assert_eq(e.get_device_short_id(), "aabbccdd\xe2\x80\xa6")
	end)
end)




-- =============================================
-- =============================================
-- ======= 6/ SQLite Path Forwarding ===========
-- =============================================
-- =============================================

helpers.describe("export — get_sqlite_path", function()
	helpers.it("returns the sqlite_path from the injected paths table", function()
		local e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		local expected_path = "/private/tmp/ergopti_metrics/test-uuid/db.sqlite"
		e.init({
			paths     = { sqlite_path = expected_path },
			device_id = "test-uuid-aabb-ccdd-eeff000011223344",
			get_db    = function() return nil end,
		})
		helpers.assert_eq(e.get_sqlite_path(), expected_path)
	end)
end)




-- ==================================================
--- ===================================================
-- ======= 7/ get_native_app_category Fallback =======
--- ===================================================
-- ==================================================

helpers.describe("export — get_native_app_category fallback", function()
	-- This function makes live hs.application.get() calls on a real machine.
	-- We only test the pure guard branches (nil / empty input).
	local e

	helpers.it("setup: init export module", function()
		e = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["lib.i18n"] = { get = function(k) return k end }
		e.init({
			paths     = { sqlite_path = "/tmp/db.sqlite" },
			device_id = "cat-test-uuid-0000-0000-000000000000",
			get_db    = function() return nil end,
		})
		helpers.assert_true(true)
	end)

	helpers.it("nil app_name returns a non-empty string", function()
		local cat = e.get_native_app_category(nil)
		helpers.assert_eq(type(cat), "string")
		helpers.assert_true(#cat > 0)
	end)

	helpers.it("empty string app_name returns a non-empty string", function()
		local cat = e.get_native_app_category("")
		helpers.assert_eq(type(cat), "string")
		helpers.assert_true(#cat > 0)
	end)

	helpers.it("unknown app name falls back without crashing", function()
		local ok, cat = pcall(function()
			return e.get_native_app_category("NonExistentApp_ZZZZ")
		end)
		helpers.assert_true(ok)
		helpers.assert_eq(type(cat), "string")
	end)
end)

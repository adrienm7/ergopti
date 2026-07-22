--- tests/unit/lib/test_reload_guard.lua

--- ==============================================================================
--- MODULE: reload_guard (regression)
--- DESCRIPTION:
--- Locks down the reload-vs-quit signal that keeps Karabiner-Elements alive
--- across an hs.reload().
---
--- ROOT CAUSE ENCODED: hs.shutdownCallback fires for BOTH a reload and a real
--- quit. The shutdown handler used to kill the KE user-level bridge every time,
--- which on the user's KE version cascaded the root grabber daemon down — so
--- after a reload the next boot's health check found no grabber and popped the
--- native "install Karabiner" prompt. reload_guard must report is_reloading()
--- == true after a controlled reload was marked (→ handler skips the kill) and
--- == false on a fresh/cleared state (genuine quit → handler kills). A stale
--- sentinel must expire so a later quit is not misread as a reload.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

--- Loads a fresh reload_guard with a clean stubbed persistent store.
local function fresh()
	package.loaded["adapters.storage"] = nil
	package.loaded["lib.reload_guard"] = nil
	return helpers.load_with_stubs("lib.reload_guard")
end

helpers.describe("reload_guard: reload-vs-quit signal", function()
	helpers.it("reports false on a fresh, cleared state (= genuine quit)", function()
		local rg = fresh()
		rg.clear()
		helpers.assert_eq(rg.is_reloading(), false)
	end)

	helpers.it("reports true right after a reload is marked", function()
		local rg = fresh()
		rg.clear()
		rg.mark_reload()
		helpers.assert_eq(rg.is_reloading(), true)
	end)

	helpers.it("clear() resets a previously marked reload", function()
		local rg = fresh()
		rg.mark_reload()
		helpers.assert_eq(rg.is_reloading(), true)
		rg.clear()
		helpers.assert_eq(rg.is_reloading(), false)
	end)

	helpers.it("treats a stale sentinel as not-a-reload (TTL expiry)", function()
		local rg = fresh()
		-- Plant a sentinel far in the past, bypassing mark_reload(), so the TTL
		-- window is exceeded and a later genuine quit is not misread as a reload.
		local storage = require("adapters.storage")
		storage.set("ergopti_reload_in_progress", os.time() - 100000)
		helpers.assert_eq(rg.is_reloading(), false)
	end)

	helpers.it("ignores a non-numeric sentinel value", function()
		local rg = fresh()
		local storage = require("adapters.storage")
		storage.set("ergopti_reload_in_progress", "garbage")
		helpers.assert_eq(rg.is_reloading(), false)
	end)
end)

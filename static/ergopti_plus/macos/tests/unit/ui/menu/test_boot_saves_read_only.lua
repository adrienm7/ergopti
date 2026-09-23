--- tests/unit/ui/menu/test_boot_saves_read_only.lua

--- ==============================================================================
--- MODULE: Read-only Preference Saves After An Unusable Boot Regression
--- DESCRIPTION:
--- When the saved preferences cannot be applied feature by feature (a refusal
--- whose runtime posture is unknown) the boot restores the pre-load defaults.
--- The save transaction was then seeded from those defaults, so the next toggle
--- wrote them over a valid config.toml. A corrupt config.toml was overwritten
--- the same way, although its loader promised to keep it untouched. Both
--- sessions are now read-only for saves: a save is refused with an ERROR that
--- says why, and the change is rolled back instead of written.
--- ==============================================================================

local helpers = require("tests.helpers")
local boot = require("tests.support.menu_boot_fixture").boot





-- ==========================================
-- ==========================================
-- ======= 1/ Read-only Save Sessions =======
-- ==========================================
-- ==========================================

helpers.describe("boot never writes defaults over a present file (R5)", function()
	helpers.it("refuses saves after an unavoidable rollback over a valid file", function()
		local fixture = boot({ gestures_enable = false, gestures_query = "throw" })
		helpers.assert_not_nil(fixture.menu,
			"a settled rollback keeps the truthful menu available")
		helpers.assert_eq(fixture.state.gestures, false)
		helpers.assert_eq(fixture.state.keylogger_enabled, false,
			"the rollback restored the pre-load defaults")

		fixture.state.keylogger_enabled = true
		helpers.assert_eq(fixture.save_prefs(), false,
			"the pre-load defaults must never be written over the valid file")
		helpers.assert_eq(#fixture.saves, 0)
		helpers.assert_eq(fixture.state.keylogger_enabled, false,
			"a refused save must roll the unsaved change back")
		helpers.assert_true(fixture.has_error("read-only"),
			"the refused save must say why")
	end)

	helpers.it("refuses saves over a config.toml that could not be decoded", function()
		local fixture = boot({ load_status = "corrupt" })
		helpers.assert_not_nil(fixture.menu)
		helpers.assert_eq(fixture.save_prefs(), false,
			"in-memory defaults must never overwrite a recoverable file")
		helpers.assert_eq(#fixture.saves, 0)
		helpers.assert_true(fixture.has_error("read-only"))
	end)

	helpers.it("still seeds and saves a fresh install without config.toml", function()
		local fixture = boot({ load_status = "absent" })
		helpers.assert_not_nil(fixture.menu)
		helpers.assert_eq(fixture.boot_saves, 1, "a fresh install seeds its first config.toml")
		helpers.assert_eq(fixture.save_prefs(), true)
		helpers.assert_eq(#fixture.saves, 2)
		helpers.assert_true(not fixture.has_error("read-only"))
	end)
end)





-- =================================================
-- =================================================
-- ======= 2/ Transaction Read-only Contract =======
-- =================================================
-- =================================================

helpers.describe("preferences transaction read-only contract", function()
	--- Binds one transaction over a recording Preferences double.
	--- @param reason function read_only_reason option.
	--- @return function save
	--- @return table state
	--- @return table calls
	local function bind(reason)
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.preferences_transaction"] = nil
		local Transaction = require("ui.menu.preferences_transaction")
		local calls = { save = 0, restore = 0 }
		local state = { gestures = false }
		local save = Transaction.bind({
			save = function()
				calls.save = calls.save + 1
				return true, {}
			end,
		}, {
			path = "/virtual/config.toml",
			state = state,
			initial_state = state,
			initial_preferences = {},
			restore_runtime = function()
				calls.restore = calls.restore + 1
				return true
			end,
			read_only_reason = reason,
		})
		return save, state, calls
	end

	helpers.it("refuses to write and rolls the change back while a reason is set", function()
		local save, state, calls = bind(function() return "boot rollback" end)
		state.gestures = true
		helpers.assert_eq(save(), false)
		helpers.assert_eq(calls.save, 0, "a read-only session must never reach Preferences.save")
		helpers.assert_eq(state.gestures, false, "the unsaved change must be rolled back")
		helpers.assert_eq(calls.restore, 1, "the runtime must be restored with the state")
	end)

	helpers.it("saves normally while the reason is nil", function()
		local save, state, calls = bind(function() return nil end)
		state.gestures = true
		helpers.assert_eq(save(), true)
		helpers.assert_eq(calls.save, 1)
	end)

	helpers.it("rejects a reason that is not a string", function()
		local save = bind(function() return false end)
		helpers.assert_true(not pcall(save), "a malformed read-only reason must fail fast")
		helpers.assert_true(not pcall(bind, "boot rollback"),
			"the option itself must be a function")
	end)
end)

return true

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

helpers.describe("shortcut scope menu admission", function()
	--- Restores the complete module cache changed by the existing menu boot fixture.
	local function isolated(callback)
		local saved, old_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do saved[name] = value end
		local ok, err = xpcall(callback, debug.traceback)
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		_G.hs = old_hs
		if not ok then error(err, 0) end
	end
	for _, result_name in ipairs({ "true", "false", "nil" }) do
		helpers.it("routes terminal shortcut result " .. result_name .. " through the real menu fence", function()
			isolated(function()
				local fixture = boot()
				fixture.global_actions()
				local ctx, selected, constructions, invalidations = fixture.ctx, nil, 0, 0
				package.loaded["ui.menu.builder"].invalidate_cache = function() invalidations = invalidations + 1 end
				local idle = true
				package.loaded["ui.menu.menu_shortcuts"].scope_idle = function() return idle end
				for _, name in ipairs({ "bindings", "keyboard_shortcuts", "tap_keys", "script_control" }) do
					package.loaded["modules.shortcuts." .. name] = {}
				end
				ctx.shortcuts.start_script_control = function(keymap, shortcuts, gestures, karabiner)
					helpers.assert_true(keymap == ctx.keymap and shortcuts == ctx.shortcuts)
					helpers.assert_true(gestures == ctx.gestures and karabiner == ctx.karabiner)
					return true
				end
				local owner = { pending = function() return false end, retry_restore = function() return true end }
				package.loaded["ui.menu.shortcuts_scope"] = { new = function(options)
					constructions, selected = constructions + 1, options
					owner.apply = function(mode)
						helpers.assert_eq(mode, "clear")
						return options.admission("shortcut scope wiring", function()
							helpers.assert_true(options.idle(), "the active global fence is not menu compensation debt")
							helpers.assert_eq(options.admission("competing mutation", function() error("reentrant mutation") end), false)
							if result_name == "nil" then return nil end
							return result_name == "true"
						end, owner)
					end
					return owner
				end }
				local expected
				if result_name ~= "nil" then expected = result_name == "true" end
				helpers.assert_eq(ctx.apply_preference_scope("shortcuts", "clear"), expected)
				helpers.assert_eq(constructions, 1)
				helpers.assert_true(selected.shortcuts == ctx.shortcuts and selected.state == ctx.state)
				helpers.assert_true(selected.bindings == package.loaded["modules.shortcuts.bindings"])
				helpers.assert_true(selected.keyboard == package.loaded["modules.shortcuts.keyboard_shortcuts"])
				helpers.assert_true(selected.tap_keys == package.loaded["modules.shortcuts.tap_keys"])
				helpers.assert_true(selected.script_control == package.loaded["modules.shortcuts.script_control"])
				helpers.assert_true(selected.start_script_control())
				helpers.assert_eq(invalidations, expected == true and 1 or 0)
				idle = false
				helpers.assert_eq(selected.idle(), false)
				helpers.assert_true(type(selected.checkpoint) == "table" and type(selected.demotions) == "table")
			end)
		end)
	end
	helpers.it("refuses shortcut scope construction after corrupt preferences", function()
		isolated(function()
			local fixture = boot({ load_status = "corrupt" })
			fixture.global_actions()
			package.loaded["ui.menu.menu_shortcuts"].scope_idle = function() return true end
			package.loaded["ui.menu.shortcuts_scope"] = { new = function() error("read-only construction") end }
			helpers.assert_eq(fixture.ctx.apply_preference_scope("shortcuts", "clear"), false)
		end)
	end)
end)

return true

--- tests/unit/modules/karabiner/test_config.lua

--- ==============================================================================
--- MODULE: karabiner.config Unit Tests
--- DESCRIPTION:
--- Validates the data shaping helpers in karabiner/config.lua: building the
--- default state, computing the non-canonical combo set, and the user-config
--- migration logic for legacy combo formats.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Config = helpers.load_with_stubs("modules.karabiner.config")




-- =====================================
--- ======================================
-- ======= 1/ build_default_state =======
--- ======================================
-- =====================================

helpers.describe("Config.build_default_state", function()
	helpers.it("creates one tap_hold entry per supplied key", function()
		local tap_hold_keys = {
			{ id = "escape", label = "Esc" },
			{ id = "tab",    label = "Tab" },
		}
		local state = Config.build_default_state(tap_hold_keys, {})
		helpers.assert_eq(type(state.tap_hold_config), "table")
		helpers.assert_eq(type(state.tap_hold_config.escape), "table")
		helpers.assert_eq(type(state.tap_hold_config.tab), "table")
	end)

	helpers.it("emits 'none' for unknown keys", function()
		local tap_hold_keys = { { id = "nonexistent_key", label = "X" } }
		local state = Config.build_default_state(tap_hold_keys, {})
		helpers.assert_eq(state.tap_hold_config.nonexistent_key.tap, "none")
		helpers.assert_eq(state.tap_hold_config.nonexistent_key.hold, "none")
	end)

	helpers.it("creates one combo entry per supplied combo def", function()
		local combos = { { id = "rcmd_lcmd" }, { id = "rcmd_rctrl" } }
		local state = Config.build_default_state({}, combos)
		helpers.assert_true(state.mod_combos_config.rcmd_lcmd ~= nil)
		helpers.assert_true(state.mod_combos_config.rcmd_rctrl ~= nil)
	end)

	helpers.it("populates default timeouts", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_true(type(state.tap_hold_timeout_ms) == "number")
		helpers.assert_true(type(state.sticky_timeout_ms) == "number")
		helpers.assert_true(type(state.simultaneous_threshold_ms) == "number")
		helpers.assert_eq(type(state.combo_symmetric), "boolean")
	end)

	helpers.it("starts disabled", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_eq(state.enabled, false)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ compute_non_canonical =========
-- =========================================
-- =========================================

helpers.describe("Config.compute_non_canonical_combos", function()
	helpers.it("returns empty when no reverse pairs exist", function()
		local mod_combos = {
			{ id = "ab", from = { simultaneous = { { key_code = "a" }, { key_code = "b" } } } },
			{ id = "cd", from = { simultaneous = { { key_code = "c" }, { key_code = "d" } } } },
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(next(nc), nil)
	end)

	helpers.it("flags reverse pair as non-canonical", function()
		local mod_combos = {
			{ id = "ab", from = { simultaneous = { { key_code = "a" }, { key_code = "b" } } } },
			{ id = "ba", from = { simultaneous = { { key_code = "b" }, { key_code = "a" } } } },
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(nc.ab, nil)
		helpers.assert_eq(nc.ba, true)
	end)

	helpers.it("ignores combos with malformed simultaneous", function()
		local mod_combos = {
			{ id = "bad1", from = {} },
			{ id = "bad2", from = { simultaneous = { { key_code = "a" } } } },  -- only 1 key
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(next(nc), nil)
	end)
end)

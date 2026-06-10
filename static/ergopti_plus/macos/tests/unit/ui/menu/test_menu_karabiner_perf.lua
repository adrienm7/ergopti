--- tests/unit/ui/menu/test_menu_karabiner_perf.lua

--- ==============================================================================
--- MODULE: Karabiner Menu Open-Latency Regression Guards
--- DESCRIPTION:
--- Locks in the fix for the dominant menubar open cost. ROOT CAUSE: the Karabiner
--- submenu rebuilt its tap/hold + raccourcis picker trees on EVERY click — 182
--- modifier combos, each with a 73-action picker, is ~40k menu tables + closures
--- (~300-380 ms measured). The trees now memoise under a fingerprint of the binding
--- state and rebuild only when a binding actually changes. These tests assert that
--- an unchanged rebuild reuses the cache and that a binding change invalidates it.
--- ==============================================================================

local helpers = require("tests.helpers")


-- Minimal karabiner surface needed by the picker builders. Mutable _taps / _combos
-- let a test flip a binding and observe cache invalidation.
local function make_karabiner()
	local taps   = { left_shift = "none" }
	local combos = { esc_tab = { combo = "none", tap = "none", hold = "none" } }
	return {
		_taps = taps, _combos = combos,
		AVAILABLE_ACTIONS = {
			{ id = "none",  label = "Aucune", category = "Special", holdable = true,  tappable = true  },
			{ id = "copy",  label = "Copier", short_label = "Copier", category = "Edition", holdable = false, tappable = true },
			{ id = "layer", label = "Calque", short_label = "Calque", category = "Calque",  holdable = true,  tappable = false },
		},
		TAP_HOLD_KEYS        = { { id = "left_shift", label = "Maj G" } },
		MOD_COMBOS           = { { id = "esc_tab", label = "Esc+Tab", group = "Esc" } },
		NON_CANONICAL_COMBOS = {},
		get_combo_symmetric    = function() return false end,
		get_tap_action         = function(id) return taps[id] or "none" end,
		get_hold_action        = function(_)  return "none" end,
		get_combo_combo_action = function(id) return combos[id].combo end,
		get_combo_tap_action   = function(id) return combos[id].tap end,
		get_combo_hold_action  = function(id) return combos[id].hold end,
		set_tap_action         = function(id, a) taps[id] = a end,
		regenerate             = function() end,
	}
end


helpers.describe("menu_karabiner picker-tree memoisation", function()
	local kar = helpers.load_with_stubs("ui.menu.menu_karabiner")
	-- The baseline i18n stub lacks section(); add it on the shared table the module
	-- already captured at require-time so the builders can render section headers.
	local i18n = package.loaded["lib.i18n"]
	i18n.section = i18n.section or function(k) return k end

	helpers.it("reuses the cached trees when the binding state is unchanged", function()
		kar._reset_picker_cache()
		local k = make_karabiner()
		local th1, rc1 = kar._build_picker_trees(k, function() end, true)
		local th2, rc2 = kar._build_picker_trees(k, function() end, true)
		helpers.assert_true(th1 == th2, "tap/hold tree must be the SAME cached table on a no-change rebuild")
		helpers.assert_true(rc1 == rc2, "raccourcis tree must be the SAME cached table on a no-change rebuild")
	end)

	helpers.it("rebuilds fresh trees after a binding changes", function()
		kar._reset_picker_cache()
		local k = make_karabiner()
		local th1 = kar._build_picker_trees(k, function() end, true)
		k._taps.left_shift = "copy"  -- flip a tap binding
		local th3 = kar._build_picker_trees(k, function() end, true)
		helpers.assert_true(th3 ~= th1, "a binding change must invalidate the cache (fresh tree)")
	end)

	helpers.it("fingerprint reflects binding and enabled changes", function()
		local k = make_karabiner()
		local fp_a = kar._picker_fingerprint(k, true)
		k._combos.esc_tab.tap = "copy"
		local fp_b = kar._picker_fingerprint(k, true)
		helpers.assert_true(fp_a ~= fp_b, "fingerprint must change when a combo binding changes")
		helpers.assert_true(kar._picker_fingerprint(k, true) ~= kar._picker_fingerprint(k, false),
			"fingerprint must include the enabled flag")
	end)
end)

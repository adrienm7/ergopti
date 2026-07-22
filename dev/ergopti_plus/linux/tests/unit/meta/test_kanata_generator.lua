--- linux/tests/unit/meta/test_kanata_generator.lua

local helpers = require("tests.helpers")

helpers.describe("_shared/lua/tap_hold/kanata_generator.lua", function()
	helpers.it("module loads without error", function()
		local ok, mod = pcall(require, "tap_hold.kanata_generator")
		helpers.assert_true(ok, "require('tap_hold.kanata_generator') should succeed")
		helpers.assert_true(type(mod) == "table", "should return a table")
		helpers.assert_true(type(mod.generate) == "function", "should expose generate()")
	end)

	local gen = require("tap_hold.kanata_generator")

	helpers.it("generates defalias block with tap-hold-press entries", function()
		local keys = {
			caps_lock = {
				time_activation_seconds = 0.35,
				tap_action = "enter",
				hold_modifier = "ctrl",
			},
			left_shift = {
				time_activation_seconds = 0.35,
				tap_action = "copy",
				hold_modifier = "shift",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_true(type(output) == "string", "returns a string")
		helpers.assert_true(output:find("%(defalias"), "contains (defalias")
		helpers.assert_true(output:find("tap%-hold%-press"), "contains tap-hold-press")
		helpers.assert_true(output:find("cap"), "contains cap alias")
		helpers.assert_true(output:find("lsft"), "contains lsft alias")
		helpers.assert_true(output:find("350 350"), "contains 350ms timeout")
	end)

	helpers.it("generates correct ms from time_activation_seconds", function()
		-- 0.20s → 200ms, 0.35s → 350ms
		local keys = {
			left_ctrl = {
				time_activation_seconds = 0.20,
				tap_action = "paste",
				hold_modifier = "ctrl",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_true(output:find("200 200"), "0.20s → 200ms")
		helpers.assert_true(not output:find("350"), "should not contain 350")
	end)

	helpers.it("generates one-shot shift entry", function()
		local keys = {
			right_ctrl = {
				time_activation_seconds = 0.20,
				tap_action = "one_shot_shift",
				hold_modifier = "shift",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_true(output:find("one%-shot"), "contains one-shot")
		helpers.assert_true(output:find("ossft"), "contains ossft alias")
		helpers.assert_true(output:find("2000 lsft"), "contains 2000ms timeout")
	end)

	helpers.it("generates layer-toggle hold action", function()
		local keys = {
			left_alt = {
				time_activation_seconds = 0.20,
				tap_action = "backspace",
				hold_layer = "nav",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_true(output:find("bspc"), "tap action is bspc")
		helpers.assert_true(output:find("layer%-toggle navigation"), "hold is layer-toggle")
	end)

	helpers.it("generates alt_tab_monitor tap action", function()
		local keys = {
			tab = {
				time_activation_seconds = 0.20,
				tap_action = "alt_tab_monitor",
				hold_modifier = "alt",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_true(output:find("%(multi lalt tab%)"), "alt_tab_monitor → multi")
		helpers.assert_true(output:find("alttab"), "tab key → alttab alias")
	end)

	helpers.it("output is deterministic (stable iteration order)", function()
		local keys = {
			left_ctrl = { time_activation_seconds=0.20, tap_action="paste", hold_modifier="ctrl" },
			caps_lock = { time_activation_seconds=0.35, tap_action="enter", hold_modifier="ctrl" },
		}
		local a = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		local b = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		helpers.assert_eq(a, b, "same input → same output")
	end)

	helpers.it("skips keys not in KEY_ALIAS_MAP", function()
		local keys = {
			unknown_key = {
				time_activation_seconds = 0.20,
				tap_action = "enter",
				hold_modifier = "ctrl",
			},
		}
		local output = gen.generate(keys, { one_shot_shift_timeout_ms = 2000 })
		-- Should only have (defalias ... ) with no entries
		helpers.assert_true(output:find("%(defalias"), "contains header")
		helpers.assert_true(not output:find("tap-hold"), "no tap-hold for unknown key")
	end)
end)

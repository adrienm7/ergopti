--- tests/unit/platform/remap/tap_hold/test_tap_hold_sticky_modifiers.lua

--- ==============================================================================
--- MODULE: Sticky (one-shot) Modifiers in the Linux Engine
--- DESCRIPTION:
--- The catalogue's sticky_* actions on Linux (maintainer decision of
--- 2026-11-13: every one-shot on every OS): an arm wraps the next key that is
--- not a modifier in its modifiers, once, each modifier toggling on its own as
--- on macOS. The arm lasts the one-shot timeout; 0 is no time limit.
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_engine_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local helpers, Engine, DOWN, UP, REPEAT, KEY_A, KEY_J, trail =
	Fixture.helpers, Fixture.Engine, Fixture.DOWN, Fixture.UP, Fixture.REPEAT, Fixture.KEY_A, Fixture.KEY_J, Fixture.trail
local CODES = Engine.STICKY_MODIFIER_CODES

local function engine(timeout_ms)
	return Engine.new({ keys = {}, tap_min_ms = 50, lone_tap_max_ms = 0, one_shot_timeout_ms = timeout_ms or 2000,
		key_text = Fixture.us_text, plan_text = Fixture.us_plan, one_shot_result = Fixture.one_shot_result })
end

helpers.describe("tap-hold engine: sticky modifiers (sticky-linux)", function()

	helpers.it("wraps the next key in a combined Ctrl+Shift arm, once (sticky-linux)", function()
		local e = engine()
		helpers.assert_true(e:arm_sticky(0, { CODES.ctrl, CODES.shift }))
		helpers.assert_eq(trail((e:process(KEY_A, DOWN, 100))), "29↓ 42↓ 30↓", "Ctrl and Shift go down before A")
		helpers.assert_eq(trail((e:process(KEY_A, REPEAT, 400))), "30⟳", "the repeat stays the engine's")
		helpers.assert_eq(trail((e:process(KEY_A, UP, 500))), "30↑ 42↑ 29↑", "A goes up, then its modifiers")
		helpers.assert_nil(e:process(KEY_J, DOWN, 600), "the arm is spent once")
	end)

	helpers.it("arms Super+Ctrl and AltGr, the Win+Ctrl and AltGr one-shots (sticky-linux)", function()
		local e = engine()
		e:arm_sticky(0, { CODES.super, CODES.ctrl })
		helpers.assert_eq(trail((e:process(KEY_A, DOWN, 10))), "29↓ 125↓ 30↓")
		e:process(KEY_A, UP, 20)
		e:arm_sticky(30, { CODES.altgr })
		helpers.assert_eq(trail((e:process(KEY_J, DOWN, 40))), "100↓ 36↓", "AltGr wraps the next key")
	end)

	helpers.it("toggles each modifier on its own, as macOS does (sticky-linux)", function()
		local e = engine()
		e:arm_sticky(0, { CODES.super })
		e:arm_sticky(0, { CODES.super, CODES.shift })
		helpers.assert_eq(e:sticky_armed(), { CODES.shift }, "Super toggled off, Shift on")
		e:arm_sticky(0, { CODES.shift })
		helpers.assert_nil(e:sticky_armed(), "the last modifier toggled off disarms")
	end)

	helpers.it("lets modifiers pass and waits for a key that is not one (sticky-linux)", function()
		local e = engine()
		e:arm_sticky(0, { CODES.ctrl })
		helpers.assert_nil(e:process(Fixture.SHIFT, DOWN, 10), "a modifier passes and leaves the arm")
		helpers.assert_eq(e:sticky_armed(), { CODES.ctrl })
	end)

	helpers.it("drops the arm past the timeout and keeps it without a limit at 0 (sticky-linux)", function()
		local timed = engine(500)
		timed:arm_sticky(0, { CODES.ctrl })
		helpers.assert_nil(timed:process(KEY_A, DOWN, 600), "past 500 ms the key passes as it is")
		local unlimited = engine(0)
		unlimited:arm_sticky(0, { CODES.ctrl })
		helpers.assert_eq(trail((unlimited:process(KEY_A, DOWN, 3600000))), "29↓ 30↓", "an hour later it still wraps")
	end)

	helpers.it("refuses unknown codes, an empty set and a stale guard (sticky-linux)", function()
		local e = engine()
		helpers.assert_true(not e:arm_sticky(0, {}), "an empty set is refused")
		helpers.assert_true(not e:arm_sticky(0, { KEY_A }), "a key that is not a sticky modifier is refused")
		helpers.assert_true(not e:arm_sticky(0 / 0, { CODES.ctrl }), "a NaN clock is refused")
		helpers.assert_true(not e:arm_sticky(0, { CODES.ctrl }, function() return false end), "a stale owner is refused")
		local current = true
		helpers.assert_true(e:arm_sticky(0, { CODES.ctrl }, function() return current end))
		current = false
		helpers.assert_nil(e:process(KEY_A, DOWN, 10), "an owner retired before the key spends nothing")
	end)

	helpers.it("releases a wrapped key and its modifiers on release_all (sticky-linux)", function()
		local e = engine()
		e:arm_sticky(0, { CODES.alt })
		e:process(KEY_A, DOWN, 10)
		helpers.assert_eq(trail(e:release_all()), "30↑ 56↑", "nothing stays down")
		helpers.assert_nil(e:sticky_armed())
	end)

end)

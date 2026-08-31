--- tests/unit/meta/test_keyboard_hook_pump.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Input-Pipeline Regression Guard
--- DESCRIPTION:
--- Regression test for the dead input pipeline in adapters/keyboard_hook.lua.
---
--- ROOT CAUSE ENCODED:
--- _pump_one() ended with `if ch and _on_char then pcall(_on_char, ch)` but never
--- assigned `ch` — _resolve_char() was never called. So no character ever reached
--- on_char and the ENTIRE daemon was inert: hotstrings, keylogger and the LLM got
--- zero keystrokes. The fix resolves the keycode (forward-declaring _resolve_char
--- to avoid the same non-hoisted-local trap) before the modifier reset.
---
--- This drives one keydown through the REAL reader over a recorded syscall
--- backend (no /dev/input node needed) and asserts the resolved character
--- reaches on_char.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================
-- ==================================================================
-- ======= 1/ Behavioural: a keydown resolves and dispatches =========
-- ==================================================================
-- ==================================================================

helpers.describe("keyboard_hook: a printable keydown resolves to a character and reaches on_char", function()
	helpers.it("dispatches the resolved character for a KEY_A (code 30) keydown", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local received = {}
		local physical = {}
		-- code 30 = KEY_A, value 1 = press.
		kh._test_drive({ { type = 1, code = 30, value = 1 } }, {
			onChar = function(ch, scancode)
				received[#received + 1] = { char = ch, scancode = scancode }
			end,
			onPhysical = function(scancode, key_name, char)
				physical[#physical + 1] = { scancode = scancode, key_name = key_name, char = char }
			end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_true(#received == 1, "on_char must be called exactly once for a printable keydown")
		helpers.assert_eq(received[1].char, "a", "on_char must receive the resolved character (code 30 = 'a' in qwerty)")
		helpers.assert_eq(received[1].scancode, 30, "on_char must preserve the physical evdev code")
		helpers.assert_eq(#physical, 1, "every physical keydown must reach the hardware callback")
		helpers.assert_eq(physical[1].scancode, 30, "hardware callback must receive evdev code 30")
		helpers.assert_eq(physical[1].char, "a", "hardware callback keeps the resolved output separate")
	end)

	helpers.it("does not dispatch on a key release (value 0)", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local received = {}
		kh._test_drive({ { type = 1, code = 30, value = 0 } }, {
			onChar = function(ch) received[#received + 1] = ch end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_true(#received == 0, "on_char must not fire on a key release")
	end)

	helpers.it("keeps non-printable physical keys for the heatmap", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local physical = {}
		kh._test_drive({ { type = 1, code = 14, value = 1 } }, {
			onChar = function() end,
			onPhysical = function(scancode, key_name, char)
				physical[#physical + 1] = { scancode = scancode, key_name = key_name, char = char }
			end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_eq(#physical, 1, "Backspace must not disappear from physical capture")
		helpers.assert_eq(physical[1].scancode, 14)
		helpers.assert_eq(physical[1].key_name, "KEY_BACKSPACE")
		helpers.assert_eq(physical[1].char, nil)
	end)
end)

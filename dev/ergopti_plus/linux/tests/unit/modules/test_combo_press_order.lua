--- tests/unit/modules/test_combo_press_order.lua

--- ==============================================================================
--- MODULE: A Chord Is Pressed in the Order a Hand Presses It
--- DESCRIPTION:
--- What `combo_emitter.press` writes to the uinput device, and in what order.
---
--- WHY ORDER IS THE WHOLE THING:
--- A synthesised chord that releases a modifier before the key it modifies leaves
--- the application seeing a BARE keystroke. `ctrl+Right` becomes `Right`: the
--- cursor moves one character instead of one word, the caller sees something
--- happen, and nothing reports an error. That is the classic way a chord
--- half-works, and no parse test can see it — the parse was right in every case.
---
--- WHY THIS COULD NOT BE TESTED BEFORE:
--- It writes to a real device. With the in-memory writer from tests/fakes the
--- events become a list, and a list can be asserted. That is what the adapter
--- boundary is FOR, and it is the first thing to use it.
---
--- WHAT ONLY HARDWARE CAN SAY: whether a compositor acts on the chord. This says
--- what was written; tests/hardware says the kernel accepted it.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

--- Presses a combo against a fake writer and returns everything it wrote.
--- @param combo string
--- @return table events, boolean ok
local function press(combo)
	local writer = Fakes.uinput_writer()
	writer.open()
	package.loaded["adapters.uinput_writer"] = writer

	local Emitter = helpers.load_module("modules.gestures.combo_emitter")
	local ok = Emitter.press(combo)

	package.loaded["adapters.uinput_writer"] = nil
	return writer.events, ok
end

local KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_RIGHT, KEY_TAB = 29, 42, 106, 15




-- =================================================================
-- =================================================================
-- ======= 1/ The order ============================================
-- =================================================================
-- =================================================================

helpers.describe("combo press: the order a hand produces", function()

	helpers.it("holds the modifier across the key it modifies", function()
		local events, ok = press("ctrl+Right")
		helpers.assert_true(ok, "the combo must be emitted")
		helpers.assert_eq(#events, 4, "two presses and two releases")

		helpers.assert_eq(events[1].code, KEY_LEFTCTRL, "ctrl down first")
		helpers.assert_eq(events[1].value, 1)
		helpers.assert_eq(events[2].code, KEY_RIGHT, "then the key")
		helpers.assert_eq(events[2].value, 1)
		helpers.assert_eq(events[3].code, KEY_RIGHT, "the key up before the modifier")
		helpers.assert_eq(events[3].value, 0)
		helpers.assert_eq(events[4].code, KEY_LEFTCTRL, "and the modifier last")
		helpers.assert_eq(events[4].value, 0,
			"releasing ctrl BEFORE Right would leave the application seeing a bare "
				.. "Right: the cursor moves one character instead of one word, and "
				.. "nothing reports an error")
	end)

	helpers.it("releases several modifiers in reverse", function()
		local events = press("ctrl+shift+Tab")
		helpers.assert_eq(#events, 6, "three down, three up")
		helpers.assert_eq(events[1].code, KEY_LEFTCTRL)
		helpers.assert_eq(events[2].code, KEY_LEFTSHIFT)
		helpers.assert_eq(events[3].code, KEY_TAB)
		helpers.assert_eq(events[4].code, KEY_TAB, "the key comes up first")
		helpers.assert_eq(events[5].code, KEY_LEFTSHIFT, "then shift")
		helpers.assert_eq(events[6].code, KEY_LEFTCTRL, "then ctrl — the reverse of the way down")
	end)

	helpers.it("presses a bare key with no modifier events at all", function()
		local events = press("Escape")
		helpers.assert_eq(#events, 2, "one down, one up, and nothing else")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ When it must write nothing ===========================
-- =================================================================
-- =================================================================

helpers.describe("combo press: when it must not write", function()

	helpers.it("writes nothing for a key name it cannot map", function()
		local events, ok = press("ctrl+Insert")
		helpers.assert_true(not ok, "an unmapped name must be refused")
		helpers.assert_eq(#events, 0,
			"and refused BEFORE anything is written: a chord half-emitted leaves the "
				.. "modifier held down, and the user's next keystroke arrives with ctrl "
				.. "on it")
	end)

	helpers.it("writes nothing when the device is not open", function()
		local writer = Fakes.uinput_writer()
		package.loaded["adapters.uinput_writer"] = writer
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		local ok = Emitter.press("ctrl+Right")
		package.loaded["adapters.uinput_writer"] = nil

		helpers.assert_true(not ok, "a closed device must refuse")
		helpers.assert_eq(#writer.events, 0,
			"the daemon owns that device's lifetime; opening it here would race the "
				.. "code that closes it")
	end)

end)

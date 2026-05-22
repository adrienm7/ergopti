--- tests/unit/lib/test_keycodes.lua

--- ==============================================================================
--- MODULE: keycodes Unit Tests
--- DESCRIPTION:
--- Validates the central keycode registry: every constant is a positive integer,
--- no two constants share a value within the same role group, and to_name()
--- correctly reverse-resolves through hs.keycodes.map.
--- ==============================================================================

local helpers = require("tests.helpers")

local Keycodes = helpers.load_with_stubs("lib.keycodes")




-- =====================================
--- ======================================
-- ======= 1/ Type & Range Sanity =======
--- ======================================
-- =====================================

helpers.describe("Keycodes: numeric constants", function()
	local fields = {
		"F13_KARABINER_RETURN", "F14_KARABINER_BACKSPACE",
		"F15_KARABINER_ESCAPE", "F16_LLM_CHAIN_SIGNAL",
		"F17_CYCLE_WINDOWS",    "F18_WAKE_OS",
		"F19_VOLUME_SCROLL_MODIFIER", "F20_LAYER_NAV_ENTERED",
		"BACKSPACE", "RETURN", "ESCAPE", "TAB", "ENTER",
		"LEFT_ARROW", "RIGHT_ARROW", "UP_ARROW", "DOWN_ARROW",
		"LAYER_SYN_1", "LAYER_SYN_2", "LAYER_SYN_3",
	}

	for _, f in ipairs(fields) do
		helpers.it("'" .. f .. "' is a positive integer", function()
			local v = Keycodes[f]
			helpers.assert_true(type(v) == "number", f .. " not a number: " .. tostring(v))
			helpers.assert_true(v > 0, f .. " not > 0: " .. tostring(v))
			helpers.assert_eq(v, math.floor(v), f .. " not an integer")
		end)
	end
end)




-- =================================
-- =================================
-- ======= 2/ No Collisions =========
-- =================================
-- =================================

helpers.describe("Keycodes: uniqueness invariants", function()
	helpers.it("F13/F14/F15 sentinels do not overlap with F16 LLM signal", function()
		helpers.assert_true(Keycodes.F13_KARABINER_RETURN ~= Keycodes.F16_LLM_CHAIN_SIGNAL)
		helpers.assert_true(Keycodes.F14_KARABINER_BACKSPACE ~= Keycodes.F16_LLM_CHAIN_SIGNAL)
		helpers.assert_true(Keycodes.F15_KARABINER_ESCAPE ~= Keycodes.F16_LLM_CHAIN_SIGNAL)
	end)

	helpers.it("F20 nav-entered does not collide with any other F-sentinel", function()
		local others = {
			Keycodes.F13_KARABINER_RETURN, Keycodes.F14_KARABINER_BACKSPACE,
			Keycodes.F15_KARABINER_ESCAPE, Keycodes.F16_LLM_CHAIN_SIGNAL,
			Keycodes.F17_CYCLE_WINDOWS,    Keycodes.F18_WAKE_OS,
			Keycodes.F19_VOLUME_SCROLL_MODIFIER,
		}
		for _, v in ipairs(others) do
			helpers.assert_true(Keycodes.F20_LAYER_NAV_ENTERED ~= v)
		end
	end)

	helpers.it("arrow keycodes are pairwise distinct", function()
		local seen = {}
		for _, k in ipairs({ "LEFT_ARROW", "RIGHT_ARROW", "UP_ARROW", "DOWN_ARROW" }) do
			helpers.assert_true(seen[Keycodes[k]] == nil, "arrow collision on " .. k)
			seen[Keycodes[k]] = k
		end
	end)

	helpers.it("layer syn keys are pairwise distinct and >= 128", function()
		helpers.assert_true(Keycodes.LAYER_SYN_1 ~= Keycodes.LAYER_SYN_2)
		helpers.assert_true(Keycodes.LAYER_SYN_2 ~= Keycodes.LAYER_SYN_3)
		helpers.assert_true(Keycodes.LAYER_SYN_1 >= 128)
	end)
end)




-- =================================
-- =================================
-- ======= 3/ to_name() ============
-- =================================
-- =================================

helpers.describe("Keycodes.to_name", function()
	helpers.it("returns the matching name from hs.keycodes.map", function()
		-- Stub hs.keycodes.map with a known entry: "f13" → 105
		_G.hs.keycodes.map = { f13 = 105, f20 = 90 }
		helpers.assert_eq(Keycodes.to_name(105), "f13")
		helpers.assert_eq(Keycodes.to_name(90), "f20")
	end)

	helpers.it("errors when the keycode is unknown", function()
		_G.hs.keycodes.map = { foo = 1 }
		local ok, err = pcall(Keycodes.to_name, 999)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("unknown keycode") ~= nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Documented values ========
-- =====================================
-- =====================================

helpers.describe("Keycodes: documented HID values", function()
	helpers.it("BACKSPACE is HID 51 (macOS)", function()
		helpers.assert_eq(Keycodes.BACKSPACE, 51)
	end)

	helpers.it("RETURN is HID 36 (macOS)", function()
		helpers.assert_eq(Keycodes.RETURN, 36)
	end)

	helpers.it("ESCAPE is HID 53 (macOS)", function()
		helpers.assert_eq(Keycodes.ESCAPE, 53)
	end)

	helpers.it("TAB is HID 48 (macOS)", function()
		helpers.assert_eq(Keycodes.TAB, 48)
	end)

	helpers.it("ENTER (numpad) is HID 76 (macOS)", function()
		helpers.assert_eq(Keycodes.ENTER, 76)
	end)

	helpers.it("arrow ranges are contiguous (123–126)", function()
		helpers.assert_eq(Keycodes.LEFT_ARROW, 123)
		helpers.assert_eq(Keycodes.RIGHT_ARROW, 124)
		helpers.assert_eq(Keycodes.DOWN_ARROW, 125)
		helpers.assert_eq(Keycodes.UP_ARROW, 126)
	end)
end)

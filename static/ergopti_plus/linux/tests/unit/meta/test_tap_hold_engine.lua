--- tests/unit/meta/test_tap_hold_engine.lua

--- ==============================================================================
--- MODULE: Tap-Hold Engine Semantics
--- DESCRIPTION:
--- The Linux tap-holds and the navigation layer were delegated to kanata, which
--- the daemon never started and which Debian 12 and Ubuntu 22.04 cannot run.
--- The daemon now does them itself, with the Windows driver's semantics; these
--- tests pin them event by event.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local DOWN, UP, REPEAT = 1, 0, 2
local SHIFT, CTRL, ALT, CAPS, ENTER, BACKSPACE = 42, 29, 56, 58, 28, 14
local KEY_A, KEY_J, KEY_LEFT, RCTRL = 30, 36, 105, 97

local DEFAULTS = {
	left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = 0.35 },
	caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.35 },
	left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 0.2 },
	right_ctrl = { tap_action = "one_shot_shift", hold_modifier = "shift", time_activation_seconds = 0.2 },
}

local function engine(keys)
	return Engine.new({ keys = keys or DEFAULTS, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
end

-- The random session also runs a Tab tap-hold and a Ctrl nobody configured.
DEFAULTS.tab = { tap_action = "alt_tab_monitor", hold_modifier = "alt", time_activation_seconds = 0.2 }

--- "42↓ 30↑" for a list of events.
local function trail(events)
	local parts = {}
	for _, ev in ipairs(events or {}) do
		parts[#parts + 1] = ev.code .. (ev.value == DOWN and "↓" or ev.value == UP and "↑" or "⟳")
	end
	return table.concat(parts, " ")
end

helpers.describe("tap-hold engine: a modifier key", function()

	helpers.it("takes the hold at key-down and taps the action on a quick lone release", function()
		local e = engine()
		helpers.assert_eq(trail(e:process(SHIFT, DOWN, 0)), "42↓", "Shift works at once for a chord or a click")
		local out, tap = e:process(SHIFT, UP, 120)
		helpers.assert_eq(trail(out), "42↑", "released before the tap is typed")
		helpers.assert_eq(tap, "copy")
	end)

	helpers.it("is a chord, not a tap, when another key came in between", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		helpers.assert_nil(e:process(KEY_A, DOWN, 30), "the letter passes through, shifted by the held Shift")
		e:process(KEY_A, UP, 60)
		local out, tap = e:process(SHIFT, UP, 100)
		helpers.assert_eq(trail(out), "42↑")
		helpers.assert_nil(tap, "Shift+A must not copy")
	end)

	helpers.it("is a hold past its threshold and a bounce below the minimum", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		local _, late = e:process(SHIFT, UP, 400)
		e:process(SHIFT, DOWN, 1000)
		local _, bounce = e:process(SHIFT, UP, 1020)
		helpers.assert_nil(late)
		helpers.assert_nil(bounce)
	end)

	helpers.it("holds another modifier than itself and taps a key through the pipeline", function()
		local e = engine()
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "29↓", "CapsLock is Ctrl while held, and never toggles")
		local out, tap = e:process(CAPS, UP, 100)
		helpers.assert_eq(trail(out), "29↑ 28↓ 28↑", "a tapped Enter is a real Enter")
		helpers.assert_nil(tap)
	end)

	helpers.it("ignores the key's own autorepeat", function()
		local e = engine()
		e:process(CAPS, DOWN, 0)
		helpers.assert_eq(trail(e:process(CAPS, REPEAT, 500)), "")
	end)

	helpers.it("lets a click or a wheel turn make it a chord", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		e:activity()
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "Shift+click must not copy")
	end)

end)

helpers.describe("tap-hold engine: thresholds and holds", function()

	helpers.it("counts a release exactly at the threshold or the minimum as a tap", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		local _, at_threshold = e:process(SHIFT, UP, 350)
		e:process(SHIFT, DOWN, 1000)
		local _, at_minimum = e:process(SHIFT, UP, 1050)
		e:process(SHIFT, DOWN, 2000)
		local _, past = e:process(SHIFT, UP, 2351)
		helpers.assert_eq(at_threshold, "copy")
		helpers.assert_eq(at_minimum, "copy")
		helpers.assert_nil(past)
	end)

	helpers.it("holds AltGr and Win, and every modifier of a combination in order", function()
		local e = engine({
			caps_lock = { tap_action = "", hold_modifier = "win", time_activation_seconds = 0.3 },
			tab = { tap_action = "", hold_modifier = "alt_gr", time_activation_seconds = 0.3 },
			left_shift = { tap_action = "", hold_modifier = "ctrl+shift+alt", time_activation_seconds = 0.3 },
		})
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "125↓")
		-- Lone holds: each Super, AltGr or Alt release is masked first.
		helpers.assert_eq(trail(e:process(CAPS, UP, 500)), "194↓ 194↑ 125↑")
		helpers.assert_eq(trail(e:process(15, DOWN, 1000)), "100↓")
		helpers.assert_eq(trail(e:process(15, UP, 1500)), "194↓ 194↑ 100↑")
		helpers.assert_eq(trail(e:process(SHIFT, DOWN, 2000)), "29↓ 42↓ 56↓")
		helpers.assert_eq(trail(e:process(SHIFT, UP, 2500)), "194↓ 194↑ 56↑ 42↑ 29↑", "released in reverse")
	end)

	helpers.it("types the key itself on a tap of a native-tap key that holds", function()
		local e = engine({ caps_lock = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.3 } })
		e:process(CAPS, DOWN, 0)
		helpers.assert_eq(trail((e:process(CAPS, UP, 100))), "29↑ 58↓ 58↑")
	end)

	helpers.it("ignores an unknown modifier name rather than pressing anything", function()
		local e = engine({ caps_lock = { tap_action = "enter", hold_modifier = "hyper", time_activation_seconds = 0.3 } })
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "")
		helpers.assert_eq(trail((e:process(CAPS, UP, 100))), "28↓ 28↑")
	end)

	helpers.it("types End then Enter for the layer's new-line key", function()
		local e = engine()
		e:process(ALT, DOWN, 0)
		helpers.assert_eq(trail(e:process(47, DOWN, 30)), "107↓ 107↑ 28↓")
		helpers.assert_eq(trail(e:process(47, UP, 60)), "28↑")
	end)

end)

helpers.describe("tap-hold engine: the navigation layer", function()

	helpers.it("turns layer keys into navigation chords while held", function()
		local e = engine()
		helpers.assert_eq(trail(e:process(ALT, DOWN, 0)), "", "the layer key itself types nothing")
		helpers.assert_eq(trail(e:process(KEY_J, DOWN, 30)), "29↓ 105↓", "J is Ctrl+Left: a word back")
		helpers.assert_eq(trail(e:process(KEY_J, REPEAT, 300)), "105⟳")
		helpers.assert_eq(trail(e:process(KEY_J, UP, 320)), "105↑ 29↑")
		local out, tap = e:process(ALT, UP, 400)
		helpers.assert_eq(trail(out), "")
		helpers.assert_nil(tap, "a layer used is not a tap")
	end)

	helpers.it("releases a layer chord even when the layer key came up first", function()
		local e = engine()
		e:process(ALT, DOWN, 0)
		e:process(37, DOWN, 30)
		e:process(ALT, UP, 60)
		helpers.assert_eq(trail(e:process(37, UP, 90)), "105↑", "K is Left, still released as Left")
		helpers.assert_nil(e:process(37, DOWN, 200), "and after the layer, K is K again")
	end)

	helpers.it("taps its own action when used alone", function()
		local e = engine()
		e:process(ALT, DOWN, 0)
		local out = e:process(ALT, UP, 100)
		helpers.assert_eq(trail(out), "14↓ 14↑")
	end)

end)

helpers.describe("tap-hold engine: under a modifier and on the layer", function()

	local TAB = 15
	local WITH_TAB = {
		left_shift = DEFAULTS.left_shift, caps_lock = DEFAULTS.caps_lock, left_alt = DEFAULTS.left_alt,
		tab = { tap_action = "alt_tab_monitor", hold_modifier = "alt", time_activation_seconds = 0.2 },
	}

	helpers.it("types Shift+Tab, not Alt+Tab, when Shift is held", function()
		local e = engine(WITH_TAB)
		e:process(SHIFT, DOWN, 0)
		helpers.assert_nil(e:process(TAB, DOWN, 50), "Tab is itself under Shift")
		helpers.assert_nil(e:process(TAB, REPEAT, 400), "and repeats as itself")
		local out, tap = e:process(TAB, UP, 450)
		helpers.assert_nil(out)
		helpers.assert_nil(tap, "no window switch")
		local _, shift_tap = e:process(SHIFT, UP, 500)
		helpers.assert_nil(shift_tap, "Shift+Tab is a chord, not a copy")
	end)

	helpers.it("types Ctrl+Tab under a held CapsLock and under a physical Ctrl", function()
		local e = engine(WITH_TAB)
		e:process(CAPS, DOWN, 0)
		helpers.assert_nil(e:process(TAB, DOWN, 50))
		e:process(TAB, UP, 80)
		e:process(CAPS, UP, 500)
		local plain = engine({ tab = WITH_TAB.tab })
		helpers.assert_nil(plain:process(CTRL, DOWN, 0), "a Ctrl nobody configured passes")
		helpers.assert_nil(plain:process(TAB, DOWN, 50))
		helpers.assert_nil(plain:process(TAB, UP, 80))
		plain:process(CTRL, UP, 100)
		helpers.assert_eq(trail(plain:process(TAB, DOWN, 200)), "56↓", "alone again, Tab is a tap-hold")
	end)

	helpers.it("keeps CapsLock a tap-hold under Shift, for Ctrl+Shift", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 20)), "29↓", "Ctrl joins the held Shift")
	end)

	helpers.it("makes CapsLock the layer's Backspace while the layer is held", function()
		local e = engine()
		e:process(ALT, DOWN, 0)
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 30)), "14↓")
		helpers.assert_eq(trail(e:process(CAPS, UP, 60)), "14↑")
		local _, tap = e:process(ALT, UP, 90)
		helpers.assert_nil(tap, "the layer was used")
	end)

end)

helpers.describe("tap-hold engine: tap sentinels and the one-shot Shift", function()

	helpers.it("types the key itself for an empty tap, and nothing for none", function()
		local e = engine({
			caps_lock = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.3 },
			tab = { tap_action = "none", hold_modifier = "alt", time_activation_seconds = 0.3 },
		})
		e:process(CAPS, DOWN, 0)
		helpers.assert_eq(trail((e:process(CAPS, UP, 100))), "29↑ 58↓ 58↑", "native: CapsLock toggles as usual")
		e:process(15, DOWN, 200)
		helpers.assert_eq(trail((e:process(15, UP, 300))), "194↓ 194↑ 56↑",
			"none: swallowed, the lone Alt released behind its mask")
	end)

	helpers.it("shifts the next key, once, and lets a modifier through while armed", function()
		local e = engine()
		e:process(RCTRL, DOWN, 0)
		helpers.assert_eq(trail((e:process(RCTRL, UP, 100))), "42↑", "the hold Shift is released")
		helpers.assert_nil(e:process(CTRL, DOWN, 150), "Ctrl does not spend it")
		helpers.assert_eq(trail(e:process(KEY_A, DOWN, 200)), "42↓ 30↓")
		helpers.assert_eq(trail(e:process(KEY_A, UP, 250)), "30↑ 42↑")
		helpers.assert_nil(e:process(KEY_A, DOWN, 300), "only once")
	end)

	helpers.it("expires the one-shot Shift", function()
		local e = engine()
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		helpers.assert_nil(e:process(KEY_A, DOWN, 2500))
	end)

	helpers.it("ignores a disabled key and a key it does not know", function()
		local e = engine({
			caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.3, enabled = false },
			not_a_key = { tap_action = "enter", time_activation_seconds = 0.3 },
		})
		helpers.assert_true(not e:handles(CAPS))
	end)

end)

helpers.describe("tap-hold engine: nothing stays pressed", function()

	helpers.it("releases every held modifier, layer chord and one-shot key", function()
		local e = engine()
		e:process(CAPS, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		e:process(ALT, DOWN, 20)
		e:process(KEY_J, DOWN, 30)
		local released = trail(e:release_all())
		for _, code in ipairs({ "105↑", "29↑", "42↑" }) do
			helpers.assert_true(released:find(code, 1, true) ~= nil, code .. " in " .. released)
		end
		helpers.assert_eq(trail(e:release_all()), "", "and it forgets them")
		helpers.assert_nil(e:process(KEY_J, UP, 40), "a late release of a forgotten key passes through")
	end)

	helpers.it("sends one Ctrl for two keys holding it, and lifts it with the last", function()
		local e = engine({
			caps_lock = DEFAULTS.caps_lock,
			left_ctrl = { tap_action = "paste", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
		})
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "29↓")
		helpers.assert_eq(trail(e:process(CTRL, DOWN, 10)), "", "already down")
		helpers.assert_eq(trail(e:process(CTRL, UP, 400)), "", "CapsLock still holds it")
		helpers.assert_eq(trail(e:process(CAPS, UP, 500)), "29↑")
	end)

	helpers.it("shares Ctrl with a physical Ctrl nobody configured", function()
		local e = engine({ caps_lock = DEFAULTS.caps_lock })
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "29↓")
		helpers.assert_eq(trail(e:process(CTRL, DOWN, 10)), "", "not pressed twice")
		helpers.assert_eq(trail(e:process(CAPS, UP, 400)), "", "the hand still holds Ctrl")
		helpers.assert_eq(trail(e:process(CTRL, UP, 500)), "", "and the kernel lets it go")
		helpers.assert_nil(e:process(CTRL, DOWN, 600), "a Ctrl alone is untouched again")
	end)

	helpers.it("types a tapped Enter again while Enter is held", function()
		local e = engine()
		helpers.assert_nil(e:process(ENTER, DOWN, 0))
		e:process(CAPS, DOWN, 10)
		local out = e:process(CAPS, UP, 100)
		helpers.assert_eq(trail(out), "29↑ 28↑ 28↓", "a keystroke, and Enter stays down as the hand has it")
		helpers.assert_nil(e:process(ENTER, UP, 200))
	end)

	helpers.it("keeps a held Backspace down through the layer's Backspace", function()
		local e = engine()
		helpers.assert_nil(e:process(BACKSPACE, DOWN, 0))
		e:process(ALT, DOWN, 10)
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 30)), "", "already down")
		helpers.assert_eq(trail(e:process(CAPS, UP, 60)), "", "the hand still holds it")
		helpers.assert_eq(trail((e:process(BACKSPACE, UP, 90))), "", "lifted by the kernel")
		e:process(ALT, UP, 120)
	end)

	helpers.it("sends one Left for two layer keys that are both Left", function()
		local e = engine({ left_alt = DEFAULTS.left_alt, caps_lock = DEFAULTS.caps_lock })
		e:process(ALT, DOWN, 0)
		helpers.assert_eq(trail(e:process(37, DOWN, 10)), "105↓")
		helpers.assert_eq(trail(e:process(KEY_J, DOWN, 20)), "29↓", "Ctrl joins; Left is already down")
		helpers.assert_eq(trail(e:process(37, UP, 30)), "", "J still holds Left")
		helpers.assert_eq(trail(e:process(KEY_J, UP, 40)), "105↑ 29↑")
	end)

	helpers.it("releases a shared modifier once", function()
		local e = engine({
			caps_lock = DEFAULTS.caps_lock,
			left_ctrl = { tap_action = "paste", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
		})
		e:process(CAPS, DOWN, 0)
		e:process(CTRL, DOWN, 10)
		helpers.assert_eq(trail(e:release_all()), "29↑")
	end)

	helpers.it("pairs every down it emits with an up over a random session", function()
		local e = engine()
		local held = {}
		local codes = { SHIFT, CAPS, ALT, RCTRL, KEY_A, KEY_J, 37, 16, 47, 15, 29 }
		local physical = {}
		local seed = 7
		local function random(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
		local now = 0
		for _ = 1, 3000 do
			now = now + random(80)
			local code = codes[random(#codes)]
			local value = physical[code] and UP or DOWN
			physical[code] = value == DOWN or nil
			local out = e:process(code, value, now)
			if out == nil then out = { { code = code, value = value } } end
			for _, ev in ipairs(out) do
				if ev.value == DOWN then
					helpers.assert_true((held[ev.code] or 0) == 0, "key " .. ev.code .. " pressed while already down")
					held[ev.code] = 1
				end
				if ev.value == UP then held[ev.code] = 0 end
			end
		end
		for code in pairs(physical) do
			local out = e:process(code, UP, now + 1)
			if out == nil then out = { { code = code, value = UP } } end
			for _, ev in ipairs(out) do
				if ev.value == DOWN then held[ev.code] = (held[ev.code] or 0) + 1 end
				if ev.value == UP then held[ev.code] = math.max(0, (held[ev.code] or 0) - 1) end
			end
		end
		for _, ev in ipairs(e:release_all()) do
			if ev.value == UP then held[ev.code] = math.max(0, (held[ev.code] or 0) - 1) end
		end
		for code, count in pairs(held) do
			helpers.assert_eq(count, 0, "key " .. code .. " left down")
		end
	end)

end)

-- A hold of Alt, AltGr or Super released with nothing typed in between is a
-- lone modifier tap: the focused application moves its focus to the menu bar
-- (Firefox, LibreOffice and other apps with access keys) or the desktop opens
-- its launcher, and the tap output that follows lands there. The default Tab
-- tap-hold holds Alt. The injector already masks its own releases with F24; a
-- lone release from this engine must be masked the same way
-- (lone-modifier-mask-2026-09-25).
helpers.describe("tap-hold engine: a lone Alt, AltGr or Super hold", function()
	local TAB, WIN, ALTGR, F24 = 15, 125, 100, 194

	helpers.it("masks the lone Alt of a tap before releasing it and typing the tap", function()
		local e = engine({ tab = { tap_action = "", hold_modifier = "alt", time_activation_seconds = 0.2 } })
		helpers.assert_eq(trail(e:process(TAB, DOWN, 0)), "56↓")
		local out, tap = e:process(TAB, UP, 100)
		helpers.assert_eq(trail(out), "194↓ 194↑ 56↑ 15↓ 15↑", "the mask comes before the Alt release")
		helpers.assert_nil(tap)
	end)

	helpers.it("masks a lone long hold too, where no tap follows", function()
		local e = engine({ tab = { tap_action = "", hold_modifier = "alt", time_activation_seconds = 0.2 } })
		e:process(TAB, DOWN, 0)
		helpers.assert_eq(trail(e:process(TAB, UP, 900)), "194↓ 194↑ 56↑")
	end)

	helpers.it("does not mask a chord, which opens no menu", function()
		local e = engine({ tab = { tap_action = "", hold_modifier = "alt", time_activation_seconds = 0.2 } })
		e:process(TAB, DOWN, 0)
		e:process(KEY_J, DOWN, 20)
		e:process(KEY_J, UP, 40)
		helpers.assert_eq(trail(e:process(TAB, UP, 100)), "56↑")
	end)

	helpers.it("masks Super and AltGr, never Ctrl or Shift", function()
		local e = engine({
			tab = { tap_action = "", hold_modifier = "win", time_activation_seconds = 0.2 },
			caps_lock = { tap_action = "", hold_modifier = "alt_gr", time_activation_seconds = 0.2 },
			enter = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
		})
		e:process(TAB, DOWN, 0)
		helpers.assert_eq(trail(e:process(TAB, UP, 100)), "194↓ 194↑ 125↑ 15↓ 15↑")
		e:process(CAPS, DOWN, 200)
		helpers.assert_eq(trail(e:process(CAPS, UP, 300)), "194↓ 194↑ 100↑ 58↓ 58↑")
		e:process(ENTER, DOWN, 400)
		helpers.assert_eq(trail(e:process(ENTER, UP, 500)), "29↑ 28↓ 28↑")
		helpers.assert_true(F24 == 194 and WIN == 125 and ALTGR == 100)
	end)

end)

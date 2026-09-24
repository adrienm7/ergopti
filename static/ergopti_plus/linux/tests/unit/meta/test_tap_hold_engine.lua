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

helpers.describe("tap-hold engine: tap sentinels and the one-shot Shift", function()

	helpers.it("types the key itself for an empty tap, and nothing for none", function()
		local e = engine({
			caps_lock = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.3 },
			tab = { tap_action = "none", hold_modifier = "alt", time_activation_seconds = 0.3 },
		})
		e:process(CAPS, DOWN, 0)
		helpers.assert_eq(trail((e:process(CAPS, UP, 100))), "29↑ 58↓ 58↑", "native: CapsLock toggles as usual")
		e:process(15, DOWN, 200)
		helpers.assert_eq(trail((e:process(15, UP, 300))), "56↑", "none: swallowed")
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

	helpers.it("pairs every down it emits with an up over a random session", function()
		local e = engine()
		local held = {}
		local codes = { SHIFT, CAPS, ALT, RCTRL, KEY_A, KEY_J, 37, 16, 47 }
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
				if ev.value == DOWN then held[ev.code] = (held[ev.code] or 0) + 1 end
				if ev.value == UP then held[ev.code] = math.max(0, (held[ev.code] or 0) - 1) end
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

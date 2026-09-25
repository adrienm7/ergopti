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

-- What each key types on a US layout with NumLock on, as the hook's key_text
-- answers; a key absent here types nothing (the hook also answers nothing for
-- a key under Ctrl, Alt or Super, and for Enter, Tab and their kind).
local US_TEXT = {
	[16] = "q", [30] = "a", [36] = "j", [48] = "b", [2] = "1", [51] = ",", [52] = ".", [57] = " ",
	[79] = "1", -- KP_1
}
local function us_text(code) return US_TEXT[code] end

-- The keystrokes a US layout types the tests' characters with.
local US_PLAN = {
	["-"] = { keycode = 12, mods = {} }, [" "] = { keycode = 57, mods = {} }, [";"] = { keycode = 39, mods = {} },
	[":"] = { keycode = 39, mods = { "shift" } }, ["?"] = { keycode = 53, mods = { "shift" } },
	A = { keycode = 30, mods = { "shift" } }, B = { keycode = 48, mods = { "shift" } },
	J = { keycode = 36, mods = { "shift" } }, Q = { keycode = 16, mods = { "shift" } },
}
local function us_plan(text)
	local steps = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if not US_PLAN[char] then return nil end
		steps[#steps + 1] = US_PLAN[char]
	end
	return steps
end

-- What the one-shot Shift types instead of a capital, as the shared table has
-- it, with ★ as the magic key.
local RESULTS = { [" "] = "-", ["."] = " :", [","] = " ;", ["="] = "º", ["★"] = "J" }
local function one_shot_result(char) return RESULTS[char] end

--- An engine on `keys` (the defaults) reading the layout through `key_text`
--- and `plan_text`.
local function engine(keys, key_text, plan_text)
	return Engine.new({ keys = keys or DEFAULTS, tap_min_ms = 50, one_shot_timeout_ms = 2000,
		key_text = key_text or us_text, plan_text = plan_text or us_plan, one_shot_result = one_shot_result })
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

	-- Windows' hook calls every key-up activity too (hook_dispatcher _OnKeyUp):
	-- a key held before the tap-hold key and released during it was used with it.
	helpers.it("is a chord when another key comes up in between (release-is-activity)", function()
		local e = engine()
		e:process(KEY_A, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		e:process(KEY_A, UP, 40)
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "A released during the Shift tap must not copy")
	end)

	helpers.it("is a chord when another tap-hold key comes up in between (release-is-activity)", function()
		local e = engine()
		e:process(CAPS, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		e:process(CAPS, UP, 40)
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "CapsLock released during the Shift tap must not copy")
	end)

	helpers.it("is a chord when a layer key or a native key comes up in between (release-is-activity)", function()
		local e = engine()
		e:process(ALT, DOWN, 0)
		e:process(KEY_J, DOWN, 10)
		e:process(ALT, UP, 300)
		e:process(CAPS, DOWN, 310)
		e:process(KEY_J, UP, 320)
		local out = e:process(CAPS, UP, 400)
		helpers.assert_eq(trail(out), "29↑", "the layer chord released during the CapsLock tap: no Enter")
		e = engine()
		e:process(CTRL, DOWN, 0)
		e:process(ENTER, DOWN, 10)
		e:process(CTRL, UP, 20)
		e:process(CAPS, DOWN, 30)
		e:process(ENTER, UP, 40)
		out = e:process(CAPS, UP, 100)
		helpers.assert_eq(trail(out), "29↑", "Ctrl+Enter's Enter released during the CapsLock tap: no Enter")
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

	helpers.it("refuses a hold modifier that is not a canonical id instead of dropping it", function()
		-- The loader canonicalises every spelling and rejects the rest; one that
		-- reaches the engine is a bug, and used to become a key with no hold.
		for _, spelling in ipairs({ "hyper", "altgr", "Ctrl", "ctrl + shift" }) do
			helpers.assert_throws(function()
				engine({ caps_lock = { tap_action = "enter", hold_modifier = spelling, time_activation_seconds = 0.3 } })
			end, spelling)
		end
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
		helpers.assert_nil(e:process(CTRL, UP, 160))
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

-- What an armed one-shot Shift does with the next key, as on Windows, whose
-- one-shot InputHook (platform/remap/one_shot_shift.ahk) ends on Backspace,
-- Enter and Delete and sends them unshifted, collects Tab and Escape as text
-- it sends back unchanged, and lets a key that types nothing (an arrow, a
-- function key, CapsLock) through without spending itself. A tap-hold's tap
-- that types a key is that key: it used to bypass the one-shot entirely, so
-- CapsLock tapped for Enter typed a bare Enter and the NEXT letter came out
-- capitalised (one-shot-next-key-2026-09-25).
helpers.describe("tap-hold engine: what the one-shot Shift does with the next key", function()

	local KEY_B = 48
	-- The verdict per key tap. A key tap this table does not name fails the
	-- first case, so a new one cannot ship without a decision.
	local TAP_ROLE = {
		enter = "spend", tab = "spend", backspace = "spend", escape = "spend", delete = "spend",
		space = "result", caps_lock = "keep",
	}
	local SPEND = { 28, 96, 14, 111, 15, 1 }
	local KEEP = { 103, 108, 105, 106, 102, 107, 104, 109, 110, 58,
		59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88 }

	--- An engine with the one-shot armed at t=100 and, optionally, CapsLock
	--- configured to tap `tap` and hold `hold`, reading `key_text`.
	local function armed(tap, hold, key_text)
		local keys = { right_ctrl = DEFAULTS.right_ctrl }
		if tap then
			keys.caps_lock = { tap_action = tap, hold_modifier = hold or "", time_activation_seconds = 0.3 }
		end
		local e = engine(keys, key_text)
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		return e
	end

	--- What a letter typed right after comes out as: shifted or not.
	local function next_letter(e)
		return trail(e:process(KEY_B, DOWN, 400) or { { code = KEY_B, value = DOWN } })
	end

	helpers.it("treats a key tapped by a tap-hold as the same key pressed by hand (one-shot-next-key)", function()
		for name, code in pairs(Engine.KEY_TAPS) do
			local role = TAP_ROLE[name]
			helpers.assert_true(role ~= nil, "no one-shot verdict for the key tap " .. name)
			local e = armed(name)
			e:process(CAPS, DOWN, 200)
			local tapped = trail((e:process(CAPS, UP, 300)))
			-- Space's result is "-", KEY_MINUS on a US layout.
			local expected = role == "shift" and string.format("42↓ %d↓ %d↑ 42↑", code, code)
				or role == "result" and "12↓ 12↑" or string.format("%d↓ %d↑", code, code)
			helpers.assert_eq(tapped, expected, name .. " tapped under a one-shot Shift")
			helpers.assert_eq(next_letter(e), role == "keep" and "42↓ 48↓" or "48↓",
				role == "keep" and name .. " types nothing, so the one-shot waits for the letter"
					or name .. " spent the one-shot: the next letter is not capitalised")
		end
	end)

	helpers.it("types the native key of a tap-hold as that key (one-shot-next-key)", function()
		local caps = armed("", "ctrl")
		helpers.assert_eq(trail(caps:process(CAPS, DOWN, 200)), "29↓", "a native-tap CapsLock that holds Ctrl")
		helpers.assert_eq(trail((caps:process(CAPS, UP, 300))), "29↑ 58↓ 58↑", "CapsLock is typed unshifted")
		helpers.assert_eq(next_letter(caps), "42↓ 48↓", "and leaves the one-shot for the letter")
		local e = engine({ right_ctrl = DEFAULTS.right_ctrl,
			enter = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.3 } })
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		e:process(ENTER, DOWN, 200)
		helpers.assert_eq(trail((e:process(ENTER, UP, 300))), "29↑ 28↓ 28↑", "a native Enter is typed unshifted")
		helpers.assert_eq(next_letter(e), "48↓", "and spends the one-shot")
	end)

	helpers.it("ends on Enter, Backspace, Delete, Tab and Escape, typed unshifted (one-shot-next-key)", function()
		for _, code in ipairs(SPEND) do
			local e = armed()
			helpers.assert_nil(e:process(code, DOWN, 200), code .. " passes through without Shift")
			helpers.assert_nil(e:process(code, UP, 250))
			helpers.assert_eq(next_letter(e), "48↓", code .. " spent the one-shot")
		end
	end)

	helpers.it("lets a key that types nothing through and stays armed (one-shot-next-key)", function()
		for _, code in ipairs(KEEP) do
			local e = armed()
			helpers.assert_nil(e:process(code, DOWN, 200), code .. " is not Shift+" .. code .. ": no selection")
			helpers.assert_nil(e:process(code, UP, 250))
			helpers.assert_eq(next_letter(e), "42↓ 48↓", code .. " left the one-shot for the letter")
		end
	end)

	-- Whether a key types text is the layout's to say, not a list of control
	-- names: Print, the volume keys, NumLock or F13 used to be shifted (Shift+
	-- Print is a region screenshot) and spent the one-shot, where Windows'
	-- InputHook never sees them (one-shot-types-nothing).
	local TYPES_NOTHING = {
		99, 119, 127, 69, 70,              -- Print, Pause, Menu, NumLock, ScrollLock
		113, 114, 115, 163, 164, 165,      -- Mute, volume down and up, next, play, previous
		183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, -- F13 to F24
	}

	helpers.it("lets Print, the volume keys, NumLock and F13 through, and stays armed (one-shot-types-nothing)", function()
		for _, code in ipairs(TYPES_NOTHING) do
			local e = armed()
			helpers.assert_nil(e:process(code, DOWN, 200), code .. " passes unshifted")
			helpers.assert_nil(e:process(code, UP, 250))
			helpers.assert_eq(next_letter(e), "42↓ 48↓", code .. " left the one-shot for the letter")
		end
	end)

	helpers.it("keeps the one-shot for a keypad key with NumLock off (one-shot-types-nothing)", function()
		local e = armed(nil, nil, function(code) if code ~= 79 then return US_TEXT[code] end end)
		helpers.assert_nil(e:process(79, DOWN, 200), "KP_End is not Shift+KP_End")
		helpers.assert_nil(e:process(79, UP, 250))
		helpers.assert_eq(next_letter(e), "42↓ 48↓")
	end)

	helpers.it("passes a shortcut unshifted and stays armed (one-shot-types-nothing)", function()
		-- Under Ctrl the hook answers that a key types nothing: Ctrl+A selects
		-- all and the one-shot waits for the letter, as on Windows.
		local ctrl_held = true
		local e = armed(nil, nil, function(code) if not ctrl_held then return US_TEXT[code] end end)
		helpers.assert_nil(e:process(KEY_A, DOWN, 200), "Ctrl+A, not Ctrl+Shift+A")
		helpers.assert_nil(e:process(KEY_A, UP, 250))
		ctrl_held = false
		helpers.assert_eq(next_letter(e), "42↓ 48↓")
	end)

	helpers.it("types a digit as it is and spends the one-shot (one-shot-types-nothing)", function()
		-- Windows types the next character in title case: "1" stays as it is.
		-- Shift made it "!", and a keypad 1 KP_End.
		for _, code in ipairs({ 2, 79 }) do
			local e = armed()
			helpers.assert_nil(e:process(code, DOWN, 200), US_TEXT[code] .. " (" .. code .. ") is typed unshifted")
			helpers.assert_nil(e:process(code, UP, 250))
			helpers.assert_eq(next_letter(e), "48↓", code .. " spent the one-shot")
		end
	end)

	helpers.it("needs the layout's text when a key taps the one-shot Shift (one-shot-types-nothing)", function()
		local ok, err = pcall(Engine.new, { keys = DEFAULTS, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
		helpers.assert_true(not ok, "an engine that cannot tell a character from Print must not start")
		helpers.assert_contains(tostring(err), "key_text")
	end)

	-- Windows types "-" for Space, " :" for ".", " ;" for ",", "J" for the
	-- magic key and so on (shared table); Linux shifted them: Shift+Space, ">",
	-- "<" (one-shot-results-shared).
	helpers.it("types the shared result for Space, a period, a comma and the magic key (one-shot-results-shared)", function()
		local text = { [57] = " ", [52] = ".", [51] = ",", [41] = "★", [48] = "b" }
		for code, expected in pairs({
			[57] = "12↓ 12↑", [52] = "57↓ 57↑ 42↓ 39↓ 39↑ 42↑", [51] = "57↓ 57↑ 39↓ 39↑", [41] = "42↓ 36↓ 36↑ 42↑",
		}) do
			local e = armed(nil, nil, function(c) return text[c] end)
			local out, tap = e:process(code, DOWN, 200)
			helpers.assert_eq(trail(out), expected, text[code] .. " gives its result, typed on the layout")
			helpers.assert_nil(tap)
			helpers.assert_eq(trail(e:process(code, REPEAT, 600)), "", "its repeat is the result's")
			helpers.assert_eq(trail(e:process(code, UP, 650)), "", "and so is its release")
			helpers.assert_eq(trail(e:process(48, DOWN, 700) or {}), "", text[code] .. " spent the one-shot")
		end
	end)

	helpers.it("hands the injector a result the layout cannot type (one-shot-results-shared)", function()
		local e = armed(nil, nil, function(c) return c == 13 and "=" or nil end)
		local out, tap = e:process(13, DOWN, 200)
		helpers.assert_eq(trail(out), "", "no key of a US layout types º")
		helpers.assert_eq(tap, { type_text = "º" })
		helpers.assert_eq(trail(e:process(13, UP, 250)), "")
	end)

	helpers.it("types a capital the layout puts on another key or level (one-shot-results-shared)", function()
		-- On AZERTY "é" is KEY_2, whose Shift level is "2": Windows types "É".
		local key_text = function(c) return c == 3 and "é" or nil end
		local e = armed(nil, nil, key_text)
		local out, tap = e:process(3, DOWN, 200)
		helpers.assert_eq(trail(out), "", "Shift+KEY_2 would type 2")
		helpers.assert_eq(tap, { type_text = "É" }, "the layout has no É: the injector types it")
		local on_altgr = function(text)
			if text == "É" then return { { keycode = 18, mods = { "shift", "altgr" } } } end
		end
		e = engine({ right_ctrl = DEFAULTS.right_ctrl }, key_text, on_altgr)
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		out, tap = e:process(3, DOWN, 200)
		helpers.assert_eq(trail(out), "42↓ 100↓ 18↓ 18↑ 100↑ 42↑", "the layout's É, on its level")
		helpers.assert_nil(tap)
	end)

	-- Windows types a result with SendEvent {Text}, which lifts the modifiers
	-- the hand holds. Here the layout's keys were pressed under them: on AZERTY,
	-- one-shot then Shift+";" (".") typed " /" and not " :", KEY_DOT under the
	-- hand's Shift (one-shot-lifts-levels).
	helpers.it("lifts the Shift or AltGr the hand holds around a result (one-shot-lifts-levels)", function()
		local RSHIFT, RALT = 54, 100
		local az_text = function(code) return code == 51 and "." or nil end
		local az_plan = function(text)
			if text == " :" then return { { keycode = 57, mods = {} }, { keycode = 52, mods = {} } } end
		end
		local e = engine({ right_ctrl = DEFAULTS.right_ctrl }, az_text, az_plan)
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		helpers.assert_nil(e:process(RSHIFT, DOWN, 150), "the hand's Shift passes")
		local out, tap = e:process(51, DOWN, 200)
		helpers.assert_eq(trail(out), "54↑ 57↓ 57↑ 52↓ 52↑ 54↓", "\" :\" on its own level, Shift back after")
		helpers.assert_nil(tap)
		-- A step on the Shift level presses Shift itself, the hand's still lifted.
		e = engine({ right_ctrl = DEFAULTS.right_ctrl }, function(code) return code == 52 and "." or nil end)
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		e:process(RALT, DOWN, 150)
		helpers.assert_eq(trail((e:process(52, DOWN, 200))), "100↑ 57↓ 57↑ 42↓ 39↓ 39↑ 42↑ 100↓",
			"a US \" :\" under a held AltGr")
		-- The live layout says which keys select a level (the hook's, here
		-- CapsLock as AltGr under lv3:caps_switch).
		e = Engine.new({ keys = { right_ctrl = DEFAULTS.right_ctrl }, tap_min_ms = 50, one_shot_timeout_ms = 2000,
			key_text = az_text, plan_text = az_plan, one_shot_result = one_shot_result,
			held_text_modifier_codes = function() return { CAPS } end })
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		helpers.assert_eq(trail((e:process(51, DOWN, 200))), "58↑ 57↓ 57↑ 52↓ 52↑ 58↓",
			"the level key the layout names is lifted")
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

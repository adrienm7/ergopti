--- tests/unit/platform/remap/tap_hold/test_tap_hold_engine_under_modifier_layer.lua

--- ==============================================================================
--- MODULE: Tap-Hold Engine Semantics
--- DESCRIPTION:
--- The Linux tap-holds and the navigation layer were delegated to kanata, which
--- the daemon never started and which Debian 12 and Ubuntu 22.04 cannot run.
--- The daemon now does them itself, with the Windows driver's semantics; these
--- tests pin them event by event.
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_engine_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local helpers, Engine, DOWN, UP, REPEAT, SHIFT, CTRL, ALT, CAPS, ENTER, BACKSPACE, KEY_A, KEY_J, RCTRL, DEFAULTS, US_TEXT, one_shot_result, engine, trail =
	Fixture.helpers, Fixture.Engine, Fixture.DOWN, Fixture.UP, Fixture.REPEAT, Fixture.SHIFT, Fixture.CTRL, Fixture.ALT, Fixture.CAPS, Fixture.ENTER, Fixture.BACKSPACE, Fixture.KEY_A, Fixture.KEY_J, Fixture.RCTRL, Fixture.DEFAULTS, Fixture.US_TEXT, Fixture.one_shot_result, Fixture.engine, Fixture.trail




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

	-- A key whose own hold is the layer another key already holds is not a
	-- second layer key: it is the layer's key where the layer maps it, and
	-- itself otherwise, with its auto-repeat, as on Windows (765f8ae4a), where
	-- no tap-hold hotkey is eligible while the layer is on. Space held for the
	-- layer under CapsLock's layer typed nothing, dropped its repeat and typed
	-- one space on a quick release; CapsLock held for the layer under LAlt's
	-- was a layer key tapping Enter, not the layer's Backspace (layer-under-layer).
	helpers.it("is the layer's key or itself when its own hold is the layer another key holds (layer-under-layer)", function()
		local SPACE = 57
		local e = engine({
			left_alt = DEFAULTS.left_alt,
			caps_lock = { tap_action = "enter", hold_layer = "nav", time_activation_seconds = 0.35 },
			space = { tap_action = "", hold_layer = "nav", time_activation_seconds = 0.2 },
		})
		e:process(ALT, DOWN, 0)
		helpers.assert_nil(e:process(SPACE, DOWN, 30), "the layer maps no Space: Space is Space")
		helpers.assert_nil(e:process(SPACE, REPEAT, 530), "and repeats as Space")
		helpers.assert_nil(e:process(SPACE, UP, 560))
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 600)), "14↓", "the layer maps CapsLock: Backspace")
		helpers.assert_eq(trail(e:process(CAPS, REPEAT, 1100)), "14⟳", "repeated as the layer's key")
		local out, tap = e:process(CAPS, UP, 1120)
		helpers.assert_eq({ trail(out), tap }, { "14↑" }, "and no Enter on its release")
		helpers.assert_eq({ trail((e:process(ALT, UP, 1200))) }, { "" }, "the layer was used")
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 1300)), "", "off the layer CapsLock holds it again")
		helpers.assert_eq(trail(e:process(KEY_J, DOWN, 1310)), "29↓ 105↓")
		e:process(KEY_J, UP, 1320)
		e:process(CAPS, UP, 1330)
		-- Tapped quickly on the layer, Space types one space.
		e:process(CAPS, DOWN, 2000)
		helpers.assert_nil(e:process(SPACE, DOWN, 2010), "a quick Space on the layer is a space")
		helpers.assert_nil(e:process(SPACE, UP, 2040))
		local _, caps_tap = e:process(CAPS, UP, 2100)
		helpers.assert_nil(caps_tap, "Space was typed on CapsLock's layer: no Enter")
	end)

	-- nav_layer.ahk swallows LAlt while the layer is on when LAlt taps
	-- Backspace with the layer on hold ("Fix when LAlt triggers the layer").
	-- Passed through as Alt, it put Alt under every chord of Space's layer: J
	-- gave Ctrl+Alt+Left, a workspace switch on GNOME (layer-under-layer).
	helpers.it("swallows LAlt tapping Backspace on another key's layer, as Windows does (layer-under-layer)", function()
		local SPACE = 57
		local e = engine({
			left_alt = DEFAULTS.left_alt,
			space = { tap_action = "", hold_layer = "nav", time_activation_seconds = 0.2 },
		})
		helpers.assert_eq(trail(e:process(SPACE, DOWN, 0)), "", "Space holds the layer")
		local down = e:process(ALT, DOWN, 300)
		helpers.assert_eq(down and trail(down), "", "LAlt is swallowed, not an Alt")
		local repeated = e:process(ALT, REPEAT, 800)
		helpers.assert_eq(repeated and trail(repeated), "", "and so is its repeat")
		helpers.assert_eq(trail(e:process(KEY_J, DOWN, 820)), "29↓ 105↓", "J is Ctrl+Left, with no Alt")
		e:process(KEY_J, UP, 840)
		local out, tap = e:process(ALT, UP, 860)
		helpers.assert_eq({ out and trail(out), tap }, { "" }, "its release too, with no Backspace")
		e:process(ALT, DOWN, 900)
		out, tap = e:process(ALT, UP, 960)
		helpers.assert_eq({ out and trail(out), tap }, { "" }, "a quick LAlt there types no Backspace")
		local _, space_tap = e:process(SPACE, UP, 1000)
		helpers.assert_nil(space_tap, "LAlt was pressed on Space's layer: no space")
		local plain = engine({
			left_alt = { tap_action = "copy", hold_layer = "nav", time_activation_seconds = 0.2 },
			space = { tap_action = "", hold_layer = "nav", time_activation_seconds = 0.2 },
		})
		plain:process(SPACE, DOWN, 0)
		helpers.assert_nil(plain:process(ALT, DOWN, 300), "any other LAlt tap: no Windows hotkey, a plain Alt")
		helpers.assert_nil(plain:process(ALT, UP, 360))
	end)

	-- Every Windows tap-hold variant needs the layer off (not LayerEnabled in
	-- each #HotIf, AltGr's in altgr_criteria.ahk), and the layer maps none of
	-- these keys, so they are native there. The shipped LShift still copied on
	-- the layer, RCtrl still held Shift and armed the one-shot, and Tab still
	-- held Alt (layer-tap-holds-off).
	helpers.it("makes a key with a modifier hold itself on the layer (layer-tap-holds-off)", function()
		local TAB = 15
		local e = engine({
			left_alt = DEFAULTS.left_alt, left_shift = DEFAULTS.left_shift,
			right_ctrl = DEFAULTS.right_ctrl, tab = DEFAULTS.tab,
		})
		e:process(ALT, DOWN, 0)
		helpers.assert_nil(e:process(SHIFT, DOWN, 300), "LShift is Shift")
		local out, tap = e:process(SHIFT, UP, 400)
		helpers.assert_eq({ out, tap }, {}, "its quick release passes and copies nothing")
		helpers.assert_nil(e:process(RCTRL, DOWN, 500), "RCtrl is Right Ctrl, not Shift")
		helpers.assert_nil(e:process(RCTRL, UP, 550), "its release passes")
		helpers.assert_nil(e:process(TAB, DOWN, 600), "Tab is Tab, not Alt")
		helpers.assert_nil(e:process(TAB, REPEAT, 1100), "and repeats as Tab")
		out, tap = e:process(TAB, UP, 1120)
		helpers.assert_eq({ out, tap }, {}, "with no window switcher on its release")
		e:process(ALT, UP, 1200)
		helpers.assert_nil(e:process(KEY_A, DOWN, 1300), "RCtrl armed no one-shot: a plain a")
		e:process(KEY_A, UP, 1310)
		helpers.assert_eq(trail(e:process(SHIFT, DOWN, 1400)), "42↓", "off the layer LShift holds again")
		local _, copy = e:process(SHIFT, UP, 1450)
		helpers.assert_eq(copy, "copy", "and copies on a tap")
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
			-- With no hold, the tap fires at key-down (tap-no-hold-instant).
			local tapped = trail((e:process(CAPS, DOWN, 200)))
			helpers.assert_eq(trail((e:process(CAPS, UP, 300))), "", name .. ": the release adds nothing")
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


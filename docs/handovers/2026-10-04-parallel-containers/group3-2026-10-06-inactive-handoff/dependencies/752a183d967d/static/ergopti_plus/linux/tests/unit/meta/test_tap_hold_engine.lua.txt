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
	local nav = require("tests.support.nav_layer_fixture").recommended()
	return Engine.new({ keys = keys or DEFAULTS, tap_min_ms = 50, one_shot_timeout_ms = 2000,
		nav_layer = nav,
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

	-- On Windows a tap fires only when the key itself was the last key pressed:
	-- A_PriorKey (TapHoldPriorKeyIsSelf) counts every key-down in the key
	-- history, auto-repeats included, and so does the InputHook tracker. Here a
	-- key held on another keyboard kept repeating through a Shift tap, which
	-- still copied (prior-key-repeat).
	helpers.it("is a chord when another key auto-repeats in between (prior-key-repeat)", function()
		local e = engine()
		e:process(KEY_A, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		e:process(KEY_A, REPEAT, 40)
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "A repeating during the Shift tap must not copy")
		e = engine()
		e:process(CAPS, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		e:process(CAPS, REPEAT, 40)
		_, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "a tap-hold key repeating during the Shift tap must not copy")
		e = engine()
		e:process(SHIFT, DOWN, 0)
		e:process(SHIFT, REPEAT, 60)
		_, tap = e:process(SHIFT, UP, 100)
		helpers.assert_eq(tap, "copy", "its own repeat is the key itself, still a tap")
	end)

	helpers.it("lets a click or a wheel turn make it a chord", function()
		local e = engine()
		e:process(SHIFT, DOWN, 0)
		e:activity()
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_nil(tap, "Shift+click must not copy")
	end)

end)

-- A key with a tap and no hold does what its Windows tap-only hotkey does.
-- Most fire at key-down and again at each auto-repeat (escape.ahk "Fire
-- immediately on key-down"); here they fired on a quick release only and never
-- repeated, so a key set to Backspace deleted one character however long it
-- was held (tap-no-hold-instant). LShift, LCtrl and RShift stay the modifier
-- they are and tap on a quick release, AltGr taps on a quick release, and a
-- few taps hold what their Windows block holds (tap-no-hold-per-key).
helpers.describe("tap-hold engine: a tap with no hold", function()

	local ESC = 1

	helpers.it("runs its action at key-down and again with each repeat (tap-no-hold-instant)", function()
		local e = engine({ escape = { tap_action = "copy", time_activation_seconds = 0.2 } })
		local out, tap = e:process(ESC, DOWN, 0)
		helpers.assert_eq(trail(out), "", "the key itself is swallowed")
		helpers.assert_eq(tap, "copy", "at key-down, not at release")
		out, tap = e:process(ESC, REPEAT, 500)
		helpers.assert_eq(tap, "copy", "held, it repeats")
		out, tap = e:process(ESC, UP, 5000)
		helpers.assert_eq(trail(out), "")
		helpers.assert_nil(tap, "the release, however late, adds nothing")
	end)

	helpers.it("types its key at key-down and again with each repeat (tap-no-hold-instant)", function()
		local e = engine({ enter = { tap_action = "backspace", time_activation_seconds = 0.2 } })
		helpers.assert_eq(trail((e:process(ENTER, DOWN, 0))), "14↓ 14↑")
		helpers.assert_eq(trail((e:process(ENTER, REPEAT, 500))), "14↓ 14↑", "held, Backspace repeats")
		helpers.assert_eq(trail((e:process(ENTER, UP, 600))), "")
	end)

	helpers.it("swallows a none tap (tap-no-hold-instant)", function()
		local e = engine({ escape = { tap_action = "none", time_activation_seconds = 0.2 } })
		local out, tap = e:process(ESC, DOWN, 0)
		helpers.assert_eq(trail(out), "")
		helpers.assert_nil(tap)
		helpers.assert_eq(trail((e:process(ESC, UP, 50))), "")
	end)

	-- rctrl.ahk 7.3: RCtrl's one-shot Shift is a tap on a quick release, and a
	-- long press holds Shift; it is never armed at key-down (tap-no-hold-per-key).
	-- Shift goes down only when the KeyWait times out, past the threshold: here
	-- it went down at key-down, so RCtrl then A within the threshold typed "A"
	-- where Windows types "a" (rctrl-one-shot-hold-past-threshold).
	helpers.it("arms RCtrl's one-shot Shift on a quick release and holds Shift for a long press (tap-no-hold-per-key)", function()
		local keys = { right_ctrl = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 } }
		local e = engine(keys)
		helpers.assert_eq(trail((e:process(RCTRL, DOWN, 0))), "", "neither Shift nor the one-shot at key-down")
		helpers.assert_eq(trail(e:tick(150)), "", "no Shift within the threshold")
		helpers.assert_eq(trail((e:process(RCTRL, UP, 180))), "")
		helpers.assert_eq(trail((e:process(KEY_A, DOWN, 190))), "42↓ 30↓", "the quick release armed the one-shot")
		e = engine(keys)
		e:process(RCTRL, DOWN, 0)
		helpers.assert_eq(trail(e:tick(200)), "", "at the threshold itself it is still a tap")
		helpers.assert_eq(trail(e:tick(201)), "42↓", "past it, Shift is held")
		helpers.assert_eq(trail(e:tick(500)), "", "once")
		helpers.assert_nil(e:process(KEY_A, DOWN, 600), "held, it is Shift: A passes under it")
		e:process(KEY_A, UP, 650)
		helpers.assert_eq(trail((e:process(RCTRL, UP, 700))), "42↑")
		helpers.assert_nil(e:process(KEY_A, DOWN, 750), "and a long press arms nothing")
	end)

	helpers.it("types a key pressed within RCtrl's threshold unshifted (rctrl-one-shot-hold-past-threshold)", function()
		local e = engine({ right_ctrl = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 } })
		e:process(RCTRL, DOWN, 0)
		helpers.assert_nil(e:process(KEY_A, DOWN, 50), "A within the threshold is a plain a")
		helpers.assert_nil(e:process(KEY_A, UP, 80))
		helpers.assert_eq(trail(e:tick(250)), "42↓", "RCtrl still down past the threshold holds Shift")
		helpers.assert_nil(e:process(KEY_J, DOWN, 300), "J goes under that Shift")
		e:process(KEY_J, UP, 320)
		local out, tap = e:process(RCTRL, UP, 400)
		helpers.assert_eq({ trail(out), tap }, { "42↑" })
		helpers.assert_nil(e:process(KEY_A, DOWN, 450), "a used RCtrl arms nothing")
		e = engine({ right_ctrl = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 } })
		e:process(RCTRL, DOWN, 0)
		e:process(KEY_A, DOWN, 50)
		e:process(KEY_A, UP, 80)
		helpers.assert_eq(trail((e:process(RCTRL, UP, 150))), "", "released within the threshold: no Shift ever")
		helpers.assert_nil(e:process(KEY_J, DOWN, 200), "and A made it a chord: nothing armed")
		helpers.assert_eq(trail(e:release_all()), "", "nothing left to release")
	end)

	-- Each key's Windows tap-only hotkey, for a catalogue tap ("copy"):
	-- "down" fires at key-down and at each repeat; "own" keeps the key the
	-- modifier it is (a ~ hotkey) and taps on a quick release, AltGr included
	-- since a tap-only AltGr passes through on Windows too
	-- (altgr-tap-only-passthrough-2026-09-26) (tap-no-hold-per-key).
	local WINDOWS_RULE = {
		escape = "down", enter = "down", backspace = "down", delete = "down", space = "down",
		win = "down", caps_lock = "down", tab = "down", left_alt = "down", right_ctrl = "down",
		left_shift = "own", left_ctrl = "own", right_shift = "own", alt_gr = "own",
	}

	helpers.it("follows each key's Windows rule for a tap with no hold (tap-no-hold-per-key)", function()
		for key_id in pairs(Engine.KEY_CODES) do
			helpers.assert_not_nil(WINDOWS_RULE[key_id], key_id .. " needs its Windows rule in this test")
		end
		for key_id, rule in pairs(WINDOWS_RULE) do
			local code = Engine.KEY_CODES[key_id]
			local keys = { [key_id] = { tap_action = "copy", time_activation_seconds = 0.2 } }
			local e = engine(keys)
			local out, tap = e:process(code, DOWN, 0)
			local repeat_out, repeat_tap = e:process(code, REPEAT, 500)
			local up_out, up_tap = e:process(code, UP, 600)
			if rule == "down" then
				helpers.assert_eq({ trail(out), tap }, { "", "copy" }, key_id .. " fires at key-down")
				helpers.assert_eq(repeat_tap, "copy", key_id .. " fires again at each repeat")
				helpers.assert_eq({ trail(up_out), up_tap }, { "" }, key_id .. ": the release adds nothing")
			else
				local own = rule == "own" and tostring(code) or nil
				-- Right Alt is a plain Alt on some layouts: its lone release is
				-- masked with F24 (194), or it would open the window menu.
				local release = own and ((key_id == "alt_gr") and "194↓ 194↑ " or "") .. own .. "↑" or ""
				helpers.assert_eq({ trail(out), tap }, { own and own .. "↓" or "" },
					key_id .. (own and " is its own modifier at key-down" or " holds nothing"))
				helpers.assert_eq({ trail(repeat_out), repeat_tap }, { "" }, key_id .. " does not fire on a repeat")
				helpers.assert_eq({ trail(up_out), up_tap }, { release },
					key_id .. ": a long press is no tap")
				e = engine(keys)
				e:process(code, DOWN, 0)
				out, tap = e:process(code, UP, 100)
				helpers.assert_eq({ trail(out), tap }, { release, "copy" },
					key_id .. " taps on a quick release")
			end
		end
	end)

	helpers.it("holds what the Windows block of a special tap holds (tap-no-hold-per-key)", function()
		local F24 = require("infra.evdev_codes").KEY_F24
		local masked_alt_up = F24 .. "↓ " .. F24 .. "↑ 56↑"
		local cases = {
			-- tab.ahk 8.1, lalt.ahk 4.3: Alt for the switcher, the monitor on a tap.
			{ "tab", "alt_tab_monitor", "56↓", masked_alt_up, "alt_tab_monitor" },
			{ "left_alt", "alt_tab_monitor", "56↓", masked_alt_up, "alt_tab_monitor" },
			-- lalt.ahk 4.2: the navigation layer, Tab on a tap.
			{ "left_alt", "tab", "", "15↓ 15↑", nil },
			-- rctrl.ahk 7.2: RCtrl itself, Tab on a tap.
			{ "right_ctrl", "tab", "97↓", "97↑ 15↓ 15↑", nil },
			-- rctrl.ahk 7.1: Backspace at key-down.
			{ "right_ctrl", "backspace", "14↓ 14↑", "", nil },
		}
		for _, case in ipairs(cases) do
			local key_id, tap_action = case[1], case[2]
			local code = Engine.KEY_CODES[key_id]
			local e = engine({ [key_id] = { tap_action = tap_action, time_activation_seconds = 0.2 } })
			helpers.assert_eq(trail((e:process(code, DOWN, 0))), case[3], key_id .. "/" .. tap_action .. " at key-down")
			local out, tap = e:process(code, UP, 100)
			helpers.assert_eq({ trail(out), tap }, { case[4], case[5] }, key_id .. "/" .. tap_action .. " on a quick release")
		end
		-- The layer is held: LAlt+J is Ctrl+Left.
		local e = engine({ left_alt = { tap_action = "tab", time_activation_seconds = 0.2 } })
		e:process(ALT, DOWN, 0)
		helpers.assert_eq(trail((e:process(KEY_J, DOWN, 50))), "29↓ 105↓", "LAlt with a Tab tap holds the layer")
	end)

	-- lshift_lctrl.ahk 3.1: LCtrl taps only when CapsLock and LAlt were up at
	-- its press (KS_IsUp SC03A and SC038, in its tap-only and its hold
	-- variants), so CapsLock+LCtrl or LAlt+LCtrl let go quickly runs no tap.
	-- LShift has no such guard (lctrl-tap-needs-caps-alt-up).
	helpers.it("taps LCtrl only with CapsLock and LAlt up at its press (lctrl-tap-needs-caps-alt-up)", function()
		local cases = {
			{ CAPS, { caps_lock = DEFAULTS.caps_lock }, "CapsLock holding Ctrl" },
			{ CAPS, {}, "a CapsLock nobody configured" },
			{ ALT, {}, "a plain LAlt" },
			{ ALT, { left_alt = { tap_action = "backspace", hold_modifier = "alt", time_activation_seconds = 0.2 } },
				"LAlt holding Alt" },
		}
		for _, hold in ipairs({ "", "ctrl" }) do
			for _, case in ipairs(cases) do
				local other, keys, label = case[1], {}, case[3] .. " (LCtrl hold '" .. hold .. "')"
				for key_id, config in pairs(case[2]) do keys[key_id] = config end
				keys.left_ctrl = { tap_action = "paste", hold_modifier = hold, time_activation_seconds = 0.2 }
				local e = engine(keys)
				e:process(other, DOWN, 0)
				e:process(CTRL, DOWN, 10)
				local _, tap = e:process(CTRL, UP, 100)
				helpers.assert_nil(tap, label .. " down at LCtrl's press: no tap")
				e:process(other, UP, 150)
				e:process(CTRL, DOWN, 200)
				_, tap = e:process(CTRL, UP, 300)
				helpers.assert_eq(tap, "paste", label .. " up again: LCtrl taps")
			end
		end
		local e = engine({ left_shift = DEFAULTS.left_shift, caps_lock = DEFAULTS.caps_lock })
		e:process(CAPS, DOWN, 0)
		e:process(SHIFT, DOWN, 10)
		local _, tap = e:process(SHIFT, UP, 100)
		helpers.assert_eq(tap, "copy", "LShift taps under a held CapsLock, as on Windows")
	end)

	-- lalt.ahk 4.1: LAlt's one-shot Shift is armed at key-down and Shift is held
	-- until the key comes up (tap-no-hold-per-key).
	helpers.it("arms LAlt's one-shot Shift at key-down and holds Shift until release (tap-no-hold-per-key)", function()
		local e = engine({ left_alt = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 } })
		helpers.assert_eq(trail((e:process(ALT, DOWN, 0))), "42↓", "Shift held from key-down")
		helpers.assert_eq(trail((e:process(ALT, REPEAT, 500))), "", "and no second arming on a repeat")
		helpers.assert_eq(trail((e:process(ALT, UP, 900))), "42↑", "released with the key, however late")
		helpers.assert_eq(trail((e:process(KEY_A, DOWN, 1000))), "42↓ 30↓", "the one-shot armed at key-down")
	end)

	-- lalt.ahk 4.1: LAlt's one-shot hotkey is SC038 with no * wildcard, so
	-- under a held modifier it does not fire and LAlt stays Alt; and it returns
	-- without arming anything when RCtrl, CapsLock, LShift or LCtrl is
	-- physically down. Here the one-shot was armed and Shift held under all of
	-- them, so Ctrl+LAlt+A typed Ctrl+Shift+A (lalt-one-shot-skip).
	helpers.it("skips LAlt's one-shot under a held modifier or a held RCtrl, CapsLock, LShift or LCtrl (lalt-one-shot-skip)", function()
		local keys = { left_alt = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 } }
		local RSHIFT, WIN = 54, 125
		for _, mod in ipairs({ CTRL, SHIFT, RCTRL, RSHIFT, WIN }) do
			local e = engine(keys)
			e:process(mod, DOWN, 0)
			helpers.assert_nil(e:process(ALT, DOWN, 10), mod .. " held: LAlt is Alt, no Shift")
			helpers.assert_nil(e:process(ALT, REPEAT, 500), mod .. " held: Alt repeats as itself")
			helpers.assert_nil(e:process(ALT, UP, 600), mod .. " held: Alt comes up as itself")
			e:process(mod, UP, 700)
			helpers.assert_nil(e:process(KEY_A, DOWN, 800), mod .. " held: nothing was armed")
		end
		-- CapsLock is no modifier here, plain or tapping Enter at key-down: LAlt
		-- then does nothing at all.
		for _, caps in ipairs({ {}, { caps_lock = { tap_action = "enter", time_activation_seconds = 0.2 } } }) do
			caps.left_alt = keys.left_alt
			local e = engine(caps)
			e:process(CAPS, DOWN, 0)
			helpers.assert_eq(trail((e:process(ALT, DOWN, 10))), "", "CapsLock held: no Alt, no Shift")
			helpers.assert_eq(trail((e:process(ALT, REPEAT, 500))), "")
			helpers.assert_eq({ trail((e:process(ALT, UP, 600))) }, { "" })
			e:process(CAPS, UP, 700)
			helpers.assert_nil(e:process(KEY_A, DOWN, 800), "CapsLock held: nothing was armed")
		end
		-- Under a modifier a tap-hold holds, as a Ctrl CapsLock does, LAlt is Alt.
		local e = engine({ left_alt = keys.left_alt, caps_lock = DEFAULTS.caps_lock })
		e:process(CAPS, DOWN, 0)
		helpers.assert_nil(e:process(ALT, DOWN, 10), "Ctrl held by CapsLock: LAlt is Alt")
	end)

	helpers.it("is still the key itself under a modifier and a layer key on the layer (tap-no-hold-instant)", function()
		local e = engine({ escape = { tap_action = "copy", time_activation_seconds = 0.2 },
			left_alt = DEFAULTS.left_alt })
		e:process(CTRL, DOWN, 0)
		helpers.assert_nil(e:process(ESC, DOWN, 10), "Ctrl+Escape is Ctrl+Escape")
		helpers.assert_nil(e:process(ESC, UP, 20))
		e:process(CTRL, UP, 30)
		e:process(ALT, DOWN, 100)
		helpers.assert_nil(e:process(ESC, DOWN, 110), "on the layer Escape is Escape, as the Windows hotkey is off")
		helpers.assert_nil(e:process(ESC, UP, 120))
	end)

end)

-- lalt.ahk 4.10: LAlt's Backspace tap goes through BackSpaceLogic, which reads
-- the keys physically held and types in place of the plain Backspace, each
-- keystroke with only its own modifiers (TextPressKey lifts the others):
-- LCtrl+Shift, or an RCtrl that is not the one-shot Shift +Shift, give
-- Ctrl+Delete; LCtrl with the one-shot RCtrl gives Ctrl+Right then
-- Ctrl+Backspace; the one-shot RCtrl alone Right then Backspace (a Delete
-- that cannot become Ctrl+Alt+Delete); Shift Delete; LCtrl or a plain RCtrl
-- Ctrl+Backspace. With the layer as its hold, the tap also needs CapsLock up
-- at its release (lalt.ahk 4.5). Linux typed Backspace under whatever was
-- held: LShift then LAlt deleted backwards (lalt-backspace-logic).
helpers.describe("tap-hold engine: LAlt's Backspace under held keys", function()

	local LSHIFT, LCTRL, RSHIFT = 42, 29, 54

	--- LAlt tapped as shipped (Backspace, the layer on hold) after `held` went
	--- down, with `keys` configured too.
	--- @return string What LAlt's release types.
	local function lalt_tap(keys, held)
		local all = { left_alt = DEFAULTS.left_alt }
		for key_id, config in pairs(keys) do all[key_id] = config end
		local e = engine(all)
		for index, code in ipairs(held) do e:process(code, DOWN, index * 10) end
		e:process(ALT, DOWN, 100)
		local out, tap = e:process(ALT, UP, 180)
		helpers.assert_nil(tap)
		return trail(out)
	end

	helpers.it("types what Windows' BackSpaceLogic types for the keys held (lalt-backspace-logic)", function()
		local cases = {
			{ "LCtrl+LShift", {}, { LCTRL, LSHIFT }, "42↑ 111↓ 111↑ 42↓" },
			{ "RCtrl+RShift", {}, { RCTRL, RSHIFT }, "54↑ 111↓ 111↑ 54↓" },
			{ "LCtrl and the one-shot RCtrl", { right_ctrl = DEFAULTS.right_ctrl }, { LCTRL, RCTRL },
				"42↑ 106↓ 106↑ 14↓ 14↑ 42↓" },
			{ "the one-shot RCtrl", { right_ctrl = DEFAULTS.right_ctrl }, { RCTRL }, "42↑ 106↓ 106↑ 14↓ 14↑ 42↓" },
			{ "LShift", {}, { LSHIFT }, "42↑ 111↓ 111↑ 42↓" },
			{ "RShift", {}, { RSHIFT }, "54↑ 111↓ 111↑ 54↓" },
			{ "LCtrl", {}, { LCTRL }, "14↓ 14↑" },
			{ "a plain RCtrl", {}, { RCTRL }, "14↓ 14↑" },
			{ "nothing", {}, {}, "14↓ 14↑" },
		}
		for _, case in ipairs(cases) do
			helpers.assert_eq(lalt_tap(case[2], case[3]), case[4], case[1] .. " then LAlt tapped")
		end
	end)

	helpers.it("types nothing when CapsLock is down at the release of its layer hold (lalt-backspace-logic)", function()
		helpers.assert_eq(lalt_tap({ caps_lock = DEFAULTS.caps_lock }, { CAPS }), "",
			"CapsLock+LAlt let go quickly: no Backspace")
		helpers.assert_eq(lalt_tap({}, { CAPS }), "", "a plain CapsLock too")
		local e = engine({ caps_lock = DEFAULTS.caps_lock,
			left_alt = { tap_action = "backspace", hold_modifier = "alt", time_activation_seconds = 0.2 } })
		e:process(CAPS, DOWN, 0)
		e:process(ALT, DOWN, 10)
		helpers.assert_eq(trail((e:process(ALT, UP, 100))), "194↓ 194↑ 56↑ 14↓ 14↑",
			"no such guard with a modifier hold (its lone Alt masked first)")
	end)

	helpers.it("decides again at each repeat when LAlt has no hold (lalt-backspace-logic)", function()
		local e = engine({ left_alt = { tap_action = "backspace", time_activation_seconds = 0.2 } })
		e:process(LSHIFT, DOWN, 0)
		helpers.assert_eq(trail((e:process(ALT, DOWN, 10))), "42↑ 111↓ 111↑ 42↓", "Delete at key-down")
		helpers.assert_eq(trail((e:process(ALT, REPEAT, 510))), "42↑ 111↓ 111↑ 42↓", "and at each repeat")
		e:process(LSHIFT, UP, 520)
		helpers.assert_eq(trail((e:process(ALT, REPEAT, 540))), "14↓ 14↑", "Shift let go: Backspace again")
		helpers.assert_eq(trail((e:process(ALT, UP, 600))), "")
	end)

	helpers.it("spends an armed one-shot Shift (lalt-backspace-logic)", function()
		local e = engine({ left_alt = DEFAULTS.left_alt, right_ctrl = DEFAULTS.right_ctrl })
		e:process(RCTRL, DOWN, 0)
		e:process(RCTRL, UP, 100)
		e:process(LSHIFT, DOWN, 200)
		e:process(ALT, DOWN, 210)
		helpers.assert_eq(trail((e:process(ALT, UP, 260))), "42↑ 111↓ 111↑ 42↓")
		e:process(LSHIFT, UP, 270)
		helpers.assert_nil(e:process(KEY_A, DOWN, 300), "the Delete spent the one-shot: a plain a")
	end)

	-- The keyboard hook names the modifiers down before this engine's own
	-- events are dispatched: LAlt holding Alt had just released it, and lifting
	-- it again then pressing it back left Alt down (lalt-backspace-logic).
	helpers.it("keeps up a modifier its own release just lifted (lalt-backspace-logic)", function()
		local e = Engine.new({ keys = { left_alt = { tap_action = "backspace", hold_modifier = "alt",
				time_activation_seconds = 0.2 } },
			tap_min_ms = 50, one_shot_timeout_ms = 2000,
			held_text_modifier_codes = function() return { LSHIFT } end,
			held_shortcut_modifier_codes = function() return { ALT } end })
		e:process(LSHIFT, DOWN, 0)
		e:process(ALT, DOWN, 10)
		helpers.assert_eq(trail((e:process(ALT, UP, 100))), "194↓ 194↑ 56↑ 42↑ 111↓ 111↑ 42↓",
			"Alt stays up, the hand's Shift is lifted around the Delete")
	end)

end)

-- rctrl.ahk 7.1 and _RCtrlBackspaceTap: RCtrl's Backspace tap types Delete
-- while LShift (only the left one) is physically down, and Right then
-- Backspace, spending the one-shot, while LAlt tapping the one-shot Shift is
-- down; otherwise a Backspace under the held modifiers. Linux typed
-- Shift+Backspace and left the one-shot armed (rctrl-backspace-logic).
helpers.describe("tap-hold engine: RCtrl's Backspace under held keys", function()

	local LSHIFT, RSHIFT = 42, 54
	local ONE_SHOT_LALT = { tap_action = "one_shot_shift", time_activation_seconds = 0.2 }

	helpers.it("types Delete under LShift, at key-down and each repeat with no hold (rctrl-backspace-logic)", function()
		local e = engine({ right_ctrl = { tap_action = "backspace", time_activation_seconds = 0.2 } })
		e:process(LSHIFT, DOWN, 0)
		helpers.assert_eq(trail((e:process(RCTRL, DOWN, 10))), "42↑ 111↓ 111↑ 42↓", "Delete at key-down")
		helpers.assert_eq(trail((e:process(RCTRL, REPEAT, 510))), "42↑ 111↓ 111↑ 42↓", "and at each repeat")
		e:process(RCTRL, UP, 520)
		e:process(LSHIFT, UP, 530)
		e:process(RSHIFT, DOWN, 600)
		helpers.assert_eq(trail((e:process(RCTRL, DOWN, 610))), "14↓ 14↑", "RShift is no LShift here: Backspace")
	end)

	helpers.it("types Delete under LShift on the tap of a hold (rctrl-backspace-logic)", function()
		local e = engine({ right_ctrl = { tap_action = "backspace", hold_modifier = "ctrl", time_activation_seconds = 0.2 } })
		e:process(LSHIFT, DOWN, 0)
		e:process(RCTRL, DOWN, 10)
		helpers.assert_eq(trail((e:process(RCTRL, UP, 100))), "29↑ 42↑ 111↓ 111↑ 42↓")
		e:process(LSHIFT, UP, 200)
		e:process(RCTRL, DOWN, 300)
		helpers.assert_eq(trail((e:process(RCTRL, UP, 400))), "29↑ 14↓ 14↑", "alone, a Backspace")
	end)

	helpers.it("types Right then Backspace under LAlt's one-shot Shift and spends it (rctrl-backspace-logic)", function()
		local e = engine({ right_ctrl = { tap_action = "backspace", time_activation_seconds = 0.2 },
			left_alt = ONE_SHOT_LALT })
		helpers.assert_eq(trail((e:process(ALT, DOWN, 0))), "42↓", "LAlt holds Shift and arms the one-shot")
		helpers.assert_eq(trail((e:process(RCTRL, DOWN, 10))), "42↑ 106↓ 106↑ 14↓ 14↑ 42↓",
			"a Delete with LAlt's Shift lifted")
		e:process(RCTRL, UP, 50)
		e:process(ALT, UP, 60)
		helpers.assert_nil(e:process(KEY_A, DOWN, 100), "the one-shot is spent: a plain a")
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

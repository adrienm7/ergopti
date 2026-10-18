--- tests/unit/platform/remap/tap_hold/test_tap_hold_engine_modifier_key.lua

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
local helpers, Engine, DOWN, UP, REPEAT, SHIFT, CTRL, ALT, CAPS, ENTER, KEY_A, KEY_J, RCTRL, DEFAULTS, engine, trail =
	Fixture.helpers, Fixture.Engine, Fixture.DOWN, Fixture.UP, Fixture.REPEAT, Fixture.SHIFT, Fixture.CTRL, Fixture.ALT, Fixture.CAPS, Fixture.ENTER, Fixture.KEY_A, Fixture.KEY_J, Fixture.RCTRL, Fixture.DEFAULTS, Fixture.engine, Fixture.trail




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


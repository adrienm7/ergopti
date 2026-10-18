--- tests/unit/modules/hotstrings/engine/test_word_reset_events.lua

--- ==============================================================================
--- MODULE: Word Reset Events — Unit Tests (Linux)
--- DESCRIPTION:
--- What an arrow, a shortcut and a tap-hold do to the word being typed, under
--- `hotstrings.arrow_resets_word`, `shortcut_resets_word` and
--- `tap_hold_resets_word`. Before these options an arrow or a shortcut emptied
--- the buffer at an UNKNOWN position, so a word-start hotstring stayed silent
--- on the next word, and a tap-hold command (paste) never reached the engine.
---
--- Each case types `a`, the event, `r` through the real keyboard hook (and the
--- real tap-hold engine where a tap-hold is involved) into the real shared
--- hotstring engine, loaded from TOML-shaped entries by the real loader: `r`
--- is a word-start entry (`r` -> `R`), `z` is not. The option that owns the
--- event ON gives `aR`, OFF gives `ar`; every other option is set the other way
--- so a case passes only when the event is owned by the right one.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1

-- evdev codes of the keys the cases strike.
local K = { a = 30, r = 19, z = 44, e = 18, v = 47, s = 31, enter = 28, backspace = 14, home = 102,
	left = 105, right = 106, up = 103, down = 108, lshift = 42, lctrl = 29, lalt = 56, altgr = 100,
	lmeta = 125, caps = 58, nav_left = 37 }

-- What the capture double types for a letter key.
local LETTERS = { [K.a] = "a", [K.r] = "r", [K.z] = "z", [K.e] = "e", [K.v] = "v", [K.s] = "s" }

-- The fixture pack: one word-start entry and one entry that is not.
local FIXTURE_PATH = "/virtual/word_reset_fixture.toml"
local FIXTURE_TOML = table.concat({
	"[_meta]",
	'sections_order = ["fixture"]',
	"",
	"[fixture]",
	'"r" = { output = "R", is_word = true, auto_expand = true }',
	'"z" = { output = "Z", is_word = false, auto_expand = true }',
	"",
}, "\n")

-- CapsLock taps paste and holds Ctrl; LAlt holds the navigation layer.
local TAP_HOLDS = {
	caps_lock = { tap_action = "paste", hold_modifier = "ctrl", time_activation_seconds = 10 },
	left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 10 },
}

local SWITCHES = { "arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word" }




-- =================================================================
-- =================================================================
-- ======= 1/ The fixture ==========================================
-- =================================================================
-- =================================================================

--- A hotstring engine loaded with the fixture pack through the loader.
--- @return table engine
local function fixture_engine()
	local Loader = helpers.load_module("modules.hotstrings.loader")
	local catalogue = Loader.load_catalogue({ FIXTURE_PATH }, nil, { [FIXTURE_PATH] = FIXTURE_TOML })
	assert(catalogue.committed == true, "the fixture pack must load")
	local word_start, plain = nil, nil
	for _, mapping in ipairs(catalogue.mappings) do
		if mapping.trigger == "r" then word_start = mapping end
		if mapping.trigger == "z" then plain = mapping end
	end
	assert(word_start and word_start.is_word == true, "r is flagged word-start by the TOML")
	assert(plain and plain.is_word == false, "z is not")
	local engine = require("modules.hotstrings.engine").new()
	assert(engine:load_mappings(catalogue.mappings), "the fixture mappings must publish")
	return engine
end

--- A capture double: letters, Shift for upper case, AltGr for "€".
--- @return function captureEvent(code, value) -> text, identity, error
local function capture_double()
	local shift, altgr = false, false
	return function(code, value)
		if code == K.lshift then shift = value ~= 0; return nil, nil, nil end
		if code == K.altgr then altgr = value ~= 0; return nil, nil, nil end
		local letter = LETTERS[code]
		if value == 0 or not letter then return nil, nil, nil end
		local text = altgr and "€" or (shift and letter:upper() or letter)
		return text, text, nil
	end
end

--- Types `events` through the hook into the fixture engine, wired as the
--- daemon wires them: a character to on_char, a control key or a shortcut to
--- WordReset.apply_control, a tap action to WordReset.apply_tap_action.
--- @param events table Array of { code, value }.
--- @param switches table The [hotstrings] leaves to adopt.
--- @param tap_holds boolean|nil Install the tap-hold engine.
--- @return string screen The text the application shows.
--- @return table effects "<name>=<effect>" per control key and tap action.
--- @return table keys { name, detail } per control-key callback.
local function type_through_hook(events, switches, tap_holds)
	local previous = package.loaded["modules.hotstrings.word_reset"]
	local ok, screen, effects, keys = pcall(function()
		local WordReset = helpers.load_module("modules.hotstrings.word_reset")
		assert(WordReset.adopt_configuration({ hotstrings = switches }), "the fixture switches must adopt")
		local engine = fixture_engine()
		local text, log, seen = {}, {}, {}
		local kh = helpers.load_module("adapters.keyboard_hook")
		if tap_holds then
			local TapHoldEngine = require("platform.remap.tap_hold_engine")
			kh.set_remapper(TapHoldEngine.new({ keys = TAP_HOLDS, tap_min_ms = 0, one_shot_timeout_ms = 2000,
				nav_layer = require("tests.support.nav_layer_fixture").recommended() }), function(action, binding)
				log[#log + 1] = tostring(action) .. "=" .. WordReset.apply_tap_action(engine, binding)
			end)
		end
		local stream = {}
		for index, pair in ipairs(events) do stream[index] = { type = EV_KEY, code = pair[1], value = pair[2] } end
		kh._test_drive(stream, {
			captureEvent = capture_double(),
			onEmitRaw = function() return true end,
			onChar = function(ch)
				text[#text + 1] = ch
				local result = engine:on_char(ch)
				if result then
					for _ = 1, result.backspace_count do table.remove(text) end
					text[#text + 1] = result.replacement
				end
			end,
			onKey = function(name, detail)
				seen[#seen + 1] = { name = name, detail = detail }
				log[#log + 1] = name .. "=" .. WordReset.apply_control(engine, name, detail)
			end,
		}, true)
		kh.set_remapper(nil)
		return table.concat(text), log, seen
	end)
	package.loaded["modules.hotstrings.word_reset"] = previous
	if not ok then error(screen, 0) end
	return screen, effects, keys
end

--- Switches with `owner` set to `on` and every other one the other way.
--- @param owner string|nil One of SWITCHES; nil sets them all to `on`.
--- @param on boolean
--- @return table switches
local function switches_for(owner, on)
	local switches = {}
	for _, key in ipairs(SWITCHES) do
		if owner == nil or key == owner then switches[key] = on else switches[key] = not on end
	end
	return switches
end

--- `a`, the event, `r`.
--- @param event table Array of { code, value }.
--- @return table events
local function around(event)
	local events = { { K.a, 1 }, { K.a, 0 } }
	for _, pair in ipairs(event) do events[#events + 1] = pair end
	events[#events + 1] = { K.r, 1 }
	events[#events + 1] = { K.r, 0 }
	return events
end

--- A key struck under held modifiers, released in reverse order.
--- @param mods table Array of modifier codes.
--- @param key integer The key.
--- @return table events
local function chord(mods, key)
	local events = {}
	for _, mod in ipairs(mods) do events[#events + 1] = { mod, 1 } end
	events[#events + 1] = { key, 1 }
	events[#events + 1] = { key, 0 }
	for index = #mods, 1, -1 do events[#events + 1] = { mods[index], 0 } end
	return events
end




-- =================================================================
-- =================================================================
-- ======= 2/ The fixture itself ===================================
-- =================================================================
-- =================================================================

helpers.describe("word reset events: the word-start fixture", function()
	helpers.it("word reset events, fires the word-start entry only at a word start", function()
		helpers.assert_eq(type_through_hook({ { K.r, 1 }, { K.r, 0 } }, switches_for(nil, true)), "R",
			"a fresh buffer starts a word")
		helpers.assert_eq(type_through_hook(around({}), switches_for(nil, true)), "ar",
			"inside a word the word-start entry stays silent")
	end)

	helpers.it("word reset events, fires the entry that is not word-start in every state", function()
		local event = chord({ K.lctrl }, K.v)
		for _, on in ipairs({ true, false }) do
			local events = { { K.a, 1 }, { K.a, 0 } }
			for _, pair in ipairs(event) do events[#events + 1] = pair end
			events[#events + 1] = { K.z, 1 }
			events[#events + 1] = { K.z, 0 }
			helpers.assert_eq(type_through_hook(events, switches_for(nil, on)), "aZ", "z fires with every switch " .. tostring(on))
		end
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 3/ The governed events ==================================
-- =================================================================
-- =================================================================

-- Each case: the event, the option that owns it, and whether it needs the
-- tap-hold engine.
local GOVERNED = {
	{ name = "a physical Left", event = { { K.left, 1 }, { K.left, 0 } }, owner = "arrow_resets_word" },
	{ name = "Up", event = { { K.up, 1 }, { K.up, 0 } }, owner = "arrow_resets_word" },
	{ name = "Shift+Right", event = chord({ K.lshift }, K.right), owner = "arrow_resets_word" },
	{ name = "Ctrl+Down", event = chord({ K.lctrl }, K.down), owner = "arrow_resets_word" },
	{ name = "a navigation-layer Left", event = chord({ K.lalt }, K.nav_left), owner = "arrow_resets_word",
		tap_holds = true },
	{ name = "Ctrl+V", event = chord({ K.lctrl }, K.v), owner = "shortcut_resets_word" },
	{ name = "Ctrl+Shift+V", event = chord({ K.lctrl, K.lshift }, K.v), owner = "shortcut_resets_word" },
	{ name = "Super+Shift+S", event = chord({ K.lmeta, K.lshift }, K.s), owner = "shortcut_resets_word" },
	{ name = "Ctrl+Alt+V", event = chord({ K.lctrl, K.lalt }, K.v), owner = "shortcut_resets_word" },
	{ name = "Ctrl+Enter", event = chord({ K.lctrl }, K.enter), owner = "shortcut_resets_word" },
	{ name = "a physical Ctrl+V beside the tap-holds", event = chord({ K.lctrl }, K.v),
		owner = "shortcut_resets_word", tap_holds = true },
	{ name = "the tap-hold paste tap", event = { { K.caps, 1 }, { K.caps, 0 } }, owner = "tap_hold_resets_word",
		tap_holds = true },
	{ name = "V under the tap-hold Ctrl", event = chord({ K.caps }, K.v), owner = "tap_hold_resets_word",
		tap_holds = true },
}

helpers.describe("word reset events: an event its option owns", function()
	for _, case in ipairs(GOVERNED) do
		helpers.it("word reset events, starts a word after " .. case.name .. " when " .. case.owner .. " is on", function()
			helpers.assert_eq(type_through_hook(around(case.event), switches_for(case.owner, true), case.tap_holds), "aR")
		end)

		helpers.it("word reset events, keeps the word across " .. case.name .. " when " .. case.owner .. " is off", function()
			helpers.assert_eq(type_through_hook(around(case.event), switches_for(case.owner, false), case.tap_holds), "ar")
		end)
	end

	helpers.it("word reset events, keeps a word start a word start when the option is off", function()
		-- The old unknown-position reset made this "r": off must leave the
		-- start exactly as it was, and a fresh buffer is a word start.
		local events = { { K.left, 1 }, { K.left, 0 }, { K.r, 1 }, { K.r, 0 } }
		helpers.assert_eq(type_through_hook(events, switches_for("arrow_resets_word", false)), "R")
		local shortcut = chord({ K.lctrl }, K.v)
		shortcut[#shortcut + 1] = { K.r, 1 }
		shortcut[#shortcut + 1] = { K.r, 0 }
		helpers.assert_eq(type_through_hook(shortcut, switches_for("shortcut_resets_word", false)), "R")
	end)

	helpers.it("word reset events, gives a tap-hold shortcut to the tap-hold option, not the shortcut one", function()
		-- "c", tap-hold Ctrl+V, "t★" must still expand with tap-holds off and
		-- shortcuts on: the chord is the tap-hold's, and its option keeps the word.
		local switches = { arrow_resets_word = true, shortcut_resets_word = true, tap_hold_resets_word = false }
		local screen, effects = type_through_hook(around(chord({ K.caps }, K.v)), switches, true)
		helpers.assert_eq(screen, "ar")
		helpers.assert_eq(effects, { "shortcut=kept" })
		local physical = type_through_hook(around(chord({ K.lctrl }, K.v)), switches, true)
		helpers.assert_eq(physical, "aR", "a physical Ctrl+V stays the shortcut option's")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 4/ What no option governs ===============================
-- =================================================================
-- =================================================================

helpers.describe("word reset events: typing and the unconditional keys", function()
	helpers.it("word reset events, types an AltGr character as text, never a shortcut", function()
		for _, on in ipairs({ true, false }) do
			local screen, effects, keys = type_through_hook(around(chord({ K.altgr }, K.e)), switches_for(nil, on))
			helpers.assert_eq(screen, "a€r", "AltGr+E typed € with every switch " .. tostring(on))
			helpers.assert_eq(#keys, 0, "AltGr reaches no control callback")
			helpers.assert_eq(#effects, 0)
		end
	end)

	helpers.it("word reset events, types Shift+letter as text, never a shortcut", function()
		for _, on in ipairs({ true, false }) do
			local screen, _, keys = type_through_hook(around(chord({ K.lshift }, K.e)), switches_for(nil, on))
			helpers.assert_eq(screen, "aEr", "Shift+E typed E with every switch " .. tostring(on))
			helpers.assert_eq(#keys, 0, "Shift reaches no control callback")
		end
	end)

	helpers.it("word reset events, still resets at an unknown position on Ctrl+Backspace with every option off", function()
		for _, on in ipairs({ true, false }) do
			local screen, effects = type_through_hook(around(chord({ K.lctrl }, K.backspace)), switches_for(nil, on))
			helpers.assert_eq(effects, { "backspace=unknown" }, "Ctrl+Backspace deleted an unknown amount")
			helpers.assert_eq(screen, "ar", "an unknown position is no word start")
		end
	end)

	helpers.it("word reset events, keeps the unconditional reset of Home whatever the options", function()
		for _, on in ipairs({ true, false }) do
			local _, effects = type_through_hook(around({ { K.home, 1 }, { K.home, 0 } }), switches_for(nil, on))
			helpers.assert_eq(effects, { "home=unknown" })
		end
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 5/ The hook's provenance and the owners =================
-- =================================================================
-- =================================================================

helpers.describe("word reset events: who produced the chord", function()
	helpers.it("word reset events, flags a chord under a tap-hold Ctrl and not one under the hand's", function()
		local _, _, held = type_through_hook(chord({ K.caps }, K.v), switches_for(nil, true), true)
		helpers.assert_eq(#held, 1)
		helpers.assert_eq(held[1].name, "shortcut")
		helpers.assert_true(held[1].detail.tap_hold == true, "the Ctrl came from CapsLock's hold")
		local _, _, physical = type_through_hook(chord({ K.lctrl }, K.v), switches_for(nil, true), true)
		helpers.assert_eq(#physical, 1)
		helpers.assert_eq(physical[1].detail.tap_hold, nil, "the hand's Ctrl is no tap-hold")
		local _, _, bare = type_through_hook(chord({ K.lctrl }, K.v), switches_for(nil, true))
		helpers.assert_eq(bare[1].detail.tap_hold, nil, "no tap-hold engine, no tap-hold chord")
	end)

	helpers.it("word reset events, names the owner of each control event", function()
		local WordReset = require("modules.hotstrings.word_reset")
		helpers.assert_eq(WordReset.control_owner("left", { mods = { ctrl = true }, tap_hold = true }), "arrow")
		helpers.assert_eq(WordReset.control_owner("shortcut", { mods = { ctrl = true } }), "shortcut")
		helpers.assert_eq(WordReset.control_owner("shortcut", { mods = { ctrl = true }, tap_hold = true }), "tap_hold")
		helpers.assert_eq(WordReset.control_owner("escape", { mods = { alt = true } }), "shortcut")
		helpers.assert_eq(WordReset.control_owner("escape", { mods = {} }), nil)
		for _, key in ipairs({ "backspace", "delete", "home", "end", "pageup", "pagedown", "insert", "tab" }) do
			helpers.assert_eq(WordReset.control_owner(key, { mods = { ctrl = true, meta = true } }), nil, key)
		end
		helpers.assert_eq(WordReset.control_owner("f5", { mods = {} }), nil)
	end)

	helpers.it("word reset events, leaves an action another owner ran to that owner", function()
		local previous = package.loaded["modules.hotstrings.word_reset"]
		local ok, err = pcall(function()
			local WordReset = helpers.load_module("modules.hotstrings.word_reset")
			assert(WordReset.adopt_configuration({ hotstrings = switches_for(nil, true) }))
			local resets = 0
			local engine = { reset = function() resets = resets + 1 end }
			helpers.assert_eq(WordReset.apply_tap_action(engine, "combination__copy"), "not_tap_hold")
			helpers.assert_eq(WordReset.apply_tap_action(engine, nil), "not_tap_hold")
			helpers.assert_eq(resets, 0, "a key combination's action is not a tap-hold's")
			helpers.assert_eq(WordReset.apply_tap_action(engine, "tap_hold__caps_lock"), "word_start")
			helpers.assert_eq(resets, 1)
		end)
		package.loaded["modules.hotstrings.word_reset"] = previous
		if not ok then error(err, 0) end
	end)
end)

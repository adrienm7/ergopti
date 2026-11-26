--- tests/unit/hotstrings/engine/engine/test_action_arrow_effects.lua

--- ==============================================================================
--- MODULE: Catalogue Key Emissions Publish Their Logical Effect
--- DESCRIPTION:
--- WRSL-001 and its CapsWord Enter/Tab extension. The keys the action catalogue
--- emits go straight to the virtual keyboard and never reach the hook, so the
--- gesture manager publishes every ACKNOWLEDGED combination to one observer,
--- whoever asked for it. WordReset applies the declared arrow policy to an
--- arrow combination; Main's tap-hold callback must not let the tap-hold option
--- overrule it; an Enter or Tab combination ends CapsWord as a physical one does.
--- ==============================================================================

local helpers = require("tests.helpers")

local MAIN_PATH = helpers.driver_root() .. "/ergopti_hotstrings.lua"

--- A fresh engine holding one word-start mapping (r -> R) and an AI context spy.
--- @return table engine, table ai_calls
local function fixture_engine()
	local engine = helpers.load_module("hotstrings.engine.engine").new()
	assert(engine:load_mappings({ { trigger = "r", replacement = "R", is_word = true, auto_expand = true } }))
	local calls = {}
	engine:attach_ai_context({
		typed = function() end, backspaced = function() end, replaced = function() end,
		reset = function() calls[#calls + 1] = "reset" end,
		navigated = function() calls[#calls + 1] = "navigated" end,
		text = function() return "" end,
	})
	return engine, calls
end

--- Runs `body` with WordReset adopting the given switches.
--- @param switches table [hotstrings] leaves.
--- @param body function Receives WordReset.
local function with_word_reset(switches, body)
	local previous = package.loaded["hotstrings.engine.word_reset"]
	local WordReset = helpers.load_module("hotstrings.engine.word_reset")
	local ok, err = pcall(function()
		assert(WordReset.adopt_configuration({ hotstrings = switches }), "the fixture switches must adopt")
		body(WordReset)
	end)
	package.loaded["hotstrings.engine.word_reset"] = previous
	if not ok then error(err, 0) end
end

helpers.describe("catalogue arrows: the arrow policy applies to every emitted arrow (WRSL-001)", function()
	helpers.it("(WRSL-001) recognises all four arrows under any modifier and nothing else", function()
		with_word_reset({ arrow_resets_word = true }, function(WordReset)
			for _, combo in ipairs({ "Left", "Right", "Up", "Down", "ctrl+Right", "shift+Left", "alt+Left", "super+Up" }) do
				helpers.assert_true(WordReset.is_arrow_combo(combo), combo)
			end
			for _, combo in ipairs({ "Return", "Tab", "ctrl+v", "Home", "ctrl+BackSpace", "Next", false }) do
				helpers.assert_eq(WordReset.is_arrow_combo(combo), false, tostring(combo))
			end
			helpers.assert_eq(WordReset.delimiter_key("Return"), "enter")
			helpers.assert_eq(WordReset.delimiter_key("ctrl+Tab"), "tab")
			helpers.assert_eq(WordReset.delimiter_key("Left"), nil)
		end)
	end)

	helpers.it("(WRSL-001) arrow reset on starts a new word and follows the AI navigation preference", function()
		with_word_reset({ arrow_resets_word = true }, function(WordReset)
			local engine, ai = fixture_engine()
			engine:on_char("a"); engine:on_char("b")
			helpers.assert_eq(WordReset.apply_emitted_combo(engine, "Left"), "word_start")
			helpers.assert_eq(ai[#ai], "navigated", "the AI context hears a navigation, not a forget")
			local fired = engine:on_char("r")
			helpers.assert_true(fired ~= nil, "the word-start mapping fires after the emitted arrow")
		end)
	end)

	helpers.it("(WRSL-001) arrow reset off keeps the word even when tap-hold reset is on", function()
		with_word_reset({ arrow_resets_word = false, tap_hold_resets_word = true }, function(WordReset)
			local engine = fixture_engine()
			engine:on_char("a"); engine:on_char("b")
			helpers.assert_eq(WordReset.apply_emitted_combo(engine, "ctrl+Right"), "kept")
			helpers.assert_eq(engine:on_char("r"), nil, "the word stays open inside « abr »")
		end)
	end)

	helpers.it("(WRSL-001) a non-arrow combination is none of this policy's business", function()
		with_word_reset({ arrow_resets_word = true }, function(WordReset)
			local engine = fixture_engine()
			engine:on_char("a")
			helpers.assert_eq(WordReset.apply_emitted_combo(engine, "ctrl+v"), "not_arrow")
			helpers.assert_eq(engine:current_buffer(), "a")
		end)
	end)
end)

helpers.describe("gesture manager: acknowledged emissions reach one observer (WRSL-001)", function()
	--- Loads a fresh manager over a controlled combo emitter.
	--- @param acknowledges boolean What the emitter answers.
	--- @return table manager, table seen
	local function manager_over_emitter(acknowledges)
		local saved = package.loaded["gestures.engine.combo_emitter"]
		package.loaded["gestures.engine.combo_emitter"] = {
			press = function() return acknowledges end,
			can_fallback = function() return false end,
		}
		local ok, manager = pcall(helpers.load_module, "gestures.engine.manager")
		if not ok then package.loaded["gestures.engine.combo_emitter"] = saved; error(manager, 0) end
		-- The manager keeps its admitted emitter only while that owner stays loaded.
		local seen = {}
		manager.set_effect_observer(function(action, combo, binding)
			seen[#seen + 1] = { action = action, combo = combo, binding = binding }
		end)
		return manager, seen, function()
			manager.set_effect_observer(nil)
			package.loaded["gestures.engine.combo_emitter"] = saved
		end
	end

	helpers.it("(WRSL-001) publishes the action, its combination and the origin after the ack", function()
		local manager, seen, restore = manager_over_emitter(true)
		helpers.assert_true(manager.execute_action("arrow_left", "gesture_slot"))
		manager.execute_action("enter", "tap_hold__caps_lock")
		helpers.assert_eq(#seen, 2)
		helpers.assert_eq(seen[1].combo, "Left")
		helpers.assert_eq(seen[1].binding, "gesture_slot")
		helpers.assert_eq(seen[2].combo, "Return")
		helpers.assert_eq(manager.emit_combo_for("arrow_left"), "Left")
		restore()
	end)

	helpers.it("(WRSL-001) publishes nothing for a refused emission", function()
		local manager, seen, restore = manager_over_emitter(false)
		manager.execute_action("arrow_left", "gesture_slot")
		helpers.assert_eq(#seen, 0, "no key moved, so no logical effect")
		restore()
	end)
end)

helpers.describe("Main wires the observer and keeps the tap-hold option off arrows (WRSL-001)", function()
	helpers.it("(WRSL-001) installs the observer for CapsWord delimiters and arrows, and skips the tap rule for an arrow", function()
		local file = assert(io.open(MAIN_PATH, "r"))
		local source = file:read("*a"); assert(file:close())
		helpers.assert_true(source:find("set_effect_observer(function(_, combo)", 1, true) ~= nil,
			"Main must install the catalogue effect observer")
		helpers.assert_true(source:find("WordReset.apply_emitted_combo(engine, combo)", 1, true) ~= nil)
		helpers.assert_true(source:find("shortcuts.caps_word_observe_control(delimiter)", 1, true) ~= nil,
			"an emitted Enter or Tab must reach the CapsWord owner")
		helpers.assert_true(source:find("WordReset.is_arrow_combo(action_catalogue.emit_combo_for(action))", 1, true) ~= nil,
			"the tap-hold callback must not apply tap_hold_resets_word to an arrow")
	end)
end)

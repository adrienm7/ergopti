--- tests/unit/modules/keymap/test_llm_tooltip_chords_consumed.lua

--- ==============================================================================
--- MODULE: Prediction Tooltip Chords Are Consumed, Every Other Chord Passes
--- DESCRIPTION:
--- The maintainer's rule, on every OS: while the AI tooltip shows predictions,
--- the configured navigation chord (llm_nav_modifiers + an arrow) moves the
--- active prediction and the configured validation chord (llm_val_modifiers +
--- digit N) inserts prediction N, and the application never receives either.
--- Any other modifier set (bare, a superset, a subset or a different one)
--- reaches the application unchanged, as does a digit beyond the predictions
--- shown, an arrow over a single prediction, and every key once the tooltip is
--- gone (llm-tooltip-chords-consumed).
---
--- Two consumers own these keys, whichever of their taps Quartz runs first: the
--- tooltip's own keyDown watcher and the keymap fallback (handle_llm_keys). The
--- fallback moved Up to the next prediction and Down to the previous one, and
--- the keymap wiped an idle word, and with it the tooltip, before asking the
--- fallback, so a chord pressed after reading the predictions for five seconds
--- reached the application. The expected verdict is computed here from set
--- equality of the pressed and configured modifiers, never through the driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.tooltip_watcher_fixture")
local with_bridge_fixture = require("tests.support.llm_bridge_fixture").with_bridge_fixture

local with_fixture = support.with_fixture
local CASES = support.CASES
local hardware_key_event = support.hardware_key_event
local drain_deferred_actions = support.drain_deferred_actions

local KEYCODE_UP = 126
local KEYCODE_DOWN = 125
local KEYCODE_DIGIT_2 = 19
local KEYCODE_DIGIT_4 = 21
local KEYCODE_DIGIT_0 = 29

-- Display form the prediction engine renders for an empty validation chord.
local EMPTY_CHORD_SHORTCUT = "\226\128\139"

-- Step each arrow must take from the middle of three predictions.
local ARROWS = {
	{ name = "Up", keycode = KEYCODE_UP, delta = -1 },
	{ name = "Down", keycode = KEYCODE_DOWN, delta = 1 },
}

-- Each configured modifier set, with a superset (one modifier added), a
-- different set and, for a combination, a subset.
local MODIFIER_SETS = {
	{ name = "none", mods = {}, superset = { "shift" }, other = { "alt" } },
	{ name = "shift", mods = { "shift" }, superset = { "shift", "ctrl" }, other = { "alt" } },
	{ name = "ctrl", mods = { "ctrl" }, superset = { "ctrl", "shift" }, other = { "alt" } },
	{ name = "alt", mods = { "alt" }, superset = { "alt", "shift" }, other = { "ctrl" } },
	{ name = "cmd", mods = { "cmd" }, superset = { "cmd", "shift" }, other = { "alt" } },
	{
		name = "ctrl+shift", mods = { "ctrl", "shift" },
		superset = { "ctrl", "shift", "alt" }, other = { "alt" }, subset = { "shift" },
	},
}





-- ================================
-- ================================
-- ======= 1/ Matrix Oracle =======
-- ================================
-- ================================

--- Whether two modifier lists name exactly the same modifiers.
--- @param left table
--- @param right table
--- @return boolean
local function same_set(left, right)
	local seen = {}
	for _, name in ipairs(left) do seen[name] = true end
	local count = 0
	for _, name in ipairs(right) do
		if not seen[name] then return false end
		count = count + 1
	end
	local expected = 0
	for _ in pairs(seen) do expected = expected + 1 end
	return count == expected
end

--- Lists the chords pressed against one configured set.
--- @param set table One MODIFIER_SETS row.
--- @return table chords { label, mods }
local function chords_for(set)
	local chords = {
		{ label = "exact", mods = set.mods },
		{ label = "bare", mods = {} },
		{ label = "superset", mods = set.superset },
		{ label = "other", mods = set.other },
	}
	if set.subset then chords[#chords + 1] = { label = "subset", mods = set.subset } end
	return chords
end

--- Builds the Hammerspoon flags of a chord. Quartz marks every arrow press
--- with the fn flag, which is never part of a configured chord.
--- @param mods table Modifier names.
--- @param is_arrow boolean
--- @return table flags
local function flags_for(mods, is_arrow)
	local flags = {}
	for _, name in ipairs(mods) do flags[name] = true end
	if is_arrow then flags.fn = true end
	return flags
end

--- Names one matrix case for failure messages.
--- @return string
local function case_name(kind, set_name, chord_label, key_name)
	return string.format("%s %s: %s %s", kind, set_name, chord_label, key_name)
end

--- Display shortcut the tooltip receives for a validation modifier list.
--- @param mods table
--- @return string
local function shortcut_for(mods)
	if #mods == 0 then return EMPTY_CHORD_SHORTCUT end
	return table.concat(mods, "+")
end





-- ============================================
-- ============================================
-- ======= 2/ The tooltip's own watcher =======
-- ============================================
-- ============================================

--- Shows `count` predictions on a fresh real tooltip and presses one key.
--- @param options table { count, nav, shortcut, keycode, flags, chars, hidden? }
--- @return boolean consumed, number|nil index, table accepted
local function press_on_tooltip(options)
	return with_fixture(function(fixture)
		local context = fixture.load_tooltip(CASES[1])
		local accepted = {}
		context.tooltip.set_accept_callback(function(index)
			accepted[#accepted + 1] = index
			return true
		end)
		local predictions = {}
		for index = 1, options.count do predictions[index] = "prediction " .. index end
		local start_index = math.min(2, options.count)
		helpers.assert_eq(context.tooltip.show_predictions(predictions, start_index, true, nil,
			options.shortcut, nil, options.nav, nil, nil, options.count), true)
		local key_watcher = context.created[CASES[1].watcher_count]
		if options.hidden then helpers.assert_eq(context.tooltip.hide_silent(), true) end
		local consumed = key_watcher.fn(hardware_key_event(options.keycode, options.flags, options.chars))
		local index = context.tooltip.get_current_index()
		drain_deferred_actions(context.timers)
		return consumed, index, accepted
	end)
end

helpers.describe("prediction tooltip watcher: the navigation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured arrow chord", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				for _, arrow in ipairs(ARROWS) do
					local owned = same_set(chord.mods, set.mods)
					local name = case_name("nav", set.name, chord.label, arrow.name)
					local consumed, index = press_on_tooltip({
						count = 3, nav = set.mods, shortcut = EMPTY_CHORD_SHORTCUT,
						keycode = arrow.keycode, flags = flags_for(chord.mods, true),
					})
					helpers.assert_eq(consumed, owned, name .. ": consumed only when it is the configured chord")
					helpers.assert_eq(index, owned and 2 + arrow.delta or 2,
						name .. ": only the configured chord moves the active prediction")
					checked = checked + 1
				end
			end
		end
		helpers.assert_eq(checked, 50, "every modifier set, chord and arrow is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) leaves arrows to the app over one prediction or when disabled", function()
		for _, arrow in ipairs(ARROWS) do
			local consumed = press_on_tooltip({
				count = 1, nav = {}, shortcut = EMPTY_CHORD_SHORTCUT,
				keycode = arrow.keycode, flags = flags_for({}, true),
			})
			helpers.assert_eq(consumed, false, arrow.name .. ": one prediction has nothing to move to")
			for _, set in ipairs(MODIFIER_SETS) do
				consumed = press_on_tooltip({
					count = 3, nav = { "none" }, shortcut = EMPTY_CHORD_SHORTCUT,
					keycode = arrow.keycode, flags = flags_for(set.mods, true),
				})
				helpers.assert_eq(consumed, false, arrow.name .. " " .. set.name .. ": navigation disabled")
			end
		end
	end)

	helpers.it("(llm-tooltip-chords-consumed) consumes nothing once the tooltip is gone", function()
		for _, arrow in ipairs(ARROWS) do
			local consumed = press_on_tooltip({
				count = 3, nav = {}, shortcut = EMPTY_CHORD_SHORTCUT, hidden = true,
				keycode = arrow.keycode, flags = flags_for({}, true),
			})
			helpers.assert_eq(consumed, false, arrow.name .. ": no tooltip, no navigation")
		end
		local consumed, _, accepted = press_on_tooltip({
			count = 3, nav = {}, shortcut = EMPTY_CHORD_SHORTCUT, hidden = true,
			keycode = KEYCODE_DIGIT_2, flags = {}, chars = "2",
		})
		helpers.assert_eq(consumed, false, "no tooltip: a digit is a digit")
		helpers.assert_eq(#accepted, 0)
	end)
end)

helpers.describe("prediction tooltip watcher: the validation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured digit chord", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				local owned = same_set(chord.mods, set.mods)
				local name = case_name("val", set.name, chord.label, "2")
				local consumed, _, accepted = press_on_tooltip({
					count = 3, nav = {}, shortcut = shortcut_for(set.mods),
					keycode = KEYCODE_DIGIT_2, flags = flags_for(chord.mods, false), chars = "2",
				})
				helpers.assert_eq(consumed, owned, name .. ": consumed only when it is the configured chord")
				helpers.assert_eq(accepted, owned and { 2 } or {}, name .. ": only the configured chord inserts")
				checked = checked + 1
			end
		end
		helpers.assert_eq(checked, 25, "every modifier set and chord is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) types a digit beyond the predictions shown", function()
		for _, set in ipairs(MODIFIER_SETS) do
			for _, digit in ipairs({ { keycode = KEYCODE_DIGIT_4, chars = "4" }, { keycode = KEYCODE_DIGIT_0, chars = "0" } }) do
				local consumed, _, accepted = press_on_tooltip({
					count = 3, nav = {}, shortcut = shortcut_for(set.mods),
					keycode = digit.keycode, flags = flags_for(set.mods, false), chars = digit.chars,
				})
				helpers.assert_eq(consumed, false, set.name .. "+" .. digit.chars .. ": beyond three predictions")
				helpers.assert_eq(#accepted, 0)
			end
		end
	end)
end)





-- ========================================================
-- ========================================================
-- ======= 3/ The keymap fallback (handle_llm_keys) =======
-- ========================================================
-- ========================================================

--- Presses one key through the real bridge over three visible predictions.
--- @param options table { nav, val, keycode, flags, visible?, count? }
--- @return boolean consumed, table moves, table accepted
local function press_on_bridge(options)
	return with_bridge_fixture(function(fixture)
		local predictions = {}
		for index = 1, options.count or 3 do predictions[index] = "prediction " .. index end
		fixture.engine_visible = options.visible ~= false
		fixture.predictions = predictions
		fixture.current_index = 2
		fixture.navigation_mods = options.nav
		fixture.validation_mods = options.val
		fixture.engine.set_llm_enabled(true)
		local moves, accepted = {}, {}
		fixture.engine.navigate = function(delta)
			moves[#moves + 1] = delta
			return true
		end
		fixture.bridge.apply_prediction = function(index)
			accepted[#accepted + 1] = index
			return true
		end
		local consumed = fixture.bridge.handle_llm_keys(options.keycode, options.flags, false)
		return consumed, moves, accepted
	end)
end

helpers.describe("keymap fallback: the navigation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured arrow chord, Up to the previous", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				for _, arrow in ipairs(ARROWS) do
					local owned = same_set(chord.mods, set.mods)
					local name = case_name("nav", set.name, chord.label, arrow.name)
					local consumed, moves = press_on_bridge({
						nav = set.mods, val = {}, keycode = arrow.keycode,
						flags = flags_for(chord.mods, true),
					})
					helpers.assert_eq(consumed, owned, name .. ": consumed only when it is the configured chord")
					helpers.assert_eq(moves, owned and { arrow.delta } or {},
						name .. ": the chord moves the way the tooltip watcher does")
					checked = checked + 1
				end
			end
		end
		helpers.assert_eq(checked, 50, "every modifier set, chord and arrow is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) leaves arrows to the app over one prediction, when disabled or hidden", function()
		for _, arrow in ipairs(ARROWS) do
			local flags = flags_for({}, true)
			helpers.assert_eq(press_on_bridge({ nav = {}, val = {}, keycode = arrow.keycode, flags = flags,
				count = 1 }), false, arrow.name .. ": one prediction")
			helpers.assert_eq(press_on_bridge({ nav = { "none" }, val = {}, keycode = arrow.keycode,
				flags = flags }), false, arrow.name .. ": navigation disabled")
			helpers.assert_eq(press_on_bridge({ nav = {}, val = {}, keycode = arrow.keycode, flags = flags,
				visible = false }), false, arrow.name .. ": no tooltip")
		end
	end)
end)

helpers.describe("keymap fallback: the validation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured digit chord", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				local owned = same_set(chord.mods, set.mods)
				local name = case_name("val", set.name, chord.label, "2")
				local consumed, _, accepted = press_on_bridge({
					nav = {}, val = set.mods, keycode = KEYCODE_DIGIT_2,
					flags = flags_for(chord.mods, false),
				})
				helpers.assert_eq(consumed, owned, name .. ": consumed only when it is the configured chord")
				helpers.assert_eq(accepted, owned and { 2 } or {}, name .. ": only the configured chord inserts")
				checked = checked + 1
			end
		end
		helpers.assert_eq(checked, 25, "every modifier set and chord is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) types a digit beyond the predictions, or with no tooltip", function()
		for _, set in ipairs(MODIFIER_SETS) do
			local flags = flags_for(set.mods, false)
			helpers.assert_eq(press_on_bridge({ nav = {}, val = set.mods, keycode = KEYCODE_DIGIT_4,
				flags = flags }), false, set.name .. "+4: beyond three predictions")
			helpers.assert_eq(press_on_bridge({ nav = {}, val = set.mods, keycode = KEYCODE_DIGIT_0,
				flags = flags }), false, set.name .. "+0: slot 10 is not shown")
			helpers.assert_eq(press_on_bridge({ nav = {}, val = set.mods, keycode = KEYCODE_DIGIT_2,
				flags = flags, visible = false }), false, set.name .. "+2: no tooltip")
		end
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 4/ The keymap tap after an idle pause =======
-- =====================================================
-- =====================================================

--- Loads the real keymap keyDown tap over a bridge whose tooltip shows three
--- predictions until something resets them.
--- @return table fixture
local function load_keymap()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name:match("^modules%.llm")
			or name == "adapters.synthetic_input" or name == "adapters.event_provenance") then
			package.loaded[name] = nil
		end
	end
	local calls = {}
	local visible = true
	local bridge = setmetatable({
		init = function() return true end,
		observe_action_epoch = function() end,
		reset_for_action_epoch = function() return true end,
		reset_predictions = function()
			calls[#calls + 1] = "reset"
			visible = false
		end,
		handle_llm_keys = function(keycode)
			calls[#calls + 1] = "route"
			return visible and (keycode == KEYCODE_DOWN or keycode == KEYCODE_DIGIT_2)
		end,
		update_preview = function() end,
		check_nav_reset = function() end,
		check_escape_reset = function() return false end,
		get_llm_enabled = function() return true end,
		is_runtime_available = function() return true end,
	}, { __index = function() return function() end end })
	package.loaded["modules.keymap.llm_bridge"] = bridge

	local state = nil
	local RealState = require("modules.keymap.state")
	package.loaded["modules.keymap.state"] = setmetatable({
		new = function(...)
			state = RealState.new(...)
			return state
		end,
	}, { __index = RealState })

	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_hs.eventtap) do eventtap[key] = value end
	eventtap.new = function(types, callback)
		local tap = {
			types = types, callback = callback, enabled = true,
			start = function(self) self.enabled = true; return self end,
			stop = function(self) self.enabled = false; return self end,
			isEnabled = function(self) return self.enabled end,
		}
		taps[#taps + 1] = tap
		return tap
	end
	helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
	local Utils = require("modules.keymap.utils")
	Utils.is_ignored_window = function() return false, 1 end
	Utils.is_secure_field = function() return false, 1 end
	local hs_stub = require("hs")
	local keydown = nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			keydown = tap.callback
			break
		end
	end
	helpers.assert_not_nil(keydown, "the production keyDown tap must be created")
	helpers.assert_not_nil(state, "the keymap must build its state through the state module")

	local function press(keycode, chars)
		local properties = hs_stub.eventtap.event.properties
		return keydown({
			getType = function() return hs_stub.eventtap.event.types.keyDown end,
			getKeyCode = function() return keycode end,
			getFlags = function() return keycode == KEYCODE_DOWN and { fn = true } or {} end,
			getCharacters = function() return chars or "" end,
			getProperty = function(_self, property)
				if property == properties.eventSourceUserData then return 0 end
				return hs_stub.processInfo.processID
			end,
		})
	end
	return {
		state = state,
		calls = calls,
		press = press,
		now = function() return hs_stub.timer.secondsSinceEpoch() end,
		show = function() visible = true end,
		cleanup = function()
			for name in pairs(package.loaded) do
				if type(name) == "string" and name:match("^modules%.keymap") then package.loaded[name] = nil end
			end
		end,
	}
end

helpers.describe("keymap tap: a tooltip chord after an idle pause (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) routes the chord to the tooltip before the idle wipe", function()
		local fixture = load_keymap()
		local ok, err = pcall(function()
			for _, key in ipairs({
				{ name = "the navigation chord", keycode = KEYCODE_DOWN },
				{ name = "the validation chord", keycode = KEYCODE_DIGIT_2, chars = "2" },
			}) do
				fixture.show()
				for index = #fixture.calls, 1, -1 do fixture.calls[index] = nil end
				fixture.state.WORD_TIMEOUT_SEC = 5
				fixture.state.last_key_time = fixture.now() - 60
				helpers.assert_eq(fixture.press(key.keycode, key.chars), true,
					key.name .. " pressed after reading the predictions must never reach the application")
				helpers.assert_eq(fixture.calls, { "route" },
					key.name .. " is the tooltip's before an idle pause can dismiss it")
			end

			-- A key the tooltip does not own still starts a fresh word after the pause.
			fixture.show()
			for index = #fixture.calls, 1, -1 do fixture.calls[index] = nil end
			fixture.state.buffer = "stale"
			fixture.state.last_key_time = fixture.now() - 60
			helpers.assert_eq(fixture.press(0, "a"), false, "a letter is typed")
			helpers.assert_eq(fixture.calls[1], "route")
			helpers.assert_eq(fixture.calls[2], "reset", "the idle wipe still dismisses the predictions")
		end)
		fixture.cleanup()
		if not ok then error(err, 0) end
	end)
end)

--- tests/unit/modules/llm/test_llm_tooltip_chords_consumed.lua

--- ==============================================================================
--- MODULE: Prediction Tooltip Chords Are Consumed, Every Other Chord Passes
--- DESCRIPTION:
--- The maintainer's rule, on every OS: while the AI tooltip shows predictions,
--- the configured navigation chord (llm.navigation.nav_modifiers + an arrow:
--- Up or Left for the previous prediction, Down or Right for the next, as the
--- shared menu.llm.nav_label says, or Shift+Tab, the left Shift back and the
--- right one forward, as the Windows and macOS footers say) moves the active
--- prediction and the configured validation chord
--- (llm.navigation.val_modifiers + digit N) inserts prediction N, and the
--- application never receives either. Any other modifier set (bare, a
--- superset, a subset or a different one) reaches the application unchanged,
--- as does a digit beyond the predictions shown, an arrow over a single
--- prediction, and every key once the tooltip is gone
--- (llm-tooltip-chords-consumed).
---
--- Linux had no navigation chord: Up and Down moved only an agent's actions,
--- bare, and reached the application over every other offer; Left and Right
--- then stayed the application's while macOS cycled on them. Its digit was the
--- character the key typed, so Shift+2 was "@" on a US layout and a validation
--- chord holding Shift never accepted anything. The expected verdict is computed
--- here from set equality of the held and configured modifiers.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local EvdevCodes = require("infra.evdev_codes")
local Fakes = require("tests.fakes")

local NAVIGATION_KEY = "llm.navigation.nav_modifiers"
local VALIDATION_KEY = "llm.navigation.val_modifiers"
local WORDS = { "est bien faite", "va très bien", "reste très simple" }
local KEY_2 = 3
local KEY_4 = 5
local KEY_0 = 11
local EV_KEY = 1

-- The active prediction each arrow selects from the first of three: Up and
-- Left step back and wrap to the last, Down and Right step forward.
local ARROWS = {
	{ name = "Up", code = EvdevCodes.KEY_UP, target = 3 },
	{ name = "Down", code = EvdevCodes.KEY_DOWN, target = 2 },
	{ name = "Left", code = EvdevCodes.KEY_LEFT, target = 3 },
	{ name = "Right", code = EvdevCodes.KEY_RIGHT, target = 2 },
}

-- Each configured modifier set, with a superset (one modifier added), a
-- different set and, for a combination, a subset. cmd is the Super key.
local MODIFIER_SETS = {
	{ name = "none", mods = {}, superset = { "shift" }, other = { "alt" } },
	{ name = "shift", mods = { "shift" }, superset = { "ctrl", "shift" }, other = { "alt" } },
	{ name = "ctrl", mods = { "ctrl" }, superset = { "ctrl", "shift" }, other = { "alt" } },
	{ name = "alt", mods = { "alt" }, superset = { "alt", "shift" }, other = { "ctrl" } },
	{ name = "cmd", mods = { "cmd" }, superset = { "shift", "cmd" }, other = { "alt" } },
	{
		name = "ctrl+shift", mods = { "ctrl", "shift" },
		superset = { "ctrl", "alt", "shift" }, other = { "alt" }, subset = { "shift" },
	},
}

local FAKED = {
	"infra.llm_preferences", "adapters.secure_field_detector",
	"modules.llm.api_ollama", "modules.llm.profiles",
}
local RELOADED = {
	"modules.llm.navigation_settings", "modules.llm.display_settings", "modules.llm.prediction_engine", "ui.tooltip.llm",
	"adapters.keyboard_hook",
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

--- Lists the chords held against one configured set.
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

--- The keyboard hook's held-modifier record for a chord.
--- @param mods table Modifier names.
--- @return table held
local function held_for(mods)
	local held = {}
	for _, name in ipairs(mods) do held[name == "cmd" and "meta" or name] = true end
	return held
end

--- What the US layout's 2 key types under a chord: Shift makes it "@".
--- @param held table
--- @return string
local function two_key_identity(held)
	return held.shift and "@" or "2"
end





-- ==========================================
-- ==========================================
-- ======= 2/ An Offer On The Tooltip =======
-- ==========================================
-- ==========================================

--- Offers `count` predictions on the real tooltip, under the given chords.
--- @param options table { nav, val, count? }
--- @param body function Receives { engine, overlay, applied, drive }.
local function with_offer(options, body)
	local previous = {}
	for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
	for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name] end
	local ok, err = pcall(function()
		package.loaded["infra.llm_preferences"] = PreferencesFixture.new({ initial = {
			[NAVIGATION_KEY] = options.nav, [VALIDATION_KEY] = options.val,
			["llm.display.streaming_multi"] = options.progressive,
			["llm.display.streaming"] = options.streaming,
		} })
		helpers.load_module("modules.llm.navigation_settings")._reset()
		helpers.load_module("modules.llm.display_settings")._reset()
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
		}
		-- Each sequential request answers the next prediction.
		local requests = 0
		local frames = {}
		local callbacks = {}
		package.loaded["modules.llm.api_ollama"] = {
			chat = function(_, _, _, _, on_chunk, on_done)
				requests = requests + 1
				local text = " " .. WORDS[requests]
				callbacks[#callbacks + 1] = { chunk = on_chunk, done = on_done }
				on_chunk(text)
				on_done(text, nil)
			end,
			cancel = function() end,
		}
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return true end,
			get_current_model = function() return "test-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		local overlay = helpers.load_module("ui.tooltip.llm")
		helpers.assert_true(overlay.init({ style = {}, renderer = {
				show = function(rows)
					local count = 0
					for _, row in ipairs(rows) do
						for _, word in ipairs(WORDS) do
							if row.segments and row.segments[1].text == word then count = count + 1 end
						end
					end
					frames[#frames + 1] = count
					return true
				end,
			hide = function() return true end,
		} }), "the real tooltip must accept a renderer double")
		local world = { overlay = overlay, applied = {}, frames = frames, callbacks = callbacks }
		local scheduler = Fakes.timer_scheduler()
		world.engine = helpers.load_module("modules.llm.prediction_engine")
		world.engine.init({
			overlay = overlay,
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			apply_prediction = function(candidate)
				world.applied[#world.applied + 1] = candidate.to_type
				return true
			end,
		})
		world.engine.predict("Bonjour //", { app_id = "editor", input_chars = 2 },
			{ num_predictions = options.count or 3 })
		for _ = 1, 20 do
			if not world.engine.is_predicting() then break end
			scheduler.test.advance(0.5)
		end
		helpers.assert_eq(#world.engine.get_suggestions(), options.count or 3,
			"the tooltip must show the offered predictions")
		--- Types evdev events through the real keyboard hook in intercept mode.
		--- @return table emitted "code:value" of every event the application receives
		function world.drive(events)
			local hook = helpers.load_module("adapters.keyboard_hook")
			local emitted = {}
			hook._test_drive(events, {
				onConsume = function(detail) return world.engine.handle_shortcut(detail) end,
				onEmitRaw = function(code, value)
					emitted[#emitted + 1] = code .. ":" .. value
					return true
				end,
			}, true)
			return emitted
		end
		body(world)
		world.engine.dismiss()
	end)
	for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
	for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end





-- =======================================
-- =======================================
-- ======= 3/ The Navigation Chord =======
-- =======================================
-- =======================================

helpers.describe("prediction tooltip: the navigation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured arrow chord", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				for _, arrow in ipairs(ARROWS) do
					local owned = same_set(chord.mods, set.mods)
					local name = string.format("nav %s: %s %s", set.name, chord.label, arrow.name)
					with_offer({ nav = set.mods, val = {} }, function(world)
						helpers.assert_eq(world.engine.handle_shortcut({
							code = arrow.code, mods = held_for(chord.mods),
						}), owned, name .. ": consumed only when it is the configured chord")
						helpers.assert_eq(world.overlay.active_index(), owned and arrow.target or 1,
							name .. ": only the configured chord moves the active prediction")
						helpers.assert_eq(#world.applied, 0, name .. ": navigating inserts nothing")
					end)
					checked = checked + 1
				end
			end
		end
		helpers.assert_eq(checked, 100, "every modifier set, chord and arrow is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) leaves arrows to the app over one prediction or no tooltip", function()
		for _, arrow in ipairs(ARROWS) do
			with_offer({ nav = {}, val = {}, count = 1 }, function(world)
				helpers.assert_eq(world.engine.handle_shortcut({ code = arrow.code, mods = {} }), false,
					arrow.name .. ": one prediction has nothing to move to")
			end)
			with_offer({ nav = {}, val = {} }, function(world)
				helpers.assert_true(world.overlay.hide())
				helpers.assert_eq(world.engine.handle_shortcut({ code = arrow.code, mods = {} }), false,
					arrow.name .. ": no tooltip, no navigation")
			end)
		end
	end)

	helpers.it("(llm-tooltip-chords-consumed) holds either side's modifier, AltGr being no Alt", function()
		local sides = {
			{ nav = { "shift" }, codes = { EvdevCodes.KEY_LEFTSHIFT, EvdevCodes.KEY_RIGHTSHIFT } },
			{ nav = { "ctrl" }, codes = { EvdevCodes.KEY_LEFTCTRL, EvdevCodes.KEY_RIGHTCTRL } },
			{ nav = { "cmd" }, codes = { EvdevCodes.KEY_LEFTMETA, EvdevCodes.KEY_RIGHTMETA } },
			{ nav = { "alt" }, codes = { EvdevCodes.KEY_LEFTALT } },
		}
		for _, side in ipairs(sides) do
			for _, code in ipairs(side.codes) do
				for _, arrow in ipairs({ EvdevCodes.KEY_DOWN, EvdevCodes.KEY_RIGHT }) do
					with_offer({ nav = side.nav, val = {} }, function(world)
						local emitted = world.drive({
							{ type = EV_KEY, code = code, value = 1 },
							{ type = EV_KEY, code = arrow, value = 1 },
							{ type = EV_KEY, code = arrow, value = 0 },
							{ type = EV_KEY, code = code, value = 0 },
						})
						helpers.assert_eq(table.concat(emitted, " "), code .. ":1 " .. code .. ":0",
							side.nav[1] .. " on key " .. code .. ": the application never sees the chord's arrow "
								.. arrow)
						helpers.assert_eq(world.overlay.active_index(), 2)
					end)
				end
			end
		end
		with_offer({ nav = { "alt" }, val = {} }, function(world)
			local altgr = EvdevCodes.KEY_RIGHTALT
			local emitted = world.drive({
				{ type = EV_KEY, code = altgr, value = 1 },
				{ type = EV_KEY, code = EvdevCodes.KEY_DOWN, value = 1 },
				{ type = EV_KEY, code = EvdevCodes.KEY_DOWN, value = 0 },
				{ type = EV_KEY, code = altgr, value = 0 },
			})
			helpers.assert_eq(table.concat(emitted, " "), string.format("%d:1 %d:1 %d:0 %d:0",
				altgr, EvdevCodes.KEY_DOWN, EvdevCodes.KEY_DOWN, altgr), "AltGr+Down is the application's")
			helpers.assert_eq(world.overlay.active_index(), 1)
		end)
	end)
end)





helpers.describe("prediction tooltip: Shift+Tab (llm-nav-left-right-windows)", function()
	--- Types Shift+Tab with the given Shift keys held, through the real hook.
	--- @return table emitted
	local function shift_tab(world, shifts, extra)
		local events = {}
		for _, code in ipairs(extra or {}) do events[#events + 1] = { type = EV_KEY, code = code, value = 1 } end
		for _, code in ipairs(shifts) do events[#events + 1] = { type = EV_KEY, code = code, value = 1 } end
		events[#events + 1] = { type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 }
		events[#events + 1] = { type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 }
		for _, code in ipairs(shifts) do events[#events + 1] = { type = EV_KEY, code = code, value = 0 } end
		for _, code in ipairs(extra or {}) do events[#events + 1] = { type = EV_KEY, code = code, value = 0 } end
		return world.drive(events)
	end

	--- Asserts that a verdict is false.
	local function assert_false(value, message) helpers.assert_eq(value, false, message) end

	--- Whether the application received the Tab.
	local function saw_tab(emitted)
		for _, event in ipairs(emitted) do
			if event == EvdevCodes.KEY_TAB .. ":1" then return true end
		end
		return false
	end

	helpers.it("(llm-nav-left-right-windows) the left Shift steps back, the right one forward, whatever nav_modifiers", function()
		local checked = 0
		for _, nav in ipairs({ {}, { "ctrl" }, { "alt", "shift" } }) do
			local label = #nav > 0 and table.concat(nav, "+") or "none"
			with_offer({ nav = nav, val = {} }, function(world)
				assert_false(saw_tab(shift_tab(world, { EvdevCodes.KEY_LEFTSHIFT })),
					label .. ": the application never sees the left Shift+Tab")
				helpers.assert_eq(world.overlay.active_index(), 3, label .. ": left Shift+Tab wraps back to the last")
				assert_false(saw_tab(shift_tab(world, { EvdevCodes.KEY_RIGHTSHIFT })),
					label .. ": the application never sees the right Shift+Tab")
				helpers.assert_eq(world.overlay.active_index(), 1, label .. ": right Shift+Tab wraps forward to the first")
				assert_false(saw_tab(shift_tab(world, { EvdevCodes.KEY_RIGHTSHIFT })))
				helpers.assert_eq(world.overlay.active_index(), 2, label .. ": right Shift+Tab steps forward")
				helpers.assert_eq(#world.applied, 0, label .. ": navigating inserts nothing")
				checked = checked + 1
			end)
		end
		helpers.assert_eq(checked, 3, "every navigation configuration is checked")
	end)

	helpers.it("(llm-nav-left-right-windows) any other Shift+Tab, one prediction or no tooltip reaches the application", function()
		with_offer({ nav = {}, val = {} }, function(world)
			helpers.assert_true(saw_tab(shift_tab(world, { EvdevCodes.KEY_LEFTSHIFT, EvdevCodes.KEY_RIGHTSHIFT })),
				"both Shifts name no side")
			helpers.assert_true(saw_tab(shift_tab(world, { EvdevCodes.KEY_LEFTSHIFT }, { EvdevCodes.KEY_LEFTCTRL })),
				"Ctrl+Shift+Tab is the application's")
			helpers.assert_true(saw_tab(shift_tab(world, { EvdevCodes.KEY_RIGHTSHIFT }, { EvdevCodes.KEY_LEFTALT })),
				"Alt+Shift+Tab is the application's")
			helpers.assert_eq(world.overlay.active_index(), 1, "no other chord moves the active prediction")
		end)
		with_offer({ nav = {}, val = {}, count = 1 }, function(world)
			helpers.assert_true(saw_tab(shift_tab(world, { EvdevCodes.KEY_LEFTSHIFT })),
				"one prediction has nothing to move to")
		end)
		with_offer({ nav = {}, val = {} }, function(world)
			helpers.assert_true(world.overlay.hide())
			helpers.assert_true(saw_tab(shift_tab(world, { EvdevCodes.KEY_RIGHTSHIFT })), "no tooltip, no navigation")
		end)
	end)

	helpers.it("(llm-nav-left-right-windows) the hook names the side of the one Shift held", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local sides = {}
		hook._test_drive({
			{ type = EV_KEY, code = EvdevCodes.KEY_LEFTSHIFT, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 },
			{ type = EV_KEY, code = EvdevCodes.KEY_RIGHTSHIFT, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 },
			{ type = EV_KEY, code = EvdevCodes.KEY_LEFTSHIFT, value = 0 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 },
			{ type = EV_KEY, code = EvdevCodes.KEY_RIGHTSHIFT, value = 0 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 },
		}, {
			onConsume = function(detail)
				if detail.code == EvdevCodes.KEY_TAB then sides[#sides + 1] = tostring(detail.shift_side) end
				return false
			end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_eq(table.concat(sides, " "), "left nil right nil",
			"left, both, right, then no Shift")
	end)
end)





-- =======================================
-- =======================================
-- ======= 4/ The Validation Chord =======
-- =======================================
-- =======================================

helpers.describe("prediction tooltip: the validation chord (llm-tooltip-chords-consumed)", function()
	helpers.it("(llm-tooltip-chords-consumed) consumes exactly the configured digit chord", function()
		local checked = 0
		for _, set in ipairs(MODIFIER_SETS) do
			for _, chord in ipairs(chords_for(set)) do
				local owned = same_set(chord.mods, set.mods)
				local name = string.format("val %s: %s 2", set.name, chord.label)
				with_offer({ nav = {}, val = set.mods }, function(world)
					local held = held_for(chord.mods)
					helpers.assert_eq(world.engine.handle_shortcut({
						code = KEY_2, key = two_key_identity(held), mods = held,
					}), owned, name .. ": consumed only when it is the configured chord")
					helpers.assert_eq(world.applied, owned and { WORDS[2] } or {},
						name .. ": only the configured chord inserts prediction 2")
				end)
				checked = checked + 1
			end
		end
		helpers.assert_eq(checked, 25, "every modifier set and chord is checked")
	end)

	helpers.it("(llm-tooltip-chords-consumed) types a digit beyond the predictions, or with no tooltip", function()
		for _, set in ipairs(MODIFIER_SETS) do
			local held = held_for(set.mods)
			with_offer({ nav = {}, val = set.mods }, function(world)
				helpers.assert_eq(world.engine.handle_shortcut({ code = KEY_4, key = "4", mods = held }), false,
					set.name .. "+4: beyond three predictions")
				helpers.assert_eq(world.engine.handle_shortcut({ code = KEY_0, key = "0", mods = held }), false,
					set.name .. "+0: slot 10 is not shown")
				helpers.assert_true(world.overlay.hide())
				helpers.assert_eq(world.engine.handle_shortcut({
					code = KEY_2, key = two_key_identity(held), mods = held,
				}), false, set.name .. "+2: no tooltip")
				helpers.assert_eq(#world.applied, 0)
			end)
		end
	end)

	helpers.it("(llm-tooltip-chords-consumed) Shift on either side with the 2 key inserts prediction 2", function()
		for _, shift in ipairs({ EvdevCodes.KEY_LEFTSHIFT, EvdevCodes.KEY_RIGHTSHIFT }) do
			with_offer({ nav = {}, val = { "shift" } }, function(world)
				local emitted = world.drive({
					{ type = EV_KEY, code = shift, value = 1 },
					{ type = EV_KEY, code = KEY_2, value = 1 },
					{ type = EV_KEY, code = KEY_2, value = 0 },
					{ type = EV_KEY, code = shift, value = 0 },
				})
				helpers.assert_eq(table.concat(emitted, " "), shift .. ":1 " .. shift .. ":0",
					"key " .. shift .. ": the application never sees the @ the chord would type")
				helpers.assert_eq(world.applied, { WORDS[2] })
			end)
		end
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 5/ A Tap-Hold's Tab Is The User's Tab =======
-- =====================================================
-- =====================================================

--- Every consume decision the hook asks for while typing `events` with the
--- tap-hold engine holding `keys`.
--- @return table details { code, mods }
local function consumed_details(keys, events)
	local Engine = require("platform.remap.tap_hold_engine")
	local hook = helpers.load_module("adapters.keyboard_hook")
	hook.set_remapper(Engine.new({ keys = keys, tap_min_ms = 0, one_shot_timeout_ms = 2000 }))
	local details = {}
	local ok, err = pcall(hook._test_drive, events, {
		onConsume = function(detail)
			details[#details + 1] = { code = detail.code, mods = detail.mods }
			return false
		end,
		onEmitRaw = function() return true end,
	}, true)
	hook.set_remapper(nil)
	if not ok then error(err, 0) end
	return details
end

helpers.describe("prediction tooltip: a tap-hold's Tab (llm-accept-inserts)", function()
	helpers.it("(llm-accept-inserts) the engine's AltGr Tab tap asks the tooltip as a bare physical Tab does", function()
		-- The shipped tap-holds tap Tab with AltGr. The engine dispatches its tap
		-- as the key it emits, so the tooltip receives the same bare Tab and
		-- accepts or leaves it exactly as it does the Tab key's.
		local KEYS = { alt_gr = { tap_action = "tab", hold_modifier = "alt_gr",
			time_activation_seconds = 10 } }
		local from_tap = consumed_details(KEYS, {
			{ type = EV_KEY, code = EvdevCodes.KEY_RIGHTALT, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_RIGHTALT, value = 0 },
		})
		local tabs = {}
		for _, detail in ipairs(from_tap) do
			if detail.code == EvdevCodes.KEY_TAB then tabs[#tabs + 1] = detail end
		end
		helpers.assert_eq(#tabs, 1, "the AltGr tap must reach the tooltip as one Tab press")
		local from_key = consumed_details({}, {
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 1 },
			{ type = EV_KEY, code = EvdevCodes.KEY_TAB, value = 0 },
		})
		helpers.assert_eq(#from_key, 1)
		helpers.assert_eq(tabs[1].mods, from_key[1].mods,
			"with nothing held, the tapped Tab carries the physical Tab's (empty) modifiers")
	end)
end)





-- =========================================
-- =========================================
-- ======= 7/ Display Event Polarity =======
-- =========================================
-- =========================================

--- Reads event expectations independent of the production display condition.
--- @return table
local function display_events_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/show_all_control.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("prediction tooltip: canonical progressive display", function()
	helpers.it("shows intermediate completed variants only under progressive display (shared-show-all-events)", function()
		local corpus = display_events_corpus()
		helpers.assert_eq(#corpus.sequential_events, 2)
		for _, expected in ipairs(corpus.sequential_events) do
			with_offer({nav = {}, val = {}, count = 2, progressive = expected.progressive, streaming = false}, function(world)
				local intermediate, final = 0, 0
				for _, count in ipairs(world.frames) do
					if count == 1 then intermediate = intermediate + 1 end
					if count == 2 then final = final + 1 end
				end
				helpers.assert_eq(intermediate, expected.intermediate_frames)
				helpers.assert_eq(final, expected.final_frames)
				helpers.assert_eq(#world.callbacks, 2, "both real sequential callback paths execute")
			end)
		end
	end)

	helpers.it("does not paint retired chunks or completions under either display polarity (shared-show-all-events)", function()
		for _, expected in ipairs(display_events_corpus().sequential_events) do
			with_offer({nav = {}, val = {}, count = 2, progressive = expected.progressive, streaming = false}, function(world)
				world.engine.cancel()
				local before = #world.frames
				for _, callback in ipairs(world.callbacks) do
					callback.chunk("retired candidate")
					callback.done("retired candidate", nil)
				end
				helpers.assert_eq(#world.frames, before)
				helpers.assert_eq(#world.engine.get_suggestions(), 0)
			end)
		end
	end)
end)

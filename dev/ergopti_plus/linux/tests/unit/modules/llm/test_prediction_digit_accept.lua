--- tests/unit/modules/llm/test_prediction_digit_accept.lua

--- ==============================================================================
--- MODULE: Accepting Prediction N With The Digit N
--- DESCRIPTION:
--- By default a bare digit accepts the prediction it numbers; the AI menu can
--- require a modifier instead. While the tooltip shows predictions, the digit
--- of a shown one is the instruction to insert it and never text, even when
--- the insertion fails; a digit beyond them, or with no tooltip, types.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

--- A prediction engine offering `count` predictions on a visible tooltip.
--- @return table engine, table state { applied, visible, storage restore }
local function offering(count, apply_ok)
	local state = { applied = {}, visible = true }
	-- The chord is read once, from a throwaway store holding nothing: the
	-- shipped default. The engine keeps the real store it predicts with.
	local previous_storage = package.loaded["adapters.storage"]
	package.loaded["adapters.storage"] = Fakes.storage()
	local Navigation = helpers.load_module("modules.llm.navigation_settings")
	Navigation._reset()
	Navigation.get()
	package.loaded["adapters.storage"] = previous_storage
	state.previous_focus = package.loaded["adapters.secure_field_detector"]
	package.loaded["adapters.secure_field_detector"] = {
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
	}
	local reply = {}
	local words = { "est bien faite", "va très bien", "reste simple" }
	for index = 1, count do reply[index] = words[index] end
	package.loaded["modules.llm.api_ollama"] = {
		chat = function(_, _, _, _, on_chunk, on_done)
			local text = " " .. table.concat(reply, "\n")
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
	local engine = helpers.load_module("modules.llm.prediction_engine")
	engine.init({
		overlay = {
			show = function() state.visible = true; return true end,
			hide = function() state.visible = false end,
			is_showing = function() return state.visible end,
			-- The window is not mapped yet: the offer is presented all the same.
			is_visible = function() return false end,
		},
		apply_prediction = function(candidate)
			state.applied[#state.applied + 1] = candidate.to_type
			return apply_ok ~= false
		end,
	})
	engine.predict("Bonjour //", { app_id = "editor", input_chars = 2 })
	function state.restore()
		package.loaded["adapters.secure_field_detector"] = state.previous_focus
		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		helpers.load_module("modules.llm.navigation_settings")._reset()
	end
	return engine, state
end

local function with_offer(count, body, apply_ok)
	local engine, state = offering(count, apply_ok)
	local ok, err = pcall(body, engine, state)
	state.restore()
	if not ok then error(err, 0) end
end

helpers.describe("prediction digit accept: the engine", function()

	helpers.it("accepts prediction N with the bare digit N by default", function()
		with_offer(1, function(engine, state)
			helpers.assert_true(engine.has_suggestions(), "an offer is shown")
			helpers.assert_true(engine.handle_shortcut({ key = "1", mods = {} }), "the digit is consumed")
			helpers.assert_eq(#state.applied, 1, "and prediction 1 is inserted")
			helpers.assert_true(not engine.has_suggestions(), "the offer is spent")
		end)
	end)

	helpers.it("types a digit beyond the predictions on offer", function()
		with_offer(1, function(engine, state)
			helpers.assert_true(not engine.handle_shortcut({ key = "7", mods = {} }), "7 with one shown is text")
			helpers.assert_eq(#state.applied, 0)
			helpers.assert_true(engine.has_suggestions(), "the offer stays")
		end)
	end)

	helpers.it("swallows the digit even when the insertion fails", function()
		with_offer(1, function(engine)
			helpers.assert_true(engine.handle_shortcut({ key = "1", mods = {} }))
		end, false)
	end)

	helpers.it("lets digits type when no tooltip is shown", function()
		with_offer(1, function(engine, state)
			state.visible = false
			helpers.assert_true(not engine.handle_shortcut({ key = "1", mods = {} }), "hidden: a digit is a digit")
			engine.dismiss()
			helpers.assert_true(not engine.handle_shortcut({ key = "1", mods = {} }), "no offer: a digit is a digit")
		end)
	end)

	helpers.it("lets a digit with another modifier through, and a letter too", function()
		with_offer(1, function(engine)
			helpers.assert_true(not engine.handle_shortcut({ key = "1", mods = { shift = true } }), "Shift+1 is !")
			helpers.assert_true(not engine.handle_shortcut({ key = "1", mods = { ctrl = true } }))
			helpers.assert_true(not engine.handle_shortcut({ key = "a", mods = {} }))
		end)
	end)

	helpers.it("requires the modifier chosen in the AI menu", function()
		with_offer(1, function(engine, state)
			local previous_storage = package.loaded["adapters.storage"]
			package.loaded["adapters.storage"] = Fakes.storage()
			helpers.assert_true(require("modules.llm.navigation_settings").set({ "alt" }))
			package.loaded["adapters.storage"] = previous_storage
			helpers.assert_true(not engine.handle_shortcut({ key = "1", mods = {} }), "a bare 1 now types")
			helpers.assert_true(engine.handle_shortcut({ key = "1", mods = { alt = true } }))
			helpers.assert_eq(#state.applied, 1)
		end)
	end)

	helpers.it("reads the keypad digits, and 0 as prediction 10", function()
		with_offer(1, function(engine, state)
			helpers.assert_true(not engine.handle_shortcut({ key = "0", mods = {} }), "0 is slot 10: not on offer, typed")
			helpers.assert_eq(#state.applied, 0)
			helpers.assert_true(engine.handle_shortcut({ key = "KP_1", mods = {} }))
			helpers.assert_eq(#state.applied, 1)
		end)
	end)

end)

helpers.describe("prediction digit accept: through the keyboard hook", function()

	helpers.it("never lets the accepting digit reach the application", function()
		with_offer(1, function(engine, state)
			local hook = helpers.load_module("adapters.keyboard_hook")
			local emitted, chars = {}, {}
			hook._test_drive({
				{ type = 1, code = 2, value = 1 },
				{ type = 1, code = 2, value = 0 },
				{ type = 1, code = 3, value = 1 },
				{ type = 1, code = 3, value = 0 },
			}, {
				onConsume = function(detail) return engine.handle_shortcut(detail) end,
				onChar = function(char) chars[#chars + 1] = char end,
				onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
			}, true)
			helpers.assert_eq(table.concat(emitted, " "), "3:1 3:0", "1 swallowed, the next digit types")
			helpers.assert_eq(table.concat(chars), "2")
			helpers.assert_eq(#state.applied, 1)
		end)
	end)

end)

helpers.describe("prediction digit accept: a digit beyond the offer", function()

	helpers.it("reaches the application through the hook, and keeps the offer", function()
		with_offer(1, function(engine, state)
			local hook = helpers.load_module("adapters.keyboard_hook")
			local emitted = {}
			hook._test_drive({
				{ type = 1, code = 4, value = 1 },
				{ type = 1, code = 4, value = 0 },
			}, {
				onConsume = function(detail) return engine.handle_shortcut(detail) end,
				onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
			}, true)
			helpers.assert_eq(table.concat(emitted, " "), "4:1 4:0", "3 with one prediction shown is typed")
			helpers.assert_eq(#state.applied, 0)
		end)
	end)

end)

helpers.describe("prediction digit accept: the real tooltip's presented state", function()

	helpers.it("presents candidates before its window maps, and none once hidden", function()
		local overlay = helpers.load_module("ui.tooltip.llm")
		pcall(overlay.show, { { to_type = "va bien" } }, {})
		helpers.assert_true(overlay.is_showing(), "presented, whether or not the window is up yet")
		overlay.hide()
		helpers.assert_true(not overlay.is_showing(), "hidden by any path: nothing to accept")
	end)

end)

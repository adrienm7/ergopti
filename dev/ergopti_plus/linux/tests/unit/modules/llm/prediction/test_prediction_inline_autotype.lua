--- tests/unit/modules/llm/prediction/test_prediction_inline_autotype.lua

--- ==============================================================================
--- MODULE: Inline Auto-Type On Linux
--- DESCRIPTION:
--- The Windows inline mode, the most complete driver's (maintainer decision of
--- 2026-11-06): with llm.trigger.inline_autotype on, a finished prediction is
--- typed into the document through the same acceptance as Tab, instead of
--- waiting on offer. Off, the prediction is offered as before.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A prediction engine offering `count` predictions on a visible tooltip.
--- @return table engine, table state { applied, visible, storage restore }
local function offering(count, apply_ok, inline)
	local state = { applied = {}, visible = true }
	-- The chord is read once, from a throwaway store holding nothing: the
	-- shipped default. The engine keeps the real store it predicts with.
	local previous_storage = package.loaded["infra.llm_preferences"]
	package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new()
	local Navigation = helpers.load_module("modules.llm.navigation_settings")
	Navigation._reset()
	Navigation.get()
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
	-- The inline switch as config.toml would hold it; every other trigger
	-- setting keeps its stored value.
	local Trigger = require("modules.llm.trigger_settings")
	state.previous_get = Trigger.get
	Trigger.get = function(name, ...)
		if name == require("config_keys").LEAF.INLINE_AUTOTYPE then return inline == true end
		return state.previous_get(name, ...)
	end
	local engine = helpers.load_module("modules.llm.prediction_engine")
	engine.init({ focus_id = function() return "owned-prediction-window" end,
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
		require("modules.llm.trigger_settings").get = state.previous_get
		package.loaded["infra.llm_preferences"] = previous_storage
		package.loaded["adapters.secure_field_detector"] = state.previous_focus
		package.loaded["modules.llm.api_ollama"] = nil
		package.loaded["modules.llm.profiles"] = nil
		helpers.load_module("modules.llm.navigation_settings")._reset()
	end
	return engine, state
end

local function with_offer(count, body, apply_ok, inline)
	local engine, state = offering(count, apply_ok, inline)
	local ok, err = pcall(body, engine, state)
	state.restore()
	if not ok then error(err, 0) end
end

helpers.describe("prediction inline auto-type (llm-inline-autotype-linux)", function()
	helpers.it("(llm-inline-autotype-linux) types the finished prediction through the acceptance path", function()
		with_offer(1, function(engine, state)
			helpers.assert_eq(state.applied, { "est bien faite" }, "the prediction reached the document")
			helpers.assert_true(not engine.has_suggestions(), "nothing waits on offer")
		end, true, true)
	end)

	helpers.it("(llm-inline-autotype-linux) types one variant only", function()
		with_offer(3, function(_, state)
			helpers.assert_eq(#state.applied, 1, "typing several alternatives would be chaos")
		end, true, true)
	end)

	helpers.it("(llm-inline-autotype-linux) off, the prediction waits on offer", function()
		with_offer(1, function(engine, state)
			helpers.assert_eq(#state.applied, 0)
			helpers.assert_true(engine.has_suggestions())
		end, true, false)
	end)
end)

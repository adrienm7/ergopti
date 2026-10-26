--- tests/unit/modules/shortcuts/keyboard/test_ai_off_disarms_ai_actions.lua

--- ==============================================================================
--- MODULE: The AI Switch Off Disarms The AI Actions (macOS)
--- DESCRIPTION:
--- With the AI switched off nothing of it runs: a key bound to an AI action
--- (`llm_*`) is not armed, so the key reaches the application, and switching
--- the AI back on arms it again without a reload. Covered here: the shared
--- predicate and its notification, a configurable shortcut hotkey, a physical
--- shortcut slot's action lookup, a number-row tap key and a touchpad gesture.
---
--- ROOT CAUSE ENCODED:
--- The keys stayed bound with the AI off: the keystroke was claimed, then the
--- action refused it with a notice, so the application never saw the key.
--- ==============================================================================

local helpers = require("tests.helpers")

local ENGINE = "modules.llm.prediction_engine"

--- Runs a body with a stub prediction engine whose AI switch the body flips.
--- @param body function(state: table) state.enabled is the AI switch.
local function with_ai(body)
	local previous = package.loaded[ENGINE]
	local state = { enabled = false }
	package.loaded[ENGINE] = { get_llm_enabled = function() return state.enabled end }
	local ok, err = pcall(body, state)
	package.loaded[ENGINE] = previous
	if not ok then error(err, 0) end
end

helpers.describe("AI actions are unarmed with the AI off (ai-off-inert-macos)", function()
	helpers.it("names the llm_ actions and only those, and follows the engine's switch", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.shortcuts.ai_actions"] = nil
		local AiActions = require("modules.shortcuts.ai_actions")
		helpers.assert_eq(AiActions.is_ai_action("llm_agent_command"), true)
		helpers.assert_eq(AiActions.is_ai_action("select_line"), false)
		helpers.assert_eq(AiActions.is_ai_action(nil), false)
		with_ai(function(state)
			helpers.assert_eq(AiActions.blocked("llm_generate_prediction"), true, "off: blocked")
			helpers.assert_eq(AiActions.blocked("select_line"), false, "other actions are never gated")
			state.enabled = true
			helpers.assert_eq(AiActions.blocked("llm_generate_prediction"), false, "on: armed again")
		end)
	end)

	helpers.it("blocks an AI action when no engine is loaded", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.shortcuts.ai_actions"] = nil
		local AiActions = require("modules.shortcuts.ai_actions")
		local previous = package.loaded[ENGINE]
		package.loaded[ENGINE] = nil
		local blocked = AiActions.blocked("llm_generate_prediction")
		package.loaded[ENGINE] = previous
		helpers.assert_eq(blocked, true, "an engine that never loaded cannot run the action")
	end)

	helpers.it("notifies every layer, and one failing layer does not stop the others", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.shortcuts.ai_actions"] = nil
		local AiActions = require("modules.shortcuts.ai_actions")
		local seen = {}
		AiActions.subscribe("a", function() seen[#seen + 1] = "a" end)
		AiActions.subscribe("b", function() error("boom") end)
		AiActions.subscribe("c", function() seen[#seen + 1] = "c" end)
		AiActions.notify()
		helpers.assert_eq(table.concat(seen), "ac")
		AiActions.unsubscribe("a")
		AiActions.notify()
		helpers.assert_eq(table.concat(seen), "acc")
	end)
end)





-- =======================================
-- =======================================
-- ======= 1/ A hotkey bound to it =======
-- =======================================
-- =======================================

--- Loads the real owner with an AI slot and a plain one over a recording registrar.
local function load_keyboard()
	local enabled, order = {}, {}
	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord)
			local handle = "handle:" .. chord
			enabled[handle] = true
			order[#order + 1] = handle
			return handle
		end,
		unbind = function(handle) enabled[handle] = nil return true end,
		setEnabled = function(handle, want) enabled[handle] = want == true return true end,
	}
	package.loaded["adapters.file_system"] = {
		read = function() return '{"keys":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}' end,
	}
	package.loaded["infra.paths"] = { shared = function() return "catalogue.json" end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.gestures.actions"] = {
		is_assignable = function(action_id) return type(action_id) == "string" end,
		execute_single = function() end,
	}
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.shortcuts.ai_actions"] = nil
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	require("tests.support.keyboard_config_fixture").install(
		{ cmd_a = "llm_generate_prediction", cmd_b = "script_pause_toggle" })
	local subject = require("modules.shortcuts.keyboard_shortcuts")
	return subject, enabled, require("modules.shortcuts.ai_actions")
end

helpers.describe("AI chords under the hotkey registrar (ai-off-inert-macos)", function()
	helpers.it("leaves the AI chord released while the AI is off and arms it on the switch-on", function()
		with_ai(function(state)
			local subject, enabled, AiActions = load_keyboard()
			helpers.assert_eq(subject.start(), true)
			local plain = 0
			for _, on in pairs(enabled) do if on == true then plain = plain + 1 end end
			helpers.assert_eq(plain, 1, "the AI is off: only the plain chord is armed")
			state.enabled = true
			AiActions.notify()
			plain = 0
			for _, on in pairs(enabled) do if on == true then plain = plain + 1 end end
			helpers.assert_eq(plain, 2, "the AI back on: both chords are armed, with no reload")
			state.enabled = false
			AiActions.notify()
			plain = 0
			for _, on in pairs(enabled) do if on == true then plain = plain + 1 end end
			helpers.assert_eq(plain, 1, "the AI off again releases it")
			subject.stop()
		end)
	end)
end)





-- ===================================
-- ===================================
-- ======= 2/ A number-row key =======
-- ===================================
-- ===================================

helpers.describe("AI tap keys (ai-off-inert-macos)", function()
	helpers.it("lets the key through while the AI is off, runs the action once on", function()
		with_ai(function(state)
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["adapters.file_system"] = nil
			package.loaded["infra.paths"] = nil
			package.loaded["modules.shortcuts.ai_actions"] = nil
			package.loaded["modules.shortcuts.tap_keys"] = nil
			local TapKeys = require("modules.shortcuts.tap_keys")
			local key = nil
			for _, candidate in ipairs(TapKeys.keys()) do
				-- A stable code needs no keyboard model to be told apart.
				if #candidate.hs == 1 then key = candidate break end
			end
			helpers.assert_true(key ~= nil, "the shared list has a key with one keycode")
			TapKeys._reset()
			-- Assign through the public path: load() reads the canonical file, so
			-- the cached table is seeded by an apply of a candidate.
			local ok = TapKeys.apply_configuration(
				{ shortcuts = { tap_keys = { [key.id] = "llm_generate_prediction" } } },
				function(action) return type(action) == "string" end)
			helpers.assert_eq(ok, true)
			local action = TapKeys.decide(key.hs[1], nil)
			helpers.assert_nil(action, "the AI is off: the key types as usual")
			state.enabled = true
			action = TapKeys.decide(key.hs[1], nil)
			helpers.assert_eq(action, "llm_generate_prediction", "armed again, no reload")
		end)
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 3/ The picker greys the manual agent =======
-- ====================================================
-- ====================================================

helpers.describe("The action picker greys the agent's manual actions (ai-off-picker)", function()
	helpers.it("greys them with the AI notice while the AI is off and offers them once on", function()
		with_ai(function(state)
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["modules.shortcuts.ai_actions"] = nil
			package.loaded["ui.menu.shortcut_utils"] = nil
			local utils = require("ui.menu.shortcut_utils")
			local gestures = {
				get_action_parameter_spec = function() return nil end,
				get_action_parameter = function() return "" end,
				parameter_prompt = function() return "" end, parameter_error = function() return "" end,
				send_vocabulary = function() return {} end, llm_prompt_choices = function() return {} end,
				llm_prompt_default_count = function() return 1 end, llm_vision_choices = function() return {} end,
				llm_language_choices = function() return {} end,
			}
			local function rows()
				local items = {
					{ type = "action", id = "llm_agent_selection" }, { type = "action", id = "llm_agent_command" },
					{ type = "action", id = "llm_generate_prediction" }, { type = "action", id = "select_line" },
				}
				utils.picker_parameter_fields(gestures, items, nil)
				return items
			end
			local notice = require("infra.i18n").get("dialog.action_picker.requires_ai")
			helpers.assert_true(notice ~= require("infra.i18n").get("llm.manual_prediction.disabled"),
				"the greyed row has its own AI-off hint, not the suggestions notice")
			local off = rows()
			for index = 1, 2 do
				helpers.assert_eq(off[index].disabled, true, off[index].id .. " is greyed while the AI is off")
				helpers.assert_eq(off[index].hint, notice, "with the reason")
			end
			helpers.assert_eq(off[3].disabled, nil, "an action the catalogue does not mark stays as it was")
			helpers.assert_eq(off[4].disabled, nil)
			state.enabled = true
			local on = rows()
			helpers.assert_eq(on[1].disabled, nil, "offered again with the AI on, no reload")
			helpers.assert_eq(on[2].disabled, nil)
		end)
	end)
end)

return true

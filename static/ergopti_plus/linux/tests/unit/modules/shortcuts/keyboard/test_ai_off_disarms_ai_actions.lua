--- tests/unit/modules/shortcuts/keyboard/test_ai_off_disarms_ai_actions.lua

--- ==============================================================================
--- MODULE: The AI switch off disarms the AI actions (ai-off-inert-linux)
--- DESCRIPTION:
--- With the AI switched off nothing of it runs, as on macOS and Windows: a key
--- bound to an AI action (`llm_*`) is not armed, so the key reaches the
--- application, and switching the AI back on arms it again without a reload.
--- Covered here: the shared predicate, a modifier chord under the grab, a
--- number-row tap key and a touchpad gesture.
---
--- ROOT CAUSE ENCODED:
--- The chords stayed bound with the AI off: the keystroke was claimed, then the
--- action refused it with a notice, so the application never saw the key and
--- the user lost it for nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Fakes = helpers.load_module("tests.fakes")

local ENGINE = "modules.llm.prediction_engine"

--- Runs a body with a stub prediction engine whose AI switch the body flips.
--- @param body function(state: table) state.enabled is the AI switch.
local function with_ai(body)
	local previous = package.loaded[ENGINE]
	local state = { enabled = false }
	package.loaded[ENGINE] = { is_enabled = function() return state.enabled end }
	local ok, err = pcall(body, state)
	package.loaded[ENGINE] = previous
	if not ok then error(err, 0) end
end

helpers.describe("AI actions are unarmed with the AI off (ai-off-inert-linux)", function()
	helpers.it("names the llm_ actions and only those, and follows the engine's switch", function()
		local AiActions = require("modules.shortcuts.ai_actions")
		helpers.assert_true(AiActions.is_ai_action("llm_agent_auto_toggle"))
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
		local previous = package.loaded[ENGINE]
		package.loaded[ENGINE] = nil
		local blocked = require("modules.shortcuts.ai_actions").blocked("llm_generate_prediction")
		package.loaded[ENGINE] = previous
		helpers.assert_eq(blocked, true, "an engine that never loaded cannot run the action")
	end)
end)

-- =================================================================
-- ======= 1/ A modifier chord under the grab ======================
-- =================================================================

local held, config_path = {}, nil

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
	if config_path then os.remove(config_path) os.remove(config_path .. ".tmp") config_path = nil end
end

--- Keyboard shortcuts over two stored chords: an AI action and a plain one.
--- @return table shortcuts, table seen
local function keyboard_fixture()
	local seen = { executed = {}, deferred = {} }
	replace("adapters.storage", Fakes.storage({ initial = {
		["shortcuts.keyboard.ctrl_j"] = "llm_generate_prediction",
		["shortcuts.keyboard.ctrl_k"] = "select_line",
	} }))
	config_path = os.tmpname()
	Sandbox.write_bytes(config_path,
		"[shortcuts.keyboard]\nctrl_j = \"llm_generate_prediction\"\nctrl_k = \"select_line\"\n")
	replace("infra.config_paths", { config = function() return config_path end })
	replace("modules.gestures.manager", {
		is_assignable = function(id) return id == "select_line" or id == "llm_generate_prediction" end,
		execute_action = function(action, binding) seen.executed[#seen.executed + 1] = action .. "@" .. binding end,
	})
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
	shortcuts._reset()
	seen.opts = function()
		return { only_script = false, defer = function(fn) seen.deferred[#seen.deferred + 1] = fn return true end }
	end
	seen.tick = function()
		local queue = seen.deferred
		seen.deferred = {}
		for _, fn in ipairs(queue) do fn() end
	end
	return shortcuts, seen
end

helpers.describe("AI chords under the grab (ai-off-inert-linux)", function()
	helpers.it("leaves the chord to the application while the AI is off, then claims it once on", function()
		with_ai(function(state)
			local shortcuts, seen = keyboard_fixture()
			local ok, err = pcall(function()
				local consumed = shortcuts.consume({ key = "j", mods = { ctrl = true } }, seen.opts())
				helpers.assert_eq(consumed, false, "the AI is off: Ctrl+J belongs to the application")
				helpers.assert_eq(#seen.deferred, 0, "nothing is queued")
				helpers.assert_eq(shortcuts.consume({ key = "k", mods = { ctrl = true } }, seen.opts()), true,
					"a plain chord is unaffected by the AI switch")
				seen.tick()
				state.enabled = true
				helpers.assert_eq(shortcuts.consume({ key = "j", mods = { ctrl = true } }, seen.opts()), true,
					"the AI back on: the chord is armed again")
				seen.tick()
				helpers.assert_eq(seen.executed[2], "llm_generate_prediction@keyboard__ctrl_j")
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("drops a queued AI chord when the AI is switched off before the tick", function()
		with_ai(function(state)
			state.enabled = true
			local shortcuts, seen = keyboard_fixture()
			local ok, err = pcall(function()
				helpers.assert_eq(shortcuts.consume({ key = "j", mods = { ctrl = true } }, seen.opts()), true)
				state.enabled = false
				seen.tick()
				helpers.assert_eq(#seen.executed, 0, "the switch-off revokes the queued action")
			end)
			restore()
			if not ok then error(err, 0) end
		end)
	end)
end)

-- =================================================================
-- ======= 2/ A number-row tap key =================================
-- =================================================================

helpers.describe("AI tap keys (ai-off-inert-linux)", function()
	helpers.it("types the key while the AI is off and claims it once the AI is on", function()
		with_ai(function(state)
			local names = { "adapters.storage", "infra.config_paths", "modules.gestures.manager",
				"modules.shortcuts.tap_keys" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name] end
			local path = os.tmpname()
			Sandbox.write_bytes(path, "[shortcuts.tap_keys]\nnumber_row_left = \"llm_generate_prediction\"\n")
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = Fakes.storage({ initial = {} })
			local executed, deferred = {}, {}
			package.loaded["modules.gestures.manager"] = {
				is_assignable = function(id) return id == "llm_generate_prediction" end,
				execute_action = function(action, binding) executed[#executed + 1] = action .. "@" .. binding end,
			}
			package.loaded["modules.shortcuts.tap_keys"] = nil
			local TapKeys = require("modules.shortcuts.tap_keys")
			TapKeys.init({
				is_active = function() return true end,
				defer = function(fn) deferred[#deferred + 1] = fn return true end,
			})
			local ok, err = pcall(function()
				helpers.assert_eq(TapKeys.on_key({ code = 41, mods = {} }), false, "AI off: the key is typed")
				helpers.assert_eq(#deferred, 0)
				state.enabled = true
				helpers.assert_eq(TapKeys.on_key({ code = 41, mods = {} }), true, "AI on: the tap runs its action")
				state.enabled = false
				for _, fn in ipairs(deferred) do fn() end
				helpers.assert_eq(#executed, 0, "a switch-off between press and tick revokes it")
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			os.remove(path)
			os.remove(path .. ".tmp")
			if not ok then error(err, 0) end
		end)
	end)
end)

-- =================================================================
-- ======= 3/ A touchpad gesture ===================================
-- =================================================================

helpers.describe("AI gestures (ai-off-inert-linux)", function()
	helpers.it("runs no AI action from a gesture while the AI is off", function()
		with_ai(function(state)
			local M = helpers.load_module("modules.gestures.manager")
			local fired = {}
			M.init({ enabled = false, persist = false, action_handlers = {
				llm_generate_prediction = function() fired[#fired + 1] = "llm_generate_prediction" end,
			} })
			M._test_begin_reading({})
			helpers.assert_true(M.enable(), "the live test reader must permit enabling gestures")
			helpers.assert_true(M.set_action("swipe_5_up", "llm_generate_prediction"))
			local gesture = { fingers = 5, direction = "up", tap = false }
			helpers.assert_eq(M.dispatch_gesture(gesture), false, "AI off: the gesture does nothing")
			helpers.assert_eq(#fired, 0, "and its handler never runs")
			state.enabled = true
			helpers.assert_eq(M.dispatch_gesture(gesture), true, "AI on: the gesture runs again")
			helpers.assert_eq(fired[1], "llm_generate_prediction")
		end)
	end)
end)

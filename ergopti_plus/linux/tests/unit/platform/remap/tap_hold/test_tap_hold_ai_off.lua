--- tests/unit/platform/remap/tap_hold/test_tap_hold_ai_off.lua

--- ==============================================================================
--- MODULE: Tap-Hold Taps Bound To An AI Action Are Unarmed With The AI Off
--- DESCRIPTION:
--- With the AI switched off nothing of it runs: a tap-hold key whose tap is an
--- `llm_*` action keeps its native tap (Space types a space), instead of being
--- claimed and then refused. The hold (a modifier or a layer, never an action)
--- is unchanged. Switching the AI back on arms the tap again with no reload
--- because the engine asks at each press and release.
---
--- ROOT CAUSE ENCODED:
--- The tap-hold engine returned the AI action as the tap and the manager refused
--- it, so the key produced nothing at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")
local AiActions = require("modules.shortcuts.ai_actions")

local DOWN, UP = 1, 0
local SPACE, ESCAPE = 57, 1
local ENGINE_MODULE = "modules.llm.prediction_engine"

--- Runs a body with a stub prediction engine whose AI switch the body flips.
local function with_ai(body)
	local previous = package.loaded[ENGINE_MODULE]
	local state = { enabled = false }
	package.loaded[ENGINE_MODULE] = { is_enabled = function() return state.enabled end }
	local ok, err = pcall(body, state)
	package.loaded[ENGINE_MODULE] = previous
	if not ok then error(err, 0) end
end

--- An engine with Space tapping an AI action and holding Ctrl, and Escape
--- tapping an AI action with no hold.
local function engine()
	return Engine.new({
		keys = {
			space = { tap_action = "llm_generate_prediction", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
			escape = { tap_action = "llm_generate_prediction" },
		},
		tap_min_ms = 0, one_shot_timeout_ms = 2000,
		tap_blocked = AiActions.blocked,
		nav_layer = require("tests.support.nav_layer_fixture").recommended(),
	})
end

--- The key events as "code↓" / "code↑" in order.
local function trail(events)
	local parts = {}
	for _, event in ipairs(events or {}) do parts[#parts + 1] = event.code .. (event.value == DOWN and "↓" or "↑") end
	return table.concat(parts, " ")
end

helpers.describe("tap-hold taps bound to an AI action (ai-off-taphold)", function()
	helpers.it("types a space on a Space tap while the AI is off, runs the action once on", function()
		with_ai(function(state)
			local e = engine()
			e:process(SPACE, DOWN, 0)
			local out, tap = e:process(SPACE, UP, 100)
			helpers.assert_nil(tap, "the AI is off: no action is claimed")
			helpers.assert_true(trail(out):find("57↓ 57↑", 1, true) ~= nil, "Space typed its own space: " .. trail(out))
			state.enabled = true
			e:process(SPACE, DOWN, 1000)
			local _, armed = e:process(SPACE, UP, 1100)
			helpers.assert_eq(armed, "llm_generate_prediction", "the AI back on: the tap is armed again, no reload")
		end)
	end)

	helpers.it("leaves the hold alone while the AI is off", function()
		with_ai(function()
			local e = engine()
			helpers.assert_true(trail(e:process(SPACE, DOWN, 0)):find("29↓", 1, true) ~= nil, "Ctrl is held at once")
			local out, tap = e:process(SPACE, UP, 5000)
			helpers.assert_eq(trail(out), "29↑", "a hold past the threshold releases its modifier")
			helpers.assert_nil(tap)
		end)
	end)

	helpers.it("passes a key with a tap and no hold as itself while the AI is off", function()
		with_ai(function(state)
			local e = engine()
			local out, tap = e:process(ESCAPE, DOWN, 0)
			helpers.assert_nil(tap, "no action while off")
			helpers.assert_eq(trail(out), "1↓ 1↑", "Escape is typed")
			e:process(ESCAPE, UP, 50)
			state.enabled = true
			local _, armed = e:process(ESCAPE, DOWN, 100)
			helpers.assert_eq(armed, "llm_generate_prediction", "armed again on switch-on")
		end)
	end)

	helpers.it("never gates the engine's own key taps", function()
		with_ai(function()
			local e = Engine.new({
				keys = { space = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.2 } },
				tap_min_ms = 0, one_shot_timeout_ms = 2000, tap_blocked = AiActions.blocked,
				nav_layer = require("tests.support.nav_layer_fixture").recommended(),
			})
			e:process(SPACE, DOWN, 0)
			local out = e:process(SPACE, UP, 100)
			helpers.assert_true(trail(out):find("28↓", 1, true) ~= nil, "Enter is typed: " .. trail(out))
		end)
	end)
end)

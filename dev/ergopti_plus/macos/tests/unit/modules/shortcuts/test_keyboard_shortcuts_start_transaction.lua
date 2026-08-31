--- tests/unit/modules/shortcuts/test_keyboard_shortcuts_start_transaction.lua

--- ==============================================================================
--- MODULE: Configurable Keyboard Shortcut Startup Transaction
--- DESCRIPTION:
--- Exercises the real configurable-shortcut owner against a refused registrar
--- binding and an unbind refusal. Partial starts are rolled back, while exact
--- cleanup debt remains reachable for a later stop retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real owner with two configured slots and a controllable registrar.
--- @return table subject Loaded keyboard-shortcuts module.
--- @return table controls Mutable registrar controls.
--- @return table counters Observable registrar calls.
local function load_subject()
	local controls = {refuse_on_call = nil, unbind_refuses_once = false}
	local counters = {bind = 0, unbind = 0}
	local live = {}

	package.loaded["adapters.hotkey_registrar"] = {
		bind = function()
			counters.bind = counters.bind + 1
			if controls.refuse_on_call == counters.bind then return nil end
			local token = "handle#" .. tostring(counters.bind)
			live[token] = true
			return token
		end,
		unbind = function(token)
			counters.unbind = counters.unbind + 1
			if controls.unbind_refuses_once then
				controls.unbind_refuses_once = false
				return false
			end
			if live[token] ~= true then return false end
			live[token] = nil
			return true
		end,
	}
	package.loaded["adapters.file_system"] = {
		read = function()
			return '{"keys":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}'
		end,
	}
	package.loaded["infra.paths"] = {shared = function() return "catalogue.json" end}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.gestures.actions"] = {execute_single = function() end}
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

	local subject = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts", {
		settings = {
			getKeys = function()
				return {
					"ergopti.keyboard_shortcut_cmd_a",
					"ergopti.keyboard_shortcut_cmd_b",
				}
			end,
			get = function() return "script_pause_toggle" end,
			set = function() end,
		},
		json = {
			decode = function()
				return {keys = {{id = "a", label = "A"}, {id = "b", label = "B"}}}
			end,
		},
	})
	return subject, controls, counters
end





-- ===============================================
-- ===============================================
-- ======= 1/ Registrar Refusal Rolls Back =======
-- ===============================================
-- ===============================================

helpers.describe("configurable shortcuts: startup transaction", function()
	helpers.it("returns false after one refused binding and releases its sibling", function()
		local subject, controls, counters = load_subject()
		controls.refuse_on_call = 2

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(counters.bind, 2,
			"both configured slots must be attempted so this reaches a partial start")
		helpers.assert_eq(counters.unbind, 1,
			"the registrar handle acquired before refusal must be rolled back")

		controls.refuse_on_call = nil
		helpers.assert_eq(subject.start(), true,
			"a settled rollback must permit a complete retry")
	end)

	helpers.it("retains an unbind refusal and settles that exact handle on retry", function()
		local subject, controls = load_subject()
		helpers.assert_eq(subject.start(), true)
		controls.unbind_refuses_once = true

		helpers.assert_eq(subject.stop(), false)
		helpers.assert_eq(subject.stop(), true,
			"the refused registrar handle must remain published for cleanup retry")
	end)
end)

return true

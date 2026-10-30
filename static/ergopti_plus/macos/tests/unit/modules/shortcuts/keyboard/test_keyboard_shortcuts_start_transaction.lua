--- tests/unit/modules/shortcuts/keyboard/test_keyboard_shortcuts_start_transaction.lua

--- ==============================================================================
--- MODULE: Configurable Keyboard Shortcut Startup Transaction
--- DESCRIPTION:
--- Exercises the real configurable-shortcut owner against a refused registrar
--- binding and an unbind refusal. One refused slot fails alone and is retried,
--- while exact cleanup debt remains reachable for a later stop retry.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real owner with two configured slots and a controllable registrar.
--- @return table subject Loaded keyboard-shortcuts module.
--- @return table controls Mutable registrar controls.
--- @return table counters Observable registrar calls.
local function load_subject()
	local controls = {refuse_on_call = nil, unbind_refuses_once = false, options = {}}
	local counters = {bind = 0, unbind = 0}
	local live = {}

	package.loaded["adapters.hotkey_registrar"] = {
		bind = function(chord, _, options)
			counters.bind = counters.bind + 1
			controls.options[chord] = options
			if controls.refuse_on_call == counters.bind or controls.refuse_always then
				return nil, controls.refusal or "OS_REFUSED"
			end
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
		OS_REFUSAL = "OS_REFUSED",
	}
	package.loaded["adapters.timer_scheduler"] = { awake_time = function() return controls.now or 0 end }
	controls.rebinds = 0
	package.loaded["infra.timings"] = { sec = function() return 60 end }
	package.loaded["modules.shortcuts"] = {
		rebind_for_layout = function() controls.rebinds = controls.rebinds + 1; return true end,
	}
	package.loaded["adapters.file_system"] = {
		read = function()
			return '{"keys":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}'
		end,
	}
	package.loaded["infra.paths"] = {shared = function() return "catalogue.json" end}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	-- The start transaction is independent of which ids exist; the load-time
	-- catalogue check has its own test (test_keyboard_shortcuts_unknown_action.lua).
	package.loaded["modules.gestures.actions"] = {
		is_assignable = function(action_id) return type(action_id) == "string" end,
		execute_single = function() end,
	}
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

	require("tests.support.keyboard_config_fixture").install({ primary_a = "script_pause_toggle", primary_b = "script_pause_toggle" })
	local subject = require("modules.shortcuts.keyboard_shortcuts")
	return subject, controls, counters
end





-- ===============================================
-- ===============================================
-- ======= 1/ Registrar Refusal Rolls Back =======
-- ===============================================
-- ===============================================

helpers.describe("configurable shortcuts: startup transaction (shortcut-refusal-isolation)", function()
	helpers.it("commits the sibling of one refused slot and retries the refused one", function()
		local subject, controls, counters = load_subject()
		controls.refuse_on_call = 2

		helpers.assert_eq(subject.start(), true,
			"one refused slot must not abort the other configured shortcuts")
		helpers.assert_eq(counters.bind, 2)
		helpers.assert_eq(counters.unbind, 0,
			"the slot that registered must stay registered")
		local pending = subject.pending_slots()
		local refused_slot, refusal = next(pending)
		helpers.assert_true(refused_slot ~= nil and refusal == "OS_REFUSED",
			"the refused slot is recorded with its cause: " .. tostring(refusal))
		helpers.assert_eq(next(pending, refused_slot), nil, "only the refused slot waits")

		controls.refuse_on_call = nil
		helpers.assert_eq(subject.bind_pending(false), true,
			"the retry binds the refused slot alone")
		helpers.assert_eq(counters.bind, 3)
		helpers.assert_eq(next(subject.pending_slots()), nil)
	end)

	helpers.it("rebinds every shortcut once a minute while macOS refuses a held key", function()
		-- Field log 2026-10-30: after a layout switch Ctrl+G still held keycode 5,
		-- the Ergopti '.', and retrying Ctrl+. alone failed for 11 minutes.
		local subject, controls = load_subject()
		controls.refuse_always = true
		helpers.assert_eq(subject.start(), true)
		controls.now = 100
		helpers.assert_eq(subject.bind_pending(false), false)
		helpers.assert_eq(controls.rebinds, 1, "an OS refusal asks for one full rebind")
		controls.now = 130
		subject.bind_pending(false)
		helpers.assert_eq(controls.rebinds, 1, "not again within the minute")
		controls.now = 161
		subject.bind_pending(false)
		helpers.assert_eq(controls.rebinds, 2, "again once the minute has passed")
	end)

	helpers.it("does not rebind everything for a key the layout lacks", function()
		local subject, controls = load_subject()
		controls.refuse_always = true
		controls.refusal = "key '.' is not in the active keyboard layout"
		helpers.assert_eq(subject.start(), true)
		subject.bind_pending(false)
		helpers.assert_eq(controls.rebinds, 0)
	end)

	helpers.it("asks the registrar to refuse a key the layout lacks, except on the final retry", function()
		local subject, controls = load_subject()
		helpers.assert_eq(subject.start(), true)
		for chord, options in pairs(controls.options) do
			helpers.assert_true(type(options) == "table" and options.require_layout_key == true,
				"an ordinary start must not bind a US-ANSI guess for " .. chord)
		end
		helpers.assert_eq(subject.stop(), true)
		controls.refuse_on_call = 3
		helpers.assert_eq(subject.start(), true)
		controls.options = {}
		helpers.assert_eq(subject.bind_pending(true), true)
		local _, options = next(controls.options)
		helpers.assert_true(type(options) == "table" and options.require_layout_key == false,
			"the final retry admits the US-ANSI position")
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

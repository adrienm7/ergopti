--- tests/unit/infra/field_check/test_field_check_capslock_chord.lua

--- ==============================================================================
--- MODULE: Field Run Ctrl+Caps Lock Slot Probe (capslock-chord-field)
--- DESCRIPTION:
--- The registrar tests say macOS may never fire a Caps Lock hotkey, and no
--- synthetic event can stand in for the physical chord. The probe judges the
--- session's evidence instead:
--- 1. pressed and delivered passes; pressed and never delivered fails;
--- 2. not pressed is a skip, never a pass;
--- 3. an assigned slot must be bound; an unassigned one skips;
--- 4. the keymap modifier tap counts a Caps Lock change only with Control held,
---    and the slot's own native callback counts each delivery.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local function run(facts)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("capslock_chord", { capslock_chord_facts = function() return facts end },
			function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("Ctrl+Caps Lock slot probe (capslock-chord-field)", function()
	helpers.it("passes a chord pressed and delivered", function()
		local steps, result = run({ action = "toggle_capslock", bound = true, presses = 2, deliveries = 2 })
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.capslock_slot_bound.state, "pass")
		helpers.assert_eq(steps.capslock_chord_delivered.value, "delivered:2")
		helpers.assert_eq(steps.capslock_slot_action.value, "toggle_capslock")
	end)

	helpers.it("fails a bound slot that never received a pressed chord", function()
		local steps, result = run({ action = "toggle_capslock", bound = true, presses = 3, deliveries = 0 })
		helpers.assert_true(not result.passed, "macOS not firing the Caps Lock hotkey is the failure to prove")
		helpers.assert_eq(steps.capslock_chord_delivered.value, "never_delivered")
		helpers.assert_eq(steps.capslock_chord_presses.value, "3")
	end)

	helpers.it("skips an unpressed chord and an unassigned slot, and fails an unbound one", function()
		local steps, result = run({ action = "toggle_capslock", bound = true, presses = 0, deliveries = 0 })
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.capslock_chord_delivered.state, "skip", "nothing pressed proves nothing")
		helpers.assert_eq(steps.capslock_chord_delivered.value, "not_pressed")
		local unassigned = run({ action = "none", bound = false, presses = 1, deliveries = 0 })
		helpers.assert_eq(unassigned.capslock_slot_bound.value, "unassigned")
		helpers.assert_eq(unassigned.capslock_chord_delivered.value, "slot_inactive")
		local unbound, failed = run({ action = "toggle_capslock", bound = false, presses = 0, deliveries = 0 })
		helpers.assert_eq(unbound.capslock_slot_bound.state, "fail")
		helpers.assert_true(not failed.passed, "an assigned slot that holds no binding fails")
	end)
end)

helpers.describe("Ctrl+Caps Lock evidence sources (capslock-chord-field)", function()
	helpers.it("the keymap modifier tap counts a Caps Lock change only with Control held", function()
		local src = assert(helpers.read_driver_source("shift_tap = eventtap.new("))
		local tap = assert(src:match("shift_tap = eventtap.new%((.-)\nmouse_tap = "), "the modifier tap must exist")
		local caps = tap:find("kc == CAPS_LOCK_KC and f.ctrl", 1, true)
		helpers.assert_true(caps ~= nil, "a Caps Lock change is judged with the Control flag")
		helpers.assert_true(tap:find("CapsLockChordEvidence.note_press()", caps, true) ~= nil,
			"the press is counted inside the modifier tap")
		helpers.assert_true(src:find("local CAPS_LOCK_KC   = 57", 1, true) ~= nil, "kVK_CapsLock is 57")
	end)

	helpers.it("the slot's native callback counts each delivery, and only the Caps Lock slot's", function()
		local callbacks, executed = {}, 0
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function(chord, callback) callbacks[chord] = callback; return "handle:" .. chord end,
			bind_capslock_chord = function(chord, callback) callbacks[chord] = callback; return "caps:" .. chord end,
			unbind = function() return true end,
			setEnabled = function() return true end,
		}
		package.loaded["adapters.file_system"] = {
			read = function() return '{"keys":[{"id":"capslock","label":"Caps Lock"},{"id":"a","label":"A"}]}' end,
		}
		package.loaded["infra.paths"] = { shared = function() return "catalogue.json" end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.gestures.actions"] = {
			is_assignable = function(action_id) return type(action_id) == "string" end,
			execute_single = function() executed = executed + 1; return true end,
		}
		package.loaded["adapters.storage"] = nil
		package.loaded["modules.shortcuts.ai_actions"] = nil
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		package.loaded["infra.capslock_chord_evidence"] = nil
		local Evidence = require("infra.capslock_chord_evidence")
		require("tests.support.keyboard_config_fixture").install(
			{ secondary_capslock = "script_pause_toggle", primary_a = "script_pause_toggle" })
		local subject = require("modules.shortcuts.keyboard_shortcuts")
		helpers.assert_eq(subject.start(), true)
		helpers.assert_true(subject.is_slot_bound("secondary_capslock"), "the assigned Caps Lock slot is bound")
		local caps, plain = nil, nil
		for chord, callback in pairs(callbacks) do
			if chord:lower():find("capslock", 1, true) then caps = callback else plain = callback end
		end
		helpers.assert_true(caps ~= nil and plain ~= nil, "both slots registered a native callback")
		plain()
		helpers.assert_eq(Evidence.counts().deliveries, 0, "another slot's delivery is not the Caps Lock one")
		caps()
		helpers.assert_eq(Evidence.counts().deliveries, 1)
		helpers.assert_true(executed >= 1, "the slot's action still runs")
		subject.stop()
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		package.loaded["adapters.hotkey_registrar"] = nil
		package.loaded["adapters.file_system"] = nil
		package.loaded["infra.paths"] = nil
		package.loaded["modules.gestures.actions"] = nil
	end)

	helpers.it("counts presses and deliveries for the session", function()
		package.loaded["infra.capslock_chord_evidence"] = nil
		local Evidence = require("infra.capslock_chord_evidence")
		Evidence.reset()
		Evidence.note_press(); Evidence.note_press(); Evidence.note_delivery()
		helpers.assert_eq(Evidence.counts(), { presses = 2, deliveries = 1 })
		Evidence.reset()
		helpers.assert_eq(Evidence.counts(), { presses = 0, deliveries = 0 })
	end)
end)

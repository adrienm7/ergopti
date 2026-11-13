--- tests/unit/modules/gestures/actions/test_karabiner_actions_reachable.lua

--- ==============================================================================
--- MODULE: Karabiner catalogue actions are reachable from a gesture
--- DESCRIPTION:
--- macos/platform/remap/data/actions.json holds 73 actions the remap layer can put
--- on a key. Until 2026-08-03 only 18 of them had a row in the shared action
--- catalogue, so the gesture picker could not offer the rest: the same feature was
--- reachable from a remapped key and unreachable from a swipe, and nothing said so.
---
--- The merge is only real if the handlers FIRE. `execute_single()` returns false
--- for an action it has no function for, and the bijection gates check that an id
--- appears as a literal in the driver tree — neither of them can see a handler
--- that is registered and does nothing. That is what this file drives.
---
--- The three families fail differently, so each is exercised through its own
--- observable:
---   keystrokes        — callback-returned exact-tag action pairs
---   Karabiner writes  — layer_on / layer_off / capsword go out over
---                       the serialized Karabiner variable bridge
---   sticky modifiers  — compound modifiers arm the injector; simple Shift
---                       uses the same one-shot owner as remapped keys
---
--- HOLD-ONLY ACTIONS ARE ABSENT ON PURPOSE. The 19 remaining catalogue entries
--- (`layer`, the bare modifiers, their combinations) are `tappable: false`. A
--- gesture has no duration — a swipe happens and ends — so "hold Shift" cannot be
--- expressed as one. This file asserts they stay out, because declaring them
--- would put nineteen rows in the picker that cannot work.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_action_fixture")

-- The remap menu stores the sticky auto-cancel delay in milliseconds; any
-- positive value exercises the path, so this one is named for what it is.
local STICKY_TIMEOUT_MS = 2500




-- ==========================================================
-- ==========================================================
-- ======= 1/ Harness =======================================
-- ==========================================================
-- ==========================================================

--- Loads the registry with the two lazily-required collaborators stubbed, and
--- returns recorders for everything a handler can observably do.
--- @param variable_write_result boolean|nil Result returned by the variable bridge.
--- @return table Actions module, table recorder.
local function fresh_registry(variable_write_result)
	local seen = {
		variables = {},
		sticky = {},
		capslock = nil,
		current_revision = 0,
		lease_phase = "active",
	}
	if variable_write_result == nil then variable_write_result = true end
	function seen.complete(index, ok, reason)
		local write = seen.variables[index]
		helpers.assert_true(type(write) == "table" and type(write.callback) == "function",
			"the write must expose its real asynchronous settlement callback")
		write.callback(ok, reason or (ok and "written" or "failed"), write.revision)
	end

	package.loaded["platform.remap.ke_variables"] = {
		set = function(name, value, callback)
			seen.current_revision = seen.current_revision + 1
			seen.variables[#seen.variables + 1] = {
				name = name,
				value = value,
				callback = callback,
				revision = seen.current_revision,
			}
			return variable_write_result, seen.current_revision
		end,
		capsword_revision = function() return seen.current_revision end,
		capsword_known_active = function() return seen.capsword_active == true end,
	}
	seen.deactivations = 0
	package.loaded["platform.remap.watchers"] = {
		deactivate_capsword_by_action = function()
			seen.deactivations = seen.deactivations + 1
			return true
		end,
		note_capsword_activated = function() return true end,
	}
	package.loaded["platform.remap.lease_controller"] = {
		status = function()
			return seen.lease_phase, { phase = seen.lease_phase, token = "test-token" }
		end,
	}
	package.loaded["platform.remap"] = {
		get_sticky_timeout = function() return STICKY_TIMEOUT_MS end,
	}
	package.loaded["modules.gestures.sticky_modifiers"] = {
		toggle = function(modifiers, timeout_sec)
			seen.sticky[#seen.sticky + 1] = { modifiers = modifiers, timeout_sec = timeout_sec }
			return true
		end,
		clear = function() end,
		armed = function() return {} end,
	}
	package.loaded["platform.input.key_state"] = {
		isDown = function() return false end,
		isUp = function() return true end,
		set_capslock = function(on) seen.capslock = on end,
	}

	package.loaded["modules.gestures.actions"] = nil
	local fixture = Fixture.load("modules.gestures.actions")
	return fixture.subject, seen, fixture
end

--- Sorted, comma-joined modifier list, for readable assertions.
--- @param list table|nil
--- @return string
local function mods_of(list)
	local copy = {}
	for _, m in ipairs(list or {}) do copy[#copy + 1] = m end
	table.sort(copy)
	return table.concat(copy, ",")
end




-- ==========================================================
-- ==========================================================
-- ======= 2/ Keystroke family ==============================
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner catalogue actions: keystroke family", function()

	local function assert_keystroke(action, expected_mods, expected_key)
		local Actions, _, fixture = fresh_registry()
		helpers.assert_true(Actions.execute_single(action),
			action .. " must have a handler — execute_single() refuses an unregistered action")
		local events, down, up = fixture.drain("test.karabiner." .. action)
		helpers.assert_eq(events[1].key, expected_key, action .. " must target '" .. expected_key .. "'")
		helpers.assert_eq(mods_of(events[1].mods), expected_mods, action .. " modifiers")
		helpers.assert_eq(down.effect, "action")
		helpers.assert_eq(up.effect, "action")
	end

	helpers.it("home posts Home", function() assert_keystroke("home", "", "home") end)
	helpers.it("end posts End", function() assert_keystroke("end", "", "end") end)
	helpers.it("page_up posts Page Up", function() assert_keystroke("page_up", "", "pageup") end)
	helpers.it("page_down posts Page Down", function() assert_keystroke("page_down", "", "pagedown") end)
	helpers.it("save posts Cmd+S", function() assert_keystroke("save", "cmd", "s") end)
	helpers.it("spotlight posts Cmd+Space", function() assert_keystroke("spotlight", "cmd", "space") end)
	helpers.it("opt_backspace deletes the previous word with Option", function()
		-- Option, not Control: macOS moves and deletes by word with Option, and
		-- ctrl+delete does nothing at all here. The same confusion already cost
		-- this catalogue a per-OS split of its emit rows.
		assert_keystroke("opt_backspace", "alt", "delete")
	end)
	helpers.it("cmd_backspace deletes to the line start with Command", function()
		assert_keystroke("cmd_backspace", "cmd", "delete")
	end)
	helpers.it("cmd_delete_fwd deletes to the line end", function()
		assert_keystroke("cmd_delete_fwd", "cmd", "forwarddelete")
	end)
	-- cmd_shift_tab is not in this family any more: a posted Cmd+Shift+Tab
	-- switched nothing (the switcher follows the real Command release), so it
	-- activates the least recent application from Lua. test_app_switch_direct.lua
	-- drives it (app-switch-direct).

	helpers.it("the two F17 window actions reach the driver's own hotkeys", function()
		-- These do NOT emit their behaviour directly: they press F17, which
		-- platform/remap/watchers.lua binds to the native window cyclers. That
		-- indirection is deliberate — the native cycler is layout-independent where
		-- cmd+` is not — so the keystroke is the contract, and a "simplification"
		-- that replaced it with cmd+` would silently break AZERTY users.
		-- cycle_windows_in_app and alt_tab_apps are aliases of win_app_next and
		-- app_previous now: a gesture runs those directly, with no remap layer.
		assert_keystroke("alt_tab_windows", "shift", "f17")
		assert_keystroke("alt_tab_monitor", "ctrl", "f17")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 3/ Karabiner-variable family =====================
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner catalogue actions: engine variables", function()

	helpers.it("layer_on writes only the live layer authority", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_on"))
		helpers.assert_eq(#seen.variables, 1,
			"a mirror variable with no reader creates an extra asynchronous writer")
		helpers.assert_eq(seen.variables[1].name, "layer_active")
		helpers.assert_eq(seen.variables[1].value, 1)
	end)

	helpers.it("layer_off writes only the live layer authority", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_off"))
		helpers.assert_eq(#seen.variables, 1)
		helpers.assert_eq(seen.variables[1].name, "layer_active")
		helpers.assert_eq(seen.variables[1].value, 0)
	end)

	--- Records the navigation-layer signals the real sentinel owner publishes.
	--- @return table signals Ordered published signal names.
	--- @return table Sentinels Real control-sentinel owner.
	local function record_layer_signals()
		local Sentinels = require("modules.keymap.control_sentinels")
		local signals = {}
		Sentinels.set_listener("test.layer_wheel", function(signal) signals[#signals + 1] = signal end)
		return signals, Sentinels
	end

	helpers.it("(layer-action-wheel-sync) layer_on enters the wheel layer only after the write settles", function()
		local Actions, seen = fresh_registry()
		local signals, Sentinels = record_layer_signals()
		helpers.assert_true(Actions.execute_single("layer_on"))
		helpers.assert_eq(#signals, 0, "a queued write is not a layer transition")
		seen.complete(1, true)
		Sentinels.set_listener("test.layer_wheel", nil)
		helpers.assert_eq(#signals, 1,
			"the wheel bindings follow the layer only through this signal; without it a "
			.. "catalogue layer_on leaves the wheel scrolling (HS-002 / MI-001)")
		helpers.assert_eq(signals[1], Sentinels.NAV_LAYER_ENTERED)
	end)

	helpers.it("(layer-action-wheel-sync) layer_off leaves the wheel layer only after the write settles", function()
		local Actions, seen = fresh_registry()
		local signals, Sentinels = record_layer_signals()
		helpers.assert_true(Actions.execute_single("layer_off"))
		seen.complete(1, true)
		Sentinels.set_listener("test.layer_wheel", nil)
		helpers.assert_eq(#signals, 1)
		helpers.assert_eq(signals[1], Sentinels.NAV_LAYER_EXITED)
	end)

	helpers.it("(layer-action-wheel-sync) refused, failed and superseded writes publish nothing", function()
		local Actions, seen = fresh_registry(false)
		local signals, Sentinels = record_layer_signals()
		helpers.assert_true(Actions.execute_single("layer_on"))
		helpers.assert_eq(#signals, 0, "a refused write has no settlement to publish")

		Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_on"))
		seen.complete(1, false, "nonzero-exit")
		helpers.assert_eq(#signals, 0, "a failed write did not change the engine layer")

		Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_on"))
		helpers.assert_true(Actions.execute_single("layer_off"))
		seen.complete(1, true)
		helpers.assert_eq(#signals, 0, "an older success must not re-enter after a newer layer_off")
		seen.complete(2, true)
		Sentinels.set_listener("test.layer_wheel", nil)
		helpers.assert_eq(#signals, 1)
		helpers.assert_eq(signals[1], Sentinels.NAV_LAYER_EXITED)
	end)

	helpers.it("capsword locks CapsLock only after the variable write settles", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("capsword"))
		helpers.assert_eq(#seen.variables, 1)
		helpers.assert_eq(seen.variables[1].name, "capsword")
		helpers.assert_eq(seen.variables[1].value, 1)
		helpers.assert_eq(seen.capslock, nil,
			"acceptance only means the asynchronous CLI write was queued")
		seen.complete(1, true)
		helpers.assert_eq(seen.capslock, true,
			"the catalogue entry locks CapsLock after setting the variable. macOS "
			.. "delivers CapsLock as flagsChanged, so a keystroke would fail silently — the "
			.. "variable would be set with no visible effect and CapsWord would look broken")
	end)

	-- The catalogue action toggles on every OS (decision of 2026-11-06); macOS
	-- used to request ACTIVE again, so a second invocation left CapsWord on.
	helpers.it("(capsword-toggle) a second capsword invocation switches the running CapsWord off", function()
		local Actions, seen = fresh_registry()
		seen.capsword_active = true
		helpers.assert_true(Actions.execute_single("capsword"))
		helpers.assert_eq(seen.deactivations, 1, "the watcher's clear ends the running CapsWord")
		helpers.assert_eq(#seen.variables, 0, "no second ACTIVE request is written")
		seen.capsword_active = false
		helpers.assert_true(Actions.execute_single("capsword"))
		helpers.assert_eq(#seen.variables, 1, "control: an inactive CapsWord is switched on")
		helpers.assert_eq(seen.deactivations, 1)
	end)

	helpers.it("capsword leaves CapsLock unchanged when the variable write is refused", function()
		local Actions, seen = fresh_registry(false)
		helpers.assert_true(Actions.execute_single("capsword"))
		helpers.assert_eq(#seen.variables, 1,
			"the gesture must ask the lease-gated bridge to activate CapsWord")
		helpers.assert_eq(seen.capslock, nil,
			"an idle or disabled lease refuses the variable write; locking CapsLock anyway would "
			.. "expose a partial Ergopti feature while the remap layer is off")
	end)

	helpers.it("capsword leaves CapsLock unchanged when an accepted write fails", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("capsword"))
		seen.complete(1, false, "nonzero-exit")
		helpers.assert_eq(seen.capslock, nil,
			"a queued write is not an activation; the LED must follow the settled engine state")
	end)

	helpers.it("capsword discards a successful callback superseded by newer intent", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("capsword"))
		seen.current_revision = seen.current_revision + 1
		seen.complete(1, true)
		helpers.assert_eq(seen.capslock, nil,
			"an older successful child must not turn CapsLock on after a newer clear")
	end)

	helpers.it("capsword discards a successful callback after the lease pauses", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("capsword"))
		seen.lease_phase = "paused"
		seen.complete(1, true)
		helpers.assert_eq(seen.capslock, nil,
			"pause must not expose a half-active ErgoptiPlus feature through the system LED")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 4/ Sticky family =================================
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner catalogue actions: sticky modifiers", function()

	local function assert_sticky(action, expected_mods)
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single(action), action .. " must have a handler")
		helpers.assert_eq(#seen.sticky, 1, action .. " must arm exactly once")
		helpers.assert_eq(mods_of(seen.sticky[1].modifiers), expected_mods, action .. " modifiers")
	end

	helpers.it("sticky_shift arms the shared one-shot owner", function()
		local Actions, seen = fresh_registry()
		helpers.with_stub_scope({ "modules.keymap" }, function()
			local calls = 0
			package.loaded["modules.keymap"] = {
				arm_one_shot_shift = function() calls = calls + 1; return true end,
			}
			helpers.assert_true(Actions.execute_single("sticky_shift"))
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#seen.sticky, 0, "simple Shift must not also arm the compound injector")
		end)
	end)
	helpers.it("sticky_option arms Option, spelled alt", function()
		-- The catalogue calls it Option and a key event calls the flag "alt".
		-- Passing "option" through would arm a flag nothing carries.
		assert_sticky("sticky_option", "alt")
	end)
	helpers.it("sticky_cmd_shift arms both", function() assert_sticky("sticky_cmd_shift", "cmd,shift") end)
	helpers.it("sticky_option_shift_ctrl arms all three", function()
		assert_sticky("sticky_option_shift_ctrl", "alt,ctrl,shift")
	end)
	helpers.it("sticky_hyper arms all four", function()
		assert_sticky("sticky_hyper", "alt,cmd,ctrl,shift")
	end)

	helpers.it("passes the user's delay through, converted to seconds", function()
		local Actions, seen = fresh_registry()
		Actions.execute_single("sticky_cmd")
		helpers.assert_eq(seen.sticky[1].timeout_sec, STICKY_TIMEOUT_MS / 1000,
			"the remap menu stores milliseconds and the scheduler takes seconds; passing the "
			.. "raw value would arm a modifier for forty minutes")
	end)

	helpers.it("refuses to arm when the remap layer cannot supply a delay", function()
		local Actions, seen = fresh_registry()
		package.loaded["platform.remap"] = { get_sticky_timeout = function() return nil end }
		Actions.execute_single("sticky_cmd")
		helpers.assert_eq(#seen.sticky, 0,
			"no fallback delay: the value is the user's, and inventing one here would override "
			.. "their choice on exactly the boot where the configuration failed to load")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 5/ The hold-only actions stay out ================
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner catalogue: hold-only actions are not gestures", function()

	helpers.it("no hold-only action is registered", function()
		local Actions = fresh_registry()
		-- Every `tappable: false` entry of the catalogue. A gesture has no
		-- duration, so each of these would be a picker row that cannot work.
		local hold_only = {
			"layer", "shift", "ctrl", "cmd", "alt", "altgr", "fn",
			"cmd_shift", "cmd_option", "cmd_ctrl", "option_shift", "option_ctrl",
			"ctrl_shift", "fn_shift", "cmd_option_shift", "cmd_option_ctrl",
			"cmd_shift_ctrl", "option_shift_ctrl", "hyper",
		}
		for _, id in ipairs(hold_only) do
			helpers.assert_true(not Actions.execute_single(id),
				id .. " is hold-only in the Karabiner catalogue and must have no gesture handler — "
				.. "a swipe happens and ends, so it cannot hold anything down")
		end
	end)

end)

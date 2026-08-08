--- tests/unit/modules/gestures/test_karabiner_actions_reachable.lua

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
---                       `karabiner_cli --set-variable`, the only IPC that exists
---   sticky modifiers  — the 15 sticky_* arm the injector, since
---                       `sticky_modifier` has no IPC at all
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
--- @return table Actions module, table recorder.
local function fresh_registry()
	local seen = { variables = {}, sticky = {}, capslock = nil }

	package.loaded["platform.remap.ke_variables"] = {
		set = function(name, value)
			seen.variables[#seen.variables + 1] = { name = name, value = value }
			return true
		end,
		set_all = function(pairs_list)
			for _, entry in ipairs(pairs_list) do
				seen.variables[#seen.variables + 1] = { name = entry[1], value = entry[2] }
			end
			return true
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
	package.loaded["adapters.key_state"] = {
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
	helpers.it("cmd_shift_tab walks the switcher backwards", function()
		assert_keystroke("cmd_shift_tab", "cmd,shift", "tab")
	end)

	helpers.it("the three F17 actions reach the driver's own hotkeys", function()
		-- These do NOT emit their behaviour directly: they press F17, which
		-- platform/remap/watchers.lua binds to the native window/app cyclers. That
		-- indirection is deliberate — the native cycler is layout-independent where
		-- cmd+` is not — so the keystroke is the contract, and a "simplification"
		-- that replaced it with cmd+` would silently break AZERTY users.
		assert_keystroke("cycle_windows_in_app", "", "f17")
		assert_keystroke("alt_tab_windows", "shift", "f17")
		assert_keystroke("alt_tab_apps", "alt", "f17")
	end)

end)




-- ==========================================================
-- ==========================================================
-- ======= 3/ Karabiner-variable family =====================
-- ==========================================================
-- ==========================================================

helpers.describe("Karabiner catalogue actions: engine variables", function()

	helpers.it("layer_on switches BOTH variables on", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_on"))
		helpers.assert_eq(#seen.variables, 2,
			"the navigation layer is two variables — writing only one leaves the engine "
			.. "half-switched, with the layer latched but no manipulator testing it")
		local written = {}
		for _, v in ipairs(seen.variables) do written[v.name] = v.value end
		helpers.assert_eq(written.layer_toggle, 1)
		helpers.assert_eq(written.layer_active, 1)
	end)

	helpers.it("layer_off switches BOTH variables off", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("layer_off"))
		local written = {}
		for _, v in ipairs(seen.variables) do written[v.name] = v.value end
		helpers.assert_eq(written.layer_toggle, 0)
		helpers.assert_eq(written.layer_active, 0)
	end)

	helpers.it("capsword sets the variable AND locks CapsLock", function()
		local Actions, seen = fresh_registry()
		helpers.assert_true(Actions.execute_single("capsword"))
		helpers.assert_eq(#seen.variables, 1)
		helpers.assert_eq(seen.variables[1].name, "capsword")
		helpers.assert_eq(seen.variables[1].value, 1)
		helpers.assert_eq(seen.capslock, true,
			"the catalogue entry presses caps_lock as well as setting the variable. macOS "
			.. "delivers CapsLock as flagsChanged, so a keystroke would fail silently — the "
			.. "variable would be set with no visible effect and CapsWord would look broken")
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

	helpers.it("sticky_shift arms Shift", function() assert_sticky("sticky_shift", "shift") end)
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
		Actions.execute_single("sticky_shift")
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

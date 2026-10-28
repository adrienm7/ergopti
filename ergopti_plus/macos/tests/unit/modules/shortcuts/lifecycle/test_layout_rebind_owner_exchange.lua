--- tests/unit/modules/shortcuts/lifecycle/test_layout_rebind_owner_exchange.lua

--- ==============================================================================
--- MODULE: Layout Rebind Owner Exchange (field run 2026-10-28)
--- DESCRIPTION:
--- Drives the real shortcuts facade through a keyboard-layout rebind with two
--- children that share one physical keycode space, as macOS does. On the
--- maintainer's Mac, Ctrl+. of the configurable shortcuts was still registered
--- at the Ergopti '.' (keycode 5) when the static Ctrl+G resolved to keycode 5 in
--- the new layout: macOS refused it, the rebind failed, and every recovery then
--- handed its transaction guard to KeyboardShortcuts.resume_after_pause() as a
--- config candidate, which start() refuses: every shortcut stayed dead.
---
--- ROOT CAUSES ENCODED HERE:
--- 1. Every old-layout registration is released before the first new one.
--- 2. The recovery starts the configurable shortcuts with no candidate.
--- ==============================================================================

local helpers = require("tests.helpers")

local OLD_LAYOUT_DOT = "ctrl:5"  -- Ctrl+. at the Ergopti '.' position
local NEW_LAYOUT_G   = "ctrl:5"  -- Ctrl+G once the new layout resolves 'g' there

--- Loads the facade over two children registering into one shared keycode set.
--- @param controls table Mutable child controls.
--- @return table subject Loaded shortcuts facade.
--- @return table state Observable child state.
local function load_subject(controls)
	local state = { held = {}, bindings_started = true, keyboard_started = true,
		keyboard_paused = false, candidates = {} }
	state.held[OLD_LAYOUT_DOT] = "keyboard"

	local function acquire(owner, identity)
		if state.held[identity] ~= nil and state.held[identity] ~= owner then return false end
		state.held[identity] = owner
		return true
	end
	local function release(owner)
		for identity, holder in pairs(state.held) do
			if holder == owner then state.held[identity] = nil end
		end
	end

	package.loaded["modules.shortcuts.bindings"] = {
		DEFAULT_CHATGPT_URL = "https://example.invalid/",
		is_started = function() return state.bindings_started end,
		rebind = function()
			release("bindings")
			state.bindings_started = false
			if controls.bindings_rebind_refuses then return false end
			if not acquire("bindings", NEW_LAYOUT_G) then return false end
			state.bindings_started = true
			return true
		end,
		pause_hotkeys_only = function()
			release("bindings")
			state.bindings_started = false
			return true
		end,
		resume_hotkeys_after_pause = function()
			if not acquire("bindings", NEW_LAYOUT_G) then return false end
			state.bindings_started = true
			return true
		end,
		stop = function() release("bindings"); state.bindings_started = false; return true end,
		has_pause_debt = function() return false end,
	}
	-- The configurable owner keeps the real candidate contract of
	-- keyboard_shortcuts.lua M.start(): a non-table candidate is refused.
	local keyboard = {}
	function keyboard.start(candidate)
		state.candidates[#state.candidates + 1] = candidate == nil and "nil" or type(candidate)
		if candidate ~= nil and type(candidate) ~= "table" then return false end
		if state.keyboard_paused then return false end
		state.keyboard_started = true
		return acquire("keyboard", "ctrl:47")
	end
	function keyboard.stop()
		release("keyboard")
		state.keyboard_started = false
		return true
	end
	function keyboard.pause()
		state.keyboard_paused = true
		return keyboard.stop()
	end
	function keyboard.resume_after_pause(candidate)
		state.keyboard_paused = false
		return keyboard.start(candidate)
	end
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = keyboard
	package.loaded["modules.gestures.actions"] = {
		resume_after_cleanup = function() return true end,
		force_cleanup = function() return true end,
	}
	package.loaded["modules.shortcuts.script_control"] = {
		ACTIONS = {}, ACTION_LABELS = {},
		start = function() return true end,
		stop = function() return true end,
		is_paused = function() return false end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		set_delivery_guard = function() return true end,
	}
	package.loaded["infra.startup_transaction"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.shortcuts"] = nil
	package.loaded["modules.shortcuts.init"] = nil
	return require("modules.shortcuts"), state
end





-- ==============================================
-- ==============================================
-- ======= 1/ Break Before Make on Rebind =======
-- ==============================================
-- ==============================================

helpers.describe("layout rebind: owner exchange (shortcut-rebind-owner-exchange)", function()
	helpers.it("releases the old-layout configurable chords before the static ones rebind", function()
		local subject, state = load_subject({})

		helpers.assert_eq(subject.rebind_for_layout(), true,
			"a stale old-layout registration must not refuse the new-layout chord")
		helpers.assert_eq(state.held[NEW_LAYOUT_G], "bindings")
		helpers.assert_eq(state.keyboard_started, true)
	end)

	helpers.it("recovers a refused rebind by starting the configurable shortcuts with no candidate", function()
		local controls = { bindings_rebind_refuses = true }
		local subject, state = load_subject(controls)

		helpers.assert_eq(subject.rebind_for_layout(), false)
		controls.bindings_rebind_refuses = false
		helpers.assert_eq(subject.rebind_for_layout(), true,
			"the next layout event must recover every shortcut")
		helpers.assert_eq(state.candidates[#state.candidates], "nil",
			"the recovery must not pass its transaction guard as a config candidate")
		helpers.assert_eq(state.keyboard_started, true)
		helpers.assert_eq(state.bindings_started, true)
	end)
end)

return true

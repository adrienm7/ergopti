--- tests/unit/modules/shortcuts/test_layout_rebind_preserves_disabled.lua

--- ==============================================================================
--- MODULE: Regression — a layout change must not resurrect a disabled shortcut layer
--- DESCRIPTION:
--- The Karabiner layout-change handler re-arms the layout-dependent hotkeys after
--- an input-source switch. It used to do so as an unconditional round-trip:
---     pcall(shortcuts.pause_bindings)
---     pcall(shortcuts.resume_bindings)
--- That pair is symmetric ONLY when the layer was running to begin with.
--- resume_bindings() is an unconditional Bindings.start() + KeyboardShortcuts.start(),
--- so on a layer the user had switched OFF from the tray menu the "resume" leg
--- brought every hotkey back to life while the menu checkbox still displayed OFF.
--- It was silent because Bindings.start() logs at SUCCESS (indistinguishable from
--- normal boot noise) and the menu state was never consulted nor updated.
---
--- The pause-layout feature switches the macOS input source on every pause, so the
--- watcher fires constantly in normal use — pressing AltGr+Enter twice was enough
--- to reanimate every disabled shortcut.
---
--- ROOT CAUSE ENCODED HERE: a rebind is a no-op on a stopped layer. The running /
--- stopped decision belongs to the menu and to script_control (which snapshots
--- is_bindings_started() before pausing — see script_control.lua). A caller that
--- merely wants to re-resolve scancodes must never be able to change it.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads modules.shortcuts with a fully counting stub in place of the real
--- bindings + keyboard-shortcuts sub-modules, so the test observes exactly which
--- lifecycle calls the layout rebind makes.
--- @param started boolean Initial value reported by Bindings.is_started().
--- @return table shortcuts The loaded module.
--- @return table spy Counters {b_start, b_stop, b_rebind, ks_start, ks_stop}.
local function load_shortcuts_with_spies(started)
	local spy = { b_start = 0, b_stop = 0, b_rebind = 0, ks_start = 0, ks_stop = 0 }
	local is_started = started

	package.loaded["modules.shortcuts.bindings"] = {
		DEFAULT_CHATGPT_URL  = "https://example.invalid/",
		list_shortcuts       = function() return {} end,
		enable               = function() end,
		disable              = function() end,
		is_enabled           = function() return false end,
		set_wrap_pairs_getter = function() end,
		set_chatgpt_url      = function() end,
		is_started           = function() return is_started end,
		start                = function() spy.b_start  = spy.b_start  + 1; is_started = true  end,
		stop                 = function() spy.b_stop   = spy.b_stop   + 1; is_started = false end,
		rebind               = function() spy.b_rebind = spy.b_rebind + 1 end,
	}
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
		start           = function() spy.ks_start = spy.ks_start + 1 end,
		stop            = function() spy.ks_stop  = spy.ks_stop  + 1 end,
		set_action      = function() end,
		get_action      = function() return "none" end,
		get_slot_label  = function(s) return s end,
		get_assignments = function() return {} end,
	}
	-- script_control is proxied at require time but never exercised here.
	package.loaded["modules.shortcuts.script_control"] = {
		ACTIONS = {}, ACTION_LABELS = {},
		start = function() end, stop = function() end,
		is_paused = function() return false end,
		set_shortcut_action = function() end, set_on_pause_change = function() end,
		set_extras = function() end, toggle = function() end,
	}

	package.loaded["modules.shortcuts"] = nil
	local shortcuts = helpers.load_with_stubs("modules.shortcuts")
	return shortcuts, spy
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ A disabled layer stays disabled =================================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.rebind_for_layout: a disabled layer survives a layout change", function()

	helpers.it("does nothing at all when the bindings are stopped (the user turned them off)", function()
		local shortcuts, spy = load_shortcuts_with_spies(false)

		shortcuts.rebind_for_layout()

		-- THE regression: the old pause/resume round-trip called Bindings.start()
		-- unconditionally here, bringing every hotkey the user had disabled back.
		helpers.assert_eq(spy.b_start, 0,
			"a layout change must NOT start the bindings on a layer the user turned off")
		helpers.assert_eq(spy.ks_start, 0,
			"a layout change must NOT start the keyboard shortcuts on a disabled layer")
		helpers.assert_eq(spy.b_rebind, 0,
			"there is nothing to re-arm on a stopped layer")
		helpers.assert_eq(spy.b_stop, 0,
			"a stopped layer must not be stopped again")
	end)

	helpers.it("leaves the layer reported as stopped afterwards", function()
		local shortcuts, _spy = load_shortcuts_with_spies(false)

		shortcuts.rebind_for_layout()

		helpers.assert_eq(shortcuts.is_bindings_started(), false,
			"rebind_for_layout must never change whether the layer is running")
	end)
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ A running layer is genuinely rebound ============================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.rebind_for_layout: a running layer is rebound in place", function()

	helpers.it("calls Bindings.rebind() exactly once and never Bindings.stop()", function()
		local shortcuts, spy = load_shortcuts_with_spies(true)

		shortcuts.rebind_for_layout()

		helpers.assert_eq(spy.b_rebind, 1,
			"a running layer must be re-armed exactly once so hotkeys track the new scancodes")
		-- Bindings.stop() is the subsystem shutdown: it also tears down keep-awake.
		-- A layout rebind must never take that path (see test_rebind_preserves_keep_awake).
		helpers.assert_eq(spy.b_stop, 0,
			"a layout rebind must never call Bindings.stop() — that owns the keep-awake teardown")
	end)

	helpers.it("restarts the configurable keyboard shortcuts so they track the new layout too", function()
		local shortcuts, spy = load_shortcuts_with_spies(true)

		shortcuts.rebind_for_layout()

		helpers.assert_eq(spy.ks_stop, 1, "the keyboard shortcuts must be released once")
		helpers.assert_eq(spy.ks_start, 1, "the keyboard shortcuts must be re-bound once")
	end)

	helpers.it("leaves the layer still running afterwards", function()
		local shortcuts, _spy = load_shortcuts_with_spies(true)

		shortcuts.rebind_for_layout()

		helpers.assert_eq(shortcuts.is_bindings_started(), true,
			"rebind_for_layout must never change whether the layer is running")
	end)
end)

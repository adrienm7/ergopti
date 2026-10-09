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
local function load_shortcuts_with_spies(started, options)
	options = options or {}
	local spy = {
		b_start = 0, b_stop = 0, b_rebind = 0,
		b_hotkey_pause = 0, b_hotkey_resume = 0,
		ks_start = 0, ks_stop = 0, action_pause = 0, action_resume = 0,
	}
	spy.options = options
	local is_started = started
	local shortcuts
	local function controlled(mode, message)
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if mode == "throw" then error(message) end
		return true
	end
	local function maybe_reenter(boundary)
		if options.reenter_boundary ~= boundary then return false end
		options.reenter_boundary = nil
		spy.reentrant_pause_result = shortcuts.pause_bindings(
			options.reenter_claim or "script_control")
		return true
	end

	package.loaded["modules.shortcuts.bindings"] = {
		DEFAULT_CHATGPT_URL  = "https://example.invalid/",
		list_shortcuts       = function() return {} end,
		enable               = function() end,
		disable              = function() end,
		is_enabled           = function() return false end,
		set_wrap_pairs_getter = function() end,
		set_chatgpt_url      = function() end,
		is_started           = function() return is_started end,
		start                = function() spy.b_start  = spy.b_start  + 1; is_started = true; return true end,
		stop                 = function() spy.b_stop   = spy.b_stop   + 1; is_started = false; return true end,
		rebind               = function()
			spy.b_rebind = spy.b_rebind + 1
			is_started = false
			if maybe_reenter("bindings_rebind") then return false end
			local result = controlled(options.bindings_rebind_mode,
				"bindings rebind exploded")
			if result == true then is_started = true end
			return result
		end,
		pause                = function()
			spy.b_stop = spy.b_stop + 1; is_started = false; return true
		end,
		resume_after_pause   = function()
			spy.b_start = spy.b_start + 1; is_started = true; return true
		end,
		resume_rebind_after_pause = function()
			spy.b_start = spy.b_start + 1
			spy.b_rebind_pause_resume = (spy.b_rebind_pause_resume or 0) + 1
			local result = controlled(options.bindings_recovery_mode,
				"bindings paused-rebind recovery exploded")
			if result == true then is_started = true end
			return result
		end,
		pause_hotkeys_only = function()
			spy.b_hotkey_pause = spy.b_hotkey_pause + 1
			is_started = false
			return controlled(options.bindings_inverse_mode,
				"bindings hotkey inverse exploded")
		end,
		resume_hotkeys_after_pause = function()
			spy.b_hotkey_resume = spy.b_hotkey_resume + 1
			local result = controlled(options.bindings_recovery_mode,
				"bindings hotkey recovery exploded")
			if result == true then is_started = true end
			return result
		end,
		has_pause_debt = function() return false end,
	}
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
		start           = function()
			spy.ks_start = spy.ks_start + 1
			maybe_reenter("keyboard_start")
			return controlled(options.keyboard_start_mode,
				"keyboard start exploded")
		end,
		stop            = function() spy.ks_stop  = spy.ks_stop  + 1; return true end,
		pause           = function()
			spy.ks_stop = spy.ks_stop + 1
			return controlled(options.keyboard_inverse_mode,
				"keyboard inverse exploded")
		end,
		resume_after_pause = function()
			spy.ks_start = spy.ks_start + 1
			maybe_reenter("keyboard_start")
			return controlled(options.keyboard_recovery_mode,
				"keyboard recovery exploded")
		end,
		set_action      = function() end,
		get_action      = function() return "none" end,
		get_slot_label  = function(s) return s end,
		get_assignments = function() return {} end,
	}
	-- script_control is proxied at require time but never exercised here.
	package.loaded["modules.shortcuts.script_control"] = {
		ACTIONS = {}, ACTION_LABELS = {},
		start = function() return true end, stop = function() return true end,
		is_paused = function() return false end,
		set_shortcut_action = function() end, set_on_pause_change = function() end,
		set_extras = function() end, toggle = function() end,
	}
	package.loaded["modules.gestures.actions"] = {
		force_cleanup = function() spy.action_pause = spy.action_pause + 1; return true end,
		resume_after_cleanup = function()
			spy.action_resume = spy.action_resume + 1
			return true
		end,
	}

	package.loaded["modules.shortcuts"] = nil
	shortcuts = helpers.load_with_stubs("modules.shortcuts")
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
		helpers.assert_eq(spy.action_pause, 0)
		helpers.assert_eq(spy.action_resume, 0,
			"a layout rebind must not touch action-scope lifecycle")
	end)

	helpers.it("leaves the layer reported as stopped afterwards", function()
		local shortcuts, _spy = load_shortcuts_with_spies(false)

		shortcuts.rebind_for_layout()

		helpers.assert_eq(shortcuts.is_bindings_started(), false,
			"rebind_for_layout must never change whether the layer is running")
	end)
end)

helpers.describe("shortcuts.rebind_for_layout: ordinary failure recovery", function()
	helpers.it("recovers an interrupted ON rebind through global PAUSE/RESUME", function()
		local options = { bindings_rebind_mode = "false" }
		local shortcuts, spy = load_shortcuts_with_spies(true, options)
		helpers.assert_eq(shortcuts.rebind_for_layout(), false)
		helpers.assert_eq(shortcuts.has_bindings_pause_debt(), true)
		helpers.assert_eq(shortcuts.pause_bindings("script_control"), true)
		options.bindings_rebind_mode = nil
		helpers.assert_eq(shortcuts.resume_bindings("script_control"), true)
		helpers.assert_eq(shortcuts.is_bindings_started(), true)
		helpers.assert_eq(shortcuts.has_bindings_pause_debt(), false)
		helpers.assert_true(spy.b_start > 0,
			"rebind recovery must bypass the stale cleanup-only pause snapshot")
	end)

	for _, boundary in ipairs({ "bindings_rebind", "keyboard_start" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains a retryable ON intent after " .. boundary .. " " .. mode,
				function()
					local options = {}
					options[boundary .. "_mode"] = mode
					local shortcuts, spy = load_shortcuts_with_spies(true, options)
					helpers.assert_eq(shortcuts.rebind_for_layout(), false)
					helpers.assert_eq(shortcuts.is_bindings_started(), true,
						"the explicit recovery claim preserves the feature's ON intent")
					helpers.assert_eq(shortcuts.has_bindings_pause_debt(), true)
					options[boundary .. "_mode"] = nil
					helpers.assert_eq(shortcuts.rebind_for_layout(), true)
					helpers.assert_eq(shortcuts.is_bindings_started(), true)
					helpers.assert_eq(shortcuts.has_bindings_pause_debt(), false)
					helpers.assert_true(spy.b_hotkey_resume > 0)
					helpers.assert_eq(spy.action_pause, 0)
					helpers.assert_eq(spy.action_resume, 0,
						"layout recovery must remain hotkeys-only")
				end)
		end
	end

	for _, inverse in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps recovery debt when hotkey rollback returns " .. inverse,
			function()
				local options = {
					keyboard_start_mode = "false",
					bindings_inverse_mode = inverse,
				}
				local shortcuts, spy = load_shortcuts_with_spies(true, options)
				helpers.assert_eq(shortcuts.rebind_for_layout(), false)
				helpers.assert_eq(shortcuts.has_bindings_pause_debt(), true)
				options.keyboard_start_mode = nil
				options.bindings_inverse_mode = nil
				helpers.assert_eq(shortcuts.rebind_for_layout(), true)
				helpers.assert_true(spy.b_hotkey_pause > 0)
				helpers.assert_eq(shortcuts.has_bindings_pause_debt(), false)
			end)
	end

	for _, boundary in ipairs({ "bindings_recovery", "keyboard_recovery" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains ON intent when " .. boundary .. " returns " .. mode,
				function()
					local options = { bindings_rebind_mode = "false" }
					local shortcuts, spy = load_shortcuts_with_spies(true, options)
					helpers.assert_eq(shortcuts.rebind_for_layout(), false)
					options.bindings_rebind_mode = nil
					options[boundary .. "_mode"] = mode
					helpers.assert_eq(shortcuts.rebind_for_layout(), false)
					helpers.assert_eq(shortcuts.is_bindings_started(), true)
					helpers.assert_eq(shortcuts.has_bindings_pause_debt(), true)
					options[boundary .. "_mode"] = nil
					helpers.assert_eq(shortcuts.rebind_for_layout(), true)
					helpers.assert_eq(shortcuts.is_bindings_started(), true)
					helpers.assert_eq(shortcuts.has_bindings_pause_debt(), false)
					helpers.assert_eq(spy.action_pause, 0)
					helpers.assert_eq(spy.action_resume, 0,
						"recovery retries must stay hotkeys-only")
				end)
		end
	end

	for _, inverse in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same recovery claim when Keyboard inverse returns " .. inverse,
			function()
				local options = { bindings_rebind_mode = "false" }
				local shortcuts, spy = load_shortcuts_with_spies(true, options)
				helpers.assert_eq(shortcuts.rebind_for_layout(), false)
				options.bindings_rebind_mode = nil
				options.keyboard_recovery_mode = "false"
				options.keyboard_inverse_mode = inverse
				helpers.assert_eq(shortcuts.rebind_for_layout(), false)
				helpers.assert_eq(shortcuts.is_bindings_started(), true)
				helpers.assert_eq(shortcuts.has_bindings_pause_debt(), true)
				options.keyboard_recovery_mode = nil
				options.keyboard_inverse_mode = nil
				helpers.assert_eq(shortcuts.rebind_for_layout(), true)
				helpers.assert_eq(shortcuts.has_bindings_pause_debt(), false)
				helpers.assert_true(spy.ks_stop > 0)
				helpers.assert_eq(spy.action_pause, 0)
				helpers.assert_eq(spy.action_resume, 0)
			end)
	end
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
		helpers.assert_eq(spy.action_pause, 0)
		helpers.assert_eq(spy.action_resume, 0,
			"a layout rebind must remain hotkeys-only")
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

helpers.describe("shortcuts.rebind_for_layout: lifecycle claims supersede factories", function()
	for _, boundary in ipairs({ "bindings_rebind", "keyboard_start" }) do
		for _, claim in ipairs({ "feature_toggle", "script_control" }) do
			helpers.it("rolls back when " .. boundary .. " publishes " .. claim, function()
				local shortcuts, spy = load_shortcuts_with_spies(true, {
					reenter_boundary = boundary,
					reenter_claim = claim,
				})
				helpers.assert_eq(shortcuts.rebind_for_layout(), false)
				helpers.assert_eq(spy.reentrant_pause_result, true)
				helpers.assert_eq(shortcuts.is_bindings_started(), false,
					"the re-entrant claim must fence the aggregate before publication")
				helpers.assert_eq(shortcuts.rebind_for_layout(), false,
					"the retained claim remains admission-authoritative")
				helpers.assert_eq(shortcuts.resume_bindings(claim), true)
				helpers.assert_eq(shortcuts.is_bindings_started(), true)
			end)
		end
	end

	helpers.it("uses the full pre-rebind snapshot after a re-entrant global pause", function()
		local shortcuts, spy = load_shortcuts_with_spies(true, {
			reenter_boundary = "bindings_rebind",
			reenter_claim = "script_control",
		})
		helpers.assert_eq(shortcuts.rebind_for_layout(), false)
		helpers.assert_eq(shortcuts.resume_bindings("script_control"), true)
		helpers.assert_eq(spy.b_rebind_pause_resume, 1,
			"global resume must restore the full rebind snapshot, including keep-awake")
		helpers.assert_eq(shortcuts.is_bindings_started(), true)
	end)
end)

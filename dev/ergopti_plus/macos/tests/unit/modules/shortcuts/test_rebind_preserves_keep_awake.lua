--- tests/unit/modules/shortcuts/test_rebind_preserves_keep_awake.lua

--- ==============================================================================
--- MODULE: Regression — a layout re-arm must not tear down keep-awake
--- DESCRIPTION:
--- Bindings.stop() calls sys_acts.stop_awake(), and stop() used to be the body of
--- the layout rebind (via pause_bindings). stop_awake has exactly ONE caller
--- outside its own module — that line — so every keyboard-layout change silently
--- cancelled the keep-awake jiggler and dismissed its persistent banner.
--- Repro: press Ctrl+M (banner appears, jiggler starts), then switch the macOS
--- input source — or press AltGr+Enter twice with the pause-layout feature on,
--- since the pause layout switch itself fires the input-source watcher. The banner
--- vanishes, the jiggler stops, and the laptop sleeps during the very meeting it
--- was armed for. Nothing is notified; only DEBUG traces record it.
---
--- ROOT CAUSE ENCODED HERE: M.stop() conflated two responsibilities — "release the
--- hotkey objects" (which a rebind legitimately needs) and "shut the subsystem
--- down" (which owns the keep-awake lifecycle). The fix splits them: a shared
--- release_hotkeys() helper does the former, and ONLY M.stop() does the latter.
---
--- Both directions are asserted so a future refactor cannot collapse the two paths
--- back together: rebind must NOT stop keep-awake, and stop MUST.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ============================================================================
-- ============================================================================
-- ======= 1/ Test harness ====================================================
-- ============================================================================
-- ============================================================================

--- Loads modules.shortcuts.bindings with a counting stub in place of the system
--- actions module, so the test can observe both stop_awake() calls and how many
--- times the hotkey factories were re-invoked.
--- @return table bindings The loaded module.
--- @return table spy Counters {stop_awake, factory_calls}.
local function load_bindings_with_system_spy(options)
	options = options or {}
	local spy = { stop_awake = 0, pause_awake = 0, resume_awake = 0, factory_calls = 0 }
	local mouse_paused = false
	local pixel_paused = false
	local screenshot_claims = {}
	local bindings
	local function controlled(mode)
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if mode == "throw" then error("synthetic keep-awake lifecycle refusal") end
		return true
	end

	--- Returns a fake hotkey object, counting the factory invocation. Every bind_*
	--- factory shares this so "did the rebind actually re-create the hotkeys?" is a
	--- single number rather than a per-shortcut assertion.
	local function fake_factory()
		spy.factory_calls = spy.factory_calls + 1
		if options.reenter_factory == true and bindings then
			options.reenter_factory = false
			spy.reentrant_pause_result = bindings.pause()
		end
		return { delete = function() return true end }
	end

	package.loaded["modules.shortcuts.actions.system"] = {
		stop_awake                 = function() spy.stop_awake = spy.stop_awake + 1; return true end,
		pause_awake                = function() spy.pause_awake = spy.pause_awake + 1; return true end,
		resume_awake               = function()
			spy.resume_awake = spy.resume_awake + 1
			return controlled(options.resume_awake_mode)
		end,
		bind_instant_screenshot    = fake_factory,
		bind_layer_scroll          = fake_factory,
		bind_wrap_text_if_selected = fake_factory,
		bind_cmd_star              = fake_factory,
		-- Plain actions referenced by the ctrl_* hotkey defs. They are only passed
		-- as callbacks to hs.hotkey.bind (stubbed), never invoked here.
		toggle_awake          = function() end,
		interactive_screenshot = function() end,
		toggle_display_mirror = function() end,
		copy_pixel_color      = function() end,
		toggle_capslock       = function() end,
		lock_screen           = function() end,
		open_emoji_picker     = function() end,
		spotlight_mouse       = function() end,
		teleport_mouse        = function() end,
		pause_mouse_actions = function() mouse_paused = true; return true end,
		resume_mouse_actions = function() mouse_paused = false; return true end,
		stop_mouse_actions = function() mouse_paused = true; return true end,
		is_mouse_actions_paused = function() return mouse_paused end,
		has_pending_mouse_action = function() return false end,
		pause_pixel_actions = function() pixel_paused = true; return true end,
		resume_pixel_actions = function() pixel_paused = false; return true end,
		stop_pixel_actions = function() pixel_paused = true; return true end,
		is_pixel_actions_paused = function() return pixel_paused end,
		has_pending_pixel_action = function() return false end,
		pause_screenshot_actions = function(parent)
			screenshot_claims[parent] = true
			return true
		end,
		resume_screenshot_actions = function(parent)
			screenshot_claims[parent] = nil
			return true
		end,
		stop_screenshot_actions = function(parent)
			screenshot_claims[parent] = true
			return true
		end,
		has_screenshot_pause_claim = function(parent)
			return screenshot_claims[parent] == true
		end,
		has_pending_screenshot_action = function() return false end,
	}

	package.loaded["modules.shortcuts.bindings"] = nil
	bindings = helpers.load_with_stubs("modules.shortcuts.bindings", {
		hotkey = {
			bind = function() return { delete = function() return true end } end,
		},
	})
	return bindings, spy
end




-- ============================================================================
-- ============================================================================
-- ======= 2/ A rebind must leave keep-awake running ==========================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bindings.rebind: keep-awake survives a layout re-arm", function()

	helpers.it("re-creates the hotkeys WITHOUT ever calling stop_awake", function()
		local bindings, spy = load_bindings_with_system_spy()

		bindings.start()
		local factories_after_start = spy.factory_calls
		helpers.assert_true(factories_after_start > 0,
			"start() must have invoked the hotkey factories (harness sanity check)")

		spy.stop_awake    = 0
		spy.factory_calls = 0
		bindings.rebind()

		-- THE regression: routing the rebind through stop() cancelled the jiggler
		-- and dismissed the banner the user had armed for a meeting.
		helpers.assert_eq(spy.stop_awake, 0,
			"a layout re-arm must NOT tear down keep-awake — only a genuine shutdown owns that")

		-- …and it must be a REAL rebind, not a no-op that trivially satisfies the
		-- assertion above. The factories must have run again so the new hotkeys
		-- resolve against the new layout's scancodes.
		helpers.assert_eq(spy.factory_calls, factories_after_start,
			"rebind must actually re-create every hotkey, not silently skip the work")
	end)

	helpers.it("leaves the layer started so the rebind is transparent to callers", function()
		local bindings, _spy = load_bindings_with_system_spy()

		bindings.start()
		bindings.rebind()

		helpers.assert_eq(bindings.is_started(), true,
			"a rebind must not leave the layer stopped")
	end)

	helpers.it("is a no-op on a stopped layer (never re-arms what the user turned off)", function()
		local bindings, spy = load_bindings_with_system_spy()

		bindings.rebind()   -- never started

		helpers.assert_eq(spy.factory_calls, 0,
			"rebind on a stopped layer must not bind anything")
		helpers.assert_eq(spy.stop_awake, 0, "rebind must never touch keep-awake")
		helpers.assert_eq(bindings.is_started(), false, "rebind must not start a stopped layer")
	end)

	helpers.it("restores keep-awake when PAUSE re-enters the transient stopped rebind state", function()
		local options = {}
		local bindings, spy = load_bindings_with_system_spy(options)
		helpers.assert_eq(bindings.start(), true)
		options.reenter_factory = true

		helpers.assert_eq(bindings.rebind(), false)
		helpers.assert_eq(spy.reentrant_pause_result, false,
			"PAUSE cannot settle while a native rebind factory is still on-stack")
		helpers.assert_eq(spy.pause_awake, 1)
		helpers.assert_eq(bindings.has_pause_debt(), true)

		helpers.assert_eq(bindings.resume_rebind_after_pause(), true)
		helpers.assert_eq(spy.resume_awake, 1,
			"the ON snapshot preceding started=false must restore keep-awake exactly")
		helpers.assert_eq(bindings.is_started(), true)
		helpers.assert_eq(bindings.has_pause_debt(), false)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the rebind snapshot when keep-awake resume returns " .. mode,
			function()
				local options = {}
				local bindings, spy = load_bindings_with_system_spy(options)
				helpers.assert_eq(bindings.start(), true)
				options.reenter_factory = true
				helpers.assert_eq(bindings.rebind(), false)
				options.resume_awake_mode = mode
				helpers.assert_eq(bindings.resume_rebind_after_pause(), false)
				helpers.assert_eq(bindings.is_started(), false)
				helpers.assert_eq(bindings.has_pause_debt(), true)
				options.resume_awake_mode = nil
				helpers.assert_eq(bindings.resume_rebind_after_pause(), true)
				helpers.assert_eq(bindings.is_started(), true)
				helpers.assert_eq(bindings.has_pause_debt(), false)
				helpers.assert_eq(spy.resume_awake, 2,
					"only the same retained snapshot retries keep-awake restoration")
			end)
	end
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ A genuine shutdown still owns the teardown ======================
-- ============================================================================
-- ============================================================================

helpers.describe("shortcuts.bindings.stop: a real shutdown still tears keep-awake down", function()

	helpers.it("calls stop_awake exactly once", function()
		local bindings, spy = load_bindings_with_system_spy()

		bindings.start()
		spy.stop_awake = 0
		bindings.stop()

		-- The deliberate asymmetry: this is the ONE path that owns the keep-awake
		-- lifecycle. Encoded so a future refactor cannot collapse stop() and
		-- rebind() back into a single routine and silently reintroduce the bug.
		helpers.assert_eq(spy.stop_awake, 1,
			"a genuine shutdown MUST stop keep-awake — the jiggler cannot outlive the subsystem")
		helpers.assert_eq(bindings.is_started(), false, "stop() must leave the layer stopped")
	end)

	helpers.it("does not call stop_awake when it was never started", function()
		local bindings, spy = load_bindings_with_system_spy()

		bindings.stop()   -- never started

		helpers.assert_eq(spy.stop_awake, 0,
			"stop() on a stopped layer must early-return before the keep-awake teardown")
	end)
end)

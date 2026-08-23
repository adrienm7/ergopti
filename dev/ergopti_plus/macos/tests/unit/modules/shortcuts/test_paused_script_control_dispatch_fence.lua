--- tests/unit/modules/shortcuts/test_paused_script_control_dispatch_fence.lua

--- ==============================================================================
--- MODULE: Paused Script-Control Dispatch Fence Regression
--- DESCRIPTION:
--- Drives the real script-control eventtap callback after a committed pause.
--- The dedicated tap must remain alive so the user can resume, but that does not
--- authorize ordinary gesture or UI actions configured on its other slots.
--- ==============================================================================

local helpers = require("tests.helpers")

local dispatched = 0
local lifecycle_dispatches = { script_reload = 0, script_quit = 0 }

package.loaded["infra.logger"] = helpers.make_logger_stub()
package.loaded["infra.notifications"] = { notify = function() end }
package.loaded["infra.keycodes"] = {
	F13_KARABINER_RETURN = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE = 0x6C,
	BACKSPACE = 0x33,
	RETURN = 0x24,
	ESCAPE = 0x35,
}
package.loaded["modules.gestures.engine"] = { init = function() end }
package.loaded["modules.gestures.actions"] = {
	SG_NAMES = {
		"none", "script_pause_toggle", "script_reload", "script_quit",
		"open_metrics_typing",
	},
	AX_NAMES = {},
	get_label = function(name) return name end,
	execute_single = function(action)
		if action == "open_metrics_typing" then dispatched = dispatched + 1 end
		if lifecycle_dispatches[action] ~= nil then
			lifecycle_dispatches[action] = lifecycle_dispatches[action] + 1
		end
		return true
	end,
}
package.loaded["modules.keylogger"] = { log_shortcut = function() end }
package.loaded["modules.llm.api_mlx"] = {
	stop_warmup = function() return true end,
	resume_warmup = function() return true end,
}
package.loaded["modules.llm.api_ollama"] = { stop_warmup = function() return true end }
package.loaded["modules.llm.api_remote"] = { stop_warmup = function() return true end }
package.loaded["modules.llm.warmup_controller"] = {
	stop = function() return true end,
	schedule_warmup_with_retry = function() return true end,
}
package.loaded["ui.wpm.wpm_menubar"] = {
	is_running = function() return false end,
}
package.loaded["ui.wpm.wpm_widget"] = {
	is_running = function() return false end,
}
package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
package.loaded["ui.tooltip"] = { hide_forced = function() return true end }

package.loaded["adapters.synthetic_input"] = nil
local SyntheticInput = helpers.load_with_stubs("adapters.synthetic_input")
SyntheticInput.when_idle = function(callback)
	callback()
	return true
end
SyntheticInput.defer_after_callback = function(_, callback)
	hs.timer.doAfter(0, callback)
	return true
end

local ScriptControl = helpers.load_with_stubs("modules.shortcuts.script_control")
local hs_stub = _G.hs

hs_stub.application.frontmostApplication = function()
	return { title = function() return "TestApp" end }
end
hs_stub.eventtap.checkKeyboardModifiers = function() return { _raw = 0 } end

local keymap = {
	pause_processing = function() return true end,
	resume_processing = function() return true end,
	reset_predictions = function() return true end,
}
local shortcuts = {
	is_bindings_started = function() return false end,
}
local gestures = {
	is_enabled = function() return true end,
	suspend = function() return true end,
	resume = function() return true end,
}

--- Builds a genuine Karabiner-tagged F14 sentinel event.
--- @return table event
local function tagged_backspace_sentinel()
	return {
		getProperty = function() return 0 end,
		getKeyCode = function() return 0x6B end,
		getFlags = function() return { ctrl = true, shift = true } end,
	}
end

helpers.describe("audit pause fence: script control delivery", function()
	helpers.it("audit pause fence: rejects an ordinary configured action while preserving the live tap", function()
		ScriptControl.set_shortcut_action("backspace", "open_metrics_typing")
		ScriptControl.start(keymap, shortcuts, gestures, nil)
		ScriptControl.pause_all()

		helpers.assert_true(ScriptControl.is_paused(),
			"the precondition must be a fully committed pause")
		local taps = hs_stub.eventtap.__taps
		local tap = taps[#taps]
		helpers.assert_true(tap and tap.enabled and type(tap.fn) == "function",
			"the dedicated script-control tap must remain live during pause")

		local consumed = tap.fn(tagged_backspace_sentinel())
		helpers.assert_eq(consumed, true,
			"a recognized script-control sentinel remains consumed while paused")
		hs_stub.timer.__fire_all()

		ScriptControl.set_shortcut_action("backspace", "script_reload")
		tap.fn(tagged_backspace_sentinel())
		hs_stub.timer.__fire_all()
		ScriptControl.set_shortcut_action("backspace", "script_quit")
		tap.fn(tagged_backspace_sentinel())
		hs_stub.timer.__fire_all()
		ScriptControl.stop()

		helpers.assert_eq(dispatched, 0,
			"pause may keep lifecycle control reachable but must reject ordinary UI actions")
		helpers.assert_eq(lifecycle_dispatches.script_reload, 1,
			"reload must remain reachable as an explicit paused lifecycle action")
		helpers.assert_eq(lifecycle_dispatches.script_quit, 1,
			"quit must remain reachable as an explicit paused lifecycle action")
	end)
end)

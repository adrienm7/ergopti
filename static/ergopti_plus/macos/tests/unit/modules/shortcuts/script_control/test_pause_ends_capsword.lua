--- tests/unit/modules/shortcuts/script_control/test_pause_ends_capsword.lua

--- ==============================================================================
--- MODULE: A Pause Ends CapsWord (macOS)
--- DESCRIPTION:
--- Windows (DisableCapsWord) and Linux (cancel_caps_word) end CapsWord when the
--- driver pauses. macOS did not: the paused Karabiner graph holds no CapsWord
--- rule, so its auto-off could not answer and the CapsLock it raised stayed on
--- through the pause (paused-ends-capsword). The pause inventory now runs the
--- remap watchers' end_capsword_for_pause, and the watcher clears only a
--- CapsWord it knows is active.
--- ==============================================================================

local helpers = require("tests.helpers")

local dispatched = 0
local lifecycle_dispatches = { script_reload = 0, script_quit = 0 }

package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
package.loaded["core.ui.engine.notifications"] = { notify = function() end }
package.loaded["platform.input.keycodes"] = {
	F13_KARABINER_RETURN = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE = 0x6C,
	F18_KARABINER_DELETE = 0x4F,
	SCRIPT_CHORD_SENTINELS = require("platform.input.keycodes.core").SCRIPT_CHORD_SENTINELS,
	BACKSPACE = 0x33,
	RETURN = 0x24,
	ESCAPE = 0x35,
	FORWARD_DELETE = 0x75,
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
package.loaded["modules.keystats"] = { log_shortcut = function() end }
package.loaded["ai.engine.api.mlx"] = {
	stop_warmup = function() return true end,
	resume_warmup = function() return true end,
}
package.loaded["ai.engine.api.ollama"] = { stop_warmup = function() return true end }
package.loaded["ai.engine.api.remote"] = { stop_warmup = function() return true end }
package.loaded["ai.engine.local_servers.warmup_controller"] = {
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
package.loaded["core.ui.ui.tooltip"] = { hide_forced = function() return true end }

package.loaded["platform.input.synthetic_input"] = nil
local SyntheticInput = helpers.load_with_stubs("platform.input.synthetic_input")
SyntheticInput.when_idle = function(callback)
	callback()
	return true
end
SyntheticInput.defer_after_callback = function(_, callback)
	hs.timer.doAfter(0, callback)
	return true
end

local capsword_ends = 0
package.loaded["platform.remap.watchers"] = {
	end_capsword_for_pause = function() capsword_ends = capsword_ends + 1; return true end,
}

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

helpers.describe("(paused-ends-capsword) a pause ends CapsWord", function()
	helpers.it("(paused-ends-capsword) the pause inventory ends a running CapsWord", function()
		ScriptControl.start(keymap, shortcuts, gestures, nil)
		ScriptControl.pause_all()
		hs_stub.timer.__fire_all()
		helpers.assert_true(ScriptControl.is_paused(), "the precondition is a committed pause")
		helpers.assert_eq(capsword_ends, 1, "the pause ends CapsWord once")
		ScriptControl.resume_all()
		hs_stub.timer.__fire_all()
		helpers.assert_eq(capsword_ends, 1, "the resume restores no CapsWord")
		ScriptControl.stop()
		package.loaded["platform.remap.watchers"] = nil
	end)
end)

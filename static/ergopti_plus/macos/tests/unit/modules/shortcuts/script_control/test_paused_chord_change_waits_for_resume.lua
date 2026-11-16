--- tests/unit/modules/shortcuts/script_control/test_paused_chord_change_waits_for_resume.lua

--- ==============================================================================
--- MODULE: Paused Script Chord Change Regression
--- DESCRIPTION:
--- A script chord slot or the chords' switch changed while paused is kept as the
--- configured value at once and takes effect only once the resume settles, so
--- the chord that resumes stays the one active when the pause began (the
--- maintainer's decision of 2026-11-14). Before, the change applied at once and
--- moving the pause toggle off its chord left a paused Mac with no chord back.
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

--- Builds a genuine Karabiner-tagged sentinel event.
--- @param keycode number The slot's sentinel keycode (F14 by default).
--- @return table event
local function tagged_sentinel(keycode)
	return {
		getProperty = function() return 0 end,
		getKeyCode = function() return keycode or 0x6B end,
		getFlags = function() return { ctrl = true, shift = true } end,
	}
end

helpers.describe("(paused-chord-change) script chords changed while paused", function()
	helpers.it("(paused-chord-change) keeps the resume chord until the resume settles", function()
		ScriptControl.set_shortcut_action("script_altgr_enter", "script_pause_toggle")
		ScriptControl.set_shortcut_action("script_altgr_backspace", "none")
		ScriptControl.set_chords_enabled(true)
		ScriptControl.start(keymap, shortcuts, gestures, nil)
		ScriptControl.pause_all()
		hs_stub.timer.__fire_all()
		helpers.assert_true(ScriptControl.is_paused(), "the precondition is a committed pause")

		helpers.assert_eq(ScriptControl.set_shortcut_action("script_altgr_enter", "none"), true,
			"a paused assignment is accepted")
		helpers.assert_eq(ScriptControl.set_shortcut_action("script_altgr_backspace", "script_pause_toggle"), true,
			"a paused assignment is accepted")
		helpers.assert_eq(ScriptControl.get_shortcut_actions().script_altgr_enter, "none",
			"the configured value is the new one at once")
		helpers.assert_eq(ScriptControl.get_shortcut_actions().script_altgr_backspace, "script_pause_toggle",
			"the configured value is the new one at once")
		helpers.assert_eq(ScriptControl.slot_runs("script_altgr_enter"), true,
			"the chord active at pause time still resumes")
		helpers.assert_eq(ScriptControl.slot_runs("script_altgr_backspace"), false,
			"the new chord waits for the resume")
		helpers.assert_eq(ScriptControl.karabiner_chords().paused.script_altgr_enter, true,
			"Karabiner keeps the resume chord's sentinel while paused")

		helpers.assert_eq(ScriptControl.set_chords_enabled(false), true, "a paused switch is accepted")
		helpers.assert_eq(ScriptControl.chords_enabled(), false, "the configured switch is the new one")
		helpers.assert_eq(ScriptControl.slot_runs("script_altgr_enter"), true,
			"switching the chords off while paused keeps the way back")
		ScriptControl.set_chords_enabled(true)

		ScriptControl.resume_all()
		hs_stub.timer.__fire_all()
		helpers.assert_eq(ScriptControl.is_paused(), false, "the resume settled")
		helpers.assert_eq(ScriptControl.slot_runs("script_altgr_enter"), false,
			"the paused change applies on resume")
		helpers.assert_eq(ScriptControl.slot_runs("script_altgr_backspace"), true,
			"the paused change applies on resume")
		ScriptControl.stop()
	end)
end)

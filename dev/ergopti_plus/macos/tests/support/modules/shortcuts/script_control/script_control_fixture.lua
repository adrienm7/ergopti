--- tests/support/modules/shortcuts/script_control/script_control_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_script_control
--- DESCRIPTION:
--- Prelude shared by the test_script_control_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub modules required at top-level by script_control.lua so that load_with_stubs
-- can fully execute the module and expose pause_all/resume_all etc on the returned table.
package.loaded["infra.notifications"] = { notify = function() end }
package.loaded["infra.keycodes"] = {
	F13_KARABINER_RETURN = 0x6A,
	F14_KARABINER_BACKSPACE = 0x6B,
	F15_KARABINER_ESCAPE = 0x6C,
	F18_KARABINER_DELETE = 0x4F,
	SCRIPT_CHORD_SENTINELS = require("keycodes").SCRIPT_CHORD_SENTINELS,
	BACKSPACE = 0x33,
	RETURN = 0x24,
	ESCAPE = 0x35,
	FORWARD_DELETE = 0x75,
}
package.loaded["infra.i18n"] = { get = function(k) return k end, get_locale = function() return "fr" end }
package.loaded["modules.gestures.engine"] = {
  init = function() end
}
package.loaded["modules.gestures.conflicts"] = {
  on_action_changed = function() end
}
package.loaded["modules.gestures.actions"] = {
  init = function() end,
  get_label = function(n) return n end,
  SG_NAMES = { "none", "script_pause_toggle", "script_reload", "script_quit", "other_action" },
  AX_NAMES = {}
}
-- Pause requires tooltip teardown to commit. Keep the generic state-machine
-- tests independent from the real canvas-backed tooltip, which cannot own a
-- surface under the headless hs stub.
package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
-- The fixed HS-012 inventory lazy-loads every owner. These broad ScriptControl
-- API tests must not depend on a real owner cached by an earlier test module.
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
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["ui.wpm.wpm_widget"] = {
	is_running = function() return false end,
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["platform.remap.onboarding"] = { stop = function() return true end }

-- Force a fresh adapters.key_state so it captures THIS file's hs stub (the F-CRIT-1
-- sentinel guard delegates the live right-AltGr query to that adapter).
package.loaded["adapters.key_state"] = nil

-- These broad API tests are not serializer timing tests. Complete the newly
-- required input-idle fence synchronously while retaining the real adapter's
-- classification/defer paths used by the sentinel cases below.
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

-- ScriptControl's watchdog scheduler must capture the same fresh hs stub as
-- ScriptControl itself; load_with_stubs deliberately reloads only its target.
package.loaded["adapters.timer_scheduler"] = nil
local SC = helpers.load_with_stubs("modules.shortcuts.script_control")

return {
	SC = SC,
	SyntheticInput = SyntheticInput,
}

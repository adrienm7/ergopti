--- tests/support/modules/shortcuts/script_control/script_control_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_script_control
--- DESCRIPTION:
--- Prelude shared by the test_script_control_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["core.logger.engine.logger"] = nil
local _ = helpers.load_with_stubs("core.logger.engine.logger")

-- Stub modules required at top-level by script_control.lua so that load_with_stubs
-- can fully execute the module and expose pause_all/resume_all etc on the returned table.
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
package.loaded["core.i18n.engine.i18n"] = { get = function(k) return k end, get_locale = function() return "fr" end }
package.loaded["gestures.engine.engine"] = {
  init = function() end
}
package.loaded["gestures.engine.conflicts"] = {
  on_action_changed = function() end
}
package.loaded["gestures.engine.actions"] = {
  init = function() end,
  get_label = function(n) return n end,
  SG_NAMES = { "none", "script_pause_toggle", "script_reload", "script_quit", "other_action" },
  AX_NAMES = {}
}
-- Pause requires tooltip teardown to commit. Keep the generic state-machine
-- tests independent from the real canvas-backed tooltip, which cannot own a
-- surface under the headless hs stub.
package.loaded["core.ui.ui.tooltip"] = { hide_forced = function() return true end }
-- The fixed HS-012 inventory lazy-loads every owner. These broad ScriptControl
-- API tests must not depend on a real owner cached by an earlier test module.
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
package.loaded["metrics.ui.wpm.menubar"] = {
	is_running = function() return false end,
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["metrics.ui.wpm.widget"] = {
	is_running = function() return false end,
	stop = function() return true end,
	resume_after_pause = function() return true end,
}
package.loaded["keyboard.engine.runtime.onboarding"] = { stop = function() return true end }

-- Force a fresh adapters.key_state so it captures THIS file's hs stub (the F-CRIT-1
-- sentinel guard delegates the live right-AltGr query to that adapter).
package.loaded["platform.input.key_state"] = nil

-- These broad API tests are not serializer timing tests. Complete the newly
-- required input-idle fence synchronously while retaining the real adapter's
-- classification/defer paths used by the sentinel cases below.
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

-- ScriptControl's watchdog scheduler must capture the same fresh hs stub as
-- ScriptControl itself; load_with_stubs deliberately reloads only its target.
package.loaded["core.events.timer_scheduler"] = nil
local SC = helpers.load_with_stubs("modules.shortcuts.script_control")

return {
	SC = SC,
	SyntheticInput = SyntheticInput,
}

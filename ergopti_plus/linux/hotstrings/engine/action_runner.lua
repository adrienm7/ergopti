--- hotstrings/engine/action_runner.lua

--- ==============================================================================
--- MODULE: Hotstring Actions (Linux)
--- DESCRIPTION:
--- Runs the action of a hotstring action entry once its edit has landed
--- (_shared/hotstrings/engine/matcher/action_entry.lua): a workflow through the
--- workflow owner, any other parameterless action through the gesture
--- executor, out of the key callback on the next timer turn.
--- ==============================================================================

local Logger = require("core.logger.engine.shim")
local ActionEntry = require("hotstrings.engine.matcher.action_entry")

local M = {}

local LOG = "hotstrings.engine.action_runner"

--- Schedules the action of a committed match result.
--- @param result table A match result with action (and workflow).
--- @param deps table|nil { after, workflows, gestures } (tests).
function M.run(result, deps)
	deps = deps or {}
	local after = deps.after or function(fn) return require("core.events.timer_scheduler").after(0, fn) end
	local fields = { action = result.action, workflow = result.workflow }
	after(function()
		local gestures = deps.gestures or require("gestures.engine.manager")
		local ran, refusal = ActionEntry.dispatch(fields, {
			run_workflow = function(parameter) return (deps.workflows or require("modules.shortcuts.workflows")).run(parameter) end,
			execute = function(action) return gestures.execute_action(action, "hotstring") end,
			parameter_spec = function(action) return gestures.get_action_parameter_spec(action) end,
		})
		if not ran then
			Logger.warn(LOG, "The action '%s' of a hotstring did not run: %s.", fields.action, tostring(refusal or "refused"))
		end
	end)
end

return M

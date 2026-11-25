--- hotstrings/engine/action_runner.lua

--- ==============================================================================
--- MODULE: Hotstring Actions (macOS)
--- DESCRIPTION:
--- Runs the action of a hotstring action entry after its edit
--- (_shared/hotstrings/engine/matcher/action_entry.lua), on the next timer
--- turn so it never runs inside the event tap: a workflow through the macOS
--- workflow owner, any other parameterless action through the gesture registry.
--- ==============================================================================

local Logger = require("core.logger.engine.logger")
local ActionEntry = require("hotstrings.engine.matcher.action_entry")

local M = {}

local LOG = "hotstrings.engine.action_runner"

--- Schedules an entry's action.
--- @param fields table { action, workflow }.
--- @param deps table|nil { timer, workflows, actions } (tests).
function M.run(fields, deps)
	deps = deps or {}
	local timer = deps.timer or require("core.events.timer_scheduler")
	timer.after(0, function()
		local registry = deps.actions or require("gestures.engine.actions")
		local done, why = ActionEntry.dispatch(fields, {
			run_workflow = (deps.workflows or require("modules.shortcuts.workflows")).run,
			execute = function(action) return registry.execute_single(action, "hotstring") end,
			parameter_spec = registry.get_action_parameter_spec,
		})
		if not done then Logger.warn(LOG, "Hotstring action '%s' refused: %s.", fields.action, tostring(why or "refused")) end
	end)
end

return M

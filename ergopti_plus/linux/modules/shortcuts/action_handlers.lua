--- modules/shortcuts/action_handlers.lua

--- ==============================================================================
--- MODULE: Daemon Action Handlers (Linux)
--- DESCRIPTION:
--- Builds the one table of daemon-owned action handlers the gesture executor
--- receives at init: the script-control actions, the text actions of the
--- shortcuts manager (case transforms, selection, plain paste, wrapping) and the
--- prediction engine's manual trigger.
---
--- FEATURES & RATIONALE:
--- 1. One builder for the daemon and the catalogue parity test, so the test
---    checks the table the daemon really injects rather than a copy of it.
--- 2. Two providers never answer the same id: a duplicate is a wiring error,
---    raised at boot instead of letting the last writer win silently.
--- ==============================================================================

local M = {}

--- Merges the script-control handlers with the shortcuts manager's and the
--- prediction engine's handlers.
--- @param script_handlers table { [action_id] = function } from ScriptActions.new().handlers.
--- @param shortcuts table|nil The shortcuts manager; nil when it could not load,
---   which RuntimeGuard.optional_require has already reported.
--- @param prediction table|nil The prediction engine; nil when it could not load,
---   which RuntimeGuard.optional_require has already reported.
--- @return table { [action_id] = function(binding, parameter) }
function M.compose(script_handlers, shortcuts, prediction)
	if type(script_handlers) ~= "table" then
		error("daemon action handlers need the script-control handler table")
	end
	local composed = {}
	for action_name, handler in pairs(script_handlers) do composed[action_name] = handler end
	for _, provider in ipairs({
		{ module = shortcuts, name = "the shortcuts manager" },
		{ module = prediction, name = "the prediction engine" },
	}) do
		if provider.module ~= nil then
			if type(provider.module.action_handlers) ~= "function" then
				error(provider.name .. " does not expose action_handlers()")
			end
			for action_name, handler in pairs(provider.module.action_handlers()) do
				if composed[action_name] ~= nil then
					error("action '" .. tostring(action_name) .. "' has two daemon handlers")
				end
				composed[action_name] = handler
			end
		end
	end
	return composed
end

return M

--- infra/teardown_transaction.lua

--- ==============================================================================
--- MODULE: Retryable Local Teardown Transaction
--- DESCRIPTION:
--- Runs independent local resource-release steps without swallowing a sibling
--- failure or forgetting the only handle that can retry it. Exact external
--- fences remain a separate lifecycle concern.
---
--- FEATURES & RATIONALE:
--- 1. Failure visibility: throws and explicit false results are file-logged.
--- 2. Sibling progress: one failed cleanup never prevents healthy siblings.
--- 3. Retry ownership: only proven-successful steps are committed; failed steps
---    run again on the next controlled quit/reload attempt.
--- 4. Extensible completion: a later exit may add quit-only steps even after a
---    completed reload teardown attempt.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "infra.teardown_transaction"

--- Allocates isolated teardown state for one owner.
--- @return table state
function M.new_state()
	return {
		running = false,
		completed = {},
	}
end

--- Validates one complete step list before mutating teardown state.
--- @param steps table[] Ordered `{ name=string, run=function }` descriptors.
--- @return boolean valid
local function validate_steps(steps)
	if type(steps) ~= "table" then
		Logger.error(LOG, "Teardown steps must be a table.")
		return false
	end
	local names = {}
	for index, step in ipairs(steps) do
		if type(step) ~= "table" or type(step.name) ~= "string" or step.name == ""
			or type(step.run) ~= "function" then
			Logger.error(LOG, "Teardown step %d is malformed.", index)
			return false
		end
		if names[step.name] then
			Logger.error(LOG, "Teardown step name '%s' is duplicated.", step.name)
			return false
		end
		names[step.name] = true
	end
	return true
end

--- Runs every unfinished step and commits only exact successes.
--- A nil result is accepted for legacy stop methods; explicit false is failure.
--- @param state table State returned by `M.new_state()`.
--- @param steps table[] Ordered teardown descriptors.
--- @return boolean complete True only when every supplied step is complete.
function M.run(state, steps)
	if type(state) ~= "table" or type(state.completed) ~= "table" then
		Logger.error(LOG, "Teardown transaction state is invalid.")
		return false
	end
	if state.running then
		Logger.error(LOG, "Re-entrant teardown transaction rejected.")
		return false
	end
	if not validate_steps(steps) then return false end

	state.running = true
	local all_complete = true
	for _, step in ipairs(steps) do
		if state.completed[step.name] ~= true then
			local ok, result_or_err = xpcall(step.run, debug.traceback)
			if ok and result_or_err ~= false then
				state.completed[step.name] = true
			else
				all_complete = false
				Logger.error(LOG, "Local teardown step '%s' failed: %s",
					step.name, tostring(result_or_err))
			end
		end
	end
	state.running = false

	if all_complete then
		for _, step in ipairs(steps) do
			if state.completed[step.name] ~= true then
				all_complete = false
				break
			end
		end
	end
	return all_complete
end

return M

--- adapters/task_environment.lua

--- ==============================================================================
--- MODULE: Native Task Environment Adapter
--- DESCRIPTION:
--- Rewrites one prepared hs.task environment before start so launcher identity
--- and logger credentials remain confined to the embedded Hammerspoon process.
--- Every read, write, and readback boundary is protected and fail-closed.
--- ==============================================================================

local M = {}

local LauncherEnvironment = require("infra.launcher_environment")





-- =========================================
-- =========================================
-- ======= 1/ Prepared Task Boundary =======
-- =========================================
-- =========================================

--- Removes launcher-only authority from one task and verifies native readback.
--- The task must not have crossed start() before this function is called.
--- @param task any Prepared native hs.task handle.
--- @return boolean committed
--- @return string|nil detail
function M.sanitize(task)
	if task == nil then return false, "native task handle is missing" end

	local method_ok, get_environment = xpcall(function()
		return task.environment
	end, debug.traceback)
	if not method_ok or type(get_environment) ~= "function" then
		return false, "native task environment reader is unavailable"
	end
	local set_ok, set_environment = xpcall(function()
		return task.setEnvironment
	end, debug.traceback)
	if not set_ok or type(set_environment) ~= "function" then
		return false, "native task environment writer is unavailable"
	end

	local read_ok, environment_or_err = xpcall(function()
		return get_environment(task)
	end, debug.traceback)
	if not read_ok then
		return false, "native task environment read raised: " .. tostring(environment_or_err)
	end
	local sanitized, sanitize_err = LauncherEnvironment.child_copy(environment_or_err)
	if sanitized == nil then return false, sanitize_err end

	local write_ok, write_result = xpcall(function()
		return set_environment(task, sanitized)
	end, debug.traceback)
	if not write_ok then
		return false, "native task environment write raised: " .. tostring(write_result)
	end
	if write_result == false or write_result == nil then
		return false, "native task environment write was refused"
	end

	local verify_ok, observed_or_err = xpcall(function()
		return get_environment(task)
	end, debug.traceback)
	if not verify_ok then
		return false, "native task environment readback raised: " .. tostring(observed_or_err)
	end
	return LauncherEnvironment.verify_child_copy(sanitized, observed_or_err)
end

return M

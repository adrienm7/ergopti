--- infra/runtime_guard.lua

--- ==============================================================================
--- MODULE: Linux Runtime Failure Guard
--- DESCRIPTION:
--- Makes optional capability load failures visible and gives recurring runtime
--- callbacks one error boundary with traceback and explicit cleanup ownership.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.runtime_guard"

--- Loads one optional table module or records why the capability is unavailable.
--- @param module_name string
--- @return table|nil
function M.optional_require(module_name)
	if type(module_name) ~= "string" or module_name == "" then
		Logger.error(LOG, "Optional module name is invalid: %s", tostring(module_name))
		return nil
	end
	local ok, loaded = xpcall(function() return require(module_name) end, debug.traceback)
	if not ok then
		Logger.warn(LOG, "Optional capability '%s' is unavailable: %s", module_name, tostring(loaded))
		return nil
	end
	if type(loaded) ~= "table" then
		Logger.warn(LOG, "Optional capability '%s' returned %s, not a module table.",
			module_name, type(loaded))
		return nil
	end
	return loaded
end

--- Runs one callback and invokes its owner cleanup exactly once after failure.
--- @param label string
--- @param callback function
--- @param on_error function|nil
--- @return boolean, any
function M.call(label, callback, on_error)
	if type(callback) ~= "function" then
		Logger.error(LOG, "Runtime callback '%s' is not callable.", tostring(label))
		return false, "callback is not callable"
	end
	local ok, result = xpcall(callback, debug.traceback)
	if ok then return true, result end
	Logger.error(LOG, "Runtime callback '%s' failed: %s", tostring(label), tostring(result))
	if type(on_error) == "function" then
		local cleanup_ok, cleanup_err = xpcall(on_error, debug.traceback)
		if not cleanup_ok then
			Logger.error(LOG, "Runtime cleanup '%s' failed: %s", tostring(label), tostring(cleanup_err))
		end
	end
	return false, result
end

return M

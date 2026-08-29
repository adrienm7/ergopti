--- infra/launcher_environment.lua

--- ==============================================================================
--- MODULE: Launcher Environment Policy
--- DESCRIPTION:
--- Owns the exact environment variables that exist only to authenticate and
--- identify the embedded Hammerspoon process. They are consumed during boot and
--- must never be inherited by helper subprocesses.
--- ==============================================================================

local M = {}

local MANAGED_KEYS = {
	"ERGOPTI_LAUNCHER_PID",
	"ERGOPTI_LAUNCHER_BUNDLE_ID",
	"ERGOPTI_LOG_PORT",
	"ERGOPTI_LOG_TOKEN",
}

local MANAGED_KEY_SET = {}
for _, name in ipairs(MANAGED_KEYS) do MANAGED_KEY_SET[name] = true end





-- ===============================================
-- ===============================================
-- ======= 1/ Managed Environment Contract =======
-- ===============================================
-- ===============================================

--- Returns a fresh ordered copy of the launcher-only environment keys.
--- @return table keys
function M.managed_keys()
	local copy = {}
	for index, name in ipairs(MANAGED_KEYS) do copy[index] = name end
	return copy
end

--- Copies a native process environment while removing launcher-only authority.
--- Malformed entries fail closed because hs.task:setEnvironment accepts only
--- string pairs and silently dropping an unrelated variable could corrupt a
--- helper's execution context.
--- @param environment table Native environment returned by hs.task:environment().
--- @return table|nil sanitized
--- @return string|nil detail
function M.child_copy(environment)
	if type(environment) ~= "table" then
		return nil, "native task environment is not a table"
	end

	local sanitized = {}
	for key, value in pairs(environment) do
		if type(key) ~= "string" or type(value) ~= "string" then
			return nil, "native task environment contains a non-string entry"
		end
		if not MANAGED_KEY_SET[key] then sanitized[key] = value end
	end
	return sanitized
end

--- Verifies that a native readback contains exactly the sanitized environment.
--- @param expected table Environment submitted to hs.task:setEnvironment().
--- @param observed table Environment read back from the task.
--- @return boolean valid
--- @return string|nil detail
function M.verify_child_copy(expected, observed)
	if type(expected) ~= "table" or type(observed) ~= "table" then
		return false, "native task environment readback is not a table"
	end
	for _, name in ipairs(MANAGED_KEYS) do
		if observed[name] ~= nil then
			return false, "launcher-only environment key survived native sanitization: " .. name
		end
	end
	for key, value in pairs(expected) do
		if observed[key] ~= value then
			return false, "native task environment readback changed required key: " .. tostring(key)
		end
	end
	for key in pairs(observed) do
		if expected[key] == nil then
			return false, "native task environment readback added unexpected key: " .. tostring(key)
		end
	end
	return true
end

return M

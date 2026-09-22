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

-- The other keys the Swift launcher exports. With MANAGED_KEYS they form the
-- boot trail's presence report; only names are ever logged, because the
-- logger token is a credential.
local INFORMATIONAL_KEYS = {
	"ERGOPTI_LAUNCHER_VERSION",
	"ERGOPTI_CONFIG_DIR",
	"ERGOPTI_PATHS_FILE",
	"ERGOPTI_KARABINER_INSTALLER",
	"ERGOPTI_OLLAMA_BIN",
	"ERGOPTI_LAUNCHER_EXECUTABLE",
	"ERGOPTI_REMAP_GUARDIAN_STATUS",
	"ERGOPTI_LAUNCHER_DEVICE",
	"ERGOPTI_LAUNCHER_INODE",
	"ERGOPTI_FATAL_REPORT_FILE",
	"ERGOPTI_LAUNCHER_LOG_FILE",
}

local EXPORTED_KEYS = {}
for _, name in ipairs(MANAGED_KEYS) do EXPORTED_KEYS[#EXPORTED_KEYS + 1] = name end
for _, name in ipairs(INFORMATIONAL_KEYS) do EXPORTED_KEYS[#EXPORTED_KEYS + 1] = name end





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

--- Lists which launcher-exported keys are present, by name only.
--- @param getenv function|nil Injectable environment reader.
--- @return table present Names with a non-empty value.
--- @return table missing Names without one.
function M.presence(getenv)
	local reader = type(getenv) == "function" and getenv or os.getenv
	local present, missing = {}, {}
	for _, name in ipairs(EXPORTED_KEYS) do
		local ok, value = pcall(reader, name)
		if ok and type(value) == "string" and value ~= "" then
			present[#present + 1] = name
		else
			missing[#missing + 1] = name
		end
	end
	return present, missing
end

--- Copies a native process environment while removing launcher-only authority.
--- Malformed entries fail closed because hs.task:setEnvironment accepts only
--- string pairs and silently dropping an unrelated variable could corrupt a
--- helper's execution context.
--- @param environment table Native environment returned by hs.task:environment().
--- @param overrides table|nil Explicit per-child values; launcher-only keys are forbidden.
--- @return table|nil sanitized
--- @return string|nil detail
function M.child_copy(environment, overrides)
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
	if overrides ~= nil then
		if type(overrides) ~= "table" or getmetatable(overrides) ~= nil then
			return nil, "explicit child environment must be a plain table"
		end
		for key, value in pairs(overrides) do
			if type(key) ~= "string" or key == "" or key:find("[%z=]")
				or type(value) ~= "string" or value:find("%z") then
				return nil, "explicit child environment contains an invalid entry"
			end
			if MANAGED_KEY_SET[key] then
				return nil, "explicit child environment contains launcher-only authority: " .. key
			end
			sanitized[key] = value
		end
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

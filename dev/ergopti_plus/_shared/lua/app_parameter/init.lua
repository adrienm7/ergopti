--- _shared/lua/app_parameter/init.lua

--- ==============================================================================
--- MODULE: Application Parameter
--- DESCRIPTION:
--- The app parameter of the open_app action for the macOS and Linux drivers:
--- which values name an application, and how macOS hands one to
--- /usr/bin/open. Windows applies the same rule in
--- modules/gestures/config.ahk (GestureValidateActionParameter).
---
--- FEATURES & RATIONALE:
--- 1. One rule, pinned by _shared/tests/corpus/action_parameters/app_vectors.json,
---    which the three suites replay.
--- 2. Syntax only: whether the value names an installed application depends on
---    the machine, so the action checks it when it runs and logs a refusal.
--- ==============================================================================

local M = {}

-- The byte range of the C0 control characters, and DEL.
local LAST_CONTROL_BYTE = 31
local DELETE_BYTE = 127

-- A reverse-DNS bundle identifier has at least this many components.
local BUNDLE_ID_MIN_COMPONENTS = 3

--- Whether a stored value names an application.
--- @param value any
--- @return boolean
function M.is_valid(value)
	if type(value) ~= "string" or value == "" then return false end
	if value:find("^%s") or value:find("%s$") then return false end
	for index = 1, #value do
		local byte = value:byte(index)
		if byte <= LAST_CONTROL_BYTE or byte == DELETE_BYTE then return false end
	end
	return true
end

--- Whether a value reads as a bundle identifier (com.apple.Safari) rather than
--- an application name or path.
--- @param value string
--- @return boolean
local function is_bundle_identifier(value)
	if value:lower():find("%.app$") then return false end
	local components = 0
	for component in (value .. "."):gmatch("([^%.]*)%.") do
		if not component:find("^[%w%-]+$") then return false end
		components = components + 1
	end
	return components >= BUNDLE_ID_MIN_COMPONENTS
end

--- The arguments of /usr/bin/open that launch a value on macOS: by bundle
--- identifier (-b), otherwise by name or path (-a).
--- @param value any
--- @return table|nil args Nil when the value is invalid.
function M.macos_open_args(value)
	if not M.is_valid(value) then return nil end
	if is_bundle_identifier(value) then return { "-b", value } end
	return { "-a", value }
end

return M

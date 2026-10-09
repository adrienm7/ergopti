--- _shared/lua/error_description.lua
--- ==============================================================================
--- MODULE: Callback Error Description
--- DESCRIPTION:
--- Describes caught Lua failures without invoking object formatting callbacks.
--- Error reporting must not execute another failing or expensive __tostring.
--- ==============================================================================

local M = {}

--- Preserves primitive failure text and describes objects by their stable type.
--- @param failure any Value returned by a protected callback.
--- @return string description Safe diagnostic text without object metamethods.
function M.describe(failure)
	local kind = type(failure)
	if kind == "string" then return failure end
	if kind == "nil" then return "nil" end
	if kind == "boolean" then return failure and "true" or "false" end
	if kind == "number" then return tostring(failure) end
	return "error object (" .. kind .. ")"
end

return M

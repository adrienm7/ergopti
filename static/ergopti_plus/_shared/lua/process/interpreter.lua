--- _shared/lua/process/interpreter.lua
--- ==============================================================================
--- MODULE: Lua Interpreter Launch Metadata
--- DESCRIPTION:
--- Resolve the interpreter from Lua's negative argument indices. Those indices
--- include interpreter options and their values before the script at index zero.
--- ==============================================================================

local M = {}

--- Returns the interpreter token preceding every option in Lua launch metadata.
--- Embedded runtimes may have no launch metadata; native callers own their fallback.
--- @param arguments table|nil Lua's global arg table.
--- @return string|nil Interpreter executable token.
function M.from_arguments(arguments)
	if type(arguments) ~= "table" then return nil end
	local first = -1
	while arguments[first - 1] ~= nil do first = first - 1 end
	local executable = arguments[first]
	return type(executable) == "string" and executable ~= "" and executable or nil
end

return M

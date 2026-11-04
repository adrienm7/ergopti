--- _shared/lua/program_parameter.lua

--- Validates a private executable and literal argv without interpreting shell text.
local Json = require("json")
local Unicode = require("compat.utf8")
local function clean(value)
	return type(value) == "string" and not value:find("%z") and Unicode.len(value) ~= nil
end
local M = {}

-- The caller names its executable path syntax; no driver identity is read here.
local EXECUTABLE_SYNTAXES = {
	windows = function(executable)
		return (executable:match("^%a:[/\\]") or executable:match("^\\\\[^\\/]+\\[^\\/]+\\.")) ~= nil
			and not executable:match("^\\\\[?.]\\")
	end,
	posix = function(executable) return executable:sub(1, 1) == "/" end,
}

--- Decodes one versioned binding value without borrowing native availability.
--- @param value any Persisted scalar JSON value.
--- @param syntax string Executable path syntax: windows or posix.
--- @return table|nil program Detached executable and argument vector.
function M.parse(value, syntax)
	local accepts = EXECUTABLE_SYNTAXES[syntax]
	if type(value) ~= "string" or not accepts then return nil end
	local ok, data = pcall(Json.decode_lossless, value)
	if not ok or type(data) ~= "table" or Json.is_array(data) or Json.is_null(data) then return nil end
	local count = 0
	for key in pairs(data) do
		if key ~= "version" and key ~= "executable" and key ~= "arguments" then return nil end
		count = count + 1
	end
	if count ~= 3 or type(data.version) ~= "number" or data.version ~= 1 then return nil end
	local executable = data.executable
	if not clean(executable) or executable == "" or not accepts(executable) then return nil end
	if not Json.is_array(data.arguments) then return nil end
	local arguments = {}
	for index, argument in ipairs(data.arguments) do
		if not clean(argument) then return nil end
		arguments[index] = argument
	end
	return { executable = executable, arguments = arguments }
end

return M

--- _shared/lua/dynamic_hotstrings/user_source.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Source Loader
--- DESCRIPTION:
--- Loads a deliberately selected user factory from exact source bytes.
--- Missing sources stay absent; example publication requires an explicit action.
--- ==============================================================================
local M = {}

M.EXAMPLE_TEXT = [[-- Programmable dynamic hotstrings. This file is executable user code.
-- Preview is static metadata; callbacks run only after a matching magic key.
return function(api)
	return {
		{
			id = "clock",
			suffix = "@clock",
			preview = "Current time",
			callback = function(context)
				if context.cancelled() then return false end
				return os.date("%H:%M")
			end,
		},
	}
end
]]

--- Creates an example only when the exact configured destination is absent.
--- @param read function Classified native reader.
--- @param publish function Conditional native writer.
--- @param path string Configured source path.
--- @return boolean created
function M.create_example(read, publish, path)
	local receipt = M.read(read, path)
	if not receipt or receipt.present then return false end
	return publish(path, M.EXAMPLE_TEXT, { status = "absent" }) == true
end

--- Reads a source without creating or replacing any user file.
--- @param read function Classified native reader.
--- @param path string Configured source path.
--- @return table|nil receipt
--- @return string|nil error_kind
function M.read(read, path)
	local ok, content, status = pcall(read, path)
	if not ok then return nil, "source-read" end
	if status == "missing" or status == "absent" then
		return { path = path, present = false, content = "" }
	end
	if status ~= "ok" or type(content) ~= "string" then return nil, "source-read" end
	return { path = path, present = true, content = content }
end

--- Rechecks every byte against the admitted source, including file absence.
--- @param read function Classified native reader.
--- @param receipt table Previously read source.
--- @return boolean current
function M.current(read, receipt)
	local next_receipt = M.read(read, receipt.path)
	return next_receipt ~= nil and next_receipt.present == receipt.present
		and next_receipt.content == receipt.content
end

--- Runs the factory once at explicit load time; preview never calls this API.
--- @param read function Classified native reader.
--- @param path string Source path.
--- @param api table Native user API.
--- @return table|nil rules
--- @return table|nil receipt
--- @return string|nil error_kind
function M.load(read, path, api)
	local receipt, problem = M.read(read, path)
	if not receipt then return nil, nil, problem end
	if not receipt.present then return {}, receipt end
	local chunk
	if _VERSION == "Lua 5.1" then
		chunk = loadstring(receipt.content, "@" .. path)
		if chunk then setfenv(chunk, _G) end
	else
		chunk = load(receipt.content, "@" .. path, "t", _G)
	end
	if not chunk then return nil, receipt, "source-syntax" end
	local ok_chunk, factory = pcall(chunk)
	if not ok_chunk or type(factory) ~= "function" then return nil, receipt, "source-factory" end
	local ok_factory, rules = pcall(factory, api)
	if not ok_factory then return nil, receipt, "source-factory" end
	local valid, validation_error = require("dynamic_hotstrings.user_code").validate(rules)
	if not valid then return nil, receipt, validation_error end
	-- A factory may touch its own file. Admit only the exact bytes it executed.
	if not M.current(read, receipt) then return nil, receipt, "source-changed" end
	return valid, receipt
end

return M

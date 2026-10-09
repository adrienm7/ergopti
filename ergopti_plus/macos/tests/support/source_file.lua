--- tests/support/source_file.lua

--- ==============================================================================
--- MODULE: Complete Source File Reader
--- DESCRIPTION:
--- Returns source text only after open, read and close succeed. Read failures
--- still close the acquired handle; diagnostics retain the path and phase.
--- ==============================================================================

local M = {}

--- Reads one mandatory source file without turning I/O failure into absence.
--- @param path string Source pathname.
--- @return string Complete source text, including a valid empty file.
function M.read(path)
	assert(type(path) == "string" and path ~= "", "source file requires a non-empty path")
	local function fail(phase, reason)
		error("source " .. phase .. " failed (" .. path .. "): " .. tostring(reason), 0)
	end
	local opened = table.pack(pcall(io.open, path, "r"))
	if not opened[1] then fail("open", opened[2]) end
	if not opened[2] then fail("open", opened[3]) end
	local file = opened[2]
	local read = table.pack(pcall(file.read, file, "*a"))
	local closed = table.pack(pcall(file.close, file))
	if not read[1] then fail("read", read[2]) end
	if type(read[2]) ~= "string" then fail("read", read[3] or "expected source text") end
	if not closed[1] then fail("close", closed[2]) end
	if closed[2] ~= true then fail("close", closed[3]) end
	return read[2]
end

return M

--- tests/support/file_system_write_stub.lua

--- ==============================================================================
--- MODULE: File-System Fixture I/O Test Stub
--- DESCRIPTION:
--- Supplies faithful classified-read and boolean-write contracts for
--- serializer-focused tests on Windows, where POSIX rename cannot replace an
--- existing destination. Symlink-safe reads and atomic staging semantics are
--- covered separately by the adapter behavior suites.
--- ==============================================================================

local M = {}

--- Reads a complete fixture and exposes the production status contract.
--- @param path string Source path.
--- @return string|nil content
--- @return string status `ok`, `absent`, or `error`.
--- @return string|nil detail
function M.read_with_status(path)
	local open_ok, fh, open_err, open_code = pcall(io.open, path, "r")
	if not open_ok then return nil, "error", tostring(fh) end
	if not fh then
		if open_code == 2 then return nil, "absent", tostring(open_err) end
		return nil, "error", tostring(open_err)
	end
	local read_ok, content, read_err = pcall(fh.read, fh, "*a")
	local close_ok, closed, close_err = pcall(fh.close, fh)
	if not read_ok or type(content) ~= "string" then
		return nil, "error", tostring(read_ok and read_err or content)
	end
	if not close_ok or closed ~= true then
		return nil, "error", tostring(close_ok and close_err or closed)
	end
	return content, "ok"
end

--- Writes a complete test fixture and reports exact write/close outcomes.
--- @param path string Destination path.
--- @param content string File content.
--- @return boolean committed
function M.write(path, content)
	local fh = io.open(path, "w")
	if not fh then return false end
	local written = fh:write(content)
	local closed = fh:close()
	return written ~= nil and written ~= false and closed == true
end

return M

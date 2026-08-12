--- tests/support/file_system_write_stub.lua

--- ==============================================================================
--- MODULE: File-System Write Test Stub
--- DESCRIPTION:
--- Supplies a faithful boolean write contract for serializer-focused tests on
--- Windows, where POSIX rename cannot replace an existing destination. Atomic
--- staging semantics are covered separately by the adapter behavior suite.
--- ==============================================================================

local M = {}

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

--- tests/support/toml_output_fixture.lua

--- ==============================================================================
--- MODULE: Owned TOML Output Fixture
--- DESCRIPTION:
--- Reclaims test output and its stable writer sidecar after the transaction.
--- ==============================================================================

local M = {}
local WRITE_LOCK_SUFFIX = ".ergoptiplus-write-lock-v1"

--- Runs real writer/reader work against one owned temporary pathname.
--- @param callback function Receives the output path and its lock sidecar path.
--- @return ... Callback results.
function M.with_output(callback)
	assert(type(callback) == "function", "TOML fixture callback must be a function")
	local remove = os.remove
	local path = assert(os.tmpname()):gsub("\\", "/")
	local lock_path = path .. WRITE_LOCK_SUFFIX
	local outcome = table.pack(pcall(callback, path, lock_path))
	local cleanup_errors = {}
	-- The writer must retain this inode between transactions. Only the fixture
	-- owner may reclaim it after all work against its temporary output has ended.
	for _, owned_path in ipairs({ path, lock_path }) do
		local ok, removed, reason, code = pcall(remove, owned_path)
		if not ok or (not removed and code ~= 2) then
			cleanup_errors[#cleanup_errors + 1] = owned_path .. ": " .. tostring(ok and reason or removed)
		end
	end
	if #cleanup_errors > 0 then
		local primary = outcome[1] and "TOML fixture cleanup failed" or tostring(outcome[2])
		error(primary .. "; cleanup: " .. table.concat(cleanup_errors, "; "), 0)
	end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M

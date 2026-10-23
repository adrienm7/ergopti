--- tests/meta/lua_safety/test_file_system_read_closes_handle.lua

--- ==============================================================================
--- MODULE: File_system.lua read closes its handle (meta)
--- DESCRIPTION:
--- adapters/file_system.lua M.read must close its handle when the read panics.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("file_system.lua read closes its handle", function()

	-- ==================================================
	-- ===== 1) file_system.lua: read() FD leak fixed
	-- ==================================================

	helpers.it("file_system.lua M.read must close fh even when fh:read() panics", function()
		local src = read_src("function M.expand_path") -- adapters/file_system.lua
		assert(src, "adapters/file_system.lua must be readable")
		-- The fix: inner pcall around fh:read("*a") so fh:close() always runs.
		assert(
			src:find("pcall%(function%(%)", 1, false) and src:find("fh:close%(%)", 1, false),
			"file_system.lua: M.read must wrap fh:read() in pcall and call fh:close() outside it"
		)
	end)

end)

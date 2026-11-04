--- tests/support/shell_messages_fixture.lua

--- ==============================================================================
--- MODULE: Shell Messages Fixture
--- DESCRIPTION:
--- The Linux shell scripts source install/messages.sh, which reads the generated
--- catalogues in _generated/shell_messages/ beside the install/ folder. A test
--- that copies a script into a sandbox driver tree provides both through this
--- helper, the way the real driver tree carries them, instead of the script
--- special-casing their absence. The JavaScript gates use
--- tools/test/lib/shell-messages-fixture.cjs for the same purpose.
--- ==============================================================================

local M = {}

local helpers = require("tests.helpers")

--- Copies one file byte for byte.
--- @param source string
--- @param destination string
local function copy(source, destination)
	local input = assert(io.open(source, "rb"))
	local bytes = assert(input:read("*a"))
	assert(input:close())
	local output = assert(io.open(destination, "wb"))
	assert(output:write(bytes))
	assert(output:close())
end

--- Copies the message reader and every catalogue into a sandbox driver tree.
--- @param install_directory string The sandbox's existing install/ folder.
function M.provide(install_directory)
	local uv = require("luv")
	local driver = helpers.driver_root()
	copy(driver .. "/install/messages.sh", install_directory .. "/messages.sh")
	local generated = install_directory .. "/../_generated"
	local catalogues = generated .. "/shell_messages"
	for _, directory in ipairs({ generated, catalogues }) do
		if not uv.fs_stat(directory) then assert(uv.fs_mkdir(directory, 448)) end
	end
	local scan = assert(uv.fs_scandir(driver .. "/_generated/shell_messages"))
	local copied = 0
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then break end
		copy(driver .. "/_generated/shell_messages/" .. name, catalogues .. "/" .. name)
		copied = copied + 1
	end
	assert(copied > 0, "the driver tree holds no shell message catalogue")
end

return M

--- tests/support/network/header_policy_fixture.lua

--- ==============================================================================
--- MODULE: Native HTTP Header Policy Fixture
--- DESCRIPTION:
--- Preloads the real policy with the bundled JSON for isolated HTTP fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Loads the real policy against the bundled fixture data.
--- @return table policy
function M.load()
	local saved_paths, saved_files = package.loaded["core.fs.engine.paths"], package.loaded["core.fs.adapters.file_system"]
	local ok, policy = xpcall(function()
		package.loaded["core.fs.engine.paths"] = { shared = function(path) return helpers.driver_root() .. "../_shared/" .. path end }
		package.loaded["core.fs.adapters.file_system"] = { read_bounded = function(path, maximum)
			local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close())
			assert(#text <= maximum); return text, "ok"
		end }
		package.loaded["core.network.engine.http_header_policy"] = nil
		local actual = require("core.network.engine.http_header_policy")
		assert(actual.validate("Accept", "text/plain"))
		return actual
	end, debug.traceback)
	package.loaded["core.fs.engine.paths"], package.loaded["core.fs.adapters.file_system"] = saved_paths, saved_files
	if not ok then error(policy, 0) end
	return policy
end

return M

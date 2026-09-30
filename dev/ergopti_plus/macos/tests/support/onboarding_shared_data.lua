--- tests/support/onboarding_shared_data.lua

--- ==============================================================================
--- MODULE: Onboarding Shared Data Fixture
--- DESCRIPTION:
--- Serves the wizard's shipped data (the generated catalogue, the locale
--- files and the config migration registry) from the real shared tree to an
--- onboarding module loaded behind virtual path and file-system doubles, so
--- window and bridge tests exercise the real catalogue without authorising any
--- other file access.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

-- Captured before any fixture replaces io.open: the shipped data is read for
-- real even while a test scripts every other stream.
local real_open = io.open

-- The virtual root the patched path owner answers with for shipped data.
local SHIPPED_ROOT = "@shipped/"

--- Whether a shared-tree path names data the wizard ships.
--- @param relative string
--- @return boolean
local function shipped(relative)
	return relative == "ui/_generated/onboarding_catalogue.json"
		or relative == "core/config_schema/migrations.toml"
		or relative:match("^data/locales/[a-z][a-z]%.json$") ~= nil
end

--- Routes the shipped data through the already loaded path and file doubles.
--- Call it after the onboarding module is required and before the wizard runs.
function M.install()
	local paths = assert(package.loaded["infra.paths"], "infra.paths must be loaded")
	local files = assert(package.loaded["adapters.file_system"], "adapters.file_system must be loaded")
	local shared = paths.shared
	paths.shared = function(relative)
		if type(relative) == "string" and shipped(relative) then return SHIPPED_ROOT .. relative end
		return shared(relative)
	end
	-- Catalogue and locales go through read, the migration registry through
	-- read_with_status: both serve the shipped files and nothing else.
	for _, name in ipairs({ "read", "read_with_status" }) do
		local original = files[name]
		files[name] = function(path, ...)
			local relative = type(path) == "string" and path:sub(1, #SHIPPED_ROOT) == SHIPPED_ROOT
				and path:sub(#SHIPPED_ROOT + 1) or nil
			if relative then
				local fh = assert(real_open(helpers.shared(relative), "r"), "shipped data missing: " .. relative)
				local content = fh:read("*a")
				fh:close()
				return content, "ok"
			end
			assert(type(original) == "function", "this fixture authorises no other read: " .. tostring(path))
			return original(path, ...)
		end
	end
end

return M

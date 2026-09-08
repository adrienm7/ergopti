--- tests/support/manifest_menu_fixture.lua

--- ==============================================================================
--- MODULE: Owned Manifest Menu Fixture
--- DESCRIPTION:
--- Keeps real JSON file reads while removing fixture artifacts on every exit.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}

--- Runs a menu scenario with one temporary manifest and scoped module doubles.
--- @param content string JSON fixture contents.
--- @param logger table|nil Optional diagnostic recorder.
--- @param callback function Receives the renderer and temporary file path.
--- @return ... Callback results.
function M.with_manifest(content, logger, callback)
	assert(type(content) == "string", "manifest fixture content must be a string")
	assert(type(callback) == "function", "manifest fixture callback must be a function")
	local open, remove = io.open, os.remove
	local path = assert(os.tmpname(), "could not allocate manifest fixture")
	local handle
	local outcome = table.pack(pcall(function()
		local reason
		handle, reason = open(path, "wb")
		assert(handle, "could not open manifest fixture: " .. tostring(reason))
		local written, write_error = handle:write(content)
		assert(written, "could not write manifest fixture: " .. tostring(write_error))
		local closed, close_error = handle:close()
		handle = nil
		assert(closed, "could not close manifest fixture: " .. tostring(close_error))
		return helpers.with_stub_scope({ "infra.manifest_menu", "infra.logger" }, function()
			package.loaded["infra.logger"] = logger or helpers.make_logger_stub()
			local renderer = helpers.load_with_stubs("infra.manifest_menu")
			package.loaded["infra.paths"].shared = function(relative)
				assert(relative == "modules/menu/menu_manifest.json", "unexpected manifest fixture path")
				return path
			end
			renderer.invalidate_cache()
			return callback(renderer, path)
		end)
	end))
	local cleanup_errors = {}
	if handle then
		local ok, closed, reason = pcall(handle.close, handle)
		if not ok or not closed then
			cleanup_errors[#cleanup_errors + 1] = "close: " .. tostring(ok and reason or closed)
		end
	end
	local ok, removed, reason = pcall(remove, path)
	if not ok or not removed then
		cleanup_errors[#cleanup_errors + 1] = "remove: " .. tostring(ok and reason or removed)
	end
	if #cleanup_errors > 0 then
		local primary = outcome[1] and "manifest fixture cleanup failed" or tostring(outcome[2])
		error(primary .. "; cleanup: " .. table.concat(cleanup_errors, "; "), 0)
	end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M

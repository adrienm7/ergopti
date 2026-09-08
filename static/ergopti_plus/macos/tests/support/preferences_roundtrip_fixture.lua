--- tests/support/preferences_roundtrip_fixture.lua

--- ==============================================================================
--- MODULE: Scoped Preferences Roundtrip Fixture
--- DESCRIPTION:
--- Owns real persistence, native stubs and temporary outputs across assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local output_fixture = require("tests.support.toml_output_fixture")
local M = {}

--- Saves and loads real preferences before invoking semantic assertions.
--- @param state table Preferences to persist.
--- @param callback function Receives saved state, preferences, output and lock paths.
--- @return ... Callback results.
function M.with_roundtrip(state, callback)
	assert(type(state) == "table", "roundtrip state must be a table")
	assert(type(callback) == "function", "roundtrip callback must be a function")
	return helpers.with_stub_scope({
		"infra.preferences", "infra.logger", "adapters.file_system", "infra.fs_dir",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local preferences = helpers.load_with_stubs("infra.preferences")
		return output_fixture.with_output(function(path, lock_path)
			helpers.assert_eq(preferences.save(path, state, {}, {}), true, "preferences save must commit")
			local saved, status = preferences.load(path)
			helpers.assert_eq(status, "ok", "preferences must load committed TOML, not fallback state")
			helpers.assert_type(saved, "table", "load must return decoded preferences")
			return callback(saved, preferences, path, lock_path)
		end)
	end)
end

return M

--- tests/meta/lua_safety/test_toml_cache_closes_handles.lua

--- ==============================================================================
--- MODULE: Toml_cache.lua closes its handles (meta)
--- DESCRIPTION:
--- toml_cache.lua M.store and content_fingerprint must close their handles when a write or read panics.
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

helpers.describe("toml_cache.lua closes its handles", function()

	-- ===================================================
	-- ===== 2) toml_cache.lua: M.store FD leak fixed
	-- ===================================================

	helpers.it("toml_cache.lua M.store must close fh even when fh:write() panics", function()
		local src = read_src("local function read_source_bytes") -- adapters/toml_cache.lua
		assert(src, "adapters/toml_cache.lua must be readable")
		-- The fix: inner pcall around fh:write(body) with fh:close() outside.
		assert(
			src:find("write_ok", 1, true),
			"toml_cache.lua: M.store must use an inner pcall capturing write_ok to guarantee fh:close()"
		)
	end)

	-- ==========================================================
	-- ===== 3) toml_cache.lua: content_fingerprint FD leak fixed
	-- ==========================================================

	helpers.it("toml_cache.lua content_fingerprint must close f even when f:read() panics", function()
		local src = read_src("local function read_source_bytes") -- adapters/toml_cache.lua
		assert(src, "adapters/toml_cache.lua must be readable")
		-- The fix: inner pcall around f:read(...) with f:close() outside.
		assert(
			src:find("read_ok", 1, true),
			"toml_cache.lua: content_fingerprint must use inner pcall capturing read_ok to guarantee f:close()"
		)
	end)

end)

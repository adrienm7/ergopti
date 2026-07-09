--- tests/unit/meta/test_storage_adapter.lua

--- ==============================================================================
--- MODULE: Storage Adapter JSON Round-Trip Regression Guard
--- DESCRIPTION:
--- Verifies that the Linux storage adapter persists and reloads structured
--- values without loss. The adapter serialises its key-value store to
--- storage.json; a value stored with nested tables, arrays, and non-ASCII text
--- must survive a full persist -> reload -> read cycle byte-for-byte.
---
--- ROOT CAUSE ENCODED:
--- storage.lua used a bespoke JSON encoder/decoder. The decoder matched
--- top-level "key":value pairs with a single flat pattern whose value stopped
--- at the first "," or "}", so it could not parse nested objects or arrays: the
--- nested value was dropped and its inner keys leaked to the top level. The
--- encoder also serialised Lua arrays as string-keyed objects. Any non-flat
--- stored value was therefore corrupted on reload. The fix routes encode/decode
--- through the shared _shared/lua/json.lua codec; this test fails (nested/array
--- fields come back nil) against the bespoke codec and passes against json.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway XDG config root under the system temp directory and
--- ensures its ergopti_plus/ subdirectory exists so the storage adapter can
--- write there instead of the developer's real config.
--- @return string Absolute path to inject as XDG_CONFIG_HOME.
local function make_temp_config_root()
	local base = os.tmpname()
	os.remove(base)
	base = base:gsub("\\", "/"):gsub("/+$", "")
	if package.config:sub(1, 1) == "\\" then
		os.execute(string.format('mkdir "%s" 2>nul', (base .. "/ergopti_plus"):gsub("/", "\\")))
	else
		os.execute(string.format('mkdir -p "%s"', base .. "/ergopti_plus"))
	end
	return base
end




-- ===================================================
-- ===================================================
-- ======= 1/ JSON codec round-trip regression =======
-- ===================================================
-- ===================================================

helpers.describe("storage adapter uses the shared JSON codec", function()
	helpers.it("preserves nested tables, arrays, and unicode across a persist/reload cycle", function()
		-- Redirect the adapter at a hermetic temp store: os.getenv is patched so
		-- the module resolves XDG_CONFIG_HOME to a fresh temp dir at load time,
		-- keeping the developer's real storage.json untouched.
		local temp_root   = make_temp_config_root()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			local original = {
				name   = "café",
				nested = { inner = "résumé", count = 3 },
				list   = { 1, 2, 3 },
			}
			helpers.assert_true(storage.set("profile", original), "set() returns true")

			-- Reloading the module clears its in-memory cache, forcing get() to
			-- decode the value from disk rather than returning the live table.
			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("profile"), original,
				"persisted value must round-trip through the JSON codec")
		end)

		-- Always restore global state so later suites see the real config path
		-- and a fresh storage module; the temp-path instance must not leak.
		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(temp_root .. "/ergopti_plus/storage.json")
		os.remove(temp_root .. "/ergopti_plus/storage.json.tmp")
		if not ok then error(err, 0) end
	end)
end)

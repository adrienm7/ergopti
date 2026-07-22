--- tests/unit/lib/test_manifest_menu_resolve_disabled_when_failclosed.lua

--- ==============================================================================
--- MODULE: Regression — resolve_disabled_when fails OPEN on a manifest lookup miss (F-MED-10)
--- DESCRIPTION:
--- ManifestMenu.resolve_disabled_when(menu_key, item_id, getters) returned
--- `false` (enabled) whenever `find_item_by_id` could not locate item_id in
--- menu_key's array — directly contradicting its own docstring ("A missing
--- getter... treated as disabled so the mismatch fails loud") and the sibling
--- getter-mismatch branch a few lines below, which correctly fails CLOSED
--- with a logged ERROR. A corrupted or typo'd manifest reference (or an id
--- renamed on one side only) would silently un-gate a security-sensitive item
--- — e.g. a keylogger-disabled toggle rendering as always-enabled.
---
--- Fix: a lookup miss now fails CLOSED (returns true = disabled) and logs
--- Logger.error, matching the sibling getter-mismatch branch's pattern.
---
--- This test calls resolve_disabled_when with an item_id that does not exist
--- in the (fixture) manifest array and asserts it renders disabled (true) and
--- Logger.error fires — it fails before the fix (returns false, no log) and
--- passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway manifest fixture directory with a "test_menu" key
--- containing exactly one real item — "known_item" — so item_id lookups for
--- anything else are guaranteed misses.
--- @return string tmp_dir Absolute path of the fixture directory created.
local function write_fixture_manifest()
	local tmp_dir = os.tmpname()
	os.remove(tmp_dir) -- os.tmpname() creates a file; we want a directory
	os.execute('mkdir "' .. tmp_dir .. '"')

	local manifest_dir = tmp_dir .. "/modules/menu"
	os.execute('mkdir "' .. tmp_dir .. '/modules" "' .. manifest_dir .. '"')

	local fh = io.open(manifest_dir .. "/menu_manifest.json", "w")
	helpers.assert_true(fh ~= nil, "could not create fixture menu_manifest.json")
	fh:write([[
{
	"test_menu": [
		{ "type": "dynamic", "id": "known_item", "disabled_when": ["some_flag"] }
	]
}
]])
	fh:close()

	return tmp_dir
end

--- Builds a logger stub that records every Logger.error call's formatted message.
--- @return table logger_stub Injectable package.loaded["lib.logger"] replacement.
--- @return table error_messages Array of formatted strings passed to Logger.error (grows live).
local function make_error_capturing_logger()
	local error_messages = {}
	local logger_stub = helpers.make_logger_stub()
	logger_stub.error = function(_module, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		error_messages[#error_messages + 1] = ok and formatted or tostring(fmt)
	end
	return logger_stub, error_messages
end

helpers.describe("ManifestMenu.resolve_disabled_when: fails CLOSED on a manifest lookup miss (F-MED-10)", function()
	helpers.it("returns true (disabled) and logs Logger.error for an item_id absent from the manifest", function()
		local logger_stub, error_messages = make_error_capturing_logger()
		-- manifest_menu.lua captures `local Logger = require("lib.logger")` at
		-- require-time, so the stub must be installed BEFORE load_with_stubs
		-- forces a fresh require of lib.manifest_menu below.
		package.loaded["lib.logger"] = logger_stub

		local ManifestMenu = helpers.load_with_stubs("lib.manifest_menu")

		local tmp_dir = write_fixture_manifest()
		package.loaded["lib.paths"].shared = function(rel)
			if rel and rel ~= "" then return tmp_dir .. "/" .. rel end
			return tmp_dir
		end
		ManifestMenu.invalidate_cache()

		-- All getters truthy: if the resolver were consulting real state, every
		-- key would report "enabled" — isolates the lookup-miss code path.
		local all_true_getters = { some_flag = function() return true end }

		local disabled = ManifestMenu.resolve_disabled_when("test_menu", "does_not_exist_in_manifest", all_true_getters)

		helpers.assert_eq(disabled, true,
			"a manifest lookup miss must fail CLOSED (disabled=true), not silently render an always-enabled item (F-MED-10)")

		local logged = false
		for _, msg in ipairs(error_messages) do
			if msg:find("does_not_exist_in_manifest", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "a manifest lookup miss must log Logger.error naming the missing item_id")
	end)

	helpers.it("still returns false (enabled) for a real item whose disabled_when keys are all truthy (positive control)", function()
		local ManifestMenu = helpers.load_with_stubs("lib.manifest_menu")

		local tmp_dir = write_fixture_manifest()
		package.loaded["lib.paths"].shared = function(rel)
			if rel and rel ~= "" then return tmp_dir .. "/" .. rel end
			return tmp_dir
		end
		ManifestMenu.invalidate_cache()

		local all_true_getters = { some_flag = function() return true end }
		local disabled = ManifestMenu.resolve_disabled_when("test_menu", "known_item", all_true_getters)

		helpers.assert_eq(disabled, false,
			"a real item with every disabled_when getter truthy must remain enabled — the fail-closed fix must not " ..
			"regress the happy path")
	end)
end)

--- tests/unit/lib/test_manifest_menu_resolve_checked_when.lua

--- ==============================================================================
--- MODULE: ManifestMenu.resolve_checked_when — the fail-OPEN half of the pair
--- DESCRIPTION:
--- macOS twin of MenuRenderer_ResolveCheckedWhen. The shared menu manifest has
--- carried `checked_when` on the three metrics privacy rows since they were
--- declared, and exactly one driver could read it: AHK. On macOS the field was
--- inert data, so the same three rows were rendered by hand there.
---
--- FEATURES & RATIONALE:
--- 1. The asymmetry with `disabled_when` is the point of these cases, not an
---    incidental difference. `disabled_when` fails CLOSED and `checked_when`
---    fails OPEN, and both choices come from the same rule: never overstate
---    what is enabled. A checkmark is an ASSERTION that something is on —
---    inventing one when the state cannot be read tells the user a privacy
---    filter is active when it is not, so they stop looking for the setting
---    while the data they believed excluded is being recorded.
--- 2. A missing getter is a manifest/driver drift, so it is still logged as an
---    ERROR even though the render degrades quietly. A row whose checkmark
---    silently never appears is exactly the quiet wrong this module exists to
---    make loud.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates a throwaway manifest fixture with one checked_when item and one
--- item carrying no predicate at all.
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
		{ "type": "dynamic", "id": "two_key_item", "checked_when": ["filter_on", "master_on"] },
		{ "type": "dynamic", "id": "no_predicate_item" }
	]
}
]])
	fh:close()

	return tmp_dir
end

--- Builds a logger stub that records every Logger.error call's formatted message.
--- @return table logger_stub Injectable package.loaded["infra.logger"] replacement.
--- @return table error_messages Array of formatted strings (grows live).
local function make_error_capturing_logger()
	local error_messages = {}
	local logger_stub = helpers.make_logger_stub()
	logger_stub.error = function(_module, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		error_messages[#error_messages + 1] = ok and formatted or tostring(fmt)
	end
	return logger_stub, error_messages
end

--- Loads ManifestMenu against the fixture manifest.
--- @param logger_stub table|nil Optional logger replacement, installed first.
--- @return table ManifestMenu The freshly required module.
local function load_against_fixture(logger_stub)
	-- manifest_menu.lua captures `local Logger = require("infra.logger")` at
	-- require-time, so a stub must be installed BEFORE the fresh require.
	if logger_stub then package.loaded["infra.logger"] = logger_stub end
	local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
	local tmp_dir = write_fixture_manifest()
	package.loaded["infra.paths"].shared = function(rel)
		if rel and rel ~= "" then return tmp_dir .. "/" .. rel end
		return tmp_dir
	end
	ManifestMenu.invalidate_cache()
	return ManifestMenu
end




-- ==============================================
-- ==============================================
-- ======= 1/ Every key must be truthy ==========
-- ==============================================
-- ==============================================

helpers.describe("ManifestMenu.resolve_checked_when: the predicate is a conjunction", function()
	helpers.it("checks the row only when EVERY key is truthy", function()
		local ManifestMenu = load_against_fixture(nil)
		local both = { filter_on = function() return true end, master_on = function() return true end }
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "two_key_item", both), true,
			"both getters truthy must render the checkmark")
	end)

	helpers.it("leaves the row unchecked when any one key is falsy", function()
		local ManifestMenu = load_against_fixture(nil)
		-- The master gate off with the filter on is the real case: the filter's
		-- own flag says "yes" while the subsystem it belongs to is disabled, and
		-- showing a checkmark there claims a filter is running that is not.
		local master_off = { filter_on = function() return true end, master_on = function() return false end }
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "two_key_item", master_off), false,
			"one falsy key must clear the checkmark — the predicate is AND, not OR")
	end)

	helpers.it("never checks a row that declares no predicate", function()
		local ManifestMenu = load_against_fixture(nil)
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "no_predicate_item", {}), false,
			"an item without checked_when is not checked by this mechanism")
	end)
end)




-- ==================================================
-- ==================================================
-- ======= 2/ Failing OPEN, and saying so ===========
-- ==================================================
-- ==================================================

helpers.describe("ManifestMenu.resolve_checked_when: fails OPEN and logs", function()
	helpers.it("returns false and logs an ERROR for an item absent from the manifest", function()
		local logger_stub, errors = make_error_capturing_logger()
		local ManifestMenu = load_against_fixture(logger_stub)

		local all_true = { filter_on = function() return true end, master_on = function() return true end }
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "does_not_exist", all_true), false,
			"a lookup miss must render UNCHECKED — inventing a checkmark asserts a state nobody read")

		local logged = false
		for _, msg in ipairs(errors) do
			if msg:find("does_not_exist", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "a manifest lookup miss must log Logger.error naming the missing item_id")
	end)

	helpers.it("returns false and logs an ERROR when a declared key has no getter", function()
		local logger_stub, errors = make_error_capturing_logger()
		local ManifestMenu = load_against_fixture(logger_stub)

		-- master_on is declared by the manifest and absent from the getters table:
		-- the two have drifted.
		local partial = { filter_on = function() return true end }
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "two_key_item", partial), false,
			"a missing getter must render UNCHECKED, not fall back to the keys it could read")

		local logged = false
		for _, msg in ipairs(errors) do
			if msg:find("master_on", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "a missing getter must log Logger.error naming the key that drifted")
	end)

	helpers.it("is the OPPOSITE of resolve_disabled_when on the same miss, deliberately", function()
		local ManifestMenu = load_against_fixture(nil)
		-- Both resolvers are asked about an id that does not exist. disabled_when
		-- fails CLOSED (true = disabled), checked_when fails OPEN (false =
		-- unchecked). Written as one case because the pair is the invariant: if a
		-- future edit makes them agree, one of them has started overstating what
		-- is enabled, and which one is not obvious from either file alone.
		local none = {}
		helpers.assert_eq(ManifestMenu.resolve_disabled_when("test_menu", "does_not_exist", none), true,
			"disabled_when fails CLOSED")
		helpers.assert_eq(ManifestMenu.resolve_checked_when("test_menu", "does_not_exist", none), false,
			"checked_when fails OPEN — both answers refuse to overstate what is enabled")
	end)
end)

--- tests/support/modules/llm/settings/profile_preferences_canonical_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_profile_preferences_canonical
--- DESCRIPTION:
--- Prelude shared by the test_profile_preferences_canonical_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local Sandbox = require("test.config_unused_keys_contract").sandbox

local Toml = require("toml_codec")

local Json = require("json")

local Base64 = require("compat.base64")

--- Binds the actual idle live owner without replacing the profile/save collaborators.
--- Every native owner is fresh; all module identities/absence are journalled.
local function with_idle_live_owner(settings, body)
	local journal = {}
	for name, value in pairs(package.loaded) do journal[name] = value end
	local owner
	local ok, err = xpcall(function()
		for _, name in ipairs({ "modules.llm.prediction_engine", "modules.llm.profiles", "modules.llm.settings" }) do
			package.loaded[name] = nil
		end
		owner = require("modules.llm.prediction_engine")
		helpers.assert_true(rawequal(require("modules.llm.profile_settings"), settings),
			"the native engine captures the actual fixture profile owner")
		helpers.assert_nil(owner.init(), "fresh native initialization retains its original nil receipt")
		helpers.assert_type(owner.get_live, "function")
		helpers.assert_type(owner.set_live, "function")
		helpers.assert_nil(owner.get_live(), "the genuine initialized fixture starts with no temporary override")
		helpers.assert_eq(owner.set_live(nil), true, "the actual idle stop owner acknowledges exact nil")
		helpers.assert_nil(owner.get_live(), "idle acknowledgement cannot introduce a temporary override")
		body(owner)
	end, debug.traceback)
	local cleaned, cleanup_err = pcall(function()
		if owner then
			helpers.assert_eq(owner.stop_runtime(), true, "the fresh engine retains no native runtime debt")
			helpers.assert_eq(owner.runtime_pending(), false)
			helpers.assert_nil(owner.get_live(), "profile-only fixture actions cannot start live mode")
		end
	end)
	-- This journal also removes dependencies introduced by the genuine engine.
	for name in pairs(package.loaded) do if journal[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(journal) do package.loaded[name] = value end
	if not ok then error(err, 0) end
	if not cleaned then error(cleanup_err, 0) end
end

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings", "adapters.storage" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["llm.profiles.active"] = "raw", ["llm.profiles.num_predictions"] = 9,
			} })
			body(require("modules.llm.profile_settings"), path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

local function profile()
	return { id = "user_canonical", label = "Canonical", system_single = "Continue {context}", batch = false }
end

return {
	helpers = helpers,
	Sandbox = Sandbox,
	Toml = Toml,
	Json = Json,
	Base64 = Base64,
	with_idle_live_owner = with_idle_live_owner,
	with_config = with_config,
	profile = profile,
}

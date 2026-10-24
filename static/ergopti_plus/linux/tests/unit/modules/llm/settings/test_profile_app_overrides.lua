--- tests/unit/modules/llm/settings/test_profile_app_overrides.lua

--- ==============================================================================
--- MODULE: Linux Per-Application Profile Overrides
--- DESCRIPTION:
--- llm.app_profile_overrides maps an application to a prompt profile, as on
--- Windows. This proves the durable owner: the stored text is Windows's v1
--- envelope, a failed write changes nothing, an unreadable stored value is never
--- replaced by an empty one, and deleting a profile drops the overrides that
--- named it in the same write. The rule itself (normalisation, lookup, stored
--- text) is replayed from the shared vectors by the corpus test.
--- ==============================================================================

local helpers = require("tests.helpers")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local Overrides = require("llm.app_profile_overrides")

local held = {}

local function replace(name, value)
	if held[name] == nil then held[name] = package.loaded[name] or false end
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
end

--- A fresh settings owner over an isolated sparse preference port.
local function load_settings(initial, writes_fail)
	local storage = PreferencesFixture.new({ initial = initial or {}, writes_fail = writes_fail })
	replace("infra.llm_preferences", storage)
	package.loaded["modules.llm.profile_settings"] = nil
	local settings = require("modules.llm.profile_settings")
	settings._reset()
	return settings, storage
end

local USER = { id = "user_fixture_1", label = "Fixture", system_single = "Continue {context}", batch = false }

helpers.describe("LLM profile settings: per-application overrides", function()
	helpers.it("app-profile: no override means the menu's profile", function()
		local settings, storage = load_settings()
		helpers.assert_nil(settings.resolve_for_app("firefox"))
		helpers.assert_eq(next(settings.app_overrides()), nil)
		helpers.assert_eq(#storage.keys(), 0, "reading writes nothing")
		restore()
	end)

	helpers.it("app-profile: an override is stored as the v1 envelope and found by a normalised key", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.save_user_profile(USER, false, false))
		helpers.assert_true(settings.set_app_override("Firefox.exe", USER.id))
		helpers.assert_eq(storage.get("llm.app_profile_overrides"), Overrides.encode({ firefox = USER.id }))
		helpers.assert_eq(settings.resolve_for_app("FIREFOX").id, USER.id)
		helpers.assert_eq(settings.resolve_for_app("firefox.exe").id, USER.id)
		helpers.assert_nil(settings.resolve_for_app("kate"))
		-- A new session reads the same map back.
		package.loaded["modules.llm.profile_settings"] = nil
		local reread = require("modules.llm.profile_settings")
		reread._reset()
		helpers.assert_eq(reread.app_overrides().firefox, USER.id)
		restore()
	end)

	helpers.it("app-profile: clearing removes the override and the stored text", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.set_app_override("firefox", "advanced"))
		helpers.assert_eq(settings.clear_app_override("Firefox"), true)
		helpers.assert_nil(settings.resolve_for_app("firefox"))
		helpers.assert_nil(storage.get("llm.app_profile_overrides"), "the neutral value stays sparse")
		helpers.assert_eq(settings.clear_app_override("firefox"), false, "nothing left to clear")
		restore()
	end)

	helpers.it("app-profile: an unknown profile or an unusable application is refused", function()
		local settings, storage = load_settings()
		helpers.assert_eq(settings.set_app_override("firefox", "user_missing"), false)
		helpers.assert_eq(settings.set_app_override("", "advanced"), false)
		helpers.assert_eq(settings.set_app_override("firefox", ""), false)
		helpers.assert_eq(#storage.keys(), 0)
		restore()
	end)

	helpers.it("app-profile: a refused write leaves the map in force unchanged", function()
		local settings = load_settings({}, true)
		helpers.assert_eq(settings.set_app_override("firefox", "advanced"), false)
		helpers.assert_nil(settings.resolve_for_app("firefox"))
		restore()
	end)

	helpers.it("app-profile: an unreadable stored value applies nothing and is never overwritten", function()
		local damaged = "v1:***not-base64***"
		local settings, storage = load_settings({ ["llm.app_profile_overrides"] = damaged })
		helpers.assert_nil(settings.resolve_for_app("firefox"))
		helpers.assert_eq(settings.set_app_override("firefox", "advanced"), false,
			"a write would erase a value this build cannot read")
		helpers.assert_eq(storage.get("llm.app_profile_overrides"), damaged)
		restore()
	end)

	helpers.it("app-profile: deleting a profile drops its overrides in the same write", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.save_user_profile(USER, false, false))
		helpers.assert_true(settings.set_app_override("firefox", USER.id))
		helpers.assert_true(settings.set_app_override("kate", "advanced"))
		-- The registry was read before these writes: a menu rebuild reads it again.
		settings.list_user(true)
		helpers.assert_true(settings.delete_user_profile(USER.id))
		helpers.assert_nil(settings.resolve_for_app("firefox"))
		helpers.assert_eq(settings.resolve_for_app("kate").id, "advanced", "other overrides stay")
		helpers.assert_eq(storage.get("llm.app_profile_overrides"), Overrides.encode({ kate = "advanced" }))
		restore()
	end)
end)

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
	helpers.it("preserves historical profile keys and refuses ambiguous Unicode fallback (unicode-app-identity)", function()
		local settings, storage = load_settings()
		helpers.assert_true(settings.save_user_profile(USER, false, false))
		helpers.assert_true(settings.set_app_override("Éditeur", "advanced"))
		local before = storage.get("llm.app_profile_overrides")
		helpers.assert_eq(settings.resolve_for_app("éditeur").id, "advanced")
		helpers.assert_eq(storage.get("llm.app_profile_overrides"), before, "lookup does not migrate the v1 envelope")
		helpers.assert_true(settings.set_app_override("Ǆ", "advanced"))
		helpers.assert_true(settings.set_app_override("ǅ", USER.id))
		helpers.assert_eq(settings.resolve_for_app("Ǆ").id, "advanced")
		helpers.assert_eq(settings.resolve_for_app("ǅ").id, USER.id)
		helpers.assert_nil(settings.resolve_for_app("ǆ"), "contradictory historical profiles have no fallback")
		for _, invalid in ipairs({ string.char(0x80), string.char(0xc3), string.char(0xc0, 0xaf) }) do
			local stored = { ["É" .. invalid] = "advanced" }
			helpers.assert_eq(Overrides.resolve(stored, "É" .. invalid), "advanced")
			helpers.assert_nil(Overrides.resolve(stored, "é" .. invalid))
		end
		restore()
	end)
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

	helpers.it("app-profile: preserves a wrong-typed saved override", function()
		local Sandbox = require("test.config_unused_keys_contract").sandbox
		for _, source in ipairs({
			'[llm]\napp_profile_overrides = 42\n',
			'[llm]\napp_profile_overrides = false\n',
			'[llm]\napp_profile_overrides = []\n',
			'llm = false\n',
		}) do
			Sandbox.with_config(source, function(path)
				local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings" }
				local saved = {}
				for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
				local ok, err = pcall(function()
					package.loaded["infra.config_paths"] = { config = function() return path end }
					local settings = require("modules.llm.profile_settings")
					helpers.assert_nil(settings.resolve_for_app("firefox"))
					helpers.assert_eq(settings.set_app_override("firefox", "advanced"), false)
					helpers.assert_eq(Sandbox.read_bytes(path), source)
				end)
				for _, name in ipairs(names) do package.loaded[name] = saved[name] end
				if not ok then error(err, 0) end
			end)
		end
	end)

	helpers.it("app-profile: refuses a stale cached map after an external edit", function()
		local Sandbox = require("test.config_unused_keys_contract").sandbox
		local first = Overrides.encode({ firefox = "basic" })
		local external = Overrides.encode({ firefox = "advanced", kate = "basic" })
		local source = '[llm]\napp_profile_overrides = "' .. first .. '"\n'
		local successor = '[llm]\napp_profile_overrides = "' .. external .. '"\n'
		Sandbox.with_config(source, function(path)
			local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			local ok, err = pcall(function()
				package.loaded["infra.config_paths"] = { config = function() return path end }
				local settings = require("modules.llm.profile_settings")
				helpers.assert_eq(settings.app_overrides().firefox, "basic")
				local snapshot = settings.configuration_snapshot()
				settings._reset()
				helpers.assert_true(settings.restore_configuration(snapshot))
				local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
				helpers.assert_eq(settings.set_app_override("terminal", "advanced"), false)
				helpers.assert_eq(Sandbox.read_bytes(path), successor)
				helpers.assert_true(settings.set_app_override("terminal", "advanced"))
				local actual = settings.app_overrides()
				helpers.assert_eq(actual.firefox, "advanced")
				helpers.assert_eq(actual.kate, "basic")
				helpers.assert_eq(actual.terminal, "advanced")
			end)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end)

	for _, first_cache in ipairs({ "overrides", "registry", "overrides before reference" }) do
		helpers.it("app-profile: refuses deletion across separate cache snapshots (" .. first_cache .. " first)", function()
			local Sandbox = require("test.config_unused_keys_contract").sandbox
			local Registry = require("llm.profile_registry_codec")
			local external_profile = { id = "user_external", label = "External", system_single = "Keep external prompt",
				system_multi = "", system_multi_template = "", batch = false }
			local function document(registry, overrides)
				return '[llm]\nuser_profiles = "' .. Registry.encode(registry)
					.. '"\napp_profile_overrides = "' .. Overrides.encode(overrides)
					.. '"\n\n[external]\nmarker = "keep external setting"\n'
			end
			local initial_overrides = { kate = "basic" }
			if first_cache ~= "overrides before reference" then initial_overrides.firefox = USER.id end
			local source = document({ USER }, initial_overrides)
			local successor = document({ USER, external_profile }, { firefox = USER.id, kate = "advanced", terminal = "basic" })
			Sandbox.with_config(source, function(path)
				local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings" }
				local saved = {}
				for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
				local ok, err = pcall(function()
					package.loaded["infra.config_paths"] = { config = function() return path end }
					local settings = require("modules.llm.profile_settings")
					if first_cache ~= "registry" then
						helpers.assert_eq(settings.app_overrides().kate, "basic")
					else
						helpers.assert_eq(#settings.list_user(), 1)
					end
					local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
					if first_cache ~= "registry" then
						helpers.assert_eq(#settings.list_user(), 2)
					else
						helpers.assert_eq(settings.app_overrides().kate, "advanced")
					end
					helpers.assert_eq(settings.delete_user_profile(USER.id), false,
						"registry and override candidates must come from the same source")
					helpers.assert_eq(Sandbox.read_bytes(path), successor, "refusal preserves every external byte")
					helpers.assert_true(settings.delete_user_profile(USER.id), "a retry reads one current source")
					local actual = assert(require("toml_codec").decode(Sandbox.read_bytes(path)))
					helpers.assert_eq(Overrides.decode(actual.llm.app_profile_overrides), { kate = "advanced", terminal = "basic" })
					helpers.assert_eq(Registry.decode(actual.llm.user_profiles), { external_profile })
					helpers.assert_eq(actual.external.marker, "keep external setting")
					helpers.assert_true(settings.delete_user_profile(external_profile.id),
						"a successful deletion must not leave an override cache without its source")
				end)
				for _, name in ipairs(names) do package.loaded[name] = saved[name] end
				if not ok then error(err, 0) end
			end)
		end)
	end

	helpers.it("app-profile: deleting a profile preserves unreadable overrides", function()
		local Sandbox = require("test.config_unused_keys_contract").sandbox
		local Registry = require("llm.profile_registry_codec")
		local damaged = "v1:***not-base64***"
		local source = '[llm]\nuser_profiles = "' .. Registry.encode({ USER })
			.. '"\napp_profile_overrides = "' .. damaged .. '"\n\n[external]\nmarker = "keep external setting"\n'
		Sandbox.with_config(source, function(path)
			local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
			local ok, err = pcall(function()
				package.loaded["infra.config_paths"] = { config = function() return path end }
				local settings = require("modules.llm.profile_settings")
				helpers.assert_true(settings.delete_user_profile(USER.id))
				local actual = assert(require("toml_codec").decode(Sandbox.read_bytes(path)))
				helpers.assert_eq(actual.llm.app_profile_overrides, damaged)
				helpers.assert_eq(Registry.decode(actual.llm.user_profiles or ""), {})
				helpers.assert_eq(actual.external.marker, "keep external setting")
			end)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
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

--- tests/unit/infra/preferences/test_preferences_user_profiles_storage.lua

--- ==============================================================================
--- MODULE: User Prompt Profile Storage (macOS)
--- DESCRIPTION:
--- macOS kept the user's prompt profiles in its own [llm.profiles]
--- user_profiles array while Windows and Linux store them in llm.user_profiles,
--- the versioned envelope of _shared/lua/llm/profile_registry_codec.lua. A
--- config.toml carried between machines lost its profiles on the way. These
--- tests pin the shared key and envelope on the macOS save and load.
--- ==============================================================================

local helpers   = require("tests.helpers")
local Contract  = require("test.config_unused_keys_contract")
local TomlCodec = require("toml_codec")
local ProfileRegistry = require("llm.profile_registry_codec")

local Sandbox = Contract.sandbox

local PROFILES = {
	{ id = "user_first", label = "First Profile", system_single = "first" },
	{ id = "user_second", label = "Second Profile", system_single = "second" },
}

helpers.describe("user prompt profiles are stored at the key every OS reads (par-40-user-profiles)", function()
	local Preferences = helpers.load_with_stubs("infra.preferences")

	helpers.it("saves the profiles as the llm.user_profiles envelope", function()
		Sandbox.with_config("[llm]\nenabled = true\n", function(path)
			helpers.assert_eq(select(2, Preferences.load(path)), "ok")
			helpers.assert_eq(Preferences.save(path, { llm_user_profiles = PROFILES }, {}, {}), true)
			local saved = TomlCodec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(type(saved.llm.user_profiles), "string")
			helpers.assert_eq(ProfileRegistry.decode(saved.llm.user_profiles), PROFILES)
			helpers.assert_nil(type(saved.llm.profiles) == "table" and saved.llm.profiles.user_profiles or nil,
				"no macOS-only list is written")
		end)
	end)

	helpers.it("loads the envelope another OS wrote into the profile list", function()
		local source = "[llm]\nuser_profiles = \"" .. ProfileRegistry.encode(PROFILES) .. "\"\n"
		Sandbox.with_config(source, function(path)
			local saved, status = Preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(saved.llm_user_profiles, PROFILES)
		end)
	end)

	helpers.it("removes the key when the last profile is deleted", function()
		local source = "[llm]\nenabled = true\nuser_profiles = \"" .. ProfileRegistry.encode(PROFILES) .. "\"\n"
		Sandbox.with_config(source, function(path)
			helpers.assert_eq(select(2, Preferences.load(path)), "ok")
			helpers.assert_eq(Preferences.save(path, { llm_user_profiles = {} }, {}, {}), true)
			local saved = TomlCodec.decode(Sandbox.read_bytes(path))
			helpers.assert_nil(saved.llm.user_profiles, "an empty registry stays sparse")
			helpers.assert_eq(saved.llm.enabled, true)
		end)
	end)
end)

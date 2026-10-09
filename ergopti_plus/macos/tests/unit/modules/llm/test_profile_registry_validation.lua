--- tests/unit/modules/llm/test_profile_registry_validation.lua

--- ==============================================================================
--- MODULE: Profile Registry Validation Regressions
--- DESCRIPTION:
--- Rejects malformed entries before publishing a replacement profile registry.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_core(callback)
	return helpers.with_stub_scope({
		"modules.llm", "modules.llm.profiles", "llm.profile_selector", "infra.logger",
	}, function()
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["modules.llm.profiles"] = nil
		package.loaded["llm.profile_selector"] = nil
		return callback(helpers.load_with_stubs("modules.llm"), errors)
	end)
end

helpers.describe("profile-registry-validation", function()
	for _, value in ipairs({ true, false, 42, "private profile text" }) do
		for index = 1, 2 do
			helpers.it("rejects " .. tostring(value) .. " at entry " .. index, function()
				with_core(function(core, errors)
					local original = { { id = "kept", label = "Kept", system_single = "X" } }
					helpers.assert_eq(core.set_user_profiles(original), true)
					local replacement = {}
					if index == 2 then replacement[1] = { id = "candidate", label = "Candidate" } end
					replacement[index] = value
					helpers.assert_eq(core.set_user_profiles(replacement), false)
					local kept, candidate = false, false
					for _, profile in ipairs(core.get_all_profiles()) do
						if profile.id == "kept" then kept = true end
						if profile.id == "candidate" then candidate = true end
					end
					helpers.assert_true(kept, "the prior registry must remain usable")
					helpers.assert_eq(candidate, false, "the valid prefix must not be partially published")
					helpers.assert_eq(#errors, 1)
					helpers.assert_true(errors[1]:find("entry " .. index, 1, true) ~= nil)
					helpers.assert_true(errors[1]:find(type(value), 1, true) ~= nil)
					helpers.assert_nil(errors[1]:find("private profile text", 1, true))
				end)
			end)
		end
	end

	for index = 1, 2 do
		helpers.it("rejects decoded NaN profile id at entry " .. index, function()
			with_core(function(core, errors)
				local prefix = index == 2 and '{ id = "candidate" }, ' or ""
				local decoded = require("toml_codec").decode("profiles = [" .. prefix .. "{ id = nan }]\n")
				local id = decoded.profiles[index].id
				helpers.assert_true(type(id) == "number" and id ~= id, "real TOML must provide NaN")
				helpers.assert_eq(core.set_user_profiles({ { id = "kept", label = "Kept" } }), true)
				helpers.assert_eq(core.set_user_profiles(decoded.profiles), false)
				local kept = false
				for _, profile in ipairs(core.get_all_profiles()) do
					if profile.id == "kept" then kept = true end
					helpers.assert_true(profile.id ~= "candidate", "no partial publication")
				end
				helpers.assert_true(kept, "the prior registry must remain usable")
				helpers.assert_eq(#errors, 1)
				helpers.assert_true(errors[1]:find("entry " .. index, 1, true) ~= nil)
				helpers.assert_true(errors[1]:find("NaN", 1, true) ~= nil)
			end)
		end)
	end

	helpers.it("retains valid list identity and accepts legacy empty records", function()
		with_core(function(core, errors)
			local profiles = { {} }
			helpers.assert_eq(core.set_user_profiles(profiles), true)
			profiles[2] = { id = "appended", label = "Appended", system_single = "X" }
			local found = false
			for _, profile in ipairs(core.get_all_profiles()) do
				if profile.id == "appended" then found = true end
			end
			helpers.assert_true(found, "valid registries retain the existing reference contract")
			helpers.assert_eq(#errors, 0)
		end)
	end)
end)

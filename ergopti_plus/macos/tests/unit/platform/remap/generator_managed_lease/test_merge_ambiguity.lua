--- tests/unit/platform/remap/generator_managed_lease/test_merge_ambiguity.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Merge Ambiguity
--- DESCRIPTION:
--- Verifies exact ownership and non-destructive generation with isolated fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.generator_managed_lease_fixture")
local TOKEN = support.TOKEN
local OLD_TOKEN_A = support.OLD_TOKEN_A
local managed_rule = support.managed_rule
local personal_rule = support.personal_rule
local generated_config = support.generated_config
local with_fixture = support.with_fixture

helpers.describe("Karabiner generator merge ambiguity", function()

	helpers.it("refuses malformed existing JSON instead of overwriting it", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/malformed.json"
			fixture.file_data[path] = "{ definitely not JSON"
			local result, err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_nil(result, "malformed personal configuration must never be overwritten")
			helpers.assert_true(type(err) == "string" and err:find("JSON", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses an existing file that cannot be read", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local path = "/merge/unreadable.json"
			fixture.unreadable_paths[path] = true
			local result, err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_nil(result, "an unreadable personal configuration must never be overwritten")
			helpers.assert_true(type(err) == "string" and err:find("read", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses zero, multiple, or structurally invalid selected profiles", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local cases = {
				{ profiles = {} },
				{ profiles = { { name = "A", selected = false }, { name = "B", selected = false } } },
				{ profiles = { { name = "A", selected = true }, { name = "B", selected = true } } },
				{ profiles = { "not a profile" } },
				{
					profiles = {
						{
							name = "A",
							selected = true,
							complex_modifications = {
								rules = { named_rule = personal_rule("must not be discarded") },
							},
						},
					},
				},
			}
			for index, config in ipairs(cases) do
				local path = "/merge/ambiguous-" .. tostring(index) .. ".json"
				fixture.file_data[path] = _G.hs.json.encode(config)
				local result, err = Generator.merge_into_existing_config(incoming, path)
				helpers.assert_nil(result, "ambiguous profile selection must fail closed for case " .. tostring(index))
				helpers.assert_true(type(err) == "string" and err ~= "")
			end
		end)
	end)

	helpers.it("refuses a generated rules object that ipairs would silently skip", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local malformed_incoming = generated_config({})
			malformed_incoming.profiles[1].complex_modifications.rules = {
				hidden_rule = managed_rule(TOKEN, "normal", "hidden"),
			}
			local result, err = Generator.merge_into_existing_config(
				malformed_incoming,
				"/merge/generated-rules-object.json"
			)
			helpers.assert_nil(result, "named generated rules must not turn into an accidental cleanup")
			helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses an incoming managed rule carrying a second generation lease", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local conflicted = managed_rule(TOKEN, "normal", "conflicted")
			conflicted.manipulators[1].conditions[#conflicted.manipulators[1].conditions + 1] = {
				type = "variable_if",
				name = "ergopti_lease_" .. OLD_TOKEN_A,
				value = 1,
			}
			local result, err = Generator.merge_into_existing_config(
				generated_config({ conflicted }),
				"/merge/foreign-lease.json"
			)
			helpers.assert_nil(result, "a foreign lease condition would make a managed rule permanently inert")
			helpers.assert_true(type(err) == "string" and err:find("foreign managed condition", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses malformed or managed legacy fingerprints", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local malformed = { named = personal_rule("hidden fingerprint") }
			local result, err = Generator.merge_into_existing_config(
				incoming,
				"/merge/malformed-legacy.json",
				malformed
			)
			helpers.assert_nil(result, "a named fingerprint object must not trigger hidden removals")
			helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)
			result, err = Generator.merge_into_existing_config(
				incoming,
				"/merge/false-legacy.json",
				false
			)
			helpers.assert_nil(result, "false must not be confused with an omitted fingerprint list")
			helpers.assert_true(type(err) == "string" and err:find("dense array", 1, true) ~= nil)

			local managed_fingerprint = managed_rule(OLD_TOKEN_A, "normal", "not legacy")
			result, err = Generator.merge_into_existing_config(
				incoming,
				"/merge/managed-legacy.json",
				{ managed_fingerprint }
			)
			helpers.assert_nil(result, "managed rules cannot masquerade as historical fingerprints")
			helpers.assert_true(type(err) == "string" and err:find("untagged", 1, true) ~= nil)

			local scoped_writer_fingerprint = personal_rule("untagged scoped writer")
			scoped_writer_fingerprint.manipulators[1].to = {
				{
					set_variable = {
						name = "ergopti_capsword_" .. OLD_TOKEN_A,
						value = 1,
					},
				},
			}
			result, err = Generator.merge_into_existing_config(
				incoming,
				"/merge/scoped-writer-legacy.json",
				{ scoped_writer_fingerprint }
			)
			helpers.assert_nil(result,
				"a token-scoped runtime writer cannot masquerade as a pre-lease fingerprint")
			helpers.assert_true(type(err) == "string" and err:find("managed variable", 1, true) ~= nil)
		end)
	end)
end)

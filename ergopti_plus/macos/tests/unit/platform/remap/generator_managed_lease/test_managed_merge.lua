--- tests/unit/platform/remap/generator_managed_lease/test_managed_merge.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Managed Merge
--- DESCRIPTION:
--- Verifies exact ownership and non-destructive generation with isolated fixtures.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.generator_managed_lease_fixture")
local TOKEN = support.TOKEN
local OLD_TOKEN_A = support.OLD_TOKEN_A
local OLD_TOKEN_B = support.OLD_TOKEN_B
local state = support.state
local managed_rule = support.managed_rule
local personal_rule = support.personal_rule
local generated_config = support.generated_config
local existing_config = support.existing_config
local with_fixture = support.with_fixture

helpers.describe("Karabiner generator non-destructive managed merge", function()
	helpers.it("preserves personal state and replaces only exact managed tags in place", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local path = "/merge/personal.json"
			local near_matches = {
				personal_rule("[ErgoptiPlus managed:" .. string.rep("a", 31) .. ":normal] 31 hex"),
				personal_rule("[ErgoptiPlus managed:" .. string.rep("a", 33) .. ":normal] 33 hex"),
				personal_rule("[ErgoptiPlus managed:" .. string.rep("A", 32) .. ":normal] uppercase"),
				personal_rule("[ErgoptiPlus managed:" .. OLD_TOKEN_A .. ":other] wrong mode"),
				personal_rule("[ErgoptiPlus managed:" .. OLD_TOKEN_A .. ":normal]missing space"),
			}
			local rules = {
				personal_rule("personal before"),
				managed_rule(OLD_TOKEN_A, "normal", "stale normal"),
				personal_rule("personal middle"),
				managed_rule(OLD_TOKEN_B, "pause", "stale pause"),
			}
			for _, rule in ipairs(near_matches) do rules[#rules + 1] = rule end
			rules[#rules + 1] = personal_rule("personal after")
			local existing = existing_config(rules)
			existing.profiles[1].complex_modifications.rules = {
				personal_rule("work personal before"),
				managed_rule(OLD_TOKEN_A, "normal", "inactive-profile stale"),
				personal_rule("work personal after"),
			}
			fixture.file_data[path] = _G.hs.json.encode(existing)
			local incoming = generated_config({
				managed_rule(TOKEN, "normal", "new normal"),
				managed_rule(TOKEN, "pause", "new pause"),
			})

			local result, err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_not_nil(result, err)
			helpers.assert_true(helpers.deep_equal(result.global, existing.global), "global settings must remain byte-for-byte equivalent")
			helpers.assert_eq(result.profiles[1].name, "Work")
			helpers.assert_true(helpers.deep_equal(result.profiles[1].devices, existing.profiles[1].devices),
				"inactive-profile devices must remain untouched")
			local inactive_rules = result.profiles[1].complex_modifications.rules
			helpers.assert_eq(#inactive_rules, 2, "stale managed rules must be removed from inactive profiles")
			helpers.assert_eq(inactive_rules[1].description, "work personal before")
			helpers.assert_eq(inactive_rules[2].description, "work personal after")
			local selected = result.profiles[2]
			helpers.assert_eq(selected.name, "Personal selected")
			helpers.assert_true(helpers.deep_equal(selected.parameters, existing.profiles[2].parameters), "profile parameters must survive")
			helpers.assert_true(helpers.deep_equal(selected.devices, existing.profiles[2].devices), "devices must survive")
			helpers.assert_true(helpers.deep_equal(selected.simple_modifications, existing.profiles[2].simple_modifications), "simple modifications must survive")
			helpers.assert_true(helpers.deep_equal(selected.fn_function_keys, existing.profiles[2].fn_function_keys), "fn mappings must survive")
			helpers.assert_true(helpers.deep_equal(selected.virtual_hid_keyboard, existing.profiles[2].virtual_hid_keyboard), "virtual HID settings must survive")
			helpers.assert_true(helpers.deep_equal(
				selected.complex_modifications.parameters,
				existing.profiles[2].complex_modifications.parameters
			), "complex-modification parameters must survive")

			local merged_rules = selected.complex_modifications.rules
			helpers.assert_eq(merged_rules[1].description, "personal before")
			helpers.assert_true(merged_rules[2].description:find("new normal", 1, true) ~= nil)
			helpers.assert_true(merged_rules[3].description:find("new pause", 1, true) ~= nil)
			helpers.assert_eq(merged_rules[4].description, "personal middle")
			for index, near in ipairs(near_matches) do
				helpers.assert_eq(merged_rules[index + 4].description, near.description, "near-match tag must be preserved")
			end
			helpers.assert_eq(merged_rules[#merged_rules].description, "personal after")
		end)
	end)

	helpers.it("is idempotent and cleans all stale managed generations", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local path = "/merge/idempotent.json"
			fixture.file_data[path] = _G.hs.json.encode(existing_config({
				managed_rule(OLD_TOKEN_A, "normal", "old A"),
				personal_rule("personal"),
				managed_rule(OLD_TOKEN_B, "normal", "old B"),
			}))
			local incoming = generated_config({ managed_rule(TOKEN, "normal", "current") })
			local first, first_err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_not_nil(first, first_err)
			fixture.file_data[path] = _G.hs.json.encode(first)
			local second, second_err = Generator.merge_into_existing_config(incoming, path)
			helpers.assert_not_nil(second, second_err)
			helpers.assert_true(helpers.deep_equal(second, first), "repeating a merge must produce the same configuration")
			local current_count = 0
			local personal_count = 0
			for _, rule in ipairs(second.profiles[2].complex_modifications.rules) do
				if rule.description:find(TOKEN, 1, true) then current_count = current_count + 1 end
				if rule.description == "personal" then personal_count = personal_count + 1 end
				helpers.assert_true(rule.description:find(OLD_TOKEN_A, 1, true) == nil, "old generation A must be removed")
				helpers.assert_true(rule.description:find(OLD_TOKEN_B, 1, true) == nil, "old generation B must be removed")
			end
			helpers.assert_eq(current_count, 1, "current managed rules must not duplicate")
			helpers.assert_eq(personal_count, 1, "idempotence must never erase or duplicate a personal rule")
		end)
	end)

	helpers.it("does not invent or alter global settings for a fresh config", function()
		with_fixture(function(fixture)
			local Generator = fixture.Generator
			local result, err = Generator.merge_into_existing_config(
				generated_config({ managed_rule(TOKEN, "normal", "fresh") }),
				"/merge/absent.json"
			)
			helpers.assert_not_nil(result, err)
			helpers.assert_nil(result.global, "ErgoptiPlus must not impose stock Karabiner UI or update preferences")
		end)
	end)
end)

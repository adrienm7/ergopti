--- _shared/lua/test/personal_file_adoption_contract.lua

--- ==============================================================================
--- MODULE: Additional Personal File Adoption Contract
--- DESCRIPTION:
--- Independent lexical, physical and legacy alias decisions shared by all drivers.
--- Native registration and publication remain separate adapter tests.
--- ==============================================================================

local M = {}

--- Register literal expected adoption decisions without deriving them from production.
--- @param helpers table
--- @param corpus table
function M.run(helpers, corpus)
	local Scope = require("hotstrings.personal_scope")
	local Files = require("hotstrings.personal_files")
	local Priority = require("hotstring_priority")
	assert(#corpus.vectors == 7, "personal-file adoption inventory must contain seven vectors")
	helpers.describe("personal file adoption parity", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("(personal-file-adoption) " .. vector.name, function()
				local result, reason = Scope.plan_adoption(vector.candidates)
				helpers.assert_eq(reason, nil)
				helpers.assert_eq(result, vector.expected)
				for index, record in ipairs(result) do
					helpers.assert_true(record.source ~= vector.candidates[index].source)
					helpers.assert_true(record.source.components ~= vector.candidates[index].source.components)
					helpers.assert_eq(Priority.source_priority(record.owner), 30)
				end
			end)
		end
		helpers.it("(personal-file-adoption) policy does not expand the descriptor shape", function()
			helpers.assert_eq(Files.additional_default_enabled, true)
			helpers.assert_eq(Files.additional_default_delay_seconds, 0)
			helpers.assert_eq(Files.additional_priority_tier, "package")
			helpers.assert_eq(Files.additional_scan_max_depth, 16)
			helpers.assert_eq(Files.describe({"c.toml"}), {
				id = "personal-file:632e746f6d6c", components = {"c.toml"}, label = "c" })
			helpers.assert_eq(Priority.source_priority("personal-file:632e746F6d6c"), 10)
			helpers.assert_eq(Files.preference_default("hotstrings.groups.personal-file:632e746f6d6c"), true)
			helpers.assert_eq(Files.preference_default('hotstrings.modules."personal-file:632e746f6d6c"."é.foo"'), true)
			helpers.assert_eq(Files.preference_default("hotstrings.modules.personal-file:632e746f6d6c.é.foo"), nil)
			helpers.assert_eq(Files.preference_default("hotstrings.groups.personal-file:632e746F6d6c"), nil)
			helpers.assert_eq(Files.preference_default('hotstrings.modules."personal-file:632e746f6d6c".""'), nil)
			helpers.assert_eq(Files.preference_default("hotstrings.groups.foreign"), nil)
		end)
	end)
end

return M

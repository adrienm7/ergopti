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
		-- A scoped reset copied every personal file to <stem>.backup-<stamp>.toml in
		-- the scanned folder; discovery then loaded each copy as one more source.
		helpers.it("(personal-file-backups) writer backups are never personal sources", function()
			for _, name in ipairs({ "words.backup-20261017-190645.toml",
					"words.backup-20261017-190645-1330382656.toml", "dir/WORDS.BACKUP-20260625-004901.TOML",
					"words.backup-20260625-004901.backup-20261017-190645-1330382656.toml" }) do
				helpers.assert_true(Files.is_backup(name), name)
			end
			for _, name in ipairs({ "words.toml", "backup-20261017.toml", ".backup-20261017.toml",
					"words.backup-.toml", "words.backup-notes.toml", "words.backup-2026.toml.bak",
					"words.backup-20261017.json", "my.backup-plan.toml", 42 }) do
				helpers.assert_eq(Files.is_backup(name), false, tostring(name))
			end
			local Catalogue = require("hotstrings.catalogue_files")
			helpers.assert_eq(Catalogue.is_category_file("/x/words.backup-20261017-190645.toml"), false)
			helpers.assert_eq(Catalogue.is_category_file("/x/words.toml"), true)
		end)
	end)
end

return M

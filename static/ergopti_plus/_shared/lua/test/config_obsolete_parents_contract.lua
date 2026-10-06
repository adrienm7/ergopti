--- _shared/lua/test/config_obsolete_parents_contract.lua

--- Registers source-bound ordinary-write preservation and strict refusal controls.
local M = {}

--- Replays hand-authored shapes and operations through the shared admission owner.
--- @param helpers table Existing native runner assertions.
function M.register(helpers)
	local Parents = require("config_obsolete_parents")
	local namespaces = Parents.shortcut_namespaces()
	local function deletion(section, key) return { section = section, key = key, delete = true } end
	helpers.describe("ordinary obsolete assignment parent preservation", function()
		for _, literal in ipairs({ '"legacy"', "false", "0", '["legacy"]', "[]", '[{ future = "keep" }]' }) do
			helpers.it("retains neutral descendants of the actual source kind " .. literal, function()
				local source = "[shortcuts]\nkeyboard = " .. literal .. "\ntap_keys = " .. literal .. "\n"
				local other = { section = "future", key = "keep", value = true }
				local rows = Parents.preserve(source, { deletion("shortcuts.keyboard", "magic_editor"),
					deletion("shortcuts.tap_keys", "number_row_left"), other }, namespaces)
				helpers.assert_eq(#rows, 1)
				helpers.assert_true(rawequal(rows[1], other), "noncolliding row identity and capabilities are retained")
			end)
		end
		for _, vector in ipairs({
			{ id = "nondelete descendant", row = { section = "shortcuts.keyboard", key = "magic_editor", value = "none" } },
			{ id = "nondelete subtree", row = { section = "shortcuts.keyboard", key = "nested", value = { future = true } } },
			{ id = "whole parent deletion", row = deletion("shortcuts", "keyboard") },
			{ id = "whole parent replacement", row = { section = "shortcuts", key = "keyboard", value = {} } },
		}) do
			helpers.it("refuses " .. vector.id .. " before obsolete source can be replaced", function()
				helpers.assert_throws(function()
					Parents.preserve('[shortcuts]\nkeyboard = "legacy"\n', { vector.row }, namespaces)
				end)
			end)
		end
		helpers.it("refuses an ancestor subtree even when no descendant row is supplied", function()
			local row = { section = "root", key = "shortcuts", value = {} }
			local rows = Parents.preserve('[shortcuts]\nkeyboard = "legacy"\n',
				{ row }, { { "root", "shortcuts", "keyboard" } })
			helpers.assert_true(rawequal(rows[1], row), "an unrelated declaration cannot invent ancestry")
			local source = '[root.shortcuts]\nkeyboard = "legacy"\n'
			helpers.assert_throws(function()
				Parents.preserve(source, { { section = "root", key = "shortcuts", value = {} } },
					{ { "root", "shortcuts", "keyboard" } })
			end)
		end)
		helpers.it("does not infer an obsolete parent from an absent namespace", function()
			local row = deletion("shortcuts.keyboard", "magic_editor")
			local rows = Parents.preserve("", { row }, namespaces)
			helpers.assert_true(rawequal(rows[1], row))
		end)
		helpers.it("preserves valid table operations and their exact existing row identity", function()
			local row = { section = "shortcuts.keyboard", key = "magic_editor", value = "none", intent = "keyboard_assignment" }
			local source = '[shortcuts]\nkeyboard = { future = "keep" }\n'
			local rows = Parents.preserve(source, { row }, namespaces)
			helpers.assert_true(rawequal(rows[1], row))
			helpers.assert_eq(rows[1].intent, "keyboard_assignment")
		end)
		helpers.it("uses semantic quoted sections without matching literal or case twins", function()
			local rows = { deletion('"shortcuts"."keyboard"', "magic_editor"),
				deletion('"shortcuts.keyboard"', "magic_editor"), deletion("shortcuts.Keyboard", "cmd_a") }
			local kept = Parents.preserve('[shortcuts]\nkeyboard = false\n', rows, namespaces)
			helpers.assert_eq(#kept, 2)
			helpers.assert_true(rawequal(kept[1], rows[2]))
			helpers.assert_true(rawequal(kept[2], rows[3]))
		end)
		for _, section in ipairs({ "shortcuts.keyboard", '"shortcuts"."Keyboard"' }) do
			helpers.it("refuses a filtered duplicate logical row under " .. section, function()
				helpers.assert_throws(function()
					Parents.preserve('[shortcuts]\nkeyboard = "legacy"\n',
						{ deletion("shortcuts.keyboard", "magic_editor"), deletion(section, "magic_editor") }, namespaces)
				end)
			end)
		end
		helpers.it("retains a root obsolete parent for neutral descendants and refuses set intent", function()
			helpers.assert_eq(Parents.preserve('shortcuts = false\n', { deletion("shortcuts.keyboard", "magic_editor") }, namespaces), {})
			helpers.assert_throws(function()
				Parents.preserve('shortcuts = false\n', { { section = "shortcuts", key = "enabled", value = true } }, namespaces)
			end)
		end)
		helpers.it("refuses malformed source rather than admitting empty configuration", function()
			helpers.assert_throws(function() Parents.preserve("[shortcuts\n", {}, namespaces) end)
		end)
		for _, vector in ipairs({
			{ id = "false delete", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = false } },
			{ id = "integer delete", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = 1 } },
			{ id = "delete and value", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = true, value = "none" } },
			{ id = "missing key", row = { section = "shortcuts.keyboard", delete = true } },
			{ id = "malformed section", row = deletion("shortcuts..keyboard", "magic_editor") },
			{ id = "invalid literal capability", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = true, literal_key = 1 } },
			{ id = "foreign shape capability", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = true, source_shape = {} } },
			{ id = "nondelete assignment intent", row = { section = "shortcuts.keyboard", key = "magic_editor", delete = true, intent = "keyboard_assignment" } },
		}) do
			helpers.it("refuses malformed neutral row: " .. vector.id, function()
				helpers.assert_throws(function()
					Parents.preserve('[shortcuts]\nkeyboard = "legacy"\n', { vector.row }, namespaces)
				end)
			end)
		end
		for _, vector in ipairs({
			{ id = "sparse updates", updates = { [2] = deletion("shortcuts.keyboard", "magic_editor") }, namespaces = namespaces },
			{ id = "named updates", updates = { row = deletion("shortcuts.keyboard", "magic_editor") }, namespaces = namespaces },
			{ id = "sparse namespaces", updates = {}, namespaces = { [2] = { "shortcuts", "keyboard" } } },
			{ id = "sparse path", updates = {}, namespaces = { { [1] = "shortcuts", [3] = "keyboard" } } },
			{ id = "nonstring path", updates = {}, namespaces = { { "shortcuts", false } } },
			{ id = "empty path", updates = {}, namespaces = { {} } },
		}) do
			helpers.it("refuses malformed ownership arrays: " .. vector.id, function()
				helpers.assert_throws(function() Parents.preserve("", vector.updates, vector.namespaces) end)
			end)
		end
		helpers.it("does not manufacture a native namespace for a future source field", function()
			helpers.assert_throws(function() Parents.shortcut_namespaces({ "future" }) end)
			local row = deletion("shortcuts.future", "leaf")
			local rows = Parents.preserve('[shortcuts]\nfuture = "legacy"\n', { row }, namespaces)
			helpers.assert_true(rawequal(rows[1], row), "the existing strict writer still judges undeclared ancestry")
		end)
	end)
end

return M

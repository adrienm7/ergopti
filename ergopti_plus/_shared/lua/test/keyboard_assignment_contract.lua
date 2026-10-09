--- _shared/lua/test/keyboard_assignment_contract.lua

--- Exercises actual sparse defaults and the shared writer's closed user intent.
--- @param helpers table Native test helper owner.
return function(helpers)
	local Assignment = require("shortcuts.assignment")
	local Defaults = require("config_defaults")
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec")
	local contract = Defaults.new({ features = {
		{ path = "shortcuts.keyboard.hs_ctrl_a", default = "none", recommended = "none" },
		{ path = "shortcuts.keyboard.magic_editor", default = "open_hotstrings_editor", recommended = "open_hotstrings_editor" },
	}, scopes = {} })
	local defaults = { has_default = contract.has_default, sparse_operation = contract.operation }
	local source = '[shortcuts.keyboard]\nhs_ctrl_a = "copy"\nmagic_editor = "open_hotstrings_editor"\n[unowned]\nvalue = "preserve"\n'
	local path = "/test/keyboard-user-assignment-contract"
	local reads = 0
	local adapter = { read_with_status = function()
		reads = reads + 1
		return source, "ok"
	end }
	local function is_owned(slot) return slot == "hs_ctrl_a" or slot == "magic_editor" end
	local function is_assignable(action) return action == "none" or action == "copy" or action == "open_hotstrings_editor" end
	Writer.set_sparse_defaults(path, defaults)
	helpers.describe("ordinary keyboard assignment intent", function()
		helpers.it("(magic-editor) selected None persists through the actual sparse writer", function()
			local operation = Assignment.operation("hs_ctrl_a", "none", is_owned, is_assignable)
			helpers.assert_eq(operation.delete, nil)
			local ok, detail, content = Writer.prepare_batch(path, { operation }, adapter)
			helpers.assert_eq(ok, true, detail)
			local decoded = Codec.decode(content)
			helpers.assert_eq(decoded.shortcuts.keyboard.hs_ctrl_a, "none")
			helpers.assert_eq(decoded.unowned.value, "preserve")
		end)
		helpers.it("(magic-editor) explicit contextual recommendation is a real user value", function()
			local ok, detail, content = Writer.prepare_batch(path,
				{ Assignment.operation("magic_editor", "open_hotstrings_editor", is_owned, is_assignable) }, adapter)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(Codec.decode(content).shortcuts.keyboard.magic_editor, "open_hotstrings_editor")
		end)
		helpers.it("(magic-editor) scope neutral restoration still deletes to restore absence", function()
			local ok, detail, content = Writer.prepare_batch(path,
				{ contract.operation("shortcuts.keyboard.hs_ctrl_a", "none") }, adapter)
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(Codec.decode(content).shortcuts.keyboard.hs_ctrl_a, nil)
		end)
		helpers.it("(magic-editor) forged intent is refused before reading any source", function()
			for _, row in ipairs({
				{ section = "shortcuts.script_control", key = "hs_ctrl_a", value = "none", intent = Assignment.INTENT },
				{ section = "shortcuts.keyboard", key = "hs_ctrl_a", value = false, intent = Assignment.INTENT },
				{ section = "shortcuts.keyboard", key = "hs_ctrl_a", delete = true, intent = Assignment.INTENT },
				{ section = "shortcuts.keyboard", key = "hs_ctrl_a", value = "none", intent = "arbitrary_bypass" },
			}) do
				local before = reads
				local ok, detail = Writer.prepare_batch(path, { row }, adapter)
				helpers.assert_eq(ok, false)
				helpers.assert_eq(type(detail), "string")
				helpers.assert_eq(reads, before)
			end
		end)
		helpers.it("(magic-editor) user operations require both actual ownership validators", function()
			helpers.assert_eq(pcall(Assignment.operation, "invented_slot", "none", is_owned, is_assignable), false)
			helpers.assert_eq(pcall(Assignment.operation, "hs_ctrl_a", "invented_action", is_owned, is_assignable), false)
		end)
	end)
end

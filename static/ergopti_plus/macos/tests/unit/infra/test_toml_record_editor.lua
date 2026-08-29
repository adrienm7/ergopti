--- tests/unit/infra/test_toml_record_editor.lua

--- ==============================================================================
--- MODULE: Byte-Preserving TOML Record Editor
--- DESCRIPTION:
--- Patches one complete TOML record without normalizing unrelated line endings,
--- terminal blank lines, or the source's final-newline convention. Insertions
--- add only the separators needed to keep the resulting document structured.
--- ==============================================================================

local helpers = require("tests.helpers")
local Editor = require("infra.toml.record_editor")

helpers.describe("TOML record editor preserves bytes outside the mutation", function()
	helpers.it("replaces one CRLF record without trimming terminal blank lines", function()
		local source = "[personal]\r\n"
			.. "foo = \"old\"\r\n"
			.. "bar = \"keep\"\r\n"
			.. "\r\n\r\n"
		local expected = "[personal]\r\n"
			.. "foo = \"new\"\r\n"
			.. "bar = \"keep\"\r\n"
			.. "\r\n\r\n"

		local patched = assert(Editor.patch_table_field(
			source, "[personal]", "foo", '"new"'
		))
		helpers.assert_eq(patched, expected,
			"only the target assignment bytes may change")
	end)

	helpers.it("removes a mixed-EOL multiline record without adding an EOF newline", function()
		local source = "[settings]\r\n"
			.. "keep = 1\n"
			.. "owned = [\r\n"
			.. "  1,\n"
			.. "]\r\n"
			.. "tail = 2"
		local expected = "[settings]\r\nkeep = 1\ntail = 2"

		local patched = assert(Editor.patch_table_field(
			source, "[settings]", "owned", nil
		))
		helpers.assert_eq(patched, expected,
			"removing one complete record must preserve every surviving byte")
	end)

	helpers.it("returns an exact snapshot when a removal is a logical no-op", function()
		local source = "[settings]\r\nkeep = true\r\n\r\n"
		local patched = assert(Editor.patch_table_field(
			source, "[settings]", "missing", nil
		))
		helpers.assert_eq(patched, source,
			"a missing-field clear must not rewrite a committed source snapshot")
	end)

	helpers.it("inserts into a terminal section without changing the EOF convention", function()
		local patched = assert(Editor.patch_table_field(
			"[settings]", "[settings]", "owned", "true"
		))
		helpers.assert_eq(patched, "[settings]\nowned = true",
			"a source without a final newline must remain without one")
	end)

	helpers.it("appends a section with the adjacent CRLF convention", function()
		local source = "[first]\r\nvalue = 1\r\n\r\n"
		local patched = assert(Editor.patch_table_field(
			source, "[second]", "value", "2"
		))
		helpers.assert_eq(patched,
			source .. "[second]\r\nvalue = 2\r\n",
			"new records must use the local EOL without rewriting existing bytes")
	end)

	helpers.it("removes an empty section without collapsing surrounding blank records", function()
		local source = "[first]\r\nvalue = 1\r\n\r\n"
			.. "[owned]\r\nvalue = 2\r\n\r\n"
			.. "[last]\r\nvalue = 3\r\n\r\n"
		local expected = "[first]\r\nvalue = 1\r\n\r\n\r\n"
			.. "[last]\r\nvalue = 3\r\n\r\n"

		local patched = assert(Editor.patch_table_field(
			source, "[owned]", "value", nil,
			{ remove_empty_section = true }
		))
		helpers.assert_eq(patched, expected,
			"section cleanup must remove only owned records")
	end)
end)

return true

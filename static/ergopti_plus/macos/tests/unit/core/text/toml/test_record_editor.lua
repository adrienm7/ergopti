--- tests/unit/core/text/toml/test_record_editor.lua

--- ==============================================================================
--- MODULE: Byte-Preserving TOML Record Editor
--- DESCRIPTION:
--- Patches one complete TOML record without normalizing unrelated line endings,
--- terminal blank lines, or the source's final-newline convention. Insertions
--- add only the separators needed to keep the resulting document structured.
--- ==============================================================================

local helpers = require("tests.helpers")
local Editor = require("core.text.engine.toml.record_editor")
local Codec = require("core.text.engine.toml.codec")

helpers.describe("TOML record editor preserves bytes outside the mutation", function()
	helpers.it("preserves trailing comments when replacing scalar or multiline values", function()
		for _, entry in ipairs({
			{'value = "old#text"  # keep\r\n', 'value = "new"  # keep\r\n'},
			{'value = [\r\n  "old#text",\r\n] # keep\r\n', 'value = "new" # keep\r\n'},
			{'value = "old#text"\r\n', 'value = "new"\r\n'},
		}) do
			local source = "[owned]\r\n" .. entry[1] .. "other = 2\r\n"
			local patched = assert(Editor.patch_table_field(source, "[owned]", "value", '"new"'))
			helpers.assert_eq(patched, "[owned]\r\n" .. entry[2] .. "other = 2\r\n")
			local decoded = assert(Codec.decode(patched))
			helpers.assert_eq(decoded.owned.value, "new")
		end
	end)

	helpers.it("keeps an empty section unchanged when the requested field is absent", function()
		local source = "[owned]\r\n# user context\r\n\r\n[next]\r\nvalue = 3\r\n"
		local patched = assert(Editor.patch_table_field(source, "[owned]", "missing", nil,
			{remove_empty_section = true}))
		helpers.assert_eq(patched, source, "an absent field must not authorize removing its section")
		local decoded = assert(Codec.decode(patched))
		helpers.assert_true(type(decoded.owned) == "table")
		helpers.assert_eq(decoded.next.value, 3)
	end)

	helpers.it("retains the header comment when its final field is cleared", function()
		for _, header in ipairs({"[owned]# keep", "[owned]  # keep"}) do
			local source = header .. "\r\nvalue = 2\r\n[next]\r\nvalue = 3\r\n"
			local expected = header .. "\r\n[next]\r\nvalue = 3\r\n"
			local patched = assert(Editor.patch_table_field(source, "[owned]", "value", nil,
				{remove_empty_section = true}))
			helpers.assert_eq(patched, expected)
			local decoded = assert(Codec.decode(patched))
			helpers.assert_eq(decoded.next.value, 3)
		end
	end)

	helpers.it("leaves a quoted key containing an equals sign and other sections untouched", function()
		local source = "[_meta]\n\"delay=other\" = 4\n'delay' = 250\n"
			.. "[other]\ndelay = 99\n"
		local expected = "[_meta]\n\"delay=other\" = 4\ndelay = 750\n"
			.. "[other]\ndelay = 99\n"
		local patched = assert(Editor.patch_table_field(source, "[_meta]", "delay", "750"))
		helpers.assert_eq(patched, expected)
		local decoded = assert(Codec.decode(patched))
		helpers.assert_eq(decoded._meta["delay=other"], 4)
		helpers.assert_eq(decoded._meta.delay, 750)
		helpers.assert_eq(decoded.other.delay, 99)
	end)

	helpers.it("updates quoted spellings of a field instead of adding a duplicate", function()
		for _, key in ipairs({'"delay"', "'delay'"}) do
			local source = "[_meta]\n" .. key .. " = 250\nother = true\n"
			local patched = assert(Editor.patch_table_field(source, "[_meta]", "delay", "750"))
			helpers.assert_eq(patched, "[_meta]\ndelay = 750\nother = true\n")
			local decoded = assert(Codec.decode(patched))
			helpers.assert_eq(decoded._meta.delay, 750)
		end
	end)

	helpers.it("recognizes quoted and spaced spellings of the same section", function()
		for _, header in ipairs({'[ "_meta" ]', "[ '_meta' ]"}) do
			local source = header .. " # retained\ndelay = 250\nother = true\n"
			local patched = assert(Editor.patch_table_field(source, "[_meta]", "delay", "750"))
			helpers.assert_eq(patched, header .. " # retained\ndelay = 750\nother = true\n")
			local decoded = assert(Codec.decode(patched))
			helpers.assert_eq(decoded._meta.delay, 750)
		end
	end)

	helpers.it("updates a section whose comment touches its closing bracket", function()
		local source = "[_meta]# keep this comment\ndelay = 250\nother = true\n"
		local patched = assert(Editor.patch_table_field(source, "[_meta]", "delay", "750"))
		helpers.assert_eq(patched, "[_meta]# keep this comment\ndelay = 750\nother = true\n")
		local decoded = assert(Codec.decode(patched))
		helpers.assert_eq(decoded._meta.delay, 750)
		helpers.assert_eq(decoded._meta.other, true)
	end)

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

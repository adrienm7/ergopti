--- tests/unit/modules/test_hotstrings_config_preserves_global.lua

--- ==============================================================================
--- MODULE: Regression — saving overrides must not erase the [__global__] block
--- DESCRIPTION:
--- parse_overrides returns the category table AND the [__global__] settings as
--- two separate values. serialize_overrides only ever received the first, so any
--- save from the delays-and-colours window rewrote the shared override file
--- without the [__global__] block — silently discarding the word_delimiters the
--- AutoHotkey driver writes into the same file.
---
--- ROOT CAUSE ENCODED:
--- A round trip that reads more than it writes. Asserted as a round trip: parse a
--- file containing both, save, parse again, and require the global setting to
--- still be there.
--- ==============================================================================

local helpers = require("tests.helpers")

local DELIMS = " \t,;:!?"

helpers.describe("hotstrings_config: a save preserves the shared [__global__] block", function()

	helpers.it("word_delimiters survive a category-only save", function()
		local path = os.tmpname()
		local fh = assert(io.open(path, "w"))
		fh:write('[__global__]\nword_delimiters = "' .. DELIMS .. '"\n\n[rolls]\ndelay = 0.5\n')
		fh:close()

		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		local cfg = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		cfg.init({ override_path = path, toml_resolver = function() return nil end })

		-- A category-level change is what the window writes on every edit.
		cfg.set_override("rolls", nil, "delay", 0.75)

		local reread = io.open(path, "r")
		local content = reread and reread:read("*a") or ""
		if reread then reread:close() end

		-- Prove the save actually ran. Without this the two assertions below pass
		-- against an init that failed and a set_override that wrote nothing at all.
		helpers.assert_true(content:find("0.75", 1, true) ~= nil,
			"the category change must have been persisted, or this test asserts nothing "
			.. "about what a save preserves")

		helpers.assert_true(content:find("[__global__]", 1, true) ~= nil,
			"the shared override file is written by BOTH drivers; a macOS save that drops "
			.. "[__global__] silently discards the word delimiters the AutoHotkey side stored")
		helpers.assert_true(content:find('word_delimiters = " \\t,;:!?"', 1, true) ~= nil,
			"control bytes must be preserved as valid TOML escapes, not raw bytes")
		helpers.assert_eq(cfg.reload(), true,
			"the rewritten shared file must remain readable")
		helpers.assert_eq(cfg.get_word_delimiters(), DELIMS,
			"the delimiter value itself must survive the serialized round trip")
		os.remove(path)
	end)

end)

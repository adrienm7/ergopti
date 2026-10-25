--- tests/unit/modules/hotstrings/test_hotstrings_config_preserves_global.lua

--- ==============================================================================
--- MODULE: Regression — saving overrides must not erase the [__global__] block
--- DESCRIPTION:
--- parse_overrides returns the category table AND the [__global__] records as
--- two separate values. serialize_overrides only ever received the first, so any
--- save from the delays-and-colours window rewrote the override file without the
--- [__global__] block — silently discarding what it held. No key of it is owned
--- any more (the delimiter strings are config.toml leaves), so it is preserved
--- as foreign bytes.
---
--- ROOT CAUSE ENCODED:
--- A round trip that reads more than it writes. Asserted as a round trip: parse a
--- file containing both, save, parse again, and require the global setting to
--- still be there.
--- ==============================================================================

local helpers = require("tests.helpers")

local DELIMS = " \t,;:!?"
local CONSUMED_DELIMS = ".,?!"
local FUTURE_GLOBAL_RECORD = table.concat({
	"# Future cross-driver values may span physical lines.",
	"future_cross_driver_list = [",
	'  "alpha",',
	'  "beta", # comments inside an array belong to the record',
	"]",
	"# This unowned comment must survive too.",
}, "\n")

helpers.describe("hotstrings_config: a save preserves the [__global__] block", function()

	helpers.it("an old delimiter table survives a category-only save", function()
		local path = os.tmpname()
		local config_module = "modules.hotstrings.hotstrings_config"
		local file_system_module = "adapters.file_system"
		local saved_config = package.loaded[config_module]
		local saved_file_system = package.loaded[file_system_module]
		local ok, err = xpcall(function()
			local fh = assert(io.open(path, "w"))
			fh:write('[__global__]\nword_delimiters = "' .. DELIMS
				.. '"\nconsumed_delimiters = "' .. CONSUMED_DELIMS
				.. '"\nfuture_cross_driver_flag = true\n'
				.. FUTURE_GLOBAL_RECORD .. '\n\n[rolls]\ndelay = 0.5\n')
			fh:close()

			package.loaded[config_module] = nil
			package.loaded[file_system_module] = require("tests.support.file_system_write_stub")
			local cfg = helpers.load_with_stubs(config_module)
			cfg.init({ override_path = path, toml_resolver = function() return nil end })

			-- A category-level change is what the window writes on every edit.
			helpers.assert_eq(cfg.set_override("rolls", nil, "delay", 1.25), true)

			local reread = io.open(path, "r")
			local content = reread and reread:read("*a") or ""
			if reread then reread:close() end

			-- Prove the save actually ran. Without this the assertions below pass
			-- against an init that failed and a setter that wrote nothing at all.
			helpers.assert_true(content:find("delay_offset = 0.5", 1, true) ~= nil,
				"the category change must have been persisted, or this test asserts nothing "
				.. "about what a save preserves")

			helpers.assert_true(content:find("[__global__]", 1, true) ~= nil,
				"the shared override file is written by BOTH drivers; a macOS save that drops "
				.. "[__global__] silently discards settings the AutoHotkey side stored")
			helpers.assert_true(content:find('word_delimiters = "' .. DELIMS .. '"', 1, true) ~= nil,
				"an old delimiter string is foreign bytes now and is kept exactly as written")
			helpers.assert_true(content:find(
				'consumed_delimiters = "' .. CONSUMED_DELIMS .. '"', 1, true
			) ~= nil,
				"a category save must preserve consumed_delimiters")
			helpers.assert_true(content:find('future_cross_driver_flag = true', 1, true) ~= nil,
				"the round trip must retain future [__global__] assignments it does not own")
			helpers.assert_true(content:find(FUTURE_GLOBAL_RECORD, 1, true) ~= nil,
				"the round trip must preserve the complete raw multiline record and its comments, "
				.. "not only the first key/value line")

			local codec = require("infra.toml.codec")
			local decode_ok, decoded = pcall(codec.decode, content)
			helpers.assert_true(decode_ok and type(decoded) == "table",
				"preserving raw continuations must still produce valid TOML")
			helpers.assert_eq(decoded.__global__.future_cross_driver_list[1], "alpha",
				"the first preserved multiline value must reparse")
			helpers.assert_eq(decoded.__global__.future_cross_driver_list[2], "beta",
				"the commented continuation must reparse")
			helpers.assert_eq(cfg.reload(), true,
				"the rewritten file must remain readable")
			helpers.assert_nil(cfg.get_word_delimiters, "no delimiter string is owned by the override file")
		end, debug.traceback)
		package.loaded[config_module] = saved_config
		package.loaded[file_system_module] = saved_file_system
		os.remove(path)
		if not ok then error(err, 0) end
	end)

end)

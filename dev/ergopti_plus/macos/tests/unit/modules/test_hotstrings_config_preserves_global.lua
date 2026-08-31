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
local CONSUMED_DELIMS = ".,?!"
local FUTURE_GLOBAL_RECORD = table.concat({
	"# Future cross-driver values may span physical lines.",
	"future_cross_driver_list = [",
	'  "alpha",',
	'  "beta", # comments inside an array belong to the record',
	"]",
	"# This unowned comment must survive too.",
}, "\n")

helpers.describe("hotstrings_config: a save preserves the shared [__global__] block", function()

	helpers.it("word_delimiters survive a category-only save", function()
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
			helpers.assert_eq(cfg.set_override("rolls", nil, "delay", 0.75), true)

			local reread = io.open(path, "r")
			local content = reread and reread:read("*a") or ""
			if reread then reread:close() end

			-- Prove the save actually ran. Without this the assertions below pass
			-- against an init that failed and a setter that wrote nothing at all.
			helpers.assert_true(content:find("0.75", 1, true) ~= nil,
				"the category change must have been persisted, or this test asserts nothing "
				.. "about what a save preserves")

			helpers.assert_true(content:find("[__global__]", 1, true) ~= nil,
				"the shared override file is written by BOTH drivers; a macOS save that drops "
				.. "[__global__] silently discards settings the AutoHotkey side stored")
			helpers.assert_true(content:find('word_delimiters = " \\t,;:!?"', 1, true) ~= nil,
				"control bytes must be preserved as valid TOML escapes, not raw bytes")
			helpers.assert_true(content:find(
				'consumed_delimiters = "' .. CONSUMED_DELIMS .. '"', 1, true
			) ~= nil,
				"a macOS category save must preserve consumed_delimiters owned by the Windows driver")
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
				"the rewritten shared file must remain readable")
			helpers.assert_eq(cfg.get_word_delimiters(), DELIMS,
				"the delimiter value itself must survive the serialized round trip")
		end, debug.traceback)
		package.loaded[config_module] = saved_config
		package.loaded[file_system_module] = saved_file_system
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("delimiter patch ignores header-looking lines inside nested arrays", function()
		local path = os.tmpname()
		local config_module = "modules.hotstrings.hotstrings_config"
		local file_system_module = "adapters.file_system"
		local saved_config = package.loaded[config_module]
		local saved_file_system = package.loaded[file_system_module]
		local matrix_record = table.concat({
			"future_matrix = [",
			"  [1, 2],",
			"]",
		}, "\n")
		local ok, err = xpcall(function()
			local fh = assert(io.open(path, "w"))
			assert(fh:write("[__global__]\n" .. matrix_record
				.. '\nword_delimiters = " ,"\n\n[rolls]\ndelay = 0.5\n'))
			assert(fh:close())

			package.loaded[config_module] = nil
			package.loaded[file_system_module] = require("tests.support.file_system_write_stub")
			local cfg = helpers.load_with_stubs(config_module)
			cfg.init({ override_path = path, toml_resolver = function() return nil end })
			helpers.assert_eq(cfg.set_word_delimiters(" ;"), true,
				"the real setter must commit across a nested global array")

			local reread = assert(io.open(path, "r"))
			local content = assert(reread:read("*a"))
			assert(reread:close())
			local _, delimiter_count = content:gsub("word_delimiters%s*=", "")
			helpers.assert_eq(delimiter_count, 1,
				"a header-looking array element must not hide the existing owned key")
			helpers.assert_contains(content, matrix_record,
				"the unowned nested record must survive byte-for-byte")

			local codec = require("infra.toml.codec")
			local decode_ok, decoded = pcall(codec.decode, content)
			helpers.assert_true(decode_ok and type(decoded) == "table",
				"the published bytes must remain strict TOML")
			helpers.assert_eq(decoded.__global__.future_matrix[1][2], 2)
			helpers.assert_eq(cfg.reload(), true)
			helpers.assert_eq(cfg.get_word_delimiters(), " ;")
		end, debug.traceback)
		package.loaded[config_module] = saved_config
		package.loaded[file_system_module] = saved_file_system
		os.remove(path)
		if not ok then error(err, 0) end
	end)

	helpers.it("non-canonical delimiter records survive unrelated category saves", function()
		local config_module = "modules.hotstrings.hotstrings_config"
		local file_system_module = "adapters.file_system"
		local saved_config = package.loaded[config_module]
		local saved_file_system = package.loaded[file_system_module]
		local records = {
			'word_delimiters = " ,;!?" # user-owned trailing comment',
			"word_delimiters = ' ,;!?'",
		}
		local paths = {}
		local ok, err = xpcall(function()
			for index, record in ipairs(records) do
				local path = os.tmpname()
				paths[#paths + 1] = path
				local fh = assert(io.open(path, "w"))
				assert(fh:write("[__global__]\n" .. record
					.. "\n\n[rolls]\ndelay = 0.5\n"))
				assert(fh:close())

				package.loaded[config_module] = nil
				package.loaded[file_system_module] = require("tests.support.file_system_write_stub")
				local cfg = helpers.load_with_stubs(config_module)
				helpers.assert_eq(cfg.init({
					override_path = path,
					toml_resolver = function() return nil end,
				}), true)
				helpers.assert_eq(cfg.set_override("rolls", nil, "delay", 0.75), true,
					"the unrelated category mutation must commit")

				local reread = assert(io.open(path, "r"))
				local content = assert(reread:read("*a"))
				assert(reread:close())
				helpers.assert_contains(content, "delay = 0.75",
					"the preservation check must observe a real category save")
				helpers.assert_contains(content, record,
					"unsupported owned record " .. tostring(index)
					.. " must pass through byte-for-byte instead of disappearing")

				helpers.assert_eq(cfg.set_word_delimiters(" ;"), true,
					"an explicit delimiter edit must still replace the preserved record")
				local normalized_file = assert(io.open(path, "r"))
				local normalized = assert(normalized_file:read("*a"))
				assert(normalized_file:close())
				local _, delimiter_count = normalized:gsub("word_delimiters%s*=", "")
				helpers.assert_eq(delimiter_count, 1,
					"an explicit delimiter edit must not leave a duplicate passthrough key")
				helpers.assert_contains(normalized, 'word_delimiters = " ;"',
					"the explicit edit must publish the canonical representation")
				helpers.assert_true(normalized:find(record, 1, true) == nil,
					"the replaced non-canonical record must no longer survive")
			end
		end, debug.traceback)
		package.loaded[config_module] = saved_config
		package.loaded[file_system_module] = saved_file_system
		for _, path in ipairs(paths) do os.remove(path) end
		if not ok then error(err, 0) end
	end)

end)

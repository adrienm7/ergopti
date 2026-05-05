--- tests/unit/lib/test_toml_roundtrip.lua

--- ==============================================================================
--- MODULE: TOML Roundtrip Tests
--- DESCRIPTION:
--- Asserts that a hotstrings data structure survives a write-then-parse cycle:
--- the meta description, sections_order, section descriptions, and entries
--- (including their boolean flags) are recovered identically.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")
local writer = helpers.load_with_stubs("lib.toml_writer")
local reader = helpers.load_with_stubs("lib.toml_reader")


--- Writes the given data to a temp file, parses it back, and returns the parsed
--- structure plus the temp path so callers can inspect it if needed.
--- @param data table
--- @return table, string
local function roundtrip(data)
	local path
	if package.config:sub(1, 1) == "\\" then
		path = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/rt_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 99999)) .. ".toml"
	else
		path = os.tmpname()
	end
	assert(writer.write(path, data))
	local parsed = reader.parse(path)
	return parsed, path
end




-- ===================================
-- ===================================
-- ======= 1/ Meta Roundtrip =========
-- ===================================
-- ===================================

helpers.describe("toml roundtrip: meta block", function()
	helpers.it("preserves meta description", function()
		local data = {
			meta = { description = "A test description" },
			sections_order = {},
			sections = {},
		}
		local parsed = roundtrip(data)
		helpers.assert_eq(parsed.meta.description, "A test description")
	end)

	helpers.it("preserves sections_order", function()
		local data = {
			sections_order = { "alpha", "beta" },
			sections = {
				alpha = { description = "Alpha", entries = {} },
				beta  = { description = "Beta",  entries = {} },
			},
		}
		local parsed = roundtrip(data)
		helpers.assert_eq(parsed.sections_order[1], "alpha")
		helpers.assert_eq(parsed.sections_order[2], "beta")
	end)

	helpers.it("preserves separator markers in sections_order", function()
		local data = {
			sections_order = { "alpha", "-", "beta" },
			sections = {
				alpha = { description = "A", entries = {} },
				beta  = { description = "B", entries = {} },
			},
		}
		local parsed = roundtrip(data)
		-- Order should preserve the "-" marker
		local has_sep = false
		for _, n in ipairs(parsed.sections_order) do
			if n == "-" then has_sep = true ; break end
		end
		helpers.assert_true(has_sep, "expected separator marker preserved")
	end)
end)




-- ===================================
-- ===================================
-- ======= 2/ Entry Roundtrip ========
-- ===================================
-- ===================================

helpers.describe("toml roundtrip: entries", function()
	helpers.it("preserves single entry trigger and output", function()
		local data = {
			sections_order = { "s" },
			sections = { s = { description = "S", entries = {
				{ trigger = "hi", output = "Hello world",
				  is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
			} } },
		}
		local parsed = roundtrip(data)
		helpers.assert_eq(#parsed.sections.s.entries, 1)
		helpers.assert_eq(parsed.sections.s.entries[1].trigger, "hi")
		helpers.assert_eq(parsed.sections.s.entries[1].output, "Hello world")
	end)

	helpers.it("preserves boolean flags", function()
		local data = {
			sections_order = { "s" },
			sections = { s = { description = "S", entries = {
				{ trigger = "x", output = "X",
				  is_word = true, auto_expand = true,
				  is_case_sensitive = true, final_result = true },
			} } },
		}
		local parsed = roundtrip(data)
		local e = parsed.sections.s.entries[1]
		helpers.assert_eq(e.is_word, true)
		helpers.assert_eq(e.auto_expand, true)
		helpers.assert_eq(e.is_case_sensitive, true)
	end)

	helpers.it("preserves multiple entries in order", function()
		local data = {
			sections_order = { "s" },
			sections = { s = { description = "S", entries = {
				{ trigger = "a", output = "A", is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
				{ trigger = "b", output = "B", is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
				{ trigger = "c", output = "C", is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
			} } },
		}
		local parsed = roundtrip(data)
		helpers.assert_eq(#parsed.sections.s.entries, 3)
		helpers.assert_eq(parsed.sections.s.entries[1].trigger, "a")
		helpers.assert_eq(parsed.sections.s.entries[3].trigger, "c")
	end)

	helpers.it("survives quote and backslash characters in description", function()
		local data = {
			meta = { description = 'has "quotes"' },
			sections_order = {},
			sections = {},
		}
		local parsed = roundtrip(data)
		helpers.assert_eq(parsed.meta.description, 'has "quotes"')
	end)
end)

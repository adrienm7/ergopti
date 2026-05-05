--- tests/unit/lib/test_toml_writer.lua

--- ==============================================================================
--- MODULE: toml_writer Unit Tests
--- DESCRIPTION:
--- Verifies the TOML serializer emits a well-formed personal.toml: meta block,
--- section ordering, entries, token alias normalization, and escape handling.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")
local writer = helpers.load_with_stubs("lib.toml_writer")


--- Convenience: writes a TOML payload to a temp file and returns its content.
--- @param data table The hotstrings data structure.
--- @return string|nil
local function write_and_read(data)
	local path = os.tmpname()
	if package.config:sub(1, 1) == "\\" then
		path = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/tw_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 99999)) .. ".toml"
	end
	local ok = writer.write(path, data)
	if not ok then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local body = fh:read("*a")
	fh:close()
	return body
end




-- =================================
-- =================================
-- ======= 1/ Input Guards =========
-- =================================
-- =================================

helpers.describe("toml_writer.write: input validation", function()
	helpers.it("rejects empty path", function()
		local ok, err = writer.write("", {})
		helpers.assert_eq(ok, false)
		helpers.assert_true(type(err) == "string")
	end)

	helpers.it("rejects non-string path", function()
		local ok = writer.write(nil, {})
		helpers.assert_eq(ok, false)
	end)

	helpers.it("accepts empty data", function()
		local body = write_and_read({})
		helpers.assert_true(body ~= nil and body:find("%[_meta%]") ~= nil)
	end)
end)




-- =================================
-- =================================
-- ======= 2/ Meta Block ===========
-- =================================
-- =================================

helpers.describe("toml_writer.write: meta block", function()
	helpers.it("emits description from meta", function()
		local body = write_and_read({ meta = { description = "ma desc" } })
		helpers.assert_true(body:find('description = "ma desc"') ~= nil)
	end)

	helpers.it("falls back to default description when meta is missing", function()
		local body = write_and_read({})
		helpers.assert_true(body:find("Hotstrings personnels") ~= nil)
	end)

	helpers.it("emits empty sections_order when none provided", function()
		local body = write_and_read({})
		helpers.assert_true(body:find("sections_order = %[%]") ~= nil)
	end)

	helpers.it("emits sections_order in supplied order", function()
		local body = write_and_read({ sections_order = { "alpha", "beta" } })
		local s, _ = body:find('sections_order = %["alpha", "beta"%]')
		helpers.assert_true(s ~= nil)
	end)

	helpers.it("renders [_meta.sections] when at least one real section exists", function()
		local body = write_and_read({
			sections_order = { "alpha" },
			sections = { alpha = { description = "Alpha", entries = {} } },
		})
		helpers.assert_true(body:find("%[_meta%.sections%]") ~= nil)
		helpers.assert_true(body:find('alpha = "Alpha"') ~= nil)
	end)

	helpers.it("skips [_meta.sections] when only separators are present", function()
		local body = write_and_read({ sections_order = { "-" } })
		helpers.assert_true(body:find("%[_meta%.sections%]") == nil)
	end)
end)




-- =================================
-- =================================
-- ======= 3/ Entries =============
-- =================================
-- =================================

helpers.describe("toml_writer.write: entries", function()
	helpers.it("emits a [[section]] header for each real section", function()
		local body = write_and_read({
			sections_order = { "alpha" },
			sections = { alpha = { description = "Alpha", entries = {} } },
		})
		helpers.assert_true(body:find("%[%[alpha%]%]") ~= nil)
	end)

	helpers.it("emits one inline-table line per entry", function()
		local body = write_and_read({
			sections_order = { "alpha" },
			sections = { alpha = { description = "A", entries = {
				{ trigger = "hi", output = "Hello", is_word = true,
				  auto_expand = false, is_case_sensitive = true, final_result = false },
			} } },
		})
		helpers.assert_true(body:find('"hi" = {') ~= nil)
		helpers.assert_true(body:find('output = "Hello"') ~= nil)
		helpers.assert_true(body:find('is_word = true') ~= nil)
		helpers.assert_true(body:find('auto_expand = false') ~= nil)
		helpers.assert_true(body:find('is_case_sensitive = true') ~= nil)
	end)

	helpers.it("skips entries missing required fields", function()
		local body = write_and_read({
			sections_order = { "alpha" },
			sections = { alpha = { description = "A", entries = {
				{ trigger = "ok", output = "Hello" },
				{ trigger = "bad" },                   -- Missing output
				{ output = "no trigger" },             -- Missing trigger
			} } },
		})
		helpers.assert_true(body:find('"ok" =') ~= nil)
		helpers.assert_true(body:find('"bad" =') == nil)
	end)

	helpers.it("skips '-' separator sections in [[section]] block emission", function()
		local body = write_and_read({
			sections_order = { "-", "alpha" },
			sections = { alpha = { description = "A", entries = {} } },
		})
		helpers.assert_true(body:find("%[%[%-%]%]") == nil)
	end)
end)




-- ====================================
-- ====================================
-- ======= 4/ Escapes & Tokens ========
-- ====================================
-- ====================================

helpers.describe("toml_writer.write: escapes and tokens", function()
	helpers.it("escapes embedded quotes and backslashes", function()
		local body = write_and_read({
			sections_order = { "s" },
			sections = { s = { description = 'has "quotes" and \\backslash', entries = {} } },
		})
		helpers.assert_true(body:find('\\"quotes\\"') ~= nil)
		helpers.assert_true(body:find("\\\\backslash") ~= nil)
	end)

	helpers.it("converts literal newlines to {Enter}", function()
		local body = write_and_read({
			sections_order = { "s" },
			sections = { s = { description = "A", entries = {
				{ trigger = "t", output = "line1\nline2",
				  is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
			} } },
		})
		helpers.assert_true(body:find("{Enter}") ~= nil)
	end)

	helpers.it("normalizes token aliases ({esc} → {Escape})", function()
		local body = write_and_read({
			sections_order = { "s" },
			sections = { s = { description = "A", entries = {
				{ trigger = "t", output = "go{esc}done",
				  is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
			} } },
		})
		helpers.assert_true(body:find("{Escape}") ~= nil)
	end)

	helpers.it("normalizes {return} → {Enter}", function()
		local body = write_and_read({
			sections_order = { "s" },
			sections = { s = { description = "A", entries = {
				{ trigger = "t", output = "{return}",
				  is_word = false, auto_expand = false,
				  is_case_sensitive = false, final_result = false },
			} } },
		})
		helpers.assert_true(body:find("{Enter}") ~= nil)
	end)
end)

--- tests/unit/lib/test_toml_reader.lua

--- ==============================================================================
--- MODULE: toml_reader Unit Tests
--- DESCRIPTION:
--- Validates the project's mini-TOML parser via fixture files written to a
--- temp directory. Covers the meta block, sections, entries, escapes, and
--- bad-input handling.
--- ==============================================================================

local helpers = require("tests.helpers")

-- toml_reader logs through lib.logger; load it first under the stub
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local reader = helpers.load_with_stubs("infra.toml.reader")

local function write_temp(name, body)
	local path = os.tmpname()
	-- os.tmpname on Windows returns paths starting with \, prepend env or use cwd
	if package.config:sub(1, 1) == "\\" then
		path = path:gsub("\\", "/")
		path = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/" .. name .. "_" .. tostring(os.time()) .. ".toml"
	end
	local fh = io.open(path, "w") ; assert(fh, "cannot open " .. path)
	fh:write(body) ; fh:close()
	return path
end

helpers.describe("toml_reader.parse: meta and entries", function()
	helpers.it("parses a minimal valid file", function()
		local body = [==[
[_meta]
description = "test fixture"
sections_order = ["alpha", "beta"]

[_meta.sections]
alpha = "Alpha section"
beta = "Beta section"

[[alpha]]
"hello" = { output = "world", is_word = true }

[[beta]]
"foo" = { output = "bar" }
]==]
		local path = write_temp("min", body)
		local data, committed = reader.parse(path)
		helpers.assert_eq(committed, true, "a complete readable file must report an exact commit")
		helpers.assert_eq(data.meta.description, "test fixture")
		helpers.assert_eq(data.sections_order, { "alpha", "beta" })
		helpers.assert_eq(#data.sections.alpha.entries, 1)
		helpers.assert_eq(data.sections.alpha.entries[1].trigger, "hello")
		helpers.assert_eq(data.sections.alpha.entries[1].output, "world")
		helpers.assert_eq(data.sections.alpha.entries[1].is_word, true)
		os.remove(path)
	end)

	helpers.it("returns the empty result for a missing file", function()
		local data, committed = reader.parse("/no/such/file/anywhere.toml")
		helpers.assert_eq(data.sections, {})
		helpers.assert_eq(committed, false, "a missing file must expose the failed read transaction")
	end)

	helpers.it("returns the empty result for non-string path", function()
		local data, committed = reader.parse(nil)
		helpers.assert_eq(data.sections, {})
		helpers.assert_eq(committed, false, "an invalid path must expose the failed read transaction")
	end)

	helpers.it("reports read and close failures instead of certifying partial data", function()
		local original_open = io.open
		local cases = {
			{
				label = "read failure",
				handle = {
					lines = function() error("PRIVATE-READ-FAILURE", 0) end,
					close = function() return true end,
				},
			},
			{
				label = "close failure",
				handle = {
					lines = function() return function() return nil end end,
					close = function() return false end,
				},
			},
		}

		local test_ok, test_err = xpcall(function()
			for _, case in ipairs(cases) do
				io.open = function() return case.handle end
				local call_ok, data, committed = pcall(reader.parse, "/controlled/hotstrings.toml")
				helpers.assert_true(call_ok, case.label .. " must not escape the parser")
				helpers.assert_eq(data.sections, {}, case.label .. " must discard partial data")
				helpers.assert_eq(committed, false, case.label .. " must never report a committed parse")
			end
		end, debug.traceback)
		io.open = original_open
		if not test_ok then error(test_err, 0) end
	end)

	helpers.it("preserves UTF-8 in values", function()
		local body = [==[
[[s]]
"é" = { output = "été" }
]==]
		local path = write_temp("utf", body)
		local data = reader.parse(path)
		helpers.assert_eq(data.sections.s.entries[1].trigger, "é")
		helpers.assert_eq(data.sections.s.entries[1].output, "été")
		os.remove(path)
	end)

	helpers.it("preserves the first section after a UTF-8 BOM", function()
		local bom = string.char(0xEF, 0xBB, 0xBF)
		local body = bom .. [==[[[personal]]
"star" = { output = "." }
]==]
		local path = write_temp("bom", body)
		local data, committed = reader.parse(path)
		helpers.assert_eq(committed, true, "a BOM-prefixed readable file must still commit")
		helpers.assert_true(type(data.sections.personal) == "table",
			"the first BOM-prefixed section header must be recognized")
		helpers.assert_eq(data.sections.personal.entries[1].trigger, "star")
		helpers.assert_eq(data.sections.personal.entries[1].output, ".")
		os.remove(path)
	end)

	helpers.it("decodes escape sequences", function()
		local body = [==[
[[s]]
"a" = { output = "b\nc" }
]==]
		local path = write_temp("esc", body)
		local data = reader.parse(path)
		helpers.assert_eq(data.sections.s.entries[1].output, "b\nc")
		os.remove(path)
	end)

	helpers.it("ignores entries without an output field", function()
		local body = [==[
[[s]]
"a" = { is_word = true }
"b" = { output = "ok" }
]==]
		local path = write_temp("noout", body)
		local data = reader.parse(path)
		helpers.assert_eq(#data.sections.s.entries, 1)
		helpers.assert_eq(data.sections.s.entries[1].trigger, "b")
		os.remove(path)
	end)
end)

helpers.describe("toml_reader.load", function()
	helpers.it("returns 0 when keymap_module lacks .add", function()
		local n = reader.load("/no/such/file.toml", {})
		helpers.assert_eq(n, 0)
	end)

	helpers.it("calls keymap.add for every entry", function()
		local body = [==[
[[s]]
"a" = { output = "1" }
"b" = { output = "2" }
"c" = { output = "3" }
]==]
		local path = write_temp("load", body)
		local calls = {}
		local fake = { add = function(t, o) calls[#calls + 1] = { t, o } end }
		local n = reader.load(path, fake)
		helpers.assert_eq(n, 3)
		helpers.assert_eq(#calls, 3)
		os.remove(path)
	end)
end)

helpers.describe("toml_reader: duplicate definition commitment", function()
	helpers.it("rejects a duplicate trigger transaction before any registration", function()
		local body = [==[
[[s]]
"dup" = { output = "first" }
"dup" = { output = "second" }
]==]
		local path = write_temp("duplicate_trigger", body)
		local data, committed = reader.parse(path)

		helpers.assert_eq(committed, false,
			"a duplicate trigger must invalidate the complete read transaction")
		helpers.assert_eq(data.sections, {}, "no partial section may escape a rejected parse")

		local calls = {}
		local count = reader.load(path, {
			add = function(trigger, output)
				calls[#calls + 1] = { trigger, output }
			end,
		})
		helpers.assert_eq(count, 0, "a rejected parse must register zero entries")
		helpers.assert_eq(#calls, 0, "the keymap boundary must remain untouched")
		os.remove(path)
	end)

	helpers.it("allows the same trigger in two distinct sections", function()
		local body = [==[
[[first]]
"shared" = { output = "one" }
[[second]]
"shared" = { output = "two" }
]==]
		local path = write_temp("cross_section_trigger", body)
		local data, committed = reader.parse(path)

		helpers.assert_eq(committed, true,
			"cross-section collisions remain a registry-priority concern")
		helpers.assert_eq(data.sections.first.entries[1].output, "one")
		helpers.assert_eq(data.sections.second.entries[1].output, "two")
		os.remove(path)
	end)

	helpers.it("rejects duplicate fields inside a hotstring inline table", function()
		local body = [==[
[[s]]
"dup" = { output = "first", output = "second" }
]==]
		local path = write_temp("duplicate_inline_field", body)
		local data, committed = reader.parse(path)

		helpers.assert_eq(committed, false,
			"an inline-table duplicate must invalidate the complete read transaction")
		helpers.assert_eq(data.sections, {}, "no partially decoded entry may escape")
		os.remove(path)
	end)
end)

helpers.describe("toml_reader.parse: per-entry priority", function()
	-- Regression: parse_entry previously skipped numeric inline-table values, so a
	-- personal hotstring's `priority = N` was silently dropped and the macOS loader
	-- always fell back to the source default — making the per-hotstring priority
	-- override a no-op. These pin that the numeric value is captured as a number,
	-- and that an entry without the key reads back nil (so the cascade falls back).
	helpers.it("captures a numeric priority key as a number", function()
		local body = [==[
[[s]]
"win" = { output = "W", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false, priority = 80 }
"def" = { output = "D", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }
]==]
		local path = write_temp("prio", body)
		local data = reader.parse(path)
		local e = data.sections.s.entries
		helpers.assert_eq(e[1].trigger, "win")
		helpers.assert_eq(e[1].priority, 80)
		helpers.assert_eq(e[2].trigger, "def")
		helpers.assert_eq(e[2].priority, nil)
		os.remove(path)
	end)

	-- The collision-priority cascade also reads a FILE-level [_meta] priority and a
	-- per-section [_meta.sections.<name>] priority. These were never parsed before, so
	-- the macOS engine's section/file priority path was dormant — the delays/colors
	-- window had nothing to feed it. Pin that both levels are captured as numbers.
	helpers.it("captures file-level and per-section [_meta] priority", function()
		local body = [==[
[_meta]
priority = 35

[_meta.sections.foo]
priority = 65

[[foo]]
"hi" = { output = "yo" }
]==]
		local path = write_temp("metaprio", body)
		local data = reader.parse(path)
		helpers.assert_eq(data.meta.priority, 35)
		helpers.assert_eq(data.meta.sections.foo.priority, 65)
		os.remove(path)
	end)
end)

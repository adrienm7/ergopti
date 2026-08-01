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
		local data = reader.parse(path)
		helpers.assert_eq(data.meta.description, "test fixture")
		helpers.assert_eq(data.sections_order, { "alpha", "beta" })
		helpers.assert_eq(#data.sections.alpha.entries, 1)
		helpers.assert_eq(data.sections.alpha.entries[1].trigger, "hello")
		helpers.assert_eq(data.sections.alpha.entries[1].output, "world")
		helpers.assert_eq(data.sections.alpha.entries[1].is_word, true)
		os.remove(path)
	end)

	helpers.it("returns the empty result for a missing file", function()
		local data = reader.parse("/no/such/file/anywhere.toml")
		helpers.assert_eq(data.sections, {})
	end)

	helpers.it("returns the empty result for non-string path", function()
		local data = reader.parse(nil)
		helpers.assert_eq(data.sections, {})
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

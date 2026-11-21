--- tests/unit/hotstrings/engine/dynamic/test_personal_tag_case.lua

--- ==============================================================================
--- MODULE: Personal @-Tag Case (hcd-5-tag-case)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/personal_info/tag_case_vectors.json through the
--- real manager: a personal tag follows the typed case, one field per letter
--- (maintainer decision HCD-5, 2026-11-21). A one-letter tag is a registered
--- rule, a longer one the fire-time combo resolver; both must type the values
--- of the vector. Linux used to keep the one-letter rules exact-case, so `@N`
--- typed nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local restore_family_preferences = require("tests.support.dynamic_hotstrings_fixture").install()
local dh = helpers.load_module("hotstrings.engine.dynamic.manager")
local Engine = require("hotstrings.engine.dynamic.core")

--- Reads the shared vectors.
--- @return table
local function read_corpus()
	local this = debug.getinfo(1, "S").source:gsub("^@", "")
	local linux_root = this:match("^(.*[/\\])tests[/\\]")
	local handle = assert(io.open(linux_root .. "../_shared/tests/corpus/personal_info/tag_case_vectors.json", "r"))
	local raw = handle:read("*a")
	handle:close()
	return require("core.text.engine.json").decode(raw)
end

--- The corpus as a personal_info.toml document.
--- @param corpus table
--- @return string
local function fixture_toml(corpus)
	local lines = { "[info]" }
	for field, value in pairs(corpus.info) do lines[#lines + 1] = string.format("%s = %q", field, value) end
	lines[#lines + 1] = "[letters]"
	for letter, field in pairs(corpus.letters) do lines[#lines + 1] = string.format("%s = %q", letter, field) end
	return table.concat(lines, "\n") .. "\n"
end

--- The values the manager types for a tag: the registered rule for one letter,
--- the combo resolver otherwise.
--- @param tag string
--- @return table
local function typed_values(tag)
	if utf8.len(tag) == 1 then
		for _, rule in ipairs(Engine.get_rules()) do
			if rule.suffix == "@" .. tag then return { rule.resolver() } end
		end
		return {}
	end
	return dh.resolve_combo_values(tag)
end

helpers.describe("personal @-tag case: the shared corpus (hcd-5-tag-case)", function()
	local corpus = read_corpus()
	local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	local path = tmp_dir:gsub("\\", "/") .. "/ergopti_personal_tag_case.toml"

	for _, vector in ipairs(corpus.vectors) do
		helpers.it(vector.id .. " (hcd-5-tag-case)", function()
			local fh = assert(io.open(path, "w"))
			fh:write(fixture_toml(corpus))
			fh:close()
			local ok, err = pcall(function()
				dh.init({ trigger_char = "\\", personal_info_path = path })
				assert(dh.set_enabled(true))
				helpers.assert_eq(table.concat(vector.values, "|"), table.concat(typed_values(vector.tag), "|"),
					"the typed values of @" .. vector.tag)
			end)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end
end)

restore_family_preferences()

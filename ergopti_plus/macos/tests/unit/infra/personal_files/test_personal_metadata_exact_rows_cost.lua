--- tests/unit/infra/personal_files/test_personal_metadata_exact_rows_cost.lua

--- ==============================================================================
--- MODULE: Regression — the personal-row alias preflight stays linear
--- DESCRIPTION:
--- A whole-snapshot preferences save checks every personal hotstring row for a
--- case alias in config.toml. The check re-parsed every header and record for
--- each row; with 96 personal rows it held the main thread about 1 s
--- (2026-10-30 macOS field report: preferences.save 2 000 ms, hotstrings=970).
--- The scan is now indexed once by case-folded path. These cases pin the alias
--- verdicts against a copy of the old loop and bound the parse count.
--- ==============================================================================

local helpers = require("tests.helpers")
local KeyPath = require("toml_codec.key_path")
local Scanner = require("toml_codec.record_scanner")
local Metadata = require("hotstrings.personal_metadata")
local PersonalFiles = require("hotstrings.personal_files")

--- The shipped row-by-row check, kept as the semantic oracle.
local function reference(content, rows)
	local function same_folded(a, b)
		if #a ~= #b then return false end
		for index, segment in ipairs(a) do if segment:lower() ~= b[index]:lower() then return false end end
		return true
	end
	local scanned = Scanner.scan_records(content, { quoted_headers = true })
	if not scanned then return false end
	for _, row in ipairs(rows) do
		local target = assert(KeyPath.parse(row.section, true))
		for _, header in ipairs(scanned.headers) do
			if header.segments and same_folded(header.segments, target)
				and KeyPath.render(header.segments) ~= KeyPath.render(target) then return false end
		end
		for _, record in ipairs(scanned.records) do
			local section, key = record.section, record.key
			if record.quoted then section, key = record.quoted.section, record.quoted.key end
			local owner = section and KeyPath.parse(section, true)
			if owner and (record.quoted or record.addressable and #record.key_segments == 1)
				and same_folded(owner, target) and key:lower() == row.key:lower()
				and (KeyPath.render(owner) ~= KeyPath.render(target) or key ~= row.key) then return false end
		end
	end
	return true
end

--- A config with `groups` personal module tables of `sections` choices each.
local function personal_config(groups, sections, spell)
	local ids, lines, rows = {}, { "[hotstrings]", "enabled = true", "" }, {}
	for g = 1, groups do
		ids[g] = PersonalFiles.describe({ "perso_" .. g .. ".toml" }).id
		local section = KeyPath.render({ "hotstrings", "modules", ids[g] })
		lines[#lines + 1] = "[" .. (spell and spell(g, section) or section) .. "]"
		for s = 1, sections do
			lines[#lines + 1] = "Section_" .. s .. " = true"
			rows[#rows + 1] = { section = section, key = "Section_" .. s }
		end
		lines[#lines + 1] = ""
	end
	return table.concat(lines, "\n"), rows
end

helpers.describe("hotstrings.personal_metadata: exact personal rows preflight cost", function()
	helpers.it("accepts exact spellings and refuses header and key case aliases like the old loop", function()
		local exact, rows = personal_config(3, 4)
		helpers.assert_eq(Metadata.exact_rows_available(exact, rows), true)
		helpers.assert_eq(reference(exact, rows), true)

		local header_alias = personal_config(3, 4, function(g, section)
			return g == 2 and section:gsub("modules", "MODULES") or section
		end)
		helpers.assert_eq(Metadata.exact_rows_available(header_alias, rows), false)
		helpers.assert_eq(reference(header_alias, rows), false)

		local key_alias = exact:gsub("Section_3 = true", "section_3 = true", 1)
		helpers.assert_eq(Metadata.exact_rows_available(key_alias, rows), false)
		helpers.assert_eq(reference(key_alias, rows), false)

		local dotted_alias = exact .. "\n[hotstrings]\nMODULES.x = 1\n"
		helpers.assert_eq(Metadata.exact_rows_available(dotted_alias, rows), reference(dotted_alias, rows))
		helpers.assert_eq(Metadata.exact_rows_available(exact, {}), true)
	end)

	helpers.it("matches the old loop on random case mutations", function()
		math.randomseed(20261030)
		local base, rows = personal_config(4, 6)
		for case = 1, 200 do
			local mutated = base:gsub("Section_(%d)", function(digit)
				if math.random(40) == 1 then return "section_" .. digit end
			end)
			local probe = { rows[math.random(#rows)], rows[math.random(#rows)] }
			local expected = reference(mutated, probe)
			if Metadata.exact_rows_available(mutated, probe) ~= expected then
				error(string.format("case %d: verdict differs from the old loop (expected %s)", case, tostring(expected)), 0)
			end
		end
	end)

	helpers.it("parses each header and record once, not once per row", function()
		local content, rows = personal_config(8, 24)
		Scanner.scan_records(content, { quoted_headers = true })
		local original, calls = KeyPath.parse, 0
		KeyPath.parse = function(...) calls = calls + 1; return original(...) end
		local ok, available = pcall(Metadata.exact_rows_available, content, rows)
		KeyPath.parse = original
		assert(ok, available)
		helpers.assert_eq(available, true)
		local records = 8 * 24 + 1
		-- One parse per record plus one per row; the old loop parsed records x rows.
		helpers.assert_true(calls <= 2 * (records + #rows), string.format(
			"%d parses for %d rows over %d records", calls, #rows, records))
	end)
end)

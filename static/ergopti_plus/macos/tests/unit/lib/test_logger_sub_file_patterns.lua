--- tests/unit/lib/test_logger_sub_file_patterns.lua

--- ==============================================================================
--- MODULE: Regression — a routing pattern containing ']' must not end the array
--- DESCRIPTION:
--- The sub-file routing parser closed a multi-line TOML array on the first line
--- whose raw text contained "]". Patterns are tag-based by design — the shared
--- file's own guidance is to "prefer tag-based patterns (e.g. \"[gestures\")" —
--- so a closing bracket inside a pattern string is the norm, not an edge case.
--- Every pattern after such a line was silently discarded and the sub-file it
--- belonged to simply stopped receiving those lines.
---
--- ROOT CAUSE ENCODED:
--- Structure located by searching the raw line instead of the line minus its
--- string literals.
---
--- WHERE THIS NOW APPLIES:
--- The driver no longer parses the TOML. There were two hand-rolled parsers of
--- the same grammar, one per driver, and this bug had to be found and fixed in
--- each; the routing table is generated from the canonical file instead. The bug
--- is therefore structurally impossible in the driver, but it remains possible in
--- the GENERATOR — so this test moved with it. It compares the table the logger
--- actually loads against every pattern the canonical TOML declares, and the
--- assertion is the one that used to fail: a pattern listed AFTER a
--- bracket-bearing one must still be there.
---
--- The previous version had already degraded into pinning a spelling
--- (`src:find("strip_quoted(line)")`) because the parser was private. Asserting
--- the loaded data instead means any correct implementation satisfies it, and no
--- rename can quietly make it vacuous.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Reads the canonical [[sub_files]] entries straight from the shared TOML.
---
--- Hand-parsed here on purpose: reusing the generator's own parser would make
--- the test agree with the generator by construction, which is the one thing it
--- must not do. This reader is deliberately naive — it looks only for the fields
--- it needs — and the sanity assertions below fail loudly if it reads nothing.
--- @return table|nil Array of { name, patterns, platforms }, or nil if unreadable.
local function read_canonical_entries()
	-- tests run from the driver root: macos/ → ergopti_plus/ → _shared/
	local fh = io.open("../_shared/modules/logger/sub_files.toml", "r")
	if not fh then return nil end
	local raw = fh:read("*a")
	fh:close()

	local entries, cur, field = {}, nil, nil
	for line in raw:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed == "[[sub_files]]" then
			cur = { patterns = {}, platforms = {} }
			entries[#entries + 1] = cur
			field = nil
		elseif cur then
			local name = trimmed:match('^name%s*=%s*"([^"]*)"')
			if name then
				cur.name = name
			else
				local key, rest = trimmed:match("^(patterns)%s*=%s*%[(.*)$")
				if not key then key, rest = trimmed:match("^(platforms)%s*=%s*%[(.*)$") end
				if key then
					field = key
					for s in rest:gmatch('"([^"]*)"') do cur[field][#cur[field] + 1] = s end
					-- Closing bracket looked for OUTSIDE quoted spans — the very
					-- distinction this test exists for.
					if (rest:gsub('"[^"]*"', "")):find("]", 1, true) then field = nil end
				elseif field then
					for s in trimmed:gmatch('"([^"]*)"') do cur[field][#cur[field] + 1] = s end
					if (trimmed:gsub('"[^"]*"', "")):find("]", 1, true) then field = nil end
				end
			end
		end
	end
	return entries
end





-- ==========================================================================
-- ==========================================================================
-- ======= 1/ Every declared pattern reaches the loaded routing table =======
-- ==========================================================================
-- ==========================================================================

helpers.describe("logger: routing patterns that contain a bracket are all kept", function()

	helpers.it("keeps every pattern of an array whose entries carry ']'", function()
		local canonical = read_canonical_entries()
		helpers.assert_true(type(canonical) == "table" and #canonical > 0,
			"the canonical sub_files.toml must be readable, or this test asserts nothing")

		local routing = require("_generated.logger_sub_files")
		helpers.assert_true(type(routing) == "table" and #routing > 0,
			"the generated routing table must be loadable and non-empty — an empty table "
			.. "makes every topical log vanish with no diagnostic")

		-- name → set of patterns, as the logger will actually use them.
		local loaded = {}
		for _, sub in ipairs(routing) do
			local set = {}
			for _, pat in ipairs(sub.patterns or {}) do set[pat] = true end
			loaded[sub.name] = set
		end

		local checked, bracket_bearing = 0, 0
		for _, entry in ipairs(canonical) do
			local is_hs = false
			for _, p in ipairs(entry.platforms) do if p == "hs" then is_hs = true end end
			if is_hs then
				local file = "ErgoptiPlus_" .. entry.name .. ".log"
				helpers.assert_true(loaded[file] ~= nil,
					"sub-file '" .. file .. "' is declared for hs but missing from the routing table")
				for i, pat in ipairs(entry.patterns) do
					checked = checked + 1
					if pat:find("]", 1, true) then bracket_bearing = bracket_bearing + 1 end
					helpers.assert_true(loaded[file][pat] == true,
						"pattern #" .. i .. ' ("' .. pat .. '") of ' .. file .. " is declared in "
						.. "sub_files.toml but absent from the routing table — this is the shipped bug: "
						.. "a ']' inside a quoted pattern used to close the array early and silently "
						.. "drop every pattern after it")
				end
			end
		end

		helpers.assert_true(checked > 20,
			"only " .. checked .. " pattern(s) compared — the canonical reader is broken and this "
			.. "test is passing over nothing")
		helpers.assert_true(bracket_bearing > 0,
			"no declared pattern contains ']' any more, so nothing here exercises the bug this test "
			.. "exists for. Keep a bracketed tag pattern (the file's own guidance recommends them) "
			.. "or this assertion is decorative")
	end)

end)

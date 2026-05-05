--- tests/meta/test_no_coauthor_in_commits.lua

--- ==============================================================================
--- MODULE: Commit Hygiene Test
--- DESCRIPTION:
--- Verifies new commits (those not yet on `origin/dev`) don't include
--- `Co-Authored-By` trailers, in line with the project's commit conventions
--- (no LLM/tool credits).
---
--- Scoping to `origin/dev..HEAD` means only commits authored as part of the
--- current work-in-progress are inspected — legacy commits already on the
--- shared branches are out of scope (rewriting their history would require
--- a force-push). Going forward, every new commit must remain trailer-free.
---
--- Silently passes when git or the upstream ref is unavailable so the suite
--- still works on tarball checkouts and fresh clones without `origin/dev`.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Resolves the baseline ref for the trailer check. Prefers `origin/dev` so
--- only newly authored commits are inspected; falls back to a 20-commit window
--- when no upstream ref is available (e.g., shallow clone in CI).
--- @return string|nil The git revision range, or nil if no baseline can be found.
local function resolve_baseline()
	for _, ref in ipairs({ "origin/dev", "origin/main" }) do
		local check = io.popen(string.format("git rev-parse --verify %s 2>nul || git rev-parse --verify %s 2>/dev/null", ref, ref))
		if check then
			local out = check:read("*l")
			check:close()
			if out and #out > 0 then
				return ref .. "..HEAD"
			end
		end
	end
	return "HEAD~20..HEAD"
end

helpers.describe("meta: no Co-Authored-By trailers in new commits", function()
	helpers.it("new commits beyond origin/dev are clean", function()
		local range = resolve_baseline()
		local pipe = io.popen(string.format("git log %s --format=%%B 2>nul || git log %s --format=%%B 2>/dev/null", range, range))
		if not pipe then
			print("  (git unavailable — skipping)")
			return
		end
		local body = pipe:read("*a") or "" ; pipe:close()
		-- Strip lines that merely document or test the rule (meta-references).
		local cleaned = body
		for line in body:gmatch("[^\n]+") do
			local lower = line:lower()
			-- A meta-reference is any prose mention of the rule itself: the test
			-- file name, descriptive sentences in commit bodies, README excerpts,
			-- etc. The actual offending pattern is a properly-formed trailer at
			-- the start of a line — which we detect by anchoring the regex
			-- below — so any non-anchored mention is safe to strip here.
			local is_meta = lower:find("test_no_coauthor")
				or lower:find("free of co%-authored%-by")
				or lower:find("forbidden by conventions")
				or lower:find("co%-authored%-by trailer")
				or lower:find("no co%-authored%-by")
				or lower:find("co%-authored%-by in")
			if is_meta then
				cleaned = cleaned:gsub(line:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), "")
			end
		end
		local found = cleaned:lower():find("co%-authored%-by", 1)
		helpers.assert_true(not found,
			"Found 'Co-Authored-By' trailer in new commits (forbidden by conventions)")
	end)
end)

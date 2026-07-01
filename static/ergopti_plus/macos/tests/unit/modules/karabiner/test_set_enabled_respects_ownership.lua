--- tests/unit/modules/karabiner/test_set_enabled_respects_ownership.lua

--- ==============================================================================
--- MODULE: karabiner set_enabled ownership guard regression tests
--- DESCRIPTION:
--- Verifies that M.set_enabled(false) respects the HS-ownership check before
--- issuing the KE-kill call, mirroring the guard already present in M.kill().
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant: set_enabled must call is_hs_owned_bridge before
---    triggering the KE kill so user-managed KE sessions are never killed
---    from the feature toggle.
--- 2. Ordering Check: the ownership guard must appear BEFORE the kill call
---    in set_enabled so the guard cannot be bypassed.
--- 3. Function-Scoped Search (F-MED-17 fix): earlier versions of this test
---    searched the ENTIRE init.lua source for both substrings, so it could
---    never detect a real regression in set_enabled specifically — M.kill()
---    (an unrelated function ~29000 characters later) happens to contain
---    BOTH substrings in the right order too, so a search over the whole
---    file trivially passes even if set_enabled's own guard were deleted.
---    The fix isolates set_enabled's OWN function body first (using its
---    top-level, zero-indentation closing "end" as the boundary — tabs
---    distinguish that from nested "end"s inside the function) and searches
---    only within that slice.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the full source of modules/karabiner/init.lua.
--- @return string The file contents.
local function read_source()
	local src_path = helpers.driver_root() .. "modules/karabiner/init.lua"
	local fh = io.open(src_path, "r")
	helpers.assert_true(fh ~= nil, "modules/karabiner/init.lua must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end

--- Extracts the source body of a single top-level function, delimited by its
--- own signature and its own top-level (zero-indentation) closing "end" line.
--- This codebase indents with tabs exclusively, so a nested "end" inside an
--- if/elseif/for block always carries at least one leading tab — only the
--- function's OWN closing "end" is written as a bare "end" with no leading
--- whitespace at all. Searching for the first "\nend\n" (as a naive
--- whole-file scan would) is NOT safe here because a function containing
--- nested blocks has many standalone "end" lines before its own — but every
--- one of those is TAB-indented, so anchoring on the zero-indent form is safe.
--- @param src string The full file source.
--- @param signature string The exact function signature to search for
---   (e.g. "function M.set_enabled(value)").
--- @return string The function body, from the signature through its closing end.
local function extract_function_body(src, signature)
	local start_pos = src:find(signature, 1, true)
	helpers.assert_true(start_pos ~= nil, signature .. " must exist in the source")

	-- Search for the first "\nend" at column 0 (no leading tab/space) after the
	-- signature — this is guaranteed to be THIS function's own closing end,
	-- never a nested block's end, because every nested end is tab-indented.
	local _, end_line_end = src:find("\nend\n", start_pos, true)
	helpers.assert_true(end_line_end ~= nil,
		signature .. " must have a zero-indentation closing 'end' line")

	return src:sub(start_pos, end_line_end)
end




-- ==================================================================================
-- ==================================================================================
-- ======= 1/ set_enabled ownership guard — source-level invariant check ============
-- ==================================================================================
-- ==================================================================================

helpers.describe("karabiner.init set_enabled — ownership guard (karabiner-life-1 regression)", function()

	helpers.it("set_enabled's OWN body calls is_hs_owned_bridge before the KE kill call (F-MED-17)", function()
		local src  = read_source()
		local body = extract_function_body(src, "function M.set_enabled(value)")

		-- Sanity check: the extracted slice must actually be set_enabled, not
		-- some other function — it must NOT contain M.kill's own signature.
		helpers.assert_true(body:find("function M.kill()", 1, true) == nil,
			"extract_function_body must isolate set_enabled only, not spill into M.kill (F-MED-17 scoping check)")

		local owned_pos = body:find("is_hs_owned_bridge", 1, true)
		local kill_pos  = body:find("KeLifecycle.kill_async", 1, true)

		helpers.assert_true(owned_pos ~= nil,
			"set_enabled must reference is_hs_owned_bridge within its OWN body (ownership guard missing)")
		helpers.assert_true(kill_pos ~= nil,
			"set_enabled must reference KeLifecycle.kill_async within its OWN body")
		-- The guard must appear before the kill call; a guard appearing only
		-- after the kill would be dead code.
		helpers.assert_true(owned_pos < kill_pos,
			"is_hs_owned_bridge guard must appear before KeLifecycle.kill_async within set_enabled's own body")
	end)

	helpers.it("set_enabled's OWN body does NOT call the KE kill unconditionally in the elseif branch (F-MED-17)", function()
		local src  = read_source()
		local body = extract_function_body(src, "function M.set_enabled(value)")

		-- Pre-fix: the elseif branch called the kill directly without an ownership check.
		-- Post-fix: the kill call is nested inside an `if hs_owned then` block.
		local hs_owned_pos = body:find("hs_owned", 1, true)
		local kill_pos     = body:find("KeLifecycle.kill_async", 1, true)
		helpers.assert_true(hs_owned_pos ~= nil,
			"hs_owned variable must exist within set_enabled's own body — ownership guard is wired")
		helpers.assert_true(hs_owned_pos < kill_pos,
			"hs_owned check must gate KeLifecycle.kill_async within set_enabled's own body")
	end)

	-- Meta-regression: proves the OLD whole-file search was a false-positive
	-- risk by demonstrating that M.kill() alone (a DIFFERENT function) also
	-- independently satisfies the same ownership-before-kill ordering. This is
	-- exactly why the un-scoped version of this test file could never have
	-- caught a real regression in set_enabled specifically.
	helpers.it("M.kill() independently also has ownership-before-kill ordering (demonstrates the F-MED-17 false-positive risk)", function()
		local src  = read_source()
		local body = extract_function_body(src, "function M.kill()")

		helpers.assert_true(body:find("function M.set_enabled", 1, true) == nil,
			"extract_function_body must isolate M.kill only, not spill into set_enabled")

		local owned_pos = body:find("is_hs_owned_bridge", 1, true)
		local kill_pos   = body:find("KeLifecycle.KILL_CMD", 1, true)
		helpers.assert_true(owned_pos ~= nil and kill_pos ~= nil and owned_pos < kill_pos,
			"M.kill() itself has the ownership-before-kill ordering — proving a whole-file search "
			.. "could pass on M.kill()'s content alone, even if set_enabled had no guard at all")
	end)

end)

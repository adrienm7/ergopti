--- tests/meta/test_fs_dir_iterator_contract.lua

--- ==============================================================================
--- MODULE: hs.fs.dir Iterator-Contract Guard
--- DESCRIPTION:
--- Pins the safe-usage contract of hs.fs.dir() across the whole Hammerspoon
--- driver, and the test-stub fidelity that lets the suite enforce it.
---
--- WHY THIS EXISTS (regression for init-fsdir-drops-state):
--- hs.fs.dir() has two traps. (1) It THROWS on a missing / permission-denied
--- directory. (2) It returns TWO values — an iterator function AND a directory
--- state object that the iterator REQUIRES as its first argument (real
--- Hammerspoon checks a "directory" userdata metatable and aborts with "directory
--- metatable expected, got nil" otherwise). An earlier audit fixed trap (1) by
--- wrapping the call as `local ok, it = pcall(hs.fs.dir, dir)` and iterating
--- `for x in it do`. That pattern captures ONLY the iterator and silently drops
--- the state object — so on real Hammerspoon every such loop crashed on its first
--- step. init.lua did this in five places and the driver failed to boot
--- (init.lua:427), yet CI stayed green: the old hs stub returned a single,
--- stateless iterator (`function(_) return function() return nil end end`) that
--- needed no state, masking the entire bug class.
---
--- The fix: iterate INSIDE the pcall — `pcall(function() for x in hs.fs.dir(d) ...`
--- — so the throw is caught AND hs.fs.dir's full multi-value return flows into the
--- generic-for. The ONLY blessed shape is therefore the iterator expression
--- appearing directly in a generic-for: `for <vars> in hs.fs.dir(...) do`.
---
--- THREE INVARIANTS PINNED HERE:
---   A. SOURCE CONTRACT — in every driver Lua source, every hs.fs.dir reference is
---      consumed directly by a generic-for. No `pcall(hs.fs.dir, …)`, no
---      `local x = hs.fs.dir(…)`, no `pcall(function() return hs.fs.dir(…) end)` —
---      all of which drop the state object.
---   B. THROW PROTECTION — init.lua still wraps its hs.fs.dir iteration in a pcall
---      so an inaccessible directory cannot abort boot (the original
---      init-fsdir-pcall guarantee, preserved and strengthened).
---   C. STUB FIDELITY — the hs test stub models the real two-value, state-requiring
---      contract, so any future dropped-state regression fails under test instead
---      of hiding behind a lenient stub.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()  -- trailing slash, e.g. ".../macos/"

-- The driver entry point plus every production source root. _shared/lua is
-- resolved through helpers.shared so the folder name lives in one place.
local ENTRY_POINT = DRIVER_ROOT .. "init.lua"
local SOURCE_ROOTS = {
	DRIVER_ROOT .. "ui",
	DRIVER_ROOT .. "modules",
	DRIVER_ROOT .. "lib",
	DRIVER_ROOT .. "adapters",
	helpers.shared("lua"),
}




-- =========================================
-- =========================================
-- ======= 1/ Source scan utilities ========
-- =========================================
-- =========================================

--- Lists all .lua files recursively under a directory (popen-based, no lfs dep).
--- @param dir string Absolute directory path.
--- @return table Array of absolute paths (forward slashes).
local function list_lua_files(dir)
	local files = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return files end
	for raw in pipe:lines() do
		local line = raw:gsub("\\", "/")
		if line:match("%.lua$") then files[#files + 1] = line end
	end
	pipe:close()
	return files
end

--- Reads a file fully, returning "" when unreadable.
--- @param path string Absolute file path.
--- @return string Contents.
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return "" end
	local body = fh:read("*a")
	fh:close()
	return body
end

--- Strips Lua comments (block `--[[ ]]` then line `-- …`) so doc examples that
--- mention the forbidden pattern are never counted as code. Lua patterns treat
--- `.` as matching newlines, so the lazy block-comment pattern spans lines.
--- @param src string Source text.
--- @return string Source with comments blanked.
local function strip_comments(src)
	src = src:gsub("%-%-%[%[.-%]%]", " ")
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = (line:gsub("%-%-.*$", ""))
	end
	return table.concat(out, "\n")
end




-- ==============================================
-- ==============================================
-- ======= 2/ Source-contract invariant =========
-- ==============================================
-- ==============================================

helpers.describe("meta: hs.fs.dir is always consumed by a generic-for (init-fsdir-drops-state)", function()
	local files = { ENTRY_POINT }
	for _, root in ipairs(SOURCE_ROOTS) do
		for _, f in ipairs(list_lua_files(root)) do files[#files + 1] = f end
	end

	local total_refs   = 0   -- every hs.fs.dir reference in code (sanity: must be > 0)
	local violations   = {}  -- files where a reference is NOT a direct generic-for

	for _, path in ipairs(files) do
		local code = strip_comments(read_file(path))
		-- Count code references vs. blessed `in hs.fs.dir(` shapes. Equal counts
		-- mean every reference is the iterator expression of a generic-for —
		-- which is the only shape that keeps hs.fs.dir's second return (the
		-- directory state object) alive.
		local refs = select(2, code:gsub("hs%.fs%.dir", ""))
		local blessed = select(2, code:gsub("[^%w_]in%s+hs%.fs%.dir%s*%(", ""))
		total_refs = total_refs + refs
		if refs ~= blessed then
			violations[#violations + 1] = string.format(
				"%s (%d hs.fs.dir reference(s), %d in a generic-for)", path, refs, blessed)
			print(string.format("  VIOLATION: %s", violations[#violations]))
		end
	end

	helpers.it(string.format("every hs.fs.dir reference flows into a generic-for (%d ref(s) across driver source)", total_refs), function()
		helpers.assert_true(total_refs > 0,
			"no hs.fs.dir references found — the source scan is broken (check SOURCE_ROOTS)")
		helpers.assert_true(#violations == 0,
			string.format("%d file(s) capture hs.fs.dir's iterator and drop its state object — "
				.. "use `for x in hs.fs.dir(d) do` (inside a pcall for throw-safety), never "
				.. "`local _, it = pcall(hs.fs.dir, d)`: %s",
				#violations, table.concat(violations, "; ")))
	end)
end)





-- =================================================
--- ==================================================
--- ======= 3/ init.lua throw-protection guard =======
--- ==================================================
-- =================================================

helpers.describe("lib/fs_dir: hs.fs.dir iteration is pcall-protected (init-fsdir-pcall)", function()
	helpers.it("fs_dir.entries wraps an hs.fs.dir loop in pcall so a bad directory cannot abort boot", function()
		-- The blessed wrapper (formerly the inline safe_dir_entries in init.lua) now
		-- lives in lib/fs_dir; init.lua and the hotstrings config window both alias it
		-- (`local safe_dir_entries = require("lib.fs_dir").entries`), so the protection
		-- is enforced in exactly one place. A pcall'd closure that contains the
		-- hs.fs.dir loop is the shape that both catches the throw AND preserves the
		-- state object. `.` spans newlines in Lua patterns, so this matches across lines.
		local code = strip_comments(read_file(DRIVER_ROOT .. "lib/fs_dir.lua"))
		helpers.assert_true(
			code:match("pcall%s*%(%s*function.-hs%.fs%.dir") ~= nil,
			"lib/fs_dir.entries must iterate hs.fs.dir inside a pcall'd closure so an "
				.. "inaccessible directory is logged, not fatal (init-fsdir-pcall)")
	end)
end)




-- ============================================
-- ============================================
-- ======= 4/ Stub-fidelity invariant =========
-- ============================================
-- ============================================

helpers.describe("meta: hs stub models hs.fs.dir's real (iterator, state) contract", function()
	local stub = require("tests.stubs.hs")

	helpers.it("hs.fs.dir returns TWO values (iterator + directory state object)", function()
		helpers.assert_true(select("#", stub.fs.dir("/whatever")) == 2,
			"the stub's hs.fs.dir must return (iterator, state) like real Hammerspoon — "
				.. "a single-value stub re-blinds the suite to dropped-state bugs")
	end)

	helpers.it("the iterator aborts when called without its state (dropped-state simulation)", function()
		local iter = stub.fs.dir("/whatever")
		local ok = pcall(iter)        -- state == nil, as a dropped-state loop would do
		helpers.assert_true(ok == false,
			"the stub iterator must error when its state object is missing, mirroring real "
				.. "Hammerspoon's 'directory metatable expected, got nil'")
	end)

	helpers.it("a correct generic-for over the stub yields the registered entries", function()
		stub.fs.__set_entries("/fake/dir", { "alpha.toml", "beta.toml" })
		local seen = {}
		for name in stub.fs.dir("/fake/dir") do seen[#seen + 1] = name end
		stub.fs.__reset_entries()
		helpers.assert_eq(seen, { "alpha.toml", "beta.toml" },
			"iterating hs.fs.dir directly (state preserved) must yield the populated entries")
	end)
end)

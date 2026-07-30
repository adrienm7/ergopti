--- tests/meta/test_lua_sources_compile.lua

--- ==============================================================================
--- MODULE: Lua Source Compile Meta-Test
--- DESCRIPTION:
--- Parse-checks every production Lua source of the Hammerspoon driver — most
--- importantly the entry point init.lua — so a syntax error can never again ship
--- undetected.
---
--- WHY THIS EXISTS (regression for the unclosed-`do` bug):
--- On 2026-06-18 commit 69c76e568 wrapped a directory scan in init.lua's File
--- Watchers section inside a new `if … then … end`; the diff reused the `do`
--- block's closing `end` to balance the new nesting and so DELETED the `end`
--- that closed the `do` opened at the top of the section. init.lua became
--- unparseable (`'end' expected (to close 'do' at line 818)`), the Hammerspoon
--- driver failed to boot, and CI stayed green for two days — because the runner
--- loads individual modules through hs stubs but NEVER loads init.lua (running it
--- needs the live Hammerspoon runtime). The top-level orchestration file had zero
--- compile coverage.
---
--- THE INVARIANT PINNED HERE:
--- Every .lua file under the driver's production roots (init.lua, lib/, modules/,
--- ui/, adapters/) and under the shared Lua tree (_shared/lua/) must PARSE.
--- `loadfile` compiles the chunk to a function without executing it, so this
--- check needs no hs runtime, no filesystem side effects, and no OS access — it
--- only proves the source is syntactically valid Lua. A missing or malformed
--- entry point makes `loadfile` return nil, failing the test loudly.
---
--- Test fixtures and scratch dirs are deliberately NOT scanned: they may contain
--- intentionally malformed Lua. Test files themselves are already parse-checked by
--- the runner, which `require`s each one (a syntax error there fails at load).
--- ==============================================================================

local helpers = require("tests.helpers")

-- driver_root() ends with a trailing slash (e.g. ".../macos/").
local DRIVER_ROOT = helpers.driver_root()

-- The entry point is THE file the original bug broke; it is asserted on its own
-- (below) so a regression names it explicitly instead of hiding in a bulk count.
local ENTRY_POINT = DRIVER_ROOT .. "init.lua"

-- Production source roots that must always parse. Fixtures (tests/fixtures),
-- scratch dirs (tests/scratch_test_dir) and stubs are excluded on purpose — see
-- the module header. The shared Lua tree is resolved through helpers.shared so
-- the _shared/ folder name stays defined in exactly one place (SHARED_REL).
local SOURCE_ROOTS = {
	DRIVER_ROOT .. "lib",
	DRIVER_ROOT .. "modules",
	DRIVER_ROOT .. "ui",
	DRIVER_ROOT .. "adapters",
	helpers.shared("lua"),
}





-- =========================================
-- =========================================
-- ======= 1/ Filesystem scan helper =======
-- =========================================
-- =========================================

--- Lists all .lua files recursively under a directory.
--- Mirrors the scan helper used by the other meta tests: shells out to the
--- platform directory walker so no LuaFileSystem dependency is required.
--- @param dir string Absolute directory path (forward slashes accepted).
--- @return table List of absolute paths (forward slashes).
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
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("\\", "/")
		if line:match("%.lua$") then
			files[#files + 1] = line
		end
	end
	pipe:close()
	return files
end





-- ============================================
-- ============================================
-- ======= 2/ Compile (parse) invariant =======
-- ============================================
-- ============================================

helpers.describe("meta: every Lua source compiles", function()
	-- The entry point gets its own assertion: it is the file the original bug
	-- broke and the one the runner can never exercise, so name it explicitly.
	helpers.it("the Hammerspoon entry point init.lua parses without syntax errors", function()
		local chunk, err = loadfile(ENTRY_POINT)
		helpers.assert_true(chunk ~= nil,
			string.format("init.lua must parse (loadfile failed): %s", tostring(err)))
	end)

	-- Bulk scan of every production source root. loadfile compiles to a function
	-- without running it, so a missing/malformed file is the only way to fail.
	local sources = {}
	for _, root in ipairs(SOURCE_ROOTS) do
		for _, path in ipairs(list_lua_files(root)) do
			sources[#sources + 1] = path
		end
	end

	local scanned  = 0
	local failures = {}
	for _, path in ipairs(sources) do
		scanned = scanned + 1
		local chunk, err = loadfile(path)
		if not chunk then
			failures[#failures + 1] = tostring(err)
			print(string.format("  SYNTAX ERROR: %s", tostring(err)))
		end
	end

	helpers.it(string.format("every production Lua source parses (%d files scanned)", scanned), function()
		-- Guard against a broken scanner passing vacuously: the driver always has
		-- dozens of source files, so zero means the directory walk failed.
		helpers.assert_true(scanned > 0,
			"no .lua source files found — the directory scan failed; check SOURCE_ROOTS")
		helpers.assert_true(#failures == 0,
			string.format("%d Lua source file(s) failed to parse — see SYNTAX ERROR lines above", #failures))
	end)
end)

--- static/ergopti_plus/linux/tests/unit/meta/test_parse_coverage.lua

--- ==============================================================================
--- MODULE: Linux Parse Coverage
--- DESCRIPTION:
--- Compiles every production Lua file of the Linux driver — the entry point
--- included — and fails on the first one the interpreter refuses to parse.
---
--- ROOT CAUSE ENCODED:
--- The driver's entry point, ergopti_hotstrings.lua, had ZERO parse coverage.
--- Nothing in the suite required it (it starts a daemon), nothing compiled it,
--- and the JS gates only ever read it as text. A syntax error there — the one
--- file whose failure means the driver does not start at all — would have
--- shipped with a fully green suite and been discovered by a user. The same held
--- for every module the suite does not happen to require.
---
--- FEATURES & RATIONALE:
--- 1. loadfile COMPILES without executing. That distinction is the whole design:
---    requiring the entry point would spawn the daemon, and a probe that runs the
---    thing it is checking is not a test, it is a launch.
--- 2. The file list is discovered from disk, so a new module is covered the day
---    it lands rather than the day someone remembers to add it here.
--- 3. A floor assertion on the number of files scanned. Without it a broken walk
---    reports "0 files, 0 failures" and reads exactly like success.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ Constants =====================
-- ==========================================
-- ==========================================

--- Trees excluded from the scan, and why.
--- - tests/   the suite compiles itself by running.
--- - vendor/  third-party source, kept verbatim; not ours to fix.
local EXCLUDED = { "/tests/", "/vendor/" }

--- Test trees the runner never loads, so the "compiles itself by running"
--- exemption above does not apply to them. tests/hardware/ runs only in the CI
--- job that needs a real kernel, which means a syntax error there is invisible
--- to every developer and to every other job — the exact shape of failure this
--- gate exists to remove.
local UNLOADED_TEST_TREES = { "/tests/hardware/" }

--- Lower bound on the production file count. Measured at 72 when this landed;
--- set below that so ordinary growth or a small refactor does not trip it, but
--- far enough above zero that a walk returning nothing fails loudly.
local MIN_FILES = 60




-- ==========================================
-- ==========================================
-- ======= 2/ Discovery =====================
-- ==========================================
-- ==========================================

--- Lists every .lua file under the driver root, minus the excluded trees.
---
--- Uses lfs when available and falls back to the platform's directory lister,
--- exactly like the suite runner: CI runs LuaJIT on Linux, the maintainer runs
--- plain Lua on Windows, and a gate that only works on one of them is a gate
--- that silently stops running on the other.
--- @return table List of absolute paths.
local function production_files()
	local root = helpers.driver_root()
	local files = {}

	local function keep(path)
		local normalised = path:gsub("\\", "/")
		if not normalised:match("%.lua$") then return end
		for _, kept in ipairs(UNLOADED_TEST_TREES) do
			if normalised:find(kept, 1, true) then
				files[#files + 1] = normalised
				return
			end
		end
		for _, skip in ipairs(EXCLUDED) do
			if normalised:find(skip, 1, true) then return end
		end
		files[#files + 1] = normalised
	end

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(dir) do
				if entry ~= "." and entry ~= ".." then
					local full = dir .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full)
					elseif attr then
						keep(full)
					end
				end
			end
		end
		walk(root)
		return files
	end

	local is_windows = package.config:sub(1, 1) == "\\"
	local command = is_windows
		and ('dir /b /s "' .. root:gsub("/", "\\") .. '\\*.lua"')
		or ('find "' .. root .. '" -type f -name "*.lua"')
	local pipe = io.popen(command, "r")
	if not pipe then return files end
	for line in pipe:lines() do keep(line) end
	pipe:close()
	return files
end




-- ==========================================
-- ==========================================
-- ======= 3/ Assertions ====================
-- ==========================================
-- ==========================================

helpers.describe("linux: every production Lua file compiles", function()
	local files = production_files()

	helpers.it("the scan actually reaches the driver source", function()
		helpers.assert_true(#files >= MIN_FILES,
			string.format("expected at least %d production .lua file(s), found %d — a walk that finds nothing reports zero parse errors and reads as a pass",
				MIN_FILES, #files))
	end)

	helpers.it("the hardware harness is part of the scan", function()
		-- It is the one Lua file in this driver that no developer and no other CI
		-- job ever loads: it needs a real /dev/uinput. Without this, a typo in it
		-- surfaces as a red job on a branch nobody expected to touch the kernel.
		local found = false
		for _, path in ipairs(files) do
			if path:find("/tests/hardware/", 1, true) then found = true break end
		end
		helpers.assert_true(found,
			"tests/hardware/ must be compiled by this gate — the suite runner does not "
				.. "discover it, so nothing else ever parses it")
	end)

	helpers.it("the entry point is part of the scan", function()
		local found = false
		for _, path in ipairs(files) do
			if path:match("/ergopti_hotstrings%.lua$") then found = true break end
		end
		helpers.assert_true(found,
			"ergopti_hotstrings.lua must be in the scan — it is the file whose syntax error means the daemon does not start at all, and it is the one nothing else compiles")
	end)

	helpers.it("no production file has a syntax error", function()
		local broken = {}
		for _, path in ipairs(files) do
			local chunk, err = loadfile(path)
			if not chunk then broken[#broken + 1] = tostring(err) end
		end
		helpers.assert_eq(#broken, 0,
			"production Lua file(s) failed to compile:\n  " .. table.concat(broken, "\n  "))
	end)
end)

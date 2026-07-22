--- tests/meta/test_shell_runner_stub_restore.lua

--- ==============================================================================
--- MODULE: Regression — every shell_runner stub install must be restored
--- DESCRIPTION:
--- Scans every test file for `package.loaded["adapters.shell_runner"] = {...}`
--- installs and requires a later restore (`= nil` or `= <saved real module>`)
--- in the same file.
---
--- ROOT CAUSE ENCODED:
--- The karabiner layout-poll tests installed exec-less shell_runner stubs and
--- never restored them. Whichever test file the runner loaded next captured
--- the stub at require time — on the CI runner's file order that was
--- modules.gestures.conflicts, whose ShellRunner.exec() call then crashed
--- with "attempt to call a nil value (field 'exec')". The leak was invisible
--- locally because NTFS yields a different discovery order than APFS, so the
--- suite was green on Windows and red on macOS for the same commit.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Assignment head that installs or restores the shared shell_runner slot.
local ASSIGN_PATTERN = 'package%.loaded%[%"adapters%.shell_runner%"%]%s*=%s*'

--- Directories whose test files are scanned, relative to the driver root.
local SCAN_DIRS = { "tests/unit", "tests/meta", "tests/integration" }




-- ========================================
-- ========================================
-- ======= 1/ Portable File Walker ========
-- ========================================
-- ========================================

--- Recursively collects test file paths under a directory (lfs or shell).
--- Mirrors tests/run.lua's discovery so the scan can never miss a file the
--- runner would load.
--- @param abs string Absolute directory path.
--- @param results table Accumulator of absolute file paths.
local function collect_test_files(abs, results)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full)
					elseif entry:match("^test_.+%.lua$") then
						results[#results + 1] = full
					end
				end
			end
		end
		walk(abs)
		return
	end

	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name 'test_*.lua'", abs)
	end
	local pipe = io.popen(cmd)
	if not pipe then return end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("\\", "/")
		if line:match("test_[^/]+%.lua$") then
			results[#results + 1] = line
		end
	end
	pipe:close()
end





-- ==========================================
-- ==========================================
-- ======= 2/ Install/Restore Scanner =======
-- ==========================================
-- ==========================================

--- Finds the last stub INSTALL and whether a restore follows it.
--- An install assigns a table literal; a restore assigns nil or a saved
--- reference to the real module.
--- @param content string Full source of a test file.
--- @return boolean|nil True when a dangling install remains (nil = no install).
local function has_dangling_install(content)
	local last_install = nil
	local search_from = 1
	while true do
		local _, tail = content:find(ASSIGN_PATTERN, search_from)
		if not tail then break end
		local next_char = content:sub(tail + 1, tail + 1)
		if next_char == "{" then
			last_install = tail
		elseif last_install and tail > last_install then
			-- nil or a saved-real-module identifier after the last install
			last_install = nil
		end
		search_from = tail + 1
	end
	return last_install ~= nil
end




-- ============================
-- ============================
-- ======= 3/ The Gate ========
-- ============================
-- ============================

helpers.describe("shell_runner stub hygiene across the whole suite", function()
	helpers.it("every test file restores adapters.shell_runner after its last stub install", function()
		local files = {}
		for _, dir in ipairs(SCAN_DIRS) do
			collect_test_files(helpers.driver_root() .. "/" .. dir, files)
		end
		helpers.assert_true(#files > 50, "the walker must discover the test suite (got " .. #files .. " files)")

		local offenders = {}
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			if fh then
				local content = fh:read("*a")
				fh:close()
				if has_dangling_install(content) then
					offenders[#offenders + 1] = path:match("tests/.+$") or path
				end
			end
		end

		helpers.assert_eq(table.concat(offenders, ", "), "",
			"these test files install a package.loaded[\"adapters.shell_runner\"] stub and never "
			.. "restore it — the next test file the runner loads captures the stub at require "
			.. "time and crashes order-dependently (green locally, red in CI)")
	end)

	helpers.it("the scanner itself recognises a dangling install", function()
		local dangling = 'package.loaded["adapters.shell_runner"] = { spawn = function() end }'
		local restored = dangling .. '\npackage.loaded["adapters.shell_runner"] = nil'
		helpers.assert_true(has_dangling_install(dangling) == true,
			"an install with no later restore must be flagged")
		helpers.assert_true(has_dangling_install(restored) == false,
			"an install followed by a restore must pass")
	end)
end)

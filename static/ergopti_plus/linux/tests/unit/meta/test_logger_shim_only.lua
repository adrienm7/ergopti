--- static/ergopti_plus/linux/tests/unit/meta/test_logger_shim_only.lua

--- ==============================================================================
--- MODULE: Logger-Shim-Only Invariant Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the P0 bug where 9 of the 20 Linux port adapters did
--- `require("lib.logger")` — a module this driver does not have. Every such
--- require raised "module 'lib.logger' not found" the moment the adapter loaded,
--- silently crashing whichever feature pulled it in. The canonical entry point is
--- `require("logger.shim")`, used by the other 11 adapters.
---
--- Two facts this docstring previously got wrong, corrected here because a stale
--- rationale is how the sink bug survived:
--- 1. `linux/lib/` DOES exist (file_watchers, i18n, locale, logger_sink,
---    monotonic, timings, version). The forbidden module is `lib.logger`
---    specifically, not the whole namespace.
--- 2. `logger.shim` is NOT the print-fallback in production. Because _shared/lua
---    is on package.path, its `pcall(require, "logger")` succeeds and it returns
---    the shared CORE, whose print fallback is never reached. The core writes only
---    to an injected sink — which is why `lib/logger_sink.lua` exists and is
---    installed by the entry point. See tests/unit/meta/test_logger_sink.lua.
---
--- FEATURES & RATIONALE:
--- 1. Root-cause encoding: the test fails if ANY production Lua file under
---    adapters/ or modules/ requires "lib.logger", so the exact regression can
---    never silently return (project rule 5.9).
--- 2. Production scope only: tests/ and vendor/ are excluded so the scan can
---    name the forbidden require pattern without matching its own source.
--- 3. No external deps: directory listing shells out via io.popen exactly like
---    the test runner, so the guard runs under plain Lua 5.4 and LuaJIT alike.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()

-- Production directories to scan — deliberately excludes tests/ (this file
-- mentions the forbidden pattern in prose) and vendor/ (third-party code).
local SCAN_DIRS = { "adapters", "modules" }

-- The forbidden require, in both quote styles AHK/Lua authors might type.
local FORBIDDEN_PATTERNS = {
	'require%("lib%.logger"%)',
	"require%('lib%.logger'%)",
}


-- ===============================================
-- ===============================================
-- ======= 1/ Cross-Platform File Listing ========
-- ===============================================
-- ===============================================

--- Lists every .lua file under a directory, recursively.
--- Mirrors the runner's lfs-or-popen strategy so it needs no external library.
--- @param abs string Absolute directory path.
--- @return table Array of absolute .lua file paths.
local function list_lua_files(abs)
	local results = {}

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full)
					elseif entry:match("%.lua$") then
						results[#results + 1] = full
					end
				end
			end
		end
		walk(abs)
		return results
	end

	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", abs)
	end
	local pipe = io.popen(cmd)
	if not pipe then return results end
	for line in pipe:lines() do
		line = line:gsub("\\", "/")
		if line:match("%.lua$") then results[#results + 1] = line end
	end
	pipe:close()
	return results
end

--- Reads a whole file into a string, or returns nil on failure.
--- @param path string Absolute file path.
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end





-- ==================================================
-- ==================================================
-- ======= 2/ Logger-Shim-Only Invariant Test =======
-- ==================================================
-- ==================================================

helpers.describe("linux: production code uses logger.shim only", function()
	local offenders = {}

	for _, dir in ipairs(SCAN_DIRS) do
		for _, path in ipairs(list_lua_files(DRIVER_ROOT .. "/" .. dir)) do
			local content = read_file(path)
			if content then
				for _, pat in ipairs(FORBIDDEN_PATTERNS) do
					if content:find(pat) then
						offenders[#offenders + 1] = path
						print(string.format("  WARN: forbidden require(\"lib.logger\") in %s", path))
						break
					end
				end
			end
		end
	end

	helpers.it(
		"no adapter or module requires the non-existent lib.logger module",
		function()
			helpers.assert_true(
				#offenders == 0,
				string.format(
					"%d file(s) require lib.logger instead of logger.shim: %s",
					#offenders,
					table.concat(offenders, ", ")
				)
			)
		end
	)
end)

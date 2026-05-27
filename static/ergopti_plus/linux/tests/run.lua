--- static/ergopti_plus/linux/tests/run.lua

--- ==============================================================================
--- MODULE: Test Runner Entry Point (Linux driver)
--- DESCRIPTION:
--- Discovers and executes every Lua test file under tests/unit/ and tests/meta/.
--- Sets package.path so requires resolve against both the driver source root and
--- the shared Lua libraries, then walks the test directories recursively,
--- requiring each test_*.lua file once.
---
--- USAGE:
---     luajit tests/run.lua          # Run from the linux driver root
---     lua    tests/run.lua          # Works with plain Lua 5.4 as well
---
--- The runner exits non-zero when at least one assertion fails so it can be
--- wired into CI without further glue.
--- ==============================================================================

-- Resolve our own directory so the runner works no matter the cwd.
local self_path  = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = self_path:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
driver_root = driver_root:gsub("\\", "/")

-- When launched as "luajit tests/run.lua" from the linux root, self_path may
-- be a relative path and driver_root resolves to ".". Canonicalise it to an
-- absolute path so downstream path arithmetic is reliable.
if driver_root == "." then
	local sep      = package.config:sub(1, 1)
	local cwd_cmd  = (sep == "\\") and "cd" or "pwd"
	local cwd_pipe = io.popen(cwd_cmd)
	if cwd_pipe then
		local cwd = cwd_pipe:read("*l") or "."
		cwd_pipe:close()
		driver_root = cwd:gsub("\\", "/"):gsub("/$", "")
	end
end

-- The shared/ Lua libraries live one level above the linux driver root
-- (i.e. in static/ergopti_plus/shared/lua/).
local drivers_root = driver_root:match("^(.*)/[^/]+$") or driver_root
local shared_lua   = drivers_root .. "/shared/lua"

-- Build the package search path: driver root first, then shared libs, then tests/.
package.path = table.concat({
	driver_root .. "/?.lua",
	driver_root .. "/?/init.lua",
	shared_lua  .. "/?.lua",
	shared_lua  .. "/?/init.lua",
	driver_root .. "/tests/?.lua",
	driver_root .. "/tests/?/init.lua",
	package.path,
}, ";")

local helpers = require("tests.helpers")


-- ===================================
-- ===================================
-- ======= 1/ Test Discovery =========
-- ===================================
-- ===================================

local TEST_DIRS = {
	"tests/meta",
	"tests/unit",
}

--- Recursively collects test files under a directory.
--- Uses lfs if available, otherwise shells out to dir/ls.
--- @param dir string Directory relative to the driver root.
--- @return table List of dotted module names ready for require.
local function discover_tests(dir)
	local results = {}
	local abs     = driver_root .. "/" .. dir

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path, mod_prefix)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then
						walk(full, mod_prefix .. "." .. entry)
					elseif entry:match("^test_.+%.lua$") then
						local name = entry:gsub("%.lua$", "")
						results[#results + 1] = mod_prefix .. "." .. name
					end
				end
			end
		end
		walk(abs, dir:gsub("/", "."))
		return results
	end

	-- Fallback: shell out using io.popen.
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name 'test_*.lua'", abs)
	end
	local pipe = io.popen(cmd)
	if not pipe then return results end

	local strip_prefix = driver_root
	for line in pipe:lines() do
		line = line:gsub("\\", "/")
		local rel
		if strip_prefix ~= "" and line:sub(1, #strip_prefix):lower() == strip_prefix:lower() then
			rel = line:sub(#strip_prefix + 2):gsub("%.lua$", "")
		else
			rel = line:match("([^/]+/test_[^/]+)%.lua$")
		end
		if rel and rel:match("/test_[^/]+$") then
			results[#results + 1] = rel:gsub("/", ".")
		end
	end
	pipe:close()
	return results
end


-- =================================
-- =================================
-- ======= 2/ Test Execution =======
-- =================================
-- =================================

helpers.reset_results()

local total_modules = 0
for _, dir in ipairs(TEST_DIRS) do
	for _, mod_name in ipairs(discover_tests(dir)) do
		total_modules = total_modules + 1
		print(string.format("\n>>> Loading %s", mod_name))
		local ok, err = pcall(require, mod_name)
		if not ok then
			print(string.format("  ! load error: %s", tostring(err)))
			helpers.get_results().failed = helpers.get_results().failed + 1
		end
	end
end

local r = helpers.get_results()
print(string.format(
	"\n========================================\nTotal: %d module(s) loaded — %d passed, %d failed\n========================================",
	total_modules, r.passed, r.failed
))

if r.failed > 0 then
	for _, f in ipairs(r.failures) do
		print(string.format("  - %s : %s", f.name, f.err))
	end
	os.exit(1)
end
os.exit(0)

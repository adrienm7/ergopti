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

-- The _shared/ Lua libraries live one level above the linux driver root
-- (i.e. in static/ergopti_plus/_shared/lua/).
local drivers_root = driver_root:match("^(.*)/[^/]+$") or driver_root
local shared_lua   = drivers_root .. "/_shared/lua"

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

-- Install the pure-Lua UTF-8 compatibility shim BEFORE any test module is
-- loaded. LuaJIT 2.x does not bundle Lua 5.3's built-in utf8 library, and
-- several shared modules (keylogger/utils.lua, toml_codec, terminators) use
-- utf8.len / utf8.offset / utf8.codes as globals. Without this early install,
-- require("keylogger.utils") crashes with "attempt to index global 'utf8' (a
-- nil value)" and every dependent test (pop_utf8, compat.utf8, device_finder)
-- fails before the daemon_smoke test even reaches its compat.utf8 check.
local ok_utf8, compat_utf8 = pcall(require, "compat.utf8")
if ok_utf8 and compat_utf8 and compat_utf8.install then compat_utf8.install() end

local helpers = require("tests.helpers")
local RunnerContract = require("tests.runner_contract")
local TEST_MANIFEST = require("tests.test_manifest")

-- --only <substr> / --only=<substr>: run only test cases whose name contains the
-- substring, so a single behaviour can be re-run in isolation.
local only_filter = nil
if arg then
	for i = 1, #arg do
		if arg[i] == "--only" then
			if type(arg[i + 1]) ~= "string" or arg[i + 1] == "" then
				io.stderr:write("tests/run.lua: --only requires a nonempty substring\n")
				os.exit(2)
			end
			only_filter = arg[i + 1]
		elseif type(arg[i]) == "string" and arg[i]:match("^%-%-only=") then
			only_filter = arg[i]:gsub("^%-%-only=", "")
			if only_filter == "" then
				io.stderr:write("tests/run.lua: --only requires a nonempty substring\n")
				os.exit(2)
			end
		end
	end
end
if only_filter and only_filter ~= "" then
	helpers.set_only_filter(only_filter)
	print(string.format("Filtering to test cases matching: %q", only_filter))
end


-- ===================================
-- ===================================
-- ======= 1/ Test Discovery =========
-- ===================================
-- ===================================

local TEST_DIRS = {
	"tests/unit",
}

--- Recursively collects test files under a directory.
--- Uses lfs if available, otherwise shells out to dir/ls.
--- @param dir string Directory relative to the driver root.
--- @return table|nil List of dotted module names ready for require.
--- @return string|nil Discovery error.
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
		local ok_walk, walk_error = pcall(walk, abs, dir:gsub("/", "."))
		if not ok_walk then return nil, tostring(walk_error) end
		return results, nil
	end

	-- Fallback: shell out using io.popen.
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name 'test_*.lua'", abs)
	end
	local pipe, open_error = io.popen(cmd)
	if not pipe then return nil, tostring(open_error or "could not start discovery command") end

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
	local close_ok, close_reason, close_code = pipe:close()
	if close_ok ~= true then
		return nil, string.format("discovery command failed (%s %s)",
			tostring(close_reason), tostring(close_code))
	end
	return results, nil
end





-- =================================
-- =================================
-- ======= 2/ Test Execution =======
-- =================================
-- =================================

helpers.reset_results()

local discovered_modules = {}
for _, dir in ipairs(TEST_DIRS) do
	local modules, discovery_error = discover_tests(dir)
	if not modules then
		io.stderr:write(string.format("tests/run.lua: discovery failed for %s: %s\n",
			dir, tostring(discovery_error)))
		os.exit(1)
	end
	for _, module_name in ipairs(modules) do discovered_modules[#discovered_modules + 1] = module_name end
end

table.sort(discovered_modules)
local manifest_ok, manifest_error = RunnerContract.audit_manifest(
	discovered_modules,
	TEST_MANIFEST
)
if not manifest_ok then
	io.stderr:write("tests/run.lua: " .. tostring(manifest_error) .. "\n")
	os.exit(1)
end

local total_modules, load_errors = RunnerContract.load_modules(TEST_MANIFEST, function(mod_name)
	print(string.format("\n>>> Loading %s", mod_name))
	require(mod_name)
end)
for _, failure in ipairs(load_errors) do
	print(string.format("  ! load error in %s: %s", failure.module, failure.error))
	helpers.get_results().failed = helpers.get_results().failed + 1
end

local r = helpers.get_results()
local execution_ok, execution_error = RunnerContract.audit_execution(
	total_modules,
	r.passed,
	r.failed,
	only_filter
)
print(string.format(
	"\n========================================\nOVERALL RESULTS:\nTotal modules: %d\nPassed tests:  %d\nFailed tests:  %d\n========================================",
	total_modules, r.passed, r.failed
))

if not execution_ok then
	io.stderr:write("tests/run.lua: " .. tostring(execution_error) .. "\n")
	os.exit(1)
end

if r.failed > 0 then
	for _, f in ipairs(r.failures) do
		print(string.format("  - %s : %s\n    replay: luajit tests/run.lua --only %q", f.name, f.err, f.name))
	end
	os.exit(1)
end
os.exit(0)

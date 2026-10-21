--- tests/run.lua

--- ==============================================================================
--- MODULE: Test Runner Entry Point
--- DESCRIPTION:
--- Discovers and executes every Lua test file under tests/unit/ and tests/meta/.
--- Sets `package.path` so requires resolve against both the driver source and
--- the bundled stubs, then walks the test directories recursively, requiring
--- each `test_*.lua` file once.
---
--- USAGE:
---     lua tests/run.lua                  # Run from the hammerspoon driver root
---     lua tests/run.lua --module=meta    # One CI shard (tests/support/module_groups.lua)
---
--- The runner exits non-zero when at least one assertion fails so it can be
--- wired into CI without further glue.
--- ==============================================================================

-- Resolve our own directory so the runner works no matter the cwd.
local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = self_path:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
driver_root = driver_root:gsub("\\", "/")

-- When self_path is relative, driver_root may be "." or a relative path like
-- "static/ergopti_plus/macos". In both cases we must canonicalise to an
-- absolute path so that path arithmetic (strip_prefix matching) is reliable.
local is_absolute = driver_root:match("^[A-Za-z]:") or driver_root:match("^/")
if not is_absolute then
	-- On Windows "cd" (no args) prints the current directory.
	-- On POSIX "cd" prints nothing — use "pwd" instead.
	local sep = package.config:sub(1, 1)
	local cwd_cmd = (sep == "\\") and "cd" or "pwd"
	local cwd_handle = io.popen(cwd_cmd)
	if cwd_handle then
		local cwd = cwd_handle:read("*l") or "."
		cwd_handle:close()
		cwd = cwd:gsub("\\", "/"):gsub("/$", "")
		if driver_root == "." then
			driver_root = cwd
		else
			driver_root = cwd .. "/" .. driver_root
		end
	end
end

-- The _shared/ Lua libraries live one level above the HS driver root
-- (i.e. in static/ergopti_plus/_shared/lua/). The shims in infra/ need this
-- entry to resolve lib.toml.codec, lib.toml.reader, and lib.toml.writer modules.
local drivers_root  = driver_root:match("^(.*)/[^/]+$") or driver_root
local shared_lua    = drivers_root .. "/_shared/lua"

-- Search the driver root first (so `require("infra.x")` resolves), then the
-- shared Lua libraries, then tests/ and stubs/. Order matters: hs.lua stub
-- must win over any real hs module that might appear in the path.
package.path = table.concat({
	driver_root .. "/?.lua",
	driver_root .. "/?/init.lua",
	shared_lua  .. "/?.lua",
	shared_lua  .. "/?/init.lua",
	driver_root .. "/tests/?.lua",
	driver_root .. "/tests/?/init.lua",
	driver_root .. "/tests/unit/?.lua",
	driver_root .. "/tests/unit/?/init.lua",
	driver_root .. "/tests/stubs/?.lua",
	package.path,
}, ";")

local helpers = require("tests.helpers")
local shell_quote = require("text_utils").shell_quote
helpers.initialize_timing()
local ModuleIsolation = require("tests.support.module_isolation")
local OnlySelector = require("tests.support.only_selector")
local ModuleGroups = require("tests.support.module_groups")
local CommandLines = require("tests.support.command_lines")

-- --only accepts an exact test module path/name or a historical case-name
-- substring, so one file or behaviour can be re-run from a red message
-- arg is the global Lua args table.
-- --module selects one domain group so CI can shard the suite.
local only_filter = nil
local module_group = nil
if arg then
	local index = 1
	while index <= #arg do
		local option, value = arg[index]:match("^(%-%-[%w%-]+)=(.*)$")
		local separated = option == nil
		option = option or arg[index]
		if option ~= "--only" and option ~= "--module" then
			io.stderr:write("tests/run.lua: unknown argument " .. tostring(arg[index]) .. "\n")
			os.exit(2)
		end
		if separated then value = arg[index + 1] end
		if type(value) ~= "string" or value == "" or (separated and value:sub(1, 2) == "--") then
			io.stderr:write("tests/run.lua: " .. option .. " requires a nonempty value\n")
			os.exit(2)
		end
		if option == "--only" then only_filter = value else module_group = value end
		index = index + (separated and 2 or 1)
	end
end

-- Inject the hs stub as a global before any test loads source modules
_G.hs = require("tests.stubs.hs")




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
--- Uses `lfs` if available, otherwise shells out to `dir`/`ls`.
--- @param dir string Directory relative to the driver root.
--- @return table List of dotted module names ready for require.
local function discover_tests(dir)
	local results = {}
	local abs = driver_root .. "/" .. dir

	-- Prefer LuaFileSystem when available
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

	-- Fallback: shell out using io.popen
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', abs:gsub("/", "\\"))
	else
		cmd = string.format("find %s -type f -name 'test_*.lua'", shell_quote(abs))
	end
	-- Build an absolute, normalized prefix to strip from each result line
	local strip_prefix
	if driver_root == "." then
		-- dir /b /s prints absolute paths; resolve cwd to strip it
		local cwd_pipe = io.popen(package.config:sub(1, 1) == "\\" and "cd" or "pwd")
		if cwd_pipe then
			strip_prefix = (cwd_pipe:read("*l") or ""):gsub("\\", "/")
			cwd_pipe:close()
		else
			strip_prefix = ""
		end
	else
		strip_prefix = driver_root
	end
	for _, raw_line in ipairs(CommandLines.read(cmd)) do
		local line = raw_line:gsub("\\", "/")
		-- Match suffix that starts after the driver root and ends in .lua
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
	return results
end

--- Reads one discovered test module without executing its top-level code.
--- @param module_name string Dotted module name below the driver root.
--- @return string|nil source UTF-8/Lua source, or nil when unreadable.
local function read_test_module_source(module_name)
	local relative_path = module_name:gsub("%.", "/") .. ".lua"
	local handle = io.open(driver_root .. "/" .. relative_path, "rb")
	if not handle then return nil end
	local source = handle:read("*a")
	handle:close()
	return source
end





-- =================================
-- =================================
-- ======= 2/ Test Execution =======
-- =================================
-- =================================

helpers.reset_results()

local discovered_modules = {}
for _, dir in ipairs(TEST_DIRS) do
	local modules = discover_tests(dir)
	assert(#modules > 0, "no test modules discovered in " .. dir)
	for _, mod_name in ipairs(modules) do
		discovered_modules[#discovered_modules + 1] = mod_name
	end
end
if module_group then
	local total = #discovered_modules
	discovered_modules = ModuleGroups.select(discovered_modules, module_group)
	assert(#discovered_modules > 0,
		string.format("no test modules discovered for group %q", module_group))
	print(string.format("Module group %q: %d of %d module(s)", module_group, #discovered_modules, total))
end
local modules_to_load, narrowed, case_filter = OnlySelector.select_modules(
	discovered_modules,
	only_filter,
	read_test_module_source
)
helpers.set_only_filter(case_filter)
if only_filter and only_filter ~= "" then
	if case_filter then
		print(string.format("Filtering to test cases matching: %q", case_filter))
	else
		print(string.format("Selecting exact test module: %q", only_filter))
	end
	print(string.format(
		"Focused discovery: %d of %d module(s)%s",
		#modules_to_load,
		#discovered_modules,
		narrowed and " selected before require" or " loaded by safe fallback"
	))
end

local total_modules = 0
for _, mod_name in ipairs(modules_to_load) do
	total_modules = total_modules + 1
	ModuleIsolation.purge(driver_root, shared_lua)
	print(string.format("\n>>> Loading %s", mod_name))
	local ok, err = helpers.measure_module(mod_name, function() return require(mod_name) end)
	if not ok then
		print(string.format("  ! LOAD FAILURE in %s: %s", mod_name, tostring(err)))
		helpers.get_results().failed = helpers.get_results().failed + 1
		local failures = helpers.get_results().failures
		failures[#failures + 1] = {
			name = mod_name, err = tostring(err), kind = "module", module = mod_name,
		}
	end
end

local r = helpers.get_results()
OnlySelector.require_match(r, case_filter)
print(string.format(
	"\n========================================\nOVERALL RESULTS:\nTotal modules: %d\nPassed tests:  %d\nFailed tests:  %d\n========================================",
	total_modules, r.passed, r.failed
))

if r.failed > 0 then
	print("\n--- DETAILED FAILURES ---")
	for i, f in ipairs(r.failures) do
		if f.kind ~= "case" then print("  FAIL " .. f.name .. " — " .. f.err) end
		print(string.format(
				"[%d] %s\n    Error: %s\n    replay: lua tests/run.lua --only %s\n",
				i, f.name, f.err, shell_quote(f.kind == "case" and f.name or f.module or f.name)
			))
	end
	os.exit(1)
end
if helpers.timing_failed() then
	io.stderr:write("tests/run.lua: Lua wall timing diagnostics failed\n")
	os.exit(1)
end
print("\n[OK] All Lua unit tests passed.")
os.exit(0)

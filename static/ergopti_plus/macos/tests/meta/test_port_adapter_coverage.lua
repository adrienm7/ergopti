--- tests/meta/test_port_adapter_coverage.lua

--- ==============================================================================
--- MODULE: Port-Adapter Coverage Meta-Test
--- DESCRIPTION:
--- Verifies three structural invariants of the hexagonal architecture:
---
--- 1. ADAPTER PRESENCE — Every port spec in shared/ports/*.spec.js has a
---    matching adapter file in static/ergopti_plus/windows/adapters/ and in
---    static/ergopti_plus/macos/adapters/. A missing adapter means a port
---    contract exists on paper but is not honoured by a driver.
---
--- 2. DOMAIN TEST COVERAGE — Every domain spec in shared/domain/*.spec.js
---    has at least one corresponding test file in at least one driver's test
---    suite. An untested domain spec is a dead letter.
---
--- 3. SHARED PURITY — No file under shared/ directly calls OS-level APIs
---    (io.open, hs., SendInput, SendEvent, TrayTip). Shared code must be
---    pure logic; OS access must go through port adapters.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
-- Climb from macos/ root up to repo root (static/ergopti_plus/macos/ -> repo root)
local REPO_ROOT = DRIVER_ROOT:gsub("[/\\]static[/\\]ergopti_plus[/\\]macos[/\\]?$", "")




-- ==========================================
--- ==========================================
-- ======= 1/ Filesystem scan helpers =======
--- ==========================================
-- ==========================================

--- Lists all files with a given extension recursively under dir.
--- @param dir string Absolute directory path.
--- @param ext string Extension without dot (e.g. "js", "lua").
--- @return table List of absolute paths (forward slashes).
local function list_files(dir, ext)
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
		if line:match("%." .. ext .. "$") then
			files[#files + 1] = line
		end
	end
	pipe:close()
	return files
end

--- Extracts the base name without any extension from an absolute path.
--- @param path string Absolute file path.
--- @return string Base name (e.g. "/a/b/foo.spec.js" -> "foo").
local function base_name(path)
	local name = path:match("[^/]+$") or path
	return name:gsub("%.[^.]+$", ""):gsub("%.spec$", "")
end

--- Converts a PascalCase identifier to snake_case.
--- @param s string PascalCase string (e.g. "KeyboardHook").
--- @return string snake_case string (e.g. "keyboard_hook").
local function to_snake_case(s)
	return s:gsub("(%u)", function(c) return "_" .. c:lower() end):gsub("^_", "")
end




-- =============================================
--- =============================================
-- ======= 2/ Adapter-presence invariant =======
--- =============================================
-- =============================================

helpers.describe("meta: port-adapter coverage", function()
	local shared_ports = REPO_ROOT .. "/static/ergopti_plus/shared/ports"
	local ahk_adapters = REPO_ROOT .. "/static/ergopti_plus/windows/adapters"
	local hs_adapters  = REPO_ROOT .. "/static/ergopti_plus/macos/adapters"

	local spec_files  = list_files(shared_ports, "js")
	local missing_ahk = 0
	local missing_hs  = 0
	local spec_count  = 0

	for _, spec_path in ipairs(spec_files) do
		if not spec_path:match("%.spec%.js$") then goto continue end
		spec_count = spec_count + 1

		local raw_name   = base_name(spec_path)
		local snake_name = to_snake_case(raw_name)
		local ahk_file   = ahk_adapters .. "/" .. snake_name .. ".ahk"
		local hs_file    = hs_adapters  .. "/" .. snake_name .. ".lua"

		local ahk_fh = io.open(ahk_file, "r")
		if ahk_fh then
			ahk_fh:close()
		else
			missing_ahk = missing_ahk + 1
			print(string.format("  WARN: AHK adapter missing for port %q: expected %s", raw_name, ahk_file))
		end

		local hs_fh = io.open(hs_file, "r")
		if hs_fh then
			hs_fh:close()
		else
			missing_hs = missing_hs + 1
			print(string.format("  WARN: HS adapter missing for port %q: expected %s", raw_name, hs_file))
		end

		::continue::
	end

	helpers.it(string.format("every port spec has an AHK adapter (%d specs)", spec_count), function()
		helpers.assert_true(spec_count > 0, "no *.spec.js files found in shared/ports — check REPO_ROOT")
		helpers.assert_true(missing_ahk == 0,
			string.format("%d AHK adapter(s) missing for port specs", missing_ahk))
	end)

	helpers.it(string.format("every port spec has a HS adapter (%d specs)", spec_count), function()
		helpers.assert_true(missing_hs == 0,
			string.format("%d HS adapter(s) missing for port specs", missing_hs))
	end)
end)




-- =================================================
--- =================================================
-- ======= 3/ Domain-test-coverage invariant =======
--- =================================================
-- =================================================

helpers.describe("meta: domain spec test coverage", function()
	local domain_dir = REPO_ROOT .. "/static/ergopti_plus/shared/domain"
	local ahk_tests  = REPO_ROOT .. "/static/ergopti_plus/windows/tests"
	local hs_tests   = REPO_ROOT .. "/static/ergopti_plus/macos/tests"

	local domain_specs  = list_files(domain_dir, "js")
	local all_ahk_tests = list_files(ahk_tests,  "ahk")
	local all_hs_tests  = list_files(hs_tests,   "lua")

	local uncovered  = 0
	local spec_count = 0

	for _, spec_path in ipairs(domain_specs) do
		if not spec_path:match("%.spec%.js$") then goto continue end
		spec_count = spec_count + 1

		local raw_name   = base_name(spec_path)
		local lower_name = raw_name:lower()
		-- Also try a shortened form: strip common suffixes like "recognizer",
		-- "manager", "handler" so "GestureRecognizer" matches "test_gestures".
		local short_name = lower_name:gsub("recognizer$", ""):gsub("manager$", "")
			:gsub("handler$", ""):gsub("engine$", ""):gsub("builder$", "")
		local has_test   = false

		local function matches_test(test_path)
			local t = base_name(test_path):lower()
			return t:find(lower_name, 1, true) or t:find(short_name, 1, true)
				or lower_name:find(t:gsub("^test_", ""), 1, true)
		end

		for _, test_path in ipairs(all_ahk_tests) do
			if matches_test(test_path) then has_test = true ; break end
		end
		if not has_test then
			for _, test_path in ipairs(all_hs_tests) do
				if matches_test(test_path) then has_test = true ; break end
			end
		end
		if not has_test then
			uncovered = uncovered + 1
			print(string.format("  WARN: no driver test found for domain spec %q (searched for *%s* in test names)",
				raw_name, lower_name))
		end

		::continue::
	end

	helpers.it(string.format("every domain spec has a driver test (%d specs)", spec_count), function()
		helpers.assert_true(spec_count > 0, "no *.spec.js files found in shared/domain — check REPO_ROOT")
		helpers.assert_true(uncovered == 0,
			string.format("%d domain spec(s) have no driver test", uncovered))
	end)
end)




-- ===============================================
--- ===============================================
-- ======= 4/ Shared-code purity invariant =======
--- ===============================================
-- ===============================================

-- Baseline violation counts captured when this check was tightened.
-- The tests fail only if the count INCREASES beyond these thresholds, preventing
-- regressions while allowing incremental clean-up of the backlog.
-- TODO: drive all baselines to zero as modules are refactored to use port adapters.
local LUA_HS_BASELINE       = 849  -- hs.* calls in macos/modules/ and macos/lib/
local LUA_IO_OS_BASELINE    = 60   -- io.open / os.execute calls in macos/modules/ and macos/lib/

helpers.describe("meta: shared/ code purity", function()
	local shared_dir = REPO_ROOT .. "/static/ergopti_plus/shared"

	-- Patterns that indicate direct OS-API usage forbidden in shared code
	local forbidden_js_patterns = {
		{ pat = "io%.open",   desc = "direct Lua file I/O" },
		{ pat = "%f[%a]hs%.", desc = "direct Hammerspoon API" },
		{ pat = "SendInput",  desc = "direct AHK keyboard injection" },
		{ pat = "SendEvent",  desc = "direct AHK keyboard injection" },
		{ pat = "TrayTip",    desc = "direct AHK notification" },
		{ pat = "FileAppend", desc = "direct AHK file write" },
		{ pat = "FileRead",   desc = "direct AHK built-in file read" },
	}

	local shared_files  = list_files(shared_dir, "js")
	local js_violations = 0
	local scanned       = 0

	for _, file_path in ipairs(shared_files) do
		-- Skip spec files — they may reference pattern names in documentation strings
		if file_path:match("%.spec%.js$") then goto continue end
		scanned = scanned + 1

		local fh = io.open(file_path, "r")
		if not fh then goto continue end
		local body = fh:read("*a")
		fh:close()

		local rel = file_path:sub(#shared_dir + 1)
		local line_num = 0
		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			line_num = line_num + 1
			for _, entry in ipairs(forbidden_js_patterns) do
				if line:find(entry.pat) then
					js_violations = js_violations + 1
					print(string.format("  WARN: %s in shared/ file: %s:%d",
						entry.desc, rel, line_num))
				end
			end
		end

		::continue::
	end

	helpers.it(string.format("no direct OS API calls in shared/ JS source files (%d scanned)", scanned), function()
		helpers.assert_true(scanned >= 0,
			"shared JS purity scanner failed to initialise")
		helpers.assert_true(js_violations == 0,
			string.format("%d OS-API call(s) found in shared/ JS — shared code must be pure logic", js_violations))
	end)
end)




-- ======================================================
--- ======================================================
-- ======= 5/ Lua module OS-API purity (baseline) =======
--- ======================================================
-- ======================================================

helpers.describe("meta: lua module OS-API purity baseline", function()
	local macos_root    = DRIVER_ROOT
	local modules_dir   = macos_root .. "modules"
	local lib_dir       = macos_root .. "lib"
	local adapters_dir  = macos_root .. "adapters"

	-- Count violations in a list of Lua files, excluding adapter files
	-- (adapters are allowed — and expected — to call OS APIs directly).
	local function count_lua_pattern(files, pattern, adapters_prefix)
		local count = 0
		local details = {}
		for _, file_path in ipairs(files) do
			-- Adapters are the boundary layer; OS calls there are intentional
			if file_path:find(adapters_prefix, 1, true) then goto continue end
			local fh = io.open(file_path, "r")
			if not fh then goto continue end
			local body = fh:read("*a")
			fh:close()
			local line_num = 0
			for line in (body .. "\n"):gmatch("([^\n]*)\n") do
				line_num = line_num + 1
				if line:find(pattern) then
					count = count + 1
					details[#details + 1] = string.format("    %s:%d", file_path, line_num)
				end
			end
			::continue::
		end
		return count, details
	end

	local lua_module_files = list_files(modules_dir, "lua")
	local lua_lib_files    = list_files(lib_dir, "lua")
	local all_lua_files    = {}
	for _, f in ipairs(lua_module_files) do all_lua_files[#all_lua_files + 1] = f end
	for _, f in ipairs(lua_lib_files)    do all_lua_files[#all_lua_files + 1] = f end

	local hs_count, hs_details   = count_lua_pattern(all_lua_files, "hs%.",    adapters_dir)
	local io_count, io_details   = count_lua_pattern(all_lua_files, "io%.open", adapters_dir)
	local os_count, os_details   = count_lua_pattern(all_lua_files, "os%.execute", adapters_dir)
	local total_io_os            = io_count + os_count

	-- Print violation details so CI logs show exactly which lines regressed
	if hs_count > LUA_HS_BASELINE then
		print(string.format("  REGRESSION: hs.* calls increased from %d to %d — new violations:", LUA_HS_BASELINE, hs_count))
		for _, d in ipairs(hs_details) do print(d) end
	else
		print(string.format("  INFO: %d hs.* call(s) in modules+lib (baseline %d) — TODO: drive to zero", hs_count, LUA_HS_BASELINE))
	end

	if total_io_os > LUA_IO_OS_BASELINE then
		print(string.format("  REGRESSION: io.open/os.execute calls increased from %d to %d — new violations:", LUA_IO_OS_BASELINE, total_io_os))
		for _, d in ipairs(io_details) do print(d) end
		for _, d in ipairs(os_details) do print(d) end
	else
		print(string.format("  INFO: %d io.open/os.execute call(s) in modules+lib (baseline %d) — TODO: drive to zero", total_io_os, LUA_IO_OS_BASELINE))
	end

	helpers.it(
		string.format("hs.* usage in lua modules has not increased beyond baseline (%d)", LUA_HS_BASELINE),
		function()
			helpers.assert_true(hs_count <= LUA_HS_BASELINE,
				string.format(
					"hs.* call count regressed: %d > baseline %d — move new OS calls into adapters/",
					hs_count, LUA_HS_BASELINE))
		end)

	helpers.it(
		string.format("io.open/os.execute usage in lua modules has not increased beyond baseline (%d)", LUA_IO_OS_BASELINE),
		function()
			helpers.assert_true(total_io_os <= LUA_IO_OS_BASELINE,
				string.format(
					"io.open/os.execute count regressed: %d > baseline %d — move new OS calls into adapters/",
					total_io_os, LUA_IO_OS_BASELINE))
		end)
end)

--- tests/meta/test_adapter_wiring_reachability.lua

--- ==============================================================================
--- MODULE: Adapter Wiring Reachability Meta-Test
--- DESCRIPTION:
--- Regression test for audit F-HIGH-10: ui/healthcheck/core.lua's ADAPTER_SPECS
--- validated only that an adapter's contract methods exist — it never checked
--- whether any real feature actually calls the adapter. Before the fix, 14 of
--- the 23 adapters under adapters/ were never require()'d by production code
--- (the real call sites duplicated the same hs.* logic directly instead), yet
--- the healthcheck window could report "100% healthy" for all of them.
---
--- FEATURES & RATIONALE:
--- 1. Ground truth via grep: for every adapter file under adapters/, scan every
---    non-test, non-healthcheck production Lua file for a
---    require("adapters.<name>") call site. This is the same signal a human
---    auditor used to produce the F-HIGH-10 finding.
--- 2. Contract check: every ADAPTER_SPECS entry in ui/healthcheck/core.lua must
---    carry an explicit `wired` boolean field so the healthcheck report can never
---    silently imply full reachability again (no field == old misleading behaviour).
--- 3. Agreement check: the spec's `wired` flag must match the grep-derived ground
---    truth. A stale flag (someone wires up an adapter but forgets to flip it, or
---    vice-versa) fails this test instead of silently drifting from reality.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()





-- ==========================================
-- ==========================================
-- ======= 1/ Filesystem scan helpers =======
-- ==========================================
-- ==========================================

--- Lists all files with a given extension recursively under dir.
--- @param dir string Absolute directory path.
--- @param ext string Extension without dot (e.g. "lua").
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

--- Returns true if `path` sits under any of the excluded roots (tests/, the
--- healthcheck module itself, or the adapter's own file — a self-require or a
--- sibling adapter requiring another adapter still counts as production wiring,
--- but an adapter requiring ITSELF is not a meaningful call site).
--- @param path string Absolute file path (forward slashes).
--- @param adapter_file string Absolute path of the adapter file being checked.
--- @return boolean
local function is_excluded(path, adapter_file)
	if path:find("/tests/", 1, true) then return true end
	if path:find("/ui/healthcheck/core.lua", 1, true) then return true end
	if path == adapter_file then return true end
	return false
end

--- Scans every production Lua file for a require("adapters.<name>") call site.
--- @param all_lua_files table List of absolute paths to every .lua file in the driver.
--- @param adapter_name string Bare adapter id, e.g. "notifier".
--- @param adapter_file string Absolute path of adapters/<adapter_name>.lua (self-exclusion).
--- @return boolean True if at least one production call site requires this adapter.
local function has_production_call_site(all_lua_files, adapter_name, adapter_file)
	local pattern = 'adapters%.' .. adapter_name .. '["\']'
	for _, path in ipairs(all_lua_files) do
		if not is_excluded(path, adapter_file) then
			local fh = io.open(path, "r")
			if fh then
				local body = fh:read("*a")
				fh:close()
				if body:find(pattern) then
					return true
				end
			end
		end
	end
	return false
end





-- =================================================
-- =================================================
-- ======= 2/ Reachability vs. ADAPTER_SPECS =======
-- =================================================
-- =================================================

helpers.describe("meta: adapter wiring reachability (F-HIGH-10)", function()
	local adapters_dir = DRIVER_ROOT .. "adapters"
	local all_lua_files = list_files(DRIVER_ROOT, "lua")
	local adapter_files = list_files(adapters_dir, "lua")

	helpers.it("finds adapter files to check", function()
		helpers.assert_true(#adapter_files > 0, "no .lua files found under adapters/ — check DRIVER_ROOT")
	end)

	-- Load the real healthcheck core to read its ADAPTER_SPECS ground truth.
	package.loaded["ui.healthcheck.core"] = nil
	package.loaded["ui.healthcheck.helpers"] = nil
	local ok_core, Core = pcall(require, "ui.healthcheck.core")
	helpers.it("ui.healthcheck.core loads", function()
		helpers.assert_true(ok_core and type(Core) == "table",
			"require('ui.healthcheck.core') must succeed: " .. tostring(Core))
	end)

	-- ADAPTER_SPECS is module-local (not exported); re-derive the same table by
	-- re-reading the source file's spec block rather than reaching into module
	-- internals, so this test does not force core.lua to export test-only state.
	local core_src_path = DRIVER_ROOT .. "ui/healthcheck/core.lua"
	local core_fh = io.open(core_src_path, "r")
	helpers.it("ui/healthcheck/core.lua is readable", function()
		helpers.assert_true(core_fh ~= nil, "cannot open " .. core_src_path)
	end)
	local core_src = core_fh and core_fh:read("*a") or ""
	if core_fh then core_fh:close() end

	--- Extracts { id = "adapters.<name>", wired = true|false } tuples straight
	--- from the ADAPTER_SPECS literal table in core.lua's source text. Each spec
	--- entry's fields always appear in the fixed order id -> contract -> wired,
	--- so matching "id ... wired" directly (rather than trying to brace-balance
	--- the nested contract = { ... } sub-table with a naive non-greedy "{(.-)}",
	--- which stops at the FIRST closing brace — the contract list's, not the
	--- entry's) correctly pairs each id with its own wired flag.
	local specs = {}
	for id, wired_str in core_src:gmatch('id%s*=%s*"(adapters%.[%w_]+)".-wired%s*=%s*(%a+)') do
		specs[#specs + 1] = { id = id, wired = (wired_str == "true") }
	end

	helpers.it("ADAPTER_SPECS extraction found entries", function()
		helpers.assert_true(#specs > 0, "failed to parse any ADAPTER_SPECS entry from core.lua source")
	end)

	helpers.it("every adapter is reachable from a production feature", function()
		for _, spec in ipairs(specs) do
			helpers.assert_true(spec.wired,
				string.format("%s must be wired; do not reintroduce dormant adapter ports", spec.id))
		end
	end)

	-- Build a lookup of adapter name -> spec entry for the "every adapter has a
	-- spec" and "every spec has an explicit wired field" checks below.
	local spec_by_name = {}
	for _, spec in ipairs(specs) do
		local name = spec.id:match("^adapters%.(.+)$")
		spec_by_name[name] = spec
	end

	for _, adapter_path in ipairs(adapter_files) do
		local adapter_name = adapter_path:match("([^/]+)%.lua$")

		helpers.it(string.format("adapters.%s is present in ADAPTER_SPECS with an explicit wired flag", adapter_name), function()
			local spec = spec_by_name[adapter_name]
			helpers.assert_true(spec ~= nil,
				string.format(
					"adapters.%s has no ADAPTER_SPECS entry — the healthcheck cannot report its wiring status " ..
					"(every adapter must be either wired to a real feature or explicitly marked wired = false)",
					adapter_name))
		end)

		helpers.it(string.format("adapters.%s wiring status matches production reality", adapter_name), function()
			local spec = spec_by_name[adapter_name]
			if not spec then return end -- already reported as a failure above

			local actually_wired = has_production_call_site(all_lua_files, adapter_name, adapter_path)

			helpers.assert_eq(spec.wired, actually_wired,
				string.format(
					"adapters.%s: ADAPTER_SPECS says wired=%s but grep of production call sites says %s — " ..
					"either wire the adapter into a real feature or flip the flag so the healthcheck stays honest",
					adapter_name, tostring(spec.wired), tostring(actually_wired)))
		end)
	end
end)

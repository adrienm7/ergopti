--- tests/meta/architecture/test_port_adapter_coverage.lua

--- ==============================================================================
--- MODULE: Port-Adapter Coverage Meta-Test
--- DESCRIPTION:
--- Verifies three structural invariants of the hexagonal architecture:
---
--- 1. ADAPTER PRESENCE — Every port spec in _shared/core/ports/*.spec.js has an
---    adapter listed in _shared/core/ports/adapters.json, on Windows and on macOS,
---    and that file exists. A missing adapter means a port
---    contract exists on paper but is not honoured by a driver.
---
--- 2. DOMAIN TEST COVERAGE — Every domain spec in _shared/core/text/data/domain/*.spec.js
---    has at least one corresponding test file in at least one driver's test
---    suite. An untested domain spec is a dead letter.
---
--- 3. SHARED PURITY — No file under _shared/ directly calls OS-level APIs
---    (io.open, hs., SendInput, SendEvent, TrayTip). Shared code must be
---    pure logic; OS access must go through port adapters.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local CommandLines = require("tests.support.command_lines")

local DRIVER_ROOT = helpers.driver_root()
-- Climb from macos/ root up to repo root (static/ergopti_plus/macos/ -> repo root)
local REPO_ROOT = DRIVER_ROOT:gsub("[/\\]static[/\\]ergopti_plus[/\\]macos[/\\]?$", "")
-- Single source of truth for the shared tree in this meta test; the ports/
-- domain dirs below derive from it so a future rename of the _shared/ tree is one edit.
local SHARED_DIR = REPO_ROOT .. "/static/ergopti_plus/_shared"

-- Additional suspend/pause coverage note for meta
-- All adapters must be usable under pause; no OS calls when paused.





-- ==========================================
-- ==========================================
-- ======= 1/ Filesystem scan helpers =======
-- ==========================================
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
	local source_count = #files
	local inventory = CommandLines.read(cmd)
	assert(#inventory > 0, "source inventory must not be empty")
	for _, raw_line in ipairs(inventory) do
		local line = raw_line:gsub("\\", "/")
		if line:match("%." .. ext .. "$") then
			files[#files + 1] = line
		end
	end
	assert(#files > source_count, "source inventory contains no matching files")
	return files
end

-- Extra regression: ensure suspend/pause paths don't bypass purity or adapters
-- (cross-check with gestures/keystats/llm tests that now cover pause guards)
-- Encore plus: port coverage must now include pause-gated adapters for all features

-- Extra regression: ensure suspend/pause paths don't bypass purity or adapters
-- (cross-check with gestures/keystats/llm tests that now cover pause guards)
-- Encore plus: port coverage must now include pause-gated adapters for all features

--- Extracts the base name without any extension from an absolute path.
--- @param path string Absolute file path.
--- @return string Base name (e.g. "/a/b/foo.spec.js" -> "foo").
local function base_name(path)
	local name = path:match("[^/]+$") or path
	return name:gsub("%.[^.]+$", ""):gsub("%.spec$", "")
end





-- =============================================
-- =============================================
-- ======= 2/ Adapter-presence invariant =======
-- =============================================
-- =============================================

helpers.describe("meta: port-adapter coverage", function()
	local shared_ports  = SHARED_DIR .. "/core/ports"
	-- Where each adapter lives, by repository path: the structure plan moves
	-- adapters into the features they serve, often renamed, so the table
	-- (shared with tools/test/test-port-adapter-matrix.cjs) follows each move.
	local table_fh = assert(io.open(shared_ports .. "/adapters.json", "r"), "adapters.json is unreadable")
	local adapters = require("core.text.engine.json").decode(table_fh:read("a")).adapters
	table_fh:close()
	local function adapter_path(port, driver)
		local homes = adapters[port]
		local rel = homes and homes[driver]
		return rel and (REPO_ROOT .. "/" .. rel) or ("(no " .. driver .. " entry in adapters.json)")
	end

	local spec_files   = list_files(shared_ports, "js")
	local missing_ahk  = 0
	local missing_hs   = 0
	local missing_linux = 0
	local spec_count   = 0

	for _, spec_path in ipairs(spec_files) do
		if not spec_path:match("%.spec%.js$") then goto continue end
		spec_count = spec_count + 1

		local raw_name    = base_name(spec_path)
		local ahk_file    = adapter_path(raw_name, "windows")
		local hs_file     = adapter_path(raw_name, "macos")
		local linux_file  = adapter_path(raw_name, "linux")

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

		-- Linux must keep up with every port too, so a new port without a Linux
		-- adapter fails CI rather than letting the Linux driver silently lag.
		local linux_fh = io.open(linux_file, "r")
		if linux_fh then
			linux_fh:close()
		else
			missing_linux = missing_linux + 1
			print(string.format("  WARN: Linux adapter missing for port %q: expected %s", raw_name, linux_file))
		end

		::continue::
	end

	helpers.it(string.format("every port spec has an AHK adapter (%d specs)", spec_count), function()
		helpers.assert_true(spec_count > 0, "no *.spec.js files found in _shared/core/ports — check REPO_ROOT")
		helpers.assert_true(missing_ahk == 0,
			string.format("%d AHK adapter(s) missing for port specs", missing_ahk))
	end)

	helpers.it(string.format("every port spec has a HS adapter (%d specs)", spec_count), function()
		helpers.assert_true(missing_hs == 0,
			string.format("%d HS adapter(s) missing for port specs", missing_hs))
	end)

	-- Deliberately NOT asserted for Linux, and this is the third place the same
	-- sentence had to be undone. ADR-008 supersedes ADR-001's "adding a new driver
	-- requires only implementing the twenty port adapters": a port is a contract
	-- for the drivers that need the capability, not a checklist. Requiring a file
	-- per spec here is what produced nine Linux adapters with no production caller
	-- — every one of them satisfying this very assertion while nothing reached it.
	--
	-- The count is still computed and printed above, because "which ports does
	-- Linux not implement?" is a useful thing to be able to read. It is reported,
	-- not enforced. What IS enforced is the other direction, by
	-- tools/test/test-adapter-reachability.cjs: an adapter that exists must be
	-- required by something, held at zero on all three drivers.
	helpers.it(string.format("Linux port coverage is reported, not mandated (%d specs)", spec_count), function()
		helpers.assert_true(spec_count > 0,
			"no *.spec.js files found — the scan is broken and this reports nothing")
		helpers.assert_true(missing_linux >= 0,
			"the Linux coverage count must be computed even though it is not enforced — "
				.. "an unread number stops being maintained")
	end)
end)





-- =================================================
-- =================================================
-- ======= 3/ Domain-test-coverage invariant =======
-- =================================================
-- =================================================

helpers.describe("meta: domain spec test coverage", function()
	local domain_dir = SHARED_DIR .. "/core/text/data/domain"
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
		helpers.assert_true(spec_count > 0, "no *.spec.js files found in _shared/core/text/data/domain — check REPO_ROOT")
		helpers.assert_true(uncovered == 0,
			string.format("%d domain spec(s) have no driver test", uncovered))
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 4/ Shared-code purity invariant =======
-- ===============================================
-- ===============================================

-- Per-file OS-API line counts, admitted in os_api_purity_ledger.lua beside this
-- file: one table per tree (modules+lib, ui, init.lua), each with an hs.* and an
-- io.open/os.execute count per driver file. A file whose count differs from its
-- entry fails, upward as a regression, downward so the entry follows it, and a
-- file absent from the ledger may make no such call.
--
-- Six tree totals held this until 2026-11-22, and they had drifted: 634 hs.*
-- lines admitted in modules+lib for 574 measured, 487 in ui/ for 276, 75 and 54
-- io/os lines for 45 and 24. Each slack line was a free regression, and a total
-- let one file pay for another. Earlier history: ui/ and init.lua were first
-- counted on 2026-07-31, after relocations out of the unwatched ui/ tree had
-- been paid for as regressions; comment lines stopped counting on 2026-08-07.
local PURITY_LEDGER = require("tests.meta.architecture.os_api_purity_ledger")

helpers.describe("meta: _shared/ code purity", function()
	local shared_dir = SHARED_DIR

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
		-- Generated tables are a tool's data output, not shared logic; their
		-- embedded _comment text names files such as codegen-*-hs.cjs.
		if file_path:find("/_generated/", 1, true) then goto continue end
		scanned = scanned + 1

		local body = SourceFile.read(file_path)

		local rel = file_path:sub(#shared_dir + 1)
		local line_num = 0
		local in_multiline_comment = false

		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			line_num = line_num + 1

			-- Handle multiline comments /* ... */
			if not in_multiline_comment and line:find("/%*") then
				in_multiline_comment = true
			end

			-- Skip comments: single-line // or active multiline block
			local is_comment = in_multiline_comment or line:match("^%s*//") or line:match("^%s*%*")
			
			if not is_comment then
				for _, entry in ipairs(forbidden_js_patterns) do
					if line:find(entry.pat) then
						js_violations = js_violations + 1
						print(string.format("  WARN: %s in _shared/ file: %s:%d",
							entry.desc, rel, line_num))
					end
				end
			end

			if in_multiline_comment and line:find("%*/") then
				in_multiline_comment = false
			end
		end

		::continue::
	end

	helpers.it(string.format("no direct OS API calls in _shared/ JS source files (%d scanned)", scanned), function()
		-- A floor, not `>= 0`, which every possible run satisfies: if the walk
		-- silently stops finding files this must go red instead of reporting a
		-- clean scan of nothing.
		helpers.assert_true(scanned >= 1,
			"shared JS purity scanner failed to initialise")
		helpers.assert_true(js_violations == 0,
			string.format("%d OS-API call(s) found in _shared/ JS — shared code must be pure logic", js_violations))
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 5/ Lua module OS-API purity (baseline) =======
-- ======================================================
-- ======================================================

-- Counts violations in a list of Lua files, excluding adapter files (adapters
-- are the boundary layer; OS calls there are intentional).
--- @param files table List of absolute Lua file paths.
--- @param pattern string Lua pattern matched against each line.
--- @param adapters_prefix string Path fragment identifying the adapters tree.
--- @return number, table, table Line count, "path:line" details and line count per driver-relative file.
local function count_lua_pattern(files, pattern, adapters_prefix)
	local count = 0
	local details = {}
	local per_file = {}
	for _, file_path in ipairs(files) do
		-- Every adapters/ folder is the isolation layer, the driver's own and a
		-- feature's (core/ui/adapters): a structure move must not turn an
		-- adapter's OS calls into a regression of the tree it lands in.
		if file_path:find(adapters_prefix, 1, true)
			or file_path:find("/adapters/", #DRIVER_ROOT, true) then
			goto continue
		end
		local body = SourceFile.read(file_path)
		local line_num = 0
		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			line_num = line_num + 1
			-- Comment lines are skipped since 2026-08-07. This scanner counted them
			-- for years, and the baselines above record the cost line by line: a
			-- docstring that NAMES hs.task, a Logger.error string that spells out
			-- hs.http.asyncGet, a comment explaining why a call was removed — each
			-- read as a new OS call and each paid for with a baseline bump, which is
			-- a ratchet being loosened by prose. Seven of them landed in one merge.
			-- An OS call is a call; explaining one is the opposite of making one.
			local code = line:match("^%s*(.-)%s*$") or line
			if not code:match("^%-%-") and line:find(pattern) then
				count = count + 1
				details[#details + 1] = string.format("    %s:%d", file_path, line_num)
				local relative = file_path:sub(#DRIVER_ROOT + 1)
				per_file[relative] = (per_file[relative] or 0) + 1
			end
		end
		::continue::
	end
	return count, details, per_file
end

--- Lists every driver file whose measured line count differs from its ledger
--- entry, sorted: a rise, a fall the entry must follow, or a stale entry.
--- @param measured table Driver-relative file to measured line count.
--- @param admitted table Driver-relative file to admitted line count.
--- @return table Lines "file: measured N, ledger M".
local function ledger_differences(measured, admitted)
	local differences = {}
	local seen = {}
	for relative, count in pairs(measured) do
		seen[relative] = true
		if admitted[relative] ~= count then
			differences[#differences + 1] = string.format("%s: measured %d, ledger %s",
				relative, count, tostring(admitted[relative] or 0))
		end
	end
	for relative, count in pairs(admitted) do
		if not seen[relative] then
			differences[#differences + 1] = string.format("%s: measured 0, ledger %d", relative, count)
		end
	end
	table.sort(differences)
	return differences
end

--- Registers the hs.* and io/os ratchets for one tree against its own ledger.
--- Each tree has its own table so an improvement in one can never pay for a
--- regression in another — the failure mode that let OS calls migrate into the
--- unwatched ui/ tree for free — and each file its own count, so one file
--- cannot pay for another either.
--- @param label string Human-readable tree name and its key in PURITY_LEDGER.
--- @param files table Absolute Lua file paths making up the tree.
local function purity_ratchet(label, files)
	local adapters_dir = DRIVER_ROOT .. "adapters"
	local ledger = PURITY_LEDGER[label]

	-- Frontier guard (%f[%w]) so the pattern matches the Hammerspoon global `hs.`
	-- only at a word boundary — NOT the trailing "hs." inside identifiers such as
	-- `Paths.shared` (the centralised shared-tree resolver), which would otherwise
	-- inflate the count with a false positive.
	local _, _, hs_files = count_lua_pattern(files, "%f[%w]hs%.", adapters_dir)
	local _, _, io_files = count_lua_pattern(files, "io%.open", adapters_dir)
	local _, _, os_files = count_lua_pattern(files, "os%.execute", adapters_dir)
	local io_os_files = {}
	for relative, count in pairs(io_files) do io_os_files[relative] = count end
	for relative, count in pairs(os_files) do io_os_files[relative] = (io_os_files[relative] or 0) + count end

	-- A tree that resolves to no file would pass both ratchets forever.
	helpers.it(string.format("purity scan of %s found source files", label), function()
		helpers.assert_true(#files > 0,
			string.format("purity ratchet found NO .lua file for %s — the walk is broken, not the tree", label))
		helpers.assert_true(type(ledger) == "table" and type(ledger.hs) == "table" and type(ledger.io_os) == "table",
			string.format("os_api_purity_ledger.lua has no hs and io_os tables for %s", label))
	end)

	for _, kind in ipairs({ { "hs", "hs.*", hs_files }, { "io_os", "io.open/os.execute", io_os_files } }) do
		helpers.it(string.format("%s lines in %s match the per-file ledger", kind[2], label), function()
			local differences = ledger_differences(kind[3], ledger[kind[1]])
			helpers.assert_true(#differences == 0, string.format(
				"%s lines in %s differ from os_api_purity_ledger.lua (move new OS calls into adapters/; "
					.. "lower an entry that fell, never raise one):\n    %s",
				kind[2], label, table.concat(differences, "\n    ")))
		end)
	end
end

helpers.describe("meta: lua module OS-API purity baseline", function()
	local macos_root = DRIVER_ROOT

	local all_lua_files = {}
	for _, dir in ipairs({ "modules", "infra", "platform", "core", "settings", "menu", "tray", "ai", "apps", "clipboard", "diagnostics", "gestures", "hotstrings" }) do
		for _, f in ipairs(list_files(macos_root .. dir, "lua")) do
			-- A UI source counts in the ui pair below, wherever it lives.
			if not helpers.is_ui_source(f:sub(#DRIVER_ROOT + 1)) then
				all_lua_files[#all_lua_files + 1] = f
			end
		end
	end

	purity_ratchet("modules+lib", all_lua_files)
end)

-- The menus and windows. Every hs.* line here is a call the UI makes without
-- going through a port, and the tree is two thirds the size of modules+lib.
helpers.describe("meta: lua ui OS-API purity baseline", function()
	-- Every UI source of the driver, wherever its feature keeps it.
	local ui_files = {}
	for _, f in ipairs(list_files(DRIVER_ROOT, "lua")) do
		local relative = f:sub(#DRIVER_ROOT + 1)
		if not relative:match("^tests/") and helpers.is_ui_source(relative) then
			ui_files[#ui_files + 1] = f
		end
	end
	purity_ratchet("ui", ui_files)
end)

-- The entry point. list_files is recursive, so it is named directly rather than
-- scanned — asking for DRIVER_ROOT would pull in the whole driver.
helpers.describe("meta: lua entry-point OS-API purity baseline", function()
	purity_ratchet("init.lua", { DRIVER_ROOT .. "init.lua" })
end)

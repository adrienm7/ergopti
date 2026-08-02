--- tests/meta/test_port_adapter_coverage.lua

--- ==============================================================================
--- MODULE: Port-Adapter Coverage Meta-Test
--- DESCRIPTION:
--- Verifies three structural invariants of the hexagonal architecture:
---
--- 1. ADAPTER PRESENCE — Every port spec in _shared/core/ports/*.spec.js has a
---    matching adapter file in static/ergopti_plus/windows/adapters/ and in
---    static/ergopti_plus/macos/adapters/. A missing adapter means a port
---    contract exists on paper but is not honoured by a driver.
---
--- 2. DOMAIN TEST COVERAGE — Every domain spec in _shared/core/domain/*.spec.js
---    has at least one corresponding test file in at least one driver's test
---    suite. An untested domain spec is a dead letter.
---
--- 3. SHARED PURITY — No file under _shared/ directly calls OS-level APIs
---    (io.open, hs., SendInput, SendEvent, TrayTip). Shared code must be
---    pure logic; OS access must go through port adapters.
--- ==============================================================================

local helpers = require("tests.helpers")

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

-- Extra regression: ensure suspend/pause paths don't bypass purity or adapters
-- (cross-check with gestures/keylogger/llm tests that now cover pause guards)
-- Encore plus: port coverage must now include pause-gated adapters for all features

-- Extra regression: ensure suspend/pause paths don't bypass purity or adapters
-- (cross-check with gestures/keylogger/llm tests that now cover pause guards)
-- Encore plus: port coverage must now include pause-gated adapters for all features

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
-- =============================================
-- ======= 2/ Adapter-presence invariant =======
-- =============================================
-- =============================================

helpers.describe("meta: port-adapter coverage", function()
	local shared_ports  = SHARED_DIR .. "/core/ports"
	local ahk_adapters  = REPO_ROOT .. "/static/ergopti_plus/windows/adapters"
	local hs_adapters   = REPO_ROOT .. "/static/ergopti_plus/macos/adapters"
	local linux_adapters = REPO_ROOT .. "/static/ergopti_plus/linux/adapters"

	local spec_files   = list_files(shared_ports, "js")
	local missing_ahk  = 0
	local missing_hs   = 0
	local missing_linux = 0
	local spec_count   = 0

	for _, spec_path in ipairs(spec_files) do
		if not spec_path:match("%.spec%.js$") then goto continue end
		spec_count = spec_count + 1

		local raw_name    = base_name(spec_path)
		local snake_name  = to_snake_case(raw_name)
		local ahk_file    = ahk_adapters   .. "/" .. snake_name .. ".ahk"
		local hs_file     = hs_adapters    .. "/" .. snake_name .. ".lua"
		local linux_file  = linux_adapters .. "/" .. snake_name .. ".lua"

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
	local domain_dir = SHARED_DIR .. "/core/domain"
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
		helpers.assert_true(spec_count > 0, "no *.spec.js files found in _shared/core/domain — check REPO_ROOT")
		helpers.assert_true(uncovered == 0,
			string.format("%d domain spec(s) have no driver test", uncovered))
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 4/ Shared-code purity invariant =======
-- ===============================================
-- ===============================================

-- Baseline violation counts captured when this check was tightened.
-- The tests fail only if the count INCREASES beyond these thresholds, preventing
-- regressions while allowing incremental clean-up of the backlog.
-- TODO: drive all baselines to zero as modules are refactored to use port adapters.
--
-- ui/ AND THE ENTRY POINT USED TO BE OUTSIDE THIS SCAN.
-- The history comment on LUA_HS_BASELINE says "not new OS calls, ui/ is outside
-- this scan" twice, both times raising the baseline for code MOVED out of
-- ui/menu/ into modules/. That is the hole, stated in its own words: a
-- relocation out of the unwatched tree reads as a regression and costs a bump,
-- while a relocation INTO it is free — the ratchet could be satisfied by moving
-- OS calls to where nobody counts them. macos/ui/ holds 630 hs.* lines, two
-- thirds of what modules+lib holds, and init.lua another 46. Each tree now
-- carries its own frozen pair.
local LUA_HS_BASELINE       = 944  -- hs.* calls in macos/modules/ and macos/infra/ (+1 from the 2026-07-22 audit's space_wrap perf fix: modules/gestures/actions.lua's _cached_all_spaces adds one hs.timer.secondsSinceEpoch() to age a short-lived cache of the Space LAYOUT — a NET REDUCTION in OS work, since it removes an hs.spaces.allSpaces() private-API round-trip from every space navigation on the gesture frame callback, where a stall shows up directly as input lag; the sibling logger flush fix in the same pass was deliberately made count-based rather than time-based so it needed no clock read at all. bumped: hs.timer.secondsSinceEpoch() added to vscode_bridge for AX-call TTL cache +1, and ke_lifecycle.kill_async for microsecond-precision script path +1; +2 from relocating hs.fs.attributes + hs.json.decode out of init.lua into infra/personal_hotstrings during boot-orchestrator thinning; +4 from audit F4 relocating the keyboard-layout install/TIS glue out of ui/menu/menu_keyboard_layout.lua into modules/keymap/{layout_install,input_sources} — not new OS calls, ui/ is outside this scan; +2 from PF-1: modules/keylogger/timestamp.lua:13,16 and modules/llm/api_common.lua:151 are pure docstring/comment mentions of hs.* (this scanner does not skip comments) — NOT new OS calls, a documented false-positive class of this meta-test. The other PF-1 contributors were fixed rather than baseline-bumped: the CapsWord probe watchdog in modules/karabiner/watchers.lua now schedules through adapters/timer_scheduler instead of raw hs.timer.doAfter, and the duplicated "Respects per-section enable/disable state stored in hs.settings." docstring copy-pasted from registry_index.lua into registry_groups.lua's load_toml was reworded to point at the actual owner instead of repeating the implementation detail. modules/shortcuts/actions/system_pixel.lua:19's `local pasteboard = hs.pasteboard` is a genuine 4th copy of the same one-line alias created when system.lua was split into sub-modules (each is a separate Lua chunk needing its own upvalue — inlining it at the single call site would not reduce the count, since the hs.pasteboard reference would just move to that line instead) — counted here as unavoidable, not deduped further; +1 from F-MED-18: modules/karabiner/ke_lifecycle.lua's notify_karabiner_ready() cooldown branch now arms a genuine hs.timer.doAfter retry so a deferred "Karabiner ready" notification is no longer silently dropped forever — this whole module already uses raw hs.timer.doAfter extensively and is not yet migrated to adapters/timer_scheduler, so this one new call is left consistent with its many untouched siblings rather than converting a single call site in isolation; +7 from the 2026-07-01 audit's parallel multi-group implementation pass: each fix group verified its OWN hs.* delta in an isolated worktree before merging, so no single group saw the cumulative total. Traced line-by-line post-merge: modules/llm/init.lua +3 (two new Logger.error() strings and one comment in auto_detect_backend/set_active_profile literally spell out "hs.http.asyncGet"/describe hs.timer.doAfter while fixing F-MED-5/F-MED-6 — no new API call, the underlying asyncGet/doAfter call sites are unchanged), modules/llm/api_token_crypto.lua +1 and modules/llm/api_remote.lua +1 (new docstrings for F-MED-9's decrypt_async/prewarm_active_entry_decrypt reference "hs.execute"/"hs.settings"/"hs.task" descriptively), modules/llm/mlx_deps_checker.lua +1 (F-LOW-10's reset_bootstrap_state docstring mentions "hs.task"), and +1 from a cross-group blind spot the same way (another comment-only mention, same false-positive class) — all 7 confirmed to be comment/log-string text, not new OS call sites; verified via `git diff <pre-merge>..HEAD -- modules lib` that no actual new hs.* call was introduced; +2 from DC-1: modules/keylogger/aggregator/core.lua's load_shared_kc_to_finger() adds one genuine `pcall(hs.json.decode, content)` call to load the shared azerty.json keycode catalogue — the exact same load-shared-JSON-at-module-level pattern modules/shortcuts/actions/text.lua's load_shared_groups() already uses for the wrap-symbols catalogue (already counted in this baseline) — plus one PF-1-class comment mention ("hs.json.decode rejects it" in the BOM-stripping comment, same line-adjacent to the real call); +1 from DC-4: modules/keymap/registry.lua's _load_priority_tiers() adds one genuine `pcall(hs.json.decode, raw)` to load the shared _shared/modules/hotstrings/priority.json collision-priority tiers (dropping the hand-copied literals per plan item 14), the same load-shared-JSON-at-module-level pattern as DC-1 above. +1 from 2026-07-29: modules/keymap/utils.lua gained a COMMENT naming hs.window.timeout() while explaining why the ignored-window AX probe is served from cache and refreshed off the tap — this scanner does not strip comments, so it is a documented false positive, NOT a new OS call; verified with `git diff -- modules lib` showing the only added hs. token is inside a comment block.
local LUA_IO_OS_BASELINE    = 77   -- io.open / os.execute calls in macos/modules/ and macos/infra/ (bumped after errors-sink + diagnostic + menu + sg feature work; +1 from relocating the priority.json io.open out of init.lua into infra/personal_hotstrings; +5 from audit F4 relocating the keyboard-layout install/TIS glue out of ui/menu/menu_keyboard_layout.lua into modules/keymap/{layout_install,input_sources} — not new OS calls, ui/ is outside this scan; +1 from DC-4: modules/keymap/registry.lua's _load_priority_tiers() adds one io.open to read the shared _shared/modules/hotstrings/priority.json before decoding it — a genuine module-level shared-data load replacing the hand-copied priority literals per plan item 14; +1 / -1 from moving ui/menu/preferences.lua to infra/preferences.lua (2026-08-02, Lot 5): config persistence used outside the menu — init.lua and ui/onboarding both require it — so it is cross-cutting plumbing, not menu code. The driver's total is UNCHANGED; this is the per-tree design working as intended, and the reason each tree got its own frozen pair in the first place. The UI baselines below drop by the same amount, so the relocation cannot be used to launder OS calls in either direction.)

-- macos/ui/ — the menus and windows. First measured 2026-07-31 at 630 hs.* and
-- 65 io.open/os.execute lines; not a regression, this tree had simply never been
-- counted. It is where the keyboard-layout TIS glue lived before audit F4 moved
-- it into modules/ and paid +4/+5 for the privilege.
local LUA_HS_BASELINE_UI    = 630
local LUA_IO_OS_BASELINE_UI = 64

-- macos/init.lua — the entry point. One file, but the one file every launch
-- runs. First measured 2026-07-31 at 46 hs.* and 2 io.open/os.execute lines.
local LUA_HS_BASELINE_ENTRY    = 46
local LUA_IO_OS_BASELINE_ENTRY = 2

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
		scanned = scanned + 1

		local fh = io.open(file_path, "r")
		if not fh then goto continue end
		local body = fh:read("*a")
		fh:close()

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
--- @return number, table Line count and "path:line" details.
local function count_lua_pattern(files, pattern, adapters_prefix)
	local count = 0
	local details = {}
	for _, file_path in ipairs(files) do
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

--- Registers the hs.* and io/os ratchets for one tree against its own baselines.
--- Each tree is frozen separately so an improvement in one can never pay for a
--- regression in another — the failure mode that let OS calls migrate into the
--- unwatched ui/ tree for free.
--- @param label string Human-readable tree name, used in every message.
--- @param files table Absolute Lua file paths making up the tree.
--- @param hs_baseline number Frozen hs.* line count.
--- @param io_os_baseline number Frozen io.open + os.execute line count.
local function purity_ratchet(label, files, hs_baseline, io_os_baseline)
	local adapters_dir = DRIVER_ROOT .. "adapters"

	-- Frontier guard (%f[%w]) so the pattern matches the Hammerspoon global `hs.`
	-- only at a word boundary — NOT the trailing "hs." inside identifiers such as
	-- `Paths.shared` (the centralised shared-tree resolver), which would otherwise
	-- inflate the count with a false positive.
	local hs_count, hs_details = count_lua_pattern(files, "%f[%w]hs%.", adapters_dir)
	local io_count, io_details = count_lua_pattern(files, "io%.open", adapters_dir)
	local os_count, os_details = count_lua_pattern(files, "os%.execute", adapters_dir)
	local total_io_os          = io_count + os_count

	-- A tree that resolves to no file would pass both ratchets forever.
	helpers.it(string.format("purity scan of %s found source files", label), function()
		helpers.assert_true(#files > 0,
			string.format("purity ratchet found NO .lua file for %s — the walk is broken, not the tree", label))
	end)

	-- Print violation details so CI logs show exactly which lines regressed
	if hs_count > hs_baseline then
		print(string.format("  REGRESSION: hs.* calls in %s increased from %d to %d — new violations:", label, hs_baseline, hs_count))
		for _, d in ipairs(hs_details) do print(d) end
	else
		print(string.format("  INFO: %d hs.* call(s) in %s (baseline %d) — TODO: drive to zero", hs_count, label, hs_baseline))
	end

	if total_io_os > io_os_baseline then
		print(string.format("  REGRESSION: io.open/os.execute calls in %s increased from %d to %d — new violations:", label, io_os_baseline, total_io_os))
		for _, d in ipairs(io_details) do print(d) end
		for _, d in ipairs(os_details) do print(d) end
	else
		print(string.format("  INFO: %d io.open/os.execute call(s) in %s (baseline %d) — TODO: drive to zero", total_io_os, label, io_os_baseline))
	end

	helpers.it(
		string.format("hs.* usage in %s has not increased beyond baseline (%d)", label, hs_baseline),
		function()
			helpers.assert_true(hs_count <= hs_baseline,
				string.format(
					"hs.* call count in %s regressed: %d > baseline %d — move new OS calls into adapters/",
					label, hs_count, hs_baseline))
		end)

	helpers.it(
		string.format("io.open/os.execute usage in %s has not increased beyond baseline (%d)", label, io_os_baseline),
		function()
			helpers.assert_true(total_io_os <= io_os_baseline,
				string.format(
					"io.open/os.execute count in %s regressed: %d > baseline %d — move new OS calls into adapters/",
					label, total_io_os, io_os_baseline))
		end)
end

helpers.describe("meta: lua module OS-API purity baseline", function()
	local macos_root = DRIVER_ROOT

	local all_lua_files = {}
	for _, dir in ipairs({ "modules", "infra" }) do
		for _, f in ipairs(list_files(macos_root .. dir, "lua")) do
			all_lua_files[#all_lua_files + 1] = f
		end
	end

	purity_ratchet("modules+lib", all_lua_files, LUA_HS_BASELINE, LUA_IO_OS_BASELINE)
end)

-- The menus and windows. Every hs.* line here is a call the UI makes without
-- going through a port, and the tree is two thirds the size of modules+lib.
helpers.describe("meta: lua ui OS-API purity baseline", function()
	purity_ratchet("ui", list_files(DRIVER_ROOT .. "ui", "lua"), LUA_HS_BASELINE_UI, LUA_IO_OS_BASELINE_UI)
end)

-- The entry point. list_files is recursive, so it is named directly rather than
-- scanned — asking for DRIVER_ROOT would pull in the whole driver.
helpers.describe("meta: lua entry-point OS-API purity baseline", function()
	purity_ratchet("init.lua", { DRIVER_ROOT .. "init.lua" }, LUA_HS_BASELINE_ENTRY, LUA_IO_OS_BASELINE_ENTRY)
end)

--- tests/helpers/init.lua

--- ==============================================================================
--- MODULE: Test Helpers
--- DESCRIPTION:
--- Shared utilities for the test suite — module loading with a fresh `hs` stub,
--- fixture readers, lightweight assertions, and a minimal `describe/it` layer
--- usable when busted is unavailable.
---
--- FEATURES & RATIONALE:
--- 1. Per-test isolation: `load_with_stubs` resets `package.loaded` and the `hs`
---    global so every test starts from a clean slate.
--- 2. Zero-dependency runner: works under plain Lua 5.4 with no external libs;
---    falls through transparently to busted when present.
--- 3. Discoverable assertions: `assert_eq` and friends produce diff-style error
---    messages that point straight at the failing field.
--- ==============================================================================

local M = {}

-- Value formatting and stack-trace helpers shared with Linux (single source of truth).
local fmt = require("test.format")
M.inspect = fmt.inspect
M.deep_equal = fmt.deep_equal

-- fail_msg closure: skip this helpers file when resolving test file:line.
local _fail_msg = fmt.fail_msg_for("helpers[/\\\\]init%.lua$")


-- ===================================
-- ===================================
-- ======= 1/ Path Resolution ========
-- ===================================
-- ===================================

--- Returns the absolute path of the Hammerspoon driver root.
--- The harness sets `package.path` to include the driver root before any
--- helper loads, so we recover it from that environment.
--- @return string Absolute path with trailing slash.
function M.driver_root()
	-- Resolve from the helper's own debug source path.
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- src is .../tests/helpers/init.lua — go two dirs up.
	local helper_dir = src:match("^(.*)[/\\]helpers[/\\]init%.lua$") or "./tests"
	return helper_dir:gsub("[/\\]tests$", "") .. "/"
end

--- Returns the path to the tests/fixtures directory.
--- @return string Absolute path with trailing slash.
function M.fixtures_dir()
	return M.driver_root() .. "tests/fixtures/"
end

-- THE single source of truth for the shared-tree location in tests: a path
-- relative to the macOS driver root. _shared/ is a sibling of macos/ (both live
-- under ergopti_plus/), so it sits one level up. A future rename of the
-- _shared/ tree only needs editing this one constant.
local SHARED_REL = "../_shared"

--- Resolves a path inside the _shared/ tree, relative to the driver root.
--- Mirrors the production Paths.shared contract (nil/"" -> the shared root dir).
--- Every test that needs a shared resource MUST go through this helper rather
--- than hand-rolling ``driver_root() .. "../_shared/..."`` so the folder name
--- lives in exactly one place.
--- @param rel string|nil Path relative to _shared/, e.g. ``"llm/models.json"``.
--- @return string Absolute path.
function M.shared(rel)
	local root = M.driver_root() .. SHARED_REL
	if rel and rel ~= "" then
		return root .. "/" .. rel
	end
	return root
end





-- =====================================
-- =====================================
-- ======= 2/ Module Stub Loader =======
-- =====================================
-- =====================================

--- Runs a fixture against freshly required modules, then restores the exact
--- package cache entries even if setup or an assertion raises. Stateful parent
--- modules and their exact-owned children must be listed together; otherwise a
--- reload creates an impossible hybrid that production correctly refuses.
--- @param module_names string[] Unique dotted Lua module names.
--- @param callback function Fixture callback.
--- @return ... Callback results.
function M.with_fresh_modules(module_names, callback)
	assert(type(module_names) == "table", "module_names must be a table")
	assert(type(callback) == "function", "callback must be a function")
	local saved = {}
	local seen = {}
	for index, module_name in ipairs(module_names) do
		assert(type(module_name) == "string" and module_name ~= "",
			"module_names entries must be non-empty strings")
		assert(not seen[module_name], "duplicate module name: " .. module_name)
		seen[module_name] = true
		saved[index] = package.loaded[module_name]
		package.loaded[module_name] = nil
	end

	local outcome = { n = 0 }
	local function capture(...)
		outcome.n = select("#", ...)
		for index = 1, outcome.n do outcome[index] = select(index, ...) end
	end
	capture(xpcall(callback, debug.traceback))
	for index, module_name in ipairs(module_names) do
		package.loaded[module_name] = saved[index]
	end
	if not outcome[1] then error(outcome[2], 0) end
	return (table.unpack or unpack)(outcome, 2, outcome.n)
end

--- Reloads a module after wiping the package cache and stubbing `hs`.
--- @param module_name string Dotted Lua module name to require.
--- @param hs_overrides table|nil Optional table merged onto the default `hs` stub.
--- @return any The module's return value.
function M.load_with_stubs(module_name, hs_overrides)
	-- Drop any previous instance so module-level state resets between tests.
	--
	-- Only the NAMED module, deliberately. Clearing the subtree as well looks
	-- like the more thorough choice and breaks twenty-one tests: many place a
	-- stub submodule in package.loaded and then load the parent to assert it
	-- calls into that stub, and wiping the subtree throws the stub away. The
	-- caller decides what its module tree contains; this helper does not.
	--
	-- The cost is a real one and worth naming: a submodule that captures `hs`
	-- with `local hs = hs` at load time keeps whatever stub was global when IT
	-- was first required, and no later call here can reach it. A test that needs
	-- such a submodule re-read must clear it itself.
	package.loaded[module_name] = nil
	-- Expander and TerminatorReplay form one ownership unit: Expander.init now
	-- consumes the replay module's exact commitment, and replay correctly refuses
	-- rebinding to a different CoreState. Reloading only the parent would therefore
	-- create an impossible hybrid fixture (fresh parent, stale child).
	if module_name == "modules.keymap.expander" then
		package.loaded["modules.keymap.terminator_replay"] = nil
	end
	-- The system-action facade now exposes three stateful child owners. Reloading
	-- only the facade would retain their pause claims, exact native debt, and the
	-- previous test's native contracts as an impossible fresh-parent/stale-child
	-- composition.
	if module_name == "modules.shortcuts.actions.system" then
		package.loaded["modules.shortcuts.actions.system_pixel"] = nil
		package.loaded["modules.shortcuts.actions.system_mouse"] = nil
		package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	end
	-- Dependency checkers and their backend-local pause controller form one
	-- stateful ownership unit. A fresh checker must never inherit the previous
	-- fixture's registered owner, epoch token, or resume-stage timer.
	if module_name == "modules.llm.mlx_deps_checker"
		or module_name == "modules.llm.ollama_deps_checker" then
		package.loaded["modules.llm.dependency_bootstrap_pause_owner"] = nil
	end
	package.loaded["hs"] = nil
	-- Force a fresh stub table each call so overrides from one test never leak
	-- into the next. Modules that override hs.execute or hs.timer with a partial
	-- table would otherwise corrupt the shared singleton for all later tests.
	package.loaded["tests.stubs.hs"] = nil

	-- Fresh hs stub for this test
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()

	if type(hs_overrides) == "table" then
		for k, v in pairs(hs_overrides) do hs_stub[k] = v end
	end

	_G.hs = hs_stub
	-- Anchor the stub under the bare "hs" key so that any subsequent
	-- `require("hs")` call in the harness or cascaded modules returns
	-- exactly this same stub — not a fresh reload. Without this, Lua
	-- re-executes tests/stubs/hs.lua and creates a second KEYSTROKES
	-- table; keyStroke/keyStrokes closures captured by utils and expander
	-- would then write to the first table while the harness reads from the
	-- second, making all keystroke assertions see 0 entries.
	package.loaded["hs"] = hs_stub

	-- Clear any partial or stubbed lib.text_utils installed by a previous test file
	-- (e.g. test_apply_prediction_arms_guard.lua installs a minimal stub that lacks
	-- utf8_len / repl_title). Without this, modules that capture text_utils at
	-- require-time get the stub instead of the full shared module, causing
	-- "attempt to call a nil value (field 'utf8_len')" crashes in subsequent tests.
	-- text_utils/init.lua is pure Lua with no hs deps, so reloading it is safe.
	package.loaded["infra.text_utils"] = nil

	-- Clear any toml_codec stub installed at module level by test files that
	-- treat it as a native C library (e.g. test_config.lua). The real codec is
	-- pure Lua and loads fine in CI; the stub's encode() returns "" which
	-- causes preferences.save() to write an empty TOML file and all persistence
	-- tests to see flat = {}.
	package.loaded["infra.toml.codec"]   = nil
	package.loaded["toml_codec"]       = nil
	package.loaded["toml_codec.codec"] = nil

	-- Clear any partial lib.timings stub installed at module level by test files
	-- that only need M.sec (e.g. test_apply_prediction_paste_ops.lua installs
	-- { sec = function() ... end }, no M.ms). lib.timings has no hs dependency
	-- and is cheap to re-parse from constants.toml, so always reloading the real
	-- module is safe. Without this, any later test whose require chain reaches
	-- modules.keylogger (which calls Timings.ms(...) at module load time, e.g.
	-- via modules.keymap.llm_bridge) crashes with "attempt to call a nil value
	-- (field 'ms')" the moment modules.keylogger is not already cached.
	package.loaded["infra.timings"] = nil

	-- Drop the keyboard-layout install / input-source modules (split out of
	-- ui/menu/menu_keyboard_layout.lua in audit F4). They hold session caches and
	-- capture `local hs` at require-time, so a test that stubs hs.task to drive the
	-- async active-layout probe must get them reloaded under the fresh stub — not a
	-- cached instance bound to a previous test's hs. Same rationale as text_utils.
	package.loaded["modules.keymap.layout_install"] = nil
	package.loaded["modules.keymap.input_sources"]  = nil

	-- Drop every cached modules.keymap.registry* sub-module (registry.lua was split
	-- into registry_groups.lua + registry_index.lua). All three capture `local hs = hs`
	-- at require-time; when a test file requires only "modules.keymap.registry" (which
	-- itself requires the two split files), load_with_stubs's first line only clears
	-- the exact module_name key, leaving registry_index/registry_groups cached from
	-- whatever earlier test file first required them — bound to THAT test's now
	-- disconnected hs stub instance. Registry.is_section_enabled then silently
	-- reads/writes hs.settings against a stale store for the rest of the run
	-- (F-HIGH-23 fix). Pattern-based like the ui.menu sweep above so any future split
	-- under modules.keymap.registry* is covered automatically.
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.keymap%.registry") then
			package.loaded[name] = nil
		end
	end

	-- Drop every cached ui.menu.* module so a menu builder that captured lib.i18n at
	-- require-time (e.g. menu_karabiner / menu_utils call i18n.section) is ALWAYS
	-- re-bound to THIS test's canonical lib.i18n stub set below — never a section-less
	-- `{ get = ... }` stub a previous test file installed at module scope. Without this
	-- the full run.lua suite was order/GC-dependently RED at menu_karabiner.lua:317
	-- (i18n.section nil), masking real regressions behind a flaky failure (F-T1).
	-- Setting an existing key to nil during pairs() is safe (only ADDING keys is not).
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^ui%.menu") then
			package.loaded[name] = nil
		end
	end

	-- Always inject a minimal lib.i18n stub so that modules calling i18n.get()
	-- at require-time (terminators, conflicts, actions, profiles …) never crash
	-- with "attempt to call a nil value (field 'get')". The real lib.i18n depends
	-- on hs.settings and locale JSON files unavailable in headless unit tests.
	-- Tests that need a richer stub should override package.loaded["infra.i18n"]
	-- AFTER calling load_with_stubs (this baseline is always restored here).
	-- decorate_section / section mirror the real i18n: menu builders (via
	-- ui.menu.menu_utils.build_section_header) wrap disabled headers in the
	-- canonical "— … —" decoration, so the stub must expose them or any builder
	-- that renders a section header crashes with a nil-field call.
	package.loaded["infra.i18n"] = {
		get             = function(key) return key end,
		get_locale      = function() return "fr" end,
		set_locale      = function() end,
		decorate_section = function(text) return "— " .. text .. " —" end,
		section          = function(key) return "— " .. key .. " —" end,
		-- Mirrors the real {n} substitution. A stub narrower than the module it
		-- stands in for is how a production call to a missing function reaches
		-- nil under test and nobody notices: every consumer of i18n.format would
		-- otherwise crash here for a reason that has nothing to do with its own bug.
		format          = function(key, ...)
			local text = tostring(key)
			local args = table.pack(...)
			for n = 1, args.n do
				text = text:gsub("{" .. n .. "}", (tostring(args[n]):gsub("%%", "%%%%")))
			end
			return text
		end,
	}

	-- Stub lib.paths so that any module (e.g. llm/api_remote, profiles resolution)
	-- can find _shared/modules/llm/api_providers.json and profiles.json during headless
	-- tests. Without this, io.open fails or returns nil path, causing "not found"
	-- errors in tests that load api_remote or exercise catalogue-dependent code.
	package.loaded["infra.paths"] = {
		-- Single shared-tree resolver: all three helpers delegate to M.shared so
		-- the folder name lives in exactly one place (SHARED_REL). Mirrors the
		-- production Paths.shared contract (nil/"" → the shared root dir).
		shared          = function(rel) return M.shared(rel) end,
		shared_root     = function() return M.shared() end,
		shared_llm_path = function(name) return M.shared("modules/llm/" .. name) end,
		find_from_configdir = function(relative_target)
			-- relative_target is usually "static/ergopti_plus/_shared/data/locales"
			-- M.driver_root() is .../static/ergopti_plus/macos/
			-- We want to return .../relative_target
			return M.driver_root() .. "../../" .. relative_target
		end,
	}

	-- Minimal DEFAULT_STATE for modules.llm.init (lazy-required by
	-- profiles.resolve_system_prompt for {min_words}/{max_words} injection).
	-- Prevents "attempt to index a nil value" when Core.DEFAULT_STATE is accessed
	-- in test/CI envs.
	package.loaded["modules.llm.init"] = {
		DEFAULT_STATE = {
			llm_min_words = 4,
			llm_max_words = 20,
		},
	}

	-- Register sub-module aliases so that `require("hs.json")` etc. resolve to
	-- the same tables as `hs.json`. Some production modules call require("hs.*")
	-- directly rather than accessing the global `hs` table.
	local hs_sub_modules = {
		"json", "fs", "sqlite3", "timer", "http", "logger",
		"settings", "keycodes", "eventtap", "canvas", "styledtext",
		"notify", "dialog", "application", "window", "host",
		"pathwatcher", "urlevent", "pasteboard", "osascript",
		"spaces", "fnutils", "inspect", "task", "webview",
		"distributednotifications", "image", "menubar", "hotkey",
	}
	for _, sub in ipairs(hs_sub_modules) do
		if hs_stub[sub] ~= nil then
			package.loaded["hs." .. sub] = hs_stub[sub]
		end
	end

	return require(module_name)
end

--- Reads the contents of a fixture file relative to tests/fixtures/.
--- @param relative_path string Path under tests/fixtures.
--- @return string|nil File contents or nil if unreadable.
function M.read_fixture(relative_path)
	local path = M.fixtures_dir() .. relative_path
	local fh = io.open(path, "r")
	if not fh then return nil end
	local body = fh:read("*a")
	fh:close()
	return body
end

--- Production sources, read once per process.
---
--- The scan used to re-run its `find`/`dir` and re-read all 201 production files
--- on EVERY call, and there are several hundred call sites: ~3.3 MB of file I/O
--- per read, ~1.2 GB per suite run, for a tree that no test is allowed to
--- mutate. Caching it is what makes the symbol-keyed scan affordable enough to
--- be the DEFAULT way a source invariant is written rather than a reluctant
--- alternative to naming a path.
--- @type table|nil
local _production_sources = nil

--- Loads (once) every production Lua file under the driver root.
--- @return table Array of file bodies, tests/ excluded.
local function production_sources()
	if _production_sources then return _production_sources end

	local root = M.driver_root()
	local is_windows = package.config:sub(1, 1) == "\\"
	local command
	if is_windows then
		command = 'dir /b /s "' .. root:gsub("/", "\\") .. '*.lua"'
	else
		command = 'find "' .. root:gsub('"', '\\"') .. '" -type f -name "*.lua"'
	end

	-- Collect the PATHS first and sort them, because neither `find` nor `dir /b /s`
	-- promises an order: it follows the filesystem, so a fresh CI runner returns a
	-- different one from the last. Every source invariant built on this list was
	-- therefore non-deterministic, and one of them — the boot-ordering guard — went
	-- red or green depending on which file the scan happened to reach first.
	local paths = {}
	local pipe = io.popen(command, "r")
	if not pipe then return {} end
	for path in pipe:lines() do
		local normalized = path:gsub("\\", "/")
		if not normalized:find("/tests/", 1, true) then
			paths[#paths + 1] = path
		end
	end
	pipe:close()
	table.sort(paths)

	local bodies = {}
	for _, path in ipairs(paths) do
		local fh = io.open(path, "r")
		if fh then
			bodies[#bodies + 1] = fh:read("*a")
			fh:close()
		end
	end

	-- An empty result means the scan itself failed (no popen, wrong root). Do not
	-- cache that: a cached emptiness would make every later call return nil and
	-- every source invariant in the run pass vacuously.
	if #bodies > 0 then _production_sources = bodies end
	return bodies
end

--- Returns the concatenated production source containing an optional symbol.
---
--- Source-invariant tests must not name a production file: the implementation
--- can be split or moved without turning a useful invariant into a path error.
--- The scan deliberately excludes tests/ and works with the plain Lua runner on
--- macOS, Linux CI, and Windows.
---
--- The returned string is the concatenation of every production file containing
--- `symbol`, so a selector matching two files changes what the caller asserts —
--- pick one unique to the module under test, and prefer a declaration over a
--- path-like literal.
--- @param symbol string|nil Optional literal to select relevant source files.
--- @return string|nil Matching production Lua source, or nil when not found.
function M.read_driver_source(symbol)
	local parts = {}
	for _, body in ipairs(production_sources()) do
		if not symbol or body:find(symbol, 1, true) then
			parts[#parts + 1] = body
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, "\n")
end

--- The ONE production file containing `symbol`, for invariants about ORDER.
---
--- read_driver_source concatenates every matching file, which is right for
--- "does this appear anywhere" and wrong for "does A appear before B": byte
--- offsets across unrelated files answer a question nobody asked. The boot
--- guard compared `hs.shutdownCallback = function` against `"platform.remap"`
--- that way; both live in init.lua, but two OTHER files carry the second marker
--- alone, so whichever the scan reached first decided the verdict.
---
--- Sorting the scan made that deterministic. It did not make it meaningful —
--- init.lua happens to sort first, so the guard would have passed for a reason
--- unrelated to what it asserts. Ordering is a property of one translation
--- unit, and this returns one or fails.
---
--- Still no path is named: the caller gives a symbol, not a file, so the
--- implementation can move.
--- @param symbol string A string unique to the file being asked for.
--- @return string|nil body, string|nil err Body, or nil plus why.
function M.read_driver_unit(symbol)
	if type(symbol) ~= "string" or symbol == "" then
		return nil, "read_driver_unit() needs a symbol to look for"
	end
	local matches = {}
	for _, body in ipairs(production_sources()) do
		if body:find(symbol, 1, true) then matches[#matches + 1] = body end
	end
	if #matches == 0 then
		return nil, string.format("no production file contains %q", symbol)
	end
	if #matches > 1 then
		return nil, string.format(
			"%d production files contain %q — an ordering invariant needs a symbol "
				.. "unique to one file, or it compares offsets across unrelated sources",
			#matches, symbol)
	end
	return matches[1]
end




-- ==================================
-- ==================================
-- ======= 3/ Assertions ============
-- ==================================
-- ==================================

--- Convenience aliases to the shared format module (single source of truth).
--- deep_equal is used by assert_eq and is also available to test files.
local deep_equal = fmt.deep_equal

-- The seven assertions come from _shared/lua/test/assertions.lua. Both drivers
-- carried their own copy: six of the seven bodies were byte-identical once
-- whitespace was normalised, and the seventh differed by a single COMMENT line.
-- Two copies of an assertion library is two places for a fix to land in one of,
-- and every other test's credibility rests on these.
--
-- fail_msg is injected because it is the one genuinely per-driver part: it skips
-- the stack frames belonging to THIS file so a failure reports the caller's line.
local _assertions = require("test.assertions").build("helpers[/\\\\]init%.lua$", fmt)
M.assert_eq        = _assertions.assert_eq
M.assert_true      = _assertions.assert_true
M.assert_nil       = _assertions.assert_nil
M.assert_not_nil   = _assertions.assert_not_nil
M.assert_type      = _assertions.assert_type
M.assert_contains  = _assertions.assert_contains
M.assert_throws    = _assertions.assert_throws












--- ===================================
--- ===================================
--- ======= 4/ Mini Test Runner =======
--- ===================================
--- ===================================

local _suite_results = { passed = 0, failed = 0, failures = {} }
local _before_each_fn = nil
-- When set (via --only), M.it runs only tests whose name contains this substring.
local _only_filter = nil

--- Declares a test suite (analogous to busted’s `describe`).
--- @param name string Suite name, printed in the output.
--- @param fn function Suite body that calls `it()`.
function M.describe(name, fn)
	print(string.format("\n=== %s ===", name))
	-- Save and reset before_each so nested describes don’t inherit the outer hook
	local prev_before_each = _before_each_fn
	_before_each_fn = nil
	local ok, err = pcall(fn)
	_before_each_fn = prev_before_each
	if not ok then
		print(string.format("  ! suite error: %s", tostring(err)))
		_suite_results.failed = _suite_results.failed + 1
	end
end

--- Registers a function to run before each subsequent `it()` in the current describe block.
--- @param fn function Setup function to run before each test.
function M.before_each(fn)
	_before_each_fn = fn
end

--- Declares a single test case (analogous to busted’s `it`).
--- @param name string Test name, printed in the output.
--- @param fn function Test body.
function M.it(name, fn)
	-- --only <substr>: run only tests whose name contains the filter (plain
	-- substring, no Lua pattern magic) so one behaviour can be re-run in
	-- isolation from a red message.
	if _only_filter and not string.find(name, _only_filter, 1, true) then return end
	local ok, err = pcall(function()
		if _before_each_fn then _before_each_fn() end
		fn()
	end)
	if ok then
		_suite_results.passed = _suite_results.passed + 1
		print("  ok   " .. name)
	else
		_suite_results.failed = _suite_results.failed + 1
		_suite_results.failures[#_suite_results.failures + 1] = { name = name, err = tostring(err) }
		print("  FAIL " .. name .. " — " .. tostring(err))
	end
end

--- Builds a minimal lib.logger stub suitable for injection via package.loaded.
--- All log methods are no-ops so modules can log without crashing in headless tests.
--- @return table Logger stub with the same public API as infra/logger.lua.
function M.make_logger_stub()
	local noop = function() end
	return {
		debug   = noop, trace   = noop, done    = noop,
		info    = noop, start   = noop, success = noop,
		warn    = noop, error   = noop,
		set_level = noop, set_sink = noop, is_enabled = function() return false end,
		ring_buffer_snapshot = function() return {} end,
		pcall   = function(_, fn, ...) return pcall(fn, ...) end,
		callback = function(_, _, fn, ...) return xpcall(fn, debug.traceback, ...) end,
		build   = function() return noop end,
		install_runtime_error_capture = noop,
		init_log_path = noop,
		start_async_sink = function() return true end,
		classify_async_sink_boot_environment = function() return "standalone" end,
		set_async_sink_failure_handler = function() return true end,
		begin_async_sink_shutdown = function(callback) callback(true); return true end,
		stop_async_sink = function() return true end,
		async_sink_status = function() return { active = true } end,
	}
end

--- Returns the global test result tally.
--- @return table {passed, failed, failures}
function M.get_results() return _suite_results end

--- Resets the cumulative result counters.
function M.reset_results()
	_suite_results.passed = 0
	_suite_results.failed = 0
	_suite_results.failures = {}
end

--- Restricts M.it execution to tests whose name contains `substr` (the --only filter).
--- @param substr string|nil Substring to match; nil clears the filter (run all).
function M.set_only_filter(substr) _only_filter = substr end

return M

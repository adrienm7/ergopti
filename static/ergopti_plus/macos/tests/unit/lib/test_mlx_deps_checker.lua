--- tests/unit/lib/test_mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: mlx_deps_checker Regression Tests
--- DESCRIPTION:
--- Locks packaging-sensitive behavior for lib.mlx_deps_checker: script path
--- discovery in bundled layouts, shell quoting for PROJECT_ROOT/script path,
--- and failure callback fan-out on early task setup failures.
--- ============================================================================== 

local helpers = require("tests.helpers")




-- =========================================
-- =========================================
-- ======= 1/ Source-level invariants ======
-- =========================================
-- =========================================

local function read_source()
	local path = helpers.driver_root() .. "lib/mlx_deps_checker.lua"
	local fh = io.open(path, "r")
	if not fh then return "" end
	local body = fh:read("*a") or ""
	fh:close()
	return body
end

local SOURCE = read_source()

helpers.describe("mlx_deps_checker source invariants", function()
	helpers.it("imports lib.paths for fallback discovery", function()
		helpers.assert_true(SOURCE:find("local Paths        = require(\"lib.paths\")", 1, true) ~= nil)
	end)

	helpers.it("defines resolve_hs_root from current file location", function()
		helpers.assert_true(SOURCE:find("local function resolve_hs_root()", 1, true) ~= nil)
		helpers.assert_true(SOURCE:find("/lib/mlx_deps_checker%.lua$", 1, true) ~= nil)
	end)

	helpers.it("defines bootstrap-script resolver with upward fallback", function()
		helpers.assert_true(SOURCE:find("local function resolve_bootstrap_script_path()", 1, true) ~= nil)
		helpers.assert_true(
			SOURCE:find("Paths.find_from_configdir(\"modules/llm/ensure-mlx-deps.sh\", 12)", 1, true) ~= nil
		)
	end)

	helpers.it("defines shell_quote helper with apostrophe escaping", function()
		helpers.assert_true(SOURCE:find("local function shell_quote(value)", 1, true) ~= nil)
		helpers.assert_true(SOURCE:find("return \"'\" .. s:gsub(\"'\", \"'\\\\''\") .. \"'\"", 1, true) ~= nil)
	end)

	helpers.it("uses resolver output instead of hardcoded static root", function()
		helpers.assert_true(SOURCE:find("local script_path = resolve_bootstrap_script_path()", 1, true) ~= nil)
		helpers.assert_true(SOURCE:find("Project root introuvable depuis mlx_deps_checker.lua", 1, true) == nil)
	end)

	helpers.it("derives hs_root from resolved ensure-mlx-deps.sh path", function()
		helpers.assert_true(
			SOURCE:find("script_path:match(\"^(.*)/modules/llm/ensure%-mlx%-deps%.sh$\")", 1, true) ~= nil
		)
	end)

	helpers.it("quotes PROJECT_ROOT and script path in bash command", function()
		helpers.assert_true(SOURCE:find("PROJECT_ROOT=\" .. shell_quote(hs_root)", 1, true) ~= nil)
		helpers.assert_true(SOURCE:find("/bin/bash \" .. shell_quote(script_path)", 1, true) ~= nil)
	end)

	helpers.it("surfaces path-resolution failure with new message", function()
		helpers.assert_true(
			SOURCE:find("Unable to resolve ensure-mlx-deps.sh from current runtime paths", 1, true) ~= nil
		)
		helpers.assert_true(SOURCE:find("ensure-mlx-deps.sh introuvable.", 1, true) ~= nil)
	end)

	helpers.it("fires queued callbacks when PTY wrapper cannot be created", function()
		local marker = "_last_failure_message = i18n.get(\"mlx.deps_pty_write_failed\")"
		local at = SOURCE:find(marker, 1, true)
		helpers.assert_true(at ~= nil)
		local tail = SOURCE:sub(at, at + 220)
		helpers.assert_true(tail:find("fire_pending_callbacks(false)", 1, true) ~= nil)
	end)

	helpers.it("fires queued callbacks when hs.task creation fails", function()
		local marker = "_last_failure_message = i18n.get(\"mlx.deps_task_create_failed\")"
		local at = SOURCE:find(marker, 1, true)
		helpers.assert_true(at ~= nil)
		local tail = SOURCE:sub(at, at + 260)
		helpers.assert_true(tail:find("fire_pending_callbacks(false)", 1, true) ~= nil)
	end)
end)




-- ====================================
-- ====================================
-- ======= 2/ Public API contract =====
-- ====================================
-- ====================================

helpers.describe("mlx_deps_checker public API", function()
	local original_logger = package.loaded["lib.logger"]
	local original_window = package.loaded["ui.download_window"]
	local original_paths = package.loaded["lib.paths"]
	local original_checker = package.loaded["lib.mlx_deps_checker"]

	local calls = {
		start = 0,
		debug = 0,
		info = 0,
		warn = 0,
		error = 0,
		success = 0,
	}

	package.loaded["lib.logger"] = {
		UNIFIED_LOG_FILE = "/tmp/ergopti_test.log",
		start = function() calls.start = calls.start + 1 end,
		debug = function() calls.debug = calls.debug + 1 end,
		info = function() calls.info = calls.info + 1 end,
		warn = function() calls.warn = calls.warn + 1 end,
		error = function() calls.error = calls.error + 1 end,
		success = function() calls.success = calls.success + 1 end,
	}

	package.loaded["ui.download_window"] = {
		show = function() end,
		hide = function() end,
		set_step = function() end,
		set_progress = function() end,
		set_error = function() end,
		set_detail = function() end,
		append_log = function() end,
		is_active = function() return false end,
	}

	package.loaded["lib.paths"] = {
		find_from_configdir = function() return nil end,
	}

	package.loaded["lib.mlx_deps_checker"] = nil
	local checker = helpers.load_with_stubs("lib.mlx_deps_checker")

	helpers.it("exposes the expected state accessors", function()
		helpers.assert_eq(type(checker.get_state), "function")
		helpers.assert_eq(type(checker.is_ready), "function")
		helpers.assert_eq(type(checker.is_pending), "function")
		helpers.assert_eq(type(checker.has_failed), "function")
		helpers.assert_eq(type(checker.get_failure_message), "function")
		helpers.assert_eq(type(checker.check_and_install_deps), "function")
	end)

	helpers.it("starts in pending state", function()
		helpers.assert_eq(checker.get_state(), "pending")
		helpers.assert_eq(checker.is_pending(), true)
		helpers.assert_eq(checker.is_ready(), false)
		helpers.assert_eq(checker.has_failed(), false)
		helpers.assert_eq(checker.get_failure_message(), nil)
	end)

	package.loaded["lib.logger"] = original_logger
	package.loaded["ui.download_window"] = original_window
	package.loaded["lib.paths"] = original_paths
	package.loaded["lib.mlx_deps_checker"] = original_checker
end)

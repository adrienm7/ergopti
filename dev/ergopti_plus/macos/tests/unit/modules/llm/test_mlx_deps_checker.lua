--- tests/unit/modules/llm/test_mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: mlx_deps_checker Regression Tests
--- DESCRIPTION:
--- Locks packaging-sensitive behavior for modules.llm.mlx_deps_checker: script path
--- discovery in bundled layouts, shell quoting for PROJECT_ROOT/script path,
--- and failure callback fan-out on early task setup failures.
--- ============================================================================== 

local helpers = require("tests.helpers")





--- ==========================================
--- ==========================================
--- ======= 1/ Source-level invariants =======
--- ==========================================
--- ==========================================

-- Selected by a declaration unique to modules/llm/mlx_deps_checker.lua rather
-- than by path, so moving or splitting the module cannot turn these invariants
-- into a path error. The old form returned "" on a missing file, which made
-- every assertion below pass against an empty string.
local SOURCE = helpers.read_driver_source("local function resolve_bootstrap_script_path")
helpers.assert_true(SOURCE ~= nil, "modules/llm/mlx_deps_checker.lua source must be locatable")

helpers.describe("mlx_deps_checker source invariants", function()
	helpers.it("imports lib.paths for fallback discovery", function()
		helpers.assert_true(SOURCE:find("local Paths        = require(\"infra.paths\")", 1, true) ~= nil)
	end)

	helpers.it("defines resolve_hs_root from current file location", function()
		helpers.assert_true(SOURCE:find("local function resolve_hs_root()", 1, true) ~= nil)
		helpers.assert_true(SOURCE:find("/modules/llm/mlx_deps_checker%.lua$", 1, true) ~= nil)
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
		helpers.assert_true(SOURCE:find(
			"return settle_preflight_failure(i18n.get(\"mlx.deps_pty_write_failed\"))",
			1, true) ~= nil)
		helpers.assert_true(SOURCE:find(
			"fire_pending_callbacks(false, _pause_controller.is_admitted)",
			1, true) ~= nil)
	end)

	helpers.it("fires queued callbacks when hs.task creation fails", function()
		helpers.assert_true(SOURCE:find(
			"return settle_preflight_failure(i18n.get(\"mlx.deps_task_create_failed\"))",
			1, true) ~= nil)
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 4/ Native Task Start Contract =====================
-- ===========================================================
-- ===========================================================

helpers.describe("mlx_deps_checker: refused native launch settles immediately", function()
	helpers.it("treats task:start() false as terminal failure (mlx-deps-false-start)", function()
		package.loaded["infra.paths"] = {
			find_from_configdir = function() return nil end,
		}
		package.loaded["ui.download_window"] = {
			show = function() end, hide = function() end, set_step = function() end,
			set_progress = function() end, set_error = function() end,
			set_detail = function() end, append_log = function() end,
			is_active = function() return false end,
		}

		local checker = helpers.load_with_stubs("modules.llm.mlx_deps_checker", {
			task = {
				new = function(_, completion)
					local task = {}
					function task:start() return false end
					function task:terminate()
						completion(143, "", "start refused")
						return self
					end
					return task
				end,
			},
		})
		local settled = "not called"
		checker.check_and_install_deps(function(ok) settled = ok end)

		helpers.assert_eq(false, settled,
			"a refused launch has no completion callback, so pending callers must be "
				.. "settled synchronously instead of waiting forever")
		helpers.assert_eq("failed", checker.get_state(),
			"the public state must describe the refused launch")
	end)
end)





--- ======================================
--- ======================================
--- ======= 2/ Public API contract =======
--- ======================================
--- ======================================

helpers.describe("mlx_deps_checker public API", function()
	local original_logger = package.loaded["infra.logger"]
	local original_window = package.loaded["ui.download_window"]
	local original_paths = package.loaded["infra.paths"]
	local original_checker = package.loaded["modules.llm.mlx_deps_checker"]

	local calls = {
		start = 0,
		debug = 0,
		info = 0,
		warn = 0,
		error = 0,
		success = 0,
	}

	package.loaded["infra.logger"] = {
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

	package.loaded["infra.paths"] = {
		find_from_configdir = function() return nil end,
	}

	package.loaded["modules.llm.mlx_deps_checker"] = nil
	local checker = helpers.load_with_stubs("modules.llm.mlx_deps_checker")

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

	helpers.it("exposes reset_bootstrap_state", function()
		helpers.assert_eq(type(checker.reset_bootstrap_state), "function")
	end)

	helpers.it("reset_bootstrap_state() returns false when not in the failed state", function()
		helpers.assert_eq(checker.get_state(), "pending")
		helpers.assert_eq(checker.reset_bootstrap_state(), false,
			"resetting a non-failed state must be a no-op")
		helpers.assert_eq(checker.get_state(), "pending")
	end)

	package.loaded["infra.logger"] = original_logger
	package.loaded["ui.download_window"] = original_window
	package.loaded["infra.paths"] = original_paths
	package.loaded["modules.llm.mlx_deps_checker"] = original_checker
end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ reset_bootstrap_state() escapes the "failed" dead end (F-LOW-10) =
-- ============================================================================
-- ============================================================================

-- F-LOW-10: once "failed", check_and_install_deps() used to short-circuit
-- FOREVER with no way back to "pending" — a transient (now-resolved) failure
-- required a full Hammerspoon reload to recover from. These tests drive the
-- real module with hs.task.new stubbed to CAPTURE (not fire) its completion
-- callback, so the test controls exactly when the "bootstrap subprocess"
-- reports a failure — deterministic without touching the real filesystem or
-- spawning a real PTY-wrapped bash/python process.
helpers.describe("mlx_deps_checker: reset_bootstrap_state escapes the failed dead end (F-LOW-10)", function()

	--- Loads a fresh mlx_deps_checker with hs.task.new stubbed to capture its
	--- completion callback, and lib.paths/ui.download_window stubbed minimally
	--- so the module loads and runs without touching the real filesystem.
	--- @return table checker, function fire_with_exit_code (fires the LAST captured completion callback)
	local function load_fresh_checker()
		local captured_cbs = {}
		local hs_overrides = {
			task = {
				new = function(_exe, cb, _args)
					captured_cbs[#captured_cbs + 1] = cb
					return {
						start     = function() return true end,
						terminate = function() end,
						setStreamingCallback = function() end,
					}
				end,
			},
		}

		package.loaded["infra.paths"] = {
			find_from_configdir = function() return nil end,
		}
		package.loaded["ui.download_window"] = {
			show = function() end, hide = function() end, set_step = function() end,
			set_progress = function() end, set_error = function() end, set_detail = function() end,
			append_log = function() end, is_active = function() return false end,
		}

		-- task_lifecycle captures the current global hs table at require time.
		-- The refused-start test above intentionally loaded it against a task
		-- stub that always returns false, so a cached adapter would make every
		-- later "fresh" checker inherit that unrelated native result.
		package.loaded["adapters.task_lifecycle"] = nil
		package.loaded["modules.llm.mlx_deps_checker"] = nil
		local checker = helpers.load_with_stubs("modules.llm.mlx_deps_checker", hs_overrides)

		local function fire_with_exit_code(exit_code)
			local cb = captured_cbs[#captured_cbs]
			if cb then cb(exit_code, "", "boom: dependency install failed") end
		end

		return checker, fire_with_exit_code
	end

	helpers.it("check_and_install_deps() permanently dead-ends without reset_bootstrap_state (pre-fix behaviour)", function()
		local checker, fire_with_exit_code = load_fresh_checker()

		checker.check_and_install_deps()
		fire_with_exit_code(1)
		helpers.assert_eq(checker.get_state(), "failed", "a non-zero exit code must flip state to failed")

		-- Without calling reset_bootstrap_state(), a second attempt still
		-- short-circuits immediately to on_complete(false) — the dead end
		-- F-LOW-10 describes.
		local completed_with = "not called"
		checker.check_and_install_deps(function(ok) completed_with = ok end)
		helpers.assert_eq(completed_with, false,
			"check_and_install_deps() must still short-circuit to false while state remains failed")
		helpers.assert_eq(checker.get_state(), "failed", "state must remain failed without an explicit reset")
	end)

	helpers.it("reset_bootstrap_state() clears the failed state so retry can proceed", function()
		local checker, fire_with_exit_code = load_fresh_checker()

		checker.check_and_install_deps()
		fire_with_exit_code(1)
		helpers.assert_eq(checker.get_state(), "failed", "precondition: module must be in the failed state")

		local reset_ok = checker.reset_bootstrap_state()
		helpers.assert_eq(reset_ok, true, "reset_bootstrap_state() must report success when transitioning out of failed")
		helpers.assert_eq(checker.get_state(), "pending", "state must be back to pending after reset")
		helpers.assert_eq(checker.get_failure_message(), nil, "the stale failure message must be cleared on reset")

		-- The NEXT check_and_install_deps() call must actually attempt the
		-- bootstrap again (dispatch a new hs.task) rather than short-circuiting
		-- on a stale cached "failed" state.
		local completed_with = "not called"
		checker.check_and_install_deps(function(ok) completed_with = ok end)
		helpers.assert_eq(completed_with, "not called",
			"a fresh attempt after reset must actually dispatch a new bootstrap task (async), not short-circuit synchronously")
	end)

	helpers.it("reset_bootstrap_state() is a no-op while a bootstrap task is running", function()
		local checker, _fire = load_fresh_checker()

		-- Force into failed, reset, then start a fresh attempt WITHOUT firing
		-- its completion — the module should now consider a task "running".
		checker.check_and_install_deps()
		_fire(1)
		checker.reset_bootstrap_state()
		checker.check_and_install_deps()  -- dispatches a new task; never fired

		local reset_ok = checker.reset_bootstrap_state()
		helpers.assert_eq(reset_ok, false,
			"reset_bootstrap_state() must not act while a bootstrap task is still in flight")
	end)
end)

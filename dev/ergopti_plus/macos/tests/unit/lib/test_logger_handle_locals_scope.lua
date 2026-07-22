--- tests/unit/lib/test_logger_handle_locals_scope.lua

--- ==============================================================================
--- MODULE: Logger — File-sink Locals Are Declared Above Their Users
--- DESCRIPTION:
--- Guards a live instance of the project's documented
--- `project-lua-closure-before-local-nil-global` foot-gun inside lib/logger.lua.
---
--- ROOT CAUSE ENCODED: `_file_handle`, `_last_log_date` and `_last_log_path` were
--- declared as top-level locals ~173 lines BELOW M.init_log_path(). In Lua a
--- `local` is only captured as an upvalue by code that appears lexically AFTER
--- it; code above it binds the GLOBAL of the same name instead. So
--- init_log_path()'s `if _file_handle then … end` block read a nil global, was
--- always false, and its three assignments wrote to globals — dead code that
--- looked alive. It was harmless only because _ensure_log_file() independently
--- re-checks `_last_log_path == M.UNIFIED_LOG_FILE`; the hazard is that the dead
--- block makes that check look redundant, and deleting it would leave the logger
--- writing to the pre-init path for the whole session.
---
--- WHY THIS TEST IS A SOURCE-ORDER TEST: the failure has no observable symptom
--- today. A behavioural test would be green either way, and a test that merely
--- greps that `local _file_handle` EXISTS would be green against the broken code
--- too — exactly the false-green PROJECT_MEMORY records for this bug class. The
--- only assertion that encodes the root cause is the relative ORDER of the
--- declaration and its first user.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Selected by a declaration unique to the logger rather than by path, so
-- splitting or moving the module cannot turn this invariant into a path error.
local src = helpers.read_driver_source("local _file_handle")
if not src then error("logger file-sink source not locatable via read_driver_source") end

helpers.describe("logger — file-sink locals are declared above every user", function()
	helpers.it("declares _file_handle before M.init_log_path, which mutates it", function()
		local decl_at = src:find("local _file_handle", 1, true)
		local user_at = src:find("function M.init_log_path", 1, true)

		helpers.assert_true(decl_at ~= nil, "lib/logger.lua must declare a local _file_handle")
		helpers.assert_true(user_at ~= nil, "lib/logger.lua must define M.init_log_path")
		helpers.assert_true(decl_at < user_at,
			"`local _file_handle` must appear BEFORE M.init_log_path — declared after it, the "
			.. "function's handle-close block binds a nil global and never runs "
			.. "(project_lua_closure_before_local_nil_global)")
	end)

	helpers.it("declares _last_log_date and _last_log_path before M.init_log_path", function()
		local user_at = src:find("function M.init_log_path", 1, true)
		local date_at = src:find("local _last_log_date", 1, true)
		local path_at = src:find("local _last_log_path", 1, true)

		helpers.assert_true(date_at ~= nil and date_at < user_at,
			"`local _last_log_date` must be declared before M.init_log_path, which assigns it")
		helpers.assert_true(path_at ~= nil and path_at < user_at,
			"`local _last_log_path` must be declared before M.init_log_path, which assigns it")
	end)

	helpers.it("declares _log before the functions that call it", function()
		-- Same class, same file: _purge_old_logs and init_log_path both log, and both
		-- are defined above the dispatcher's implementation.
		local decl_at  = src:find("local _log%f[^%w_]")
		local purge_at = src:find("function M._purge_old_logs", 1, true)
		local init_at  = src:find("function M.init_log_path", 1, true)

		helpers.assert_true(decl_at ~= nil,
			"lib/logger.lua must forward-declare `local _log` for the functions defined above it")
		helpers.assert_true(decl_at < init_at,
			"`local _log` must be declared before M.init_log_path, which logs the sub-file fallback")
		helpers.assert_true(decl_at < purge_at,
			"`local _log` must be declared before M._purge_old_logs, which warns on a skipped purge")
	end)
end)

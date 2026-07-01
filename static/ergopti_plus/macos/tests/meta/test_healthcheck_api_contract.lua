--- tests/meta/test_healthcheck_api_contract.lua

--- ==============================================================================
--- MODULE: Healthcheck Diagnostic API Contract
--- DESCRIPTION:
--- Pins every external module symbol that ui/healthcheck/helpers.lua's collectors
--- call, so a renamed or removed API fails CI here instead of silently degrading
--- the user-facing diagnostic.
---
--- WHY THIS EXISTS (regression for project-healthcheck-stale-api):
--- The diagnostic collectors probed functions that did not exist — log_manager
--- .get_paths(), aggregator.get_stats(), keylogger.privacy (whole module),
--- llm.get_state(), layout.is_ergopti_base(), key_state.get_altgr/get_shift/
--- get_caps(), terminators.count()/get_magic_key(). Each call is guarded with a
--- `type(x) ~= "function"` check that logs a WARNING and falls back, so nothing
--- crashed — but the diagnostic window showed "unknown"/"n/a" for almost every
--- runtime field and every boot logged a wall of "X is not a function" warnings.
--- The guards made the breakage invisible to a "does it crash?" test. This
--- contract makes the breakage visible: it asserts the REAL functions the
--- collectors now depend on actually exist on the real modules.
---
--- MAINTENANCE: when a collector in ui/healthcheck/helpers.lua starts calling a
--- new module function, add it here. Keep this list in lock-step with the collectors.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The exact external surface ui/healthcheck/helpers.lua's collectors rely on.
-- mod = require path; fns = functions that must exist; constants = fields read.
local CONTRACT = {
	{ mod = "lib.logger",                       constants = { "UNIFIED_LOG_FILE", "ERRORS_LOG_FILE" }, fns = { "ring_buffer_snapshot" } },
	{ mod = "modules.keylogger",                fns = { "get_live_stats" } },
	{ mod = "modules.llm.init",                 fns = { "get_runtime_llm_enabled", "get_backend", "get_active_profile" } },
	{ mod = "adapters.key_state",               fns = { "is_right_altgr_held", "isDown" } },
	{ mod = "modules.keymap.terminators",       fns = { "get_terminator_defs" } },
	{ mod = "modules.keymap",                   fns = { "get_trigger_char" } },
	{ mod = "modules.shortcuts.script_control", fns = { "is_paused" } },
}





-- ==========================================
-- ==========================================
-- ======= 1/ Per-module API contract =======
-- ==========================================
-- ==========================================

helpers.describe("meta: healthcheck diagnostic API contract", function()
	for _, entry in ipairs(CONTRACT) do
		helpers.it(string.format("%s exposes the symbols healthcheck calls", entry.mod), function()
			-- Build the hs/lib stub environment, then force a REAL require of the
			-- target module. load_with_stubs injects a minimal modules.llm.init
			-- stub and returns the requested module shadowed, so we clear the
			-- package cache for the exact module and require it directly.
			helpers.load_with_stubs("lib.logger")
			package.loaded[entry.mod] = nil
			local ok, mod = pcall(require, entry.mod)
			helpers.assert_true(ok and type(mod) == "table",
				string.format("require('%s') failed — healthcheck cannot read it: %s", entry.mod, tostring(mod)))

			for _, fn in ipairs(entry.fns or {}) do
				helpers.assert_true(type(mod[fn]) == "function",
					string.format("%s.%s must be a function — healthcheck calls it (stale diagnostic API)",
						entry.mod, fn))
			end
			for _, c in ipairs(entry.constants or {}) do
				helpers.assert_true(mod[c] ~= nil,
					string.format("%s.%s must be defined — healthcheck reads it (stale diagnostic API)",
						entry.mod, c))
			end
		end)
	end
end)




-- =================================================
-- =================================================
-- ======= 2/ End-to-end: run with no stale probe ==
-- =================================================
-- =================================================

helpers.describe("meta: healthcheck.run() probes no nonexistent API", function()
	-- Self-syncing companion to the contract above: actually run the collectors
	-- against the real modules and assert none logged a stale-API warning. Catches
	-- a broken probe even if someone forgets to update the CONTRACT list.
	helpers.load_with_stubs("lib.logger")
	-- Force the real llm module (load_with_stubs injects a DEFAULT_STATE-only stub).
	package.loaded["modules.llm.init"] = nil
	package.loaded["ui.healthcheck"] = nil
	package.loaded["ui.healthcheck.core"] = nil
	package.loaded["ui.healthcheck.helpers"] = nil

	local Logger = require("lib.logger")
	local stale_probes = {}
	local orig_warn = Logger.warn
	Logger.warn = function(log_obj, fmt, ...)
		local s = tostring(fmt)
		-- Collector probe failures read "<x> is not a function" or "<mod> unavailable".
		-- Exclude any mentioning a Hammerspoon API ("hs.…"): the headless test stub
		-- intentionally omits hs.processInfo / hs.screen / hs.host fields, so _sys_info
		-- legitimately warns about those — that is a stub limitation, not a driver-API
		-- bug. We only care about DRIVER-MODULE symbols here.
		if (s:find("is not a function", 1, true) or s:find("unavailable", 1, true))
			and not s:find("hs%.") then
			stale_probes[#stale_probes + 1] = s
		end
		return orig_warn(log_obj, fmt, ...)
	end

	local ok_run, snap = pcall(function()
		return require("ui.healthcheck").run()
	end)
	Logger.warn = orig_warn

	helpers.it("healthcheck.run() returns a snapshot", function()
		helpers.assert_true(ok_run and type(snap) == "table",
			"healthcheck.run() must succeed: " .. tostring(snap))
	end)

	helpers.it("no collector references a renamed/removed module API", function()
		helpers.assert_true(#stale_probes == 0,
			"healthcheck collectors probe APIs that don't exist (diagnostic shows 'unknown'/'n/a' "
				.. "and warns every boot): " .. table.concat(stale_probes, " | "))
	end)
end)

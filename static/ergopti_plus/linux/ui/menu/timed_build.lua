--- ui/menu/timed_build.lua

--- ==============================================================================
--- MODULE: Timed Tray Menu Build (Linux)
--- DESCRIPTION:
--- Runs the menu builder on one context and records the `menu.rebuild` phase,
--- the phase the macOS driver records for the same work, so the phase summary
--- shows what a tray rebuild costs on both systems. Each rebuild also writes
--- the macOS line ("Menu tree rebuilt in N ms ...") and is judged against
--- [budgets] menu_rebuild_ms (_shared/lua/perf_budget.lua), so
--- tools/dev/field-log-analyse.py judges both drivers with one pattern. The
--- builder itself stays untouched: its tests read it as the real tray builder.
--- ==============================================================================

local Logger     = require("logger.shim")
local PhaseStats = require("infra.phase_stats")

local LOG = "ui.menu.timed_build"

local M = {}

--- Builds the menu tree and records its duration. A raised error propagates
--- unchanged and records nothing.
--- @param build function The menu builder (ui.menu.builder.build).
--- @param ctx table Menu context.
--- @return table items The tree the builder returned.
function M.run(build, ctx)
	local started = PhaseStats.now()
	local items = build(ctx)
	local elapsed_ms = PhaseStats.stop("menu.rebuild", started)
	Logger.info(LOG, "Menu tree rebuilt in %.1f ms (%d top-level item(s)).", elapsed_ms,
		type(items) == "table" and #items or 0)
	require("perf_budget").judge(Logger, LOG, "menu.rebuild", elapsed_ms,
		function() return require("infra.timings").ms("budgets", "menu_rebuild_ms") end)
	return items
end

return M

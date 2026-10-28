--- ui/menu/timed_build.lua

--- ==============================================================================
--- MODULE: Timed Tray Menu Build (Linux)
--- DESCRIPTION:
--- Runs the menu builder on one context and records the `menu.rebuild` phase,
--- the phase the macOS driver records for the same work, so the phase summary
--- shows what a tray rebuild costs on both systems. The builder itself stays
--- untouched: its tests read it as the real tray builder.
--- ==============================================================================

local PhaseStats = require("infra.phase_stats")

local M = {}

--- Builds the menu tree and records its duration. A raised error propagates
--- unchanged and records nothing.
--- @param build function The menu builder (ui.menu.menu_builder.build).
--- @param ctx table Menu context.
--- @return table items The tree the builder returned.
function M.run(build, ctx)
	local started = PhaseStats.now()
	local items = build(ctx)
	PhaseStats.stop("menu.rebuild", started)
	return items
end

return M

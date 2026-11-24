--- menu/ui/builder/suspend.lua

--- ==============================================================================
--- MODULE: Linux Menu Suspend Row
--- DESCRIPTION:
--- Builds the tray's « Suspendre » row, the one Windows and macOS show right
--- before Reload (maintainer, 2026-11-24): ticked while the daemon is paused, a
--- click pauses or resumes it through ctx.on_toggle_pause. The paused header
--- row keeps resuming too.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ok_mm, ManifestMenu = pcall(require, "menu.engine.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "menu.ui.builder.suspend"

--- Builds the suspend item.
--- @param ctx table Menu context: paused (boolean), on_toggle_pause (function).
--- @return table|nil row Provider row data, nil when the declaration is refused.
local function _build_suspend(ctx)
	if not ManifestMenu then
		Logger.error(LOG, "Manifest renderer unavailable — the Suspendre row is not drawn.")
		return nil
	end
	return ManifestMenu.check_row("top_level", "suspend", {
		suspend = function()
			if type(ctx.on_toggle_pause) ~= "function" then
				Logger.error(LOG, "Pause requested but ctx.on_toggle_pause is absent — nothing paused.")
				return false
			end
			Logger.info(LOG, "Pause toggle requested from the tray menu…")
			return ctx.on_toggle_pause()
		end,
	}, { script_paused = function() return ctx.paused == true end })
end

M.build = _build_suspend

return M

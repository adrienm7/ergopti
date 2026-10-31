--- ui/menu/menu_quit.lua

--- ==============================================================================
--- MODULE: Linux Menu Quit Row
--- DESCRIPTION:
--- Builds the tray's Quit row. The root (ui/menu/builder.lua) holds it
--- back and appends it last, after the manifest's declared order.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_quit"

--- Builds the quit item.
--- @param ctx table Menu context; on_quit is the daemon's quit request.
--- @return table|nil The declared Quit row.
local function _build_quit(ctx)
	return ManifestMenu.command_row("top_level", "quit", {
		quit = function()
			Logger.info(LOG, "Quit requested via tray menu.")
			if not ctx.on_quit then return end
			-- Only an explicit false is a refusal: the owner answers false for the
			-- causes of the shared quit admission (infra/quit_request.lua), as the
			-- macOS menu does, and the user is told with the one notice.
			if ctx.on_quit() == false then
				require("ui.menu.feature_notice").quit_refused(i18n_safe)
			end
		end,
	})
end

M.build = _build_quit

return M

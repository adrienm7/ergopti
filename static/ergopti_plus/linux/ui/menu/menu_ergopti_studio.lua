--- ui/menu/menu_ergopti_studio.lua

--- ==============================================================================
--- MODULE: Linux Menu Ergopti Studio Row
--- DESCRIPTION:
--- Builds the tray's top-level « Ergopti Studio » row. It opens the layout
--- editor window (ui/layout_manager/bridge.lua), the same window as the layout
--- submenu's « Create or edit a layout… » row, through the menu context's
--- webview manager.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_ergopti_studio"

--- Builds the Ergopti Studio row.
--- @param ctx table The menu context; `ctx.webview` is the webview manager.
--- @return table|nil The declared command row, or nil when the manifest refuses it.
local function _build_ergopti_studio(ctx)
	if not ManifestMenu then
		Logger.error(LOG, "The menu manifest is unavailable — the Ergopti Studio row is not drawn.")
		return nil
	end
	local command = require("settings.engine.keys").COMMAND.ERGOPTI_STUDIO
	return ManifestMenu.command_row("top_level", command, {
		[command] = function()
			-- Loudly, not silently: a row that cannot open its window must say so.
			if type(ctx) ~= "table" or type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager in the menu context — Ergopti Studio cannot open.")
				return false
			end
			return require("ui.layout_manager.bridge").open_editor_window(ctx.webview)
		end,
	})
end

M.build = _build_ergopti_studio

return M

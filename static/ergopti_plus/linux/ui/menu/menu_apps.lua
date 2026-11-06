--- ui/menu/menu_apps.lua

--- ==============================================================================
--- MODULE: Linux Menu Applications Submenu
--- DESCRIPTION:
--- Builds the tray's Applications submenu: one row per bundled app (App Cloner,
--- Encryptor), the same two apps macOS ships next to its driver. The rows and
--- the launch are ui/bundled_apps.lua's; this part renders them through the
--- manifest's apps_menu.
--- ==============================================================================

local M = {}

local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

--- Builds the Applications submenu.
--- @return table|nil row
local function _build_apps()
	if not ManifestMenu then return nil end
	local admitted = ManifestMenu.template_rows("apps_menu", {}, {}, {
		["apps_installed"] = function() return require("ui.bundled_apps").rows() end,
	})
	if not admitted then return nil end
	local rows = ManifestMenu.render_rows(admitted, "apps_menu")
	return ManifestMenu.group_row("top_level", "apps", rows, {})
end

M.build = _build_apps

return M

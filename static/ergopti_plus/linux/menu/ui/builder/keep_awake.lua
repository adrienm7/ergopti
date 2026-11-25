--- menu/ui/builder/keep_awake.lua

--- ==============================================================================
--- MODULE: Linux Menu « Anti-veille » Submenu
--- DESCRIPTION:
--- Builds the tray's « Anti-veille » submenu: the presets list and the active
--- preset's options list are modules/auto_click.lua's row providers; this part
--- renders them through the manifest's keep_awake_menu.
--- ==============================================================================

local M = {}

local ok_mm, ManifestMenu = pcall(require, "menu.engine.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

--- Builds the « Anti-veille » submenu.
--- @return table|nil row
local function _build_keep_awake()
	if not ManifestMenu then return nil end
	local admitted = ManifestMenu.template_rows("keep_awake_menu", {}, {}, {
		["keep_awake_presets"] = function() return require("modules.auto_click").preset_rows() end,
		["keep_awake_options"] = function() return require("modules.auto_click").option_rows() end,
	})
	if not admitted then return nil end
	local rows = ManifestMenu.render_rows(admitted, "keep_awake_menu")
	return ManifestMenu.group_row("top_level", "keep_awake", rows, {})
end

M.build = _build_keep_awake

return M

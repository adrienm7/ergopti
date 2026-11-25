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
	local AutoClick = require("modules.auto_click")
	local commands = {
		keep_awake_switch = function() return AutoClick.toggle_switch("keep_awake") end,
		keep_awake_auto_click = function() return AutoClick.toggle_switch("auto_click") end,
		keep_awake_library = function() return require("ui.keep_awake_library_bridge").open() end,
	}
	local getters = {
		keep_awake_switch_on = function() return AutoClick.switch_on("keep_awake") end,
		keep_awake_auto_click_on = function() return AutoClick.switch_on("auto_click") end,
		keep_awake_auto_click_available = function() return AutoClick.auto_click_available() end,
	}
	local admitted = ManifestMenu.template_rows("keep_awake_menu", commands, getters, {
		["keep_awake_presets"] = function() return AutoClick.preset_rows() end,
		["keep_awake_status"] = function() return AutoClick.status_rows() end,
	})
	if not admitted then return nil end
	local rows = ManifestMenu.render_rows(admitted, "keep_awake_menu")
	return ManifestMenu.group_row("top_level", "keep_awake", rows, getters)
end

M.build = _build_keep_awake

return M

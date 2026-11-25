--- menu/ui/builder/keep_awake.lua

--- ==============================================================================
--- MODULE: macOS Menu « Anti-veille » Submenu
--- DESCRIPTION:
--- Builds the menu-bar « Anti-veille » submenu: the presets list and the active
--- preset's options list are modules/shortcuts/actions/auto_click.lua's row
--- providers; this part renders them through the manifest's keep_awake_menu.
--- ==============================================================================

local M = {}

--- Builds the « Anti-veille » submenu row.
--- @return table|nil row
function M.build()
	-- Required at build time: loading the renderer with the menu module would
	-- create it before i18n is ready.
	local ManifestMenu = require("menu.engine.manifest_menu")
	local Mode = require("modules.shortcuts.actions.auto_click")
	local commands = {
		keep_awake_switch = function() return Mode.toggle_switch("keep_awake") end,
		keep_awake_auto_click = function() return Mode.toggle_switch("auto_click") end,
		keep_awake_library = function() return require("menu.ui.keep_awake_library").open() end,
	}
	local getters = {
		keep_awake_switch_on = function() return Mode.switch_on("keep_awake") end,
		keep_awake_auto_click_on = function() return Mode.switch_on("auto_click") end,
		keep_awake_auto_click_available = function() return Mode.auto_click_available() end,
	}
	local admitted = ManifestMenu.template_rows("keep_awake_menu", commands, getters, {
		["keep_awake_presets"] = function() return Mode.preset_rows() end,
		["keep_awake_status"] = function() return Mode.status_rows() end,
	})
	if not admitted then return nil end
	local rendered = ManifestMenu.render_rows(admitted, "keep_awake_menu")
	return ManifestMenu.group_row("top_level", "keep_awake", rendered, getters)
end

return M

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
	local admitted = ManifestMenu.template_rows("keep_awake_menu", {}, {}, {
		["keep_awake_presets"] = function() return Mode.preset_rows() end,
		["keep_awake_options"] = function() return Mode.option_rows() end,
	})
	if not admitted then return nil end
	local rendered = ManifestMenu.render_rows(admitted, "keep_awake_menu")
	return ManifestMenu.group_row("top_level", "keep_awake", rendered, {})
end

return M

--- ui/menu/menu_language.lua

--- ==============================================================================
--- MODULE: Linux Menu Language Submenu
--- DESCRIPTION:
--- Builds the tray's language submenu: one checked row per shipped locale, the
--- active one ticked; a click switches the locale through infra/i18n, which
--- persists it.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_language"

--- Builds the language selector submenu.
--- Lists all available locales, marks the active one with a checkmark.
--- Switching persists via i18n.set_locale() → storage adapter.
local function _build_language(ctx)
	local items = {}

	-- Try to load i18n for real locale list + switching.
	local i18n = nil
	local ok_i18n, i18n_mod = pcall(require, "infra.i18n")
	if ok_i18n then i18n = i18n_mod end

	if i18n then
		local active = i18n.get_locale()
		local locales = i18n.list_locales()
		if type(locales) ~= "table" or getmetatable(locales) ~= nil then return nil end
		local count, maximum = 0, 0
		for index, code in next, locales do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1
				or type(code) ~= "string" or code == "" then return nil end
			count, maximum = count + 1, math.max(maximum, index)
		end
		if count ~= maximum then return nil end
		for _, code in ipairs(locales) do
			local cap = code  -- capture for closure
			items[#items + 1] = {
				-- Provider data, and the tick is the tray's own check item rather
				-- than a "✓" glued to the label — that glued form put one platform's
				-- convention inside a string twenty other languages also read.
				label   = i18n.display_name(code) .. " (" .. code .. ")",
				checked = code == active,
				action  = function()
					local committed = i18n.set_locale(cap)
					-- GTK toggles before dispatch; a refused write still needs the
					-- authoritative locale image to restore its current check.
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return committed
				end,
			}
		end
	else
		-- No i18n module: two hardcoded names is a hand-written enumeration of a
		-- list the shared catalogue owns, and it logged instead of switching. A
		-- driver that cannot read its locales says so.
		Logger.error(LOG, "i18n unavailable — the language menu has no locale to offer.")
		return nil
	end

	local admitted = ManifestMenu
		and ManifestMenu.template_rows("language_menu", {}, {}, {
			["locales"] = function() return items end,
		})
	if not admitted then return nil end
	local rows = ManifestMenu.render_rows(admitted, "language_menu")
	return ManifestMenu.group_row("top_level", "language", rows, {})
end

M.build = _build_language

return M

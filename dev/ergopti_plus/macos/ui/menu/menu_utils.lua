--- ui/menu/menu_utils.lua

--- ==============================================================================
--- MODULE: Menu Utils
--- DESCRIPTION:
--- Shared helpers for building macOS menubar items in Ergopti submenus.
---
--- FEATURES & RATIONALE:
--- 1. build_section_header provides a uniform disabled separator label.
---
--- IT RETURNS A PROVIDER ROW — `label`, `disabled` — never the hs.menubar
--- shape. Every caller feeds the result into an `items` array that the shared
--- renderer materialises, and it returned `title` until 2026-08-07: a row with
--- no `label` is dropped, so the mod-combo list lost every category header
--- without a word.
--- ==============================================================================

local M = {}
local i18n = require("infra.i18n")
local RowDialect = require("menu.row_dialect")

--- Builds a disabled section header formatted as "— Label —".
--- @param label string The section label (already localized).
--- @return table Single disabled provider row.
function M.build_section_header(label)
	return { label = i18n.decorate_section(label), disabled = true }
end

--- Turns an hs.menubar row into the shape a manifest `list` provider returns.
---
--- The two differ on purpose: a row is `{title, fn, menu}` because that is what
--- hs.menubar consumes, and a provider hands over `{label, action, items}`
--- because it must not know what an hs.menubar is. This adapter exists for the
--- rows a builder ALREADY produces in the first shape — deep trees like the
--- Karabiner tap-hold pickers, which have their own recursion and are not worth
--- rewriting to move a menu onto the renderer.
---
--- Recursive, because those trees nest: an unconverted child would reach the
--- renderer as a row with no label and be dropped with a warning.
--- @param row table An hs.menubar-shaped row.
--- @return table The same row as provider data.
function M.as_provider_row(row)
	if type(row) ~= "table" then return row end
	return RowDialect.row(row)
end

--- Converts a whole hs.menubar subtree to provider rows.
--- @param menu table Array of hs.menubar-shaped rows.
--- @return table
function M.rows_from_menu(menu)
	return RowDialect.rows(menu)
end

return M

--- ui/menu/menu_utils.lua

--- ==============================================================================
--- MODULE: Menu Utils
--- DESCRIPTION:
--- Shared helpers for building macOS menubar items in Ergopti submenus.
---
--- FEATURES & RATIONALE:
--- 1. build_section_header provides a uniform disabled separator label.
--- 2. build_action_picker groups a catalogue of actions under those headers.
---
--- BOTH RETURN PROVIDER ROWS — `label`, `action`, `checked` — never the
--- hs.menubar shape. Every caller feeds the result into an `items` array that
--- the shared renderer materialises, and they returned `title`/`fn` until
--- 2026-08-07: a row with no `label` is dropped, so the Karabiner tap and hold
--- pickers showed their two ungrouped « Spécial » entries and NOTHING else, and
--- the mod-combo list lost every category header. Both were silent.
--- ==============================================================================

local M = {}
local i18n = require("infra.i18n")

--- Builds a disabled section header formatted as "— Label —".
--- @param label string The section label (already localized).
--- @return table Single disabled provider row.
function M.build_section_header(label)
	return { label = i18n.decorate_section(label), disabled = true }
end

--- Builds a filtered and grouped picker submenu for a list of named actions.
--- @param actions table List of { id, label, category, holdable?, tappable? }.
--- @param current_id string Currently selected action id.
--- @param on_select function Callback receiving the selected action id.
--- @param filter function|nil Optional predicate (action) -> bool to exclude items.
--- @return table List of provider rows with category headers and checkmarks.
function M.build_action_picker(actions, current_id, on_select, filter)
	local items = {}
	local current_category = nil
	for _, action in ipairs(actions) do
		if filter and not filter(action) then goto continue end
		if action.category ~= current_category then
			current_category = action.category
			items[#items + 1] = M.build_section_header(action.category)
		end
		local aid = action.id
		items[#items + 1] = {
			label   = action.label,
			checked = (aid == current_id),
			action  = function() on_select(aid) end,
		}
		::continue::
	end
	return items
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
	if row.title == "-" then return { separator = true } end

	local out = { label = row.title, disabled = row.disabled }
	if row.checked ~= nil then out.checked = row.checked and true or false end
	if type(row.menu) == "table" then
		local items = {}
		for index, child in ipairs(row.menu) do items[index] = M.as_provider_row(child) end
		out.items = items
	elseif type(row.fn) == "function" then
		out.action = row.fn
	end
	return out
end

--- Converts a whole hs.menubar subtree to provider rows.
--- @param menu table Array of hs.menubar-shaped rows.
--- @return table
function M.rows_from_menu(menu)
	local out = {}
	for index, row in ipairs(menu or {}) do out[index] = M.as_provider_row(row) end
	return out
end

return M

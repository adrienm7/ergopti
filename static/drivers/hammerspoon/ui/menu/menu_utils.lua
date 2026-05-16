--- ui/menu/menu_utils.lua

--- ==============================================================================
--- MODULE: Menu Utils
--- DESCRIPTION:
--- Shared helpers for building macOS menubar items in Ergopti submenus.
---
--- FEATURES & RATIONALE:
--- 1. build_category_toggle mirrors AHK's AddCategoryToggleItem so both
---    platforms produce structurally identical on/off patterns at the top
---    of every category submenu.
--- 2. build_section_header provides a uniform disabled separator label.
--- ==============================================================================

local M = {}

--- Builds the canonical ✅/❌ category toggle item followed by a separator.
--- Mirrors AHK's AddCategoryToggleItem — keeps both platforms structurally identical.
--- @param on_label string Label displayed when the category is enabled.
--- @param off_label string Label displayed when the category is disabled.
--- @param is_enabled boolean Current enabled state.
--- @param on_click function Callback invoked on click.
--- @return table Two-item list: { toggle_item, separator }.
function M.build_category_toggle(on_label, off_label, is_enabled, on_click)
	return {
		{ title = is_enabled and on_label or off_label, fn = on_click },
		{ title = "-" },
	}
end

--- Builds a disabled section header formatted as "— Label —".
--- @param label string The section label (already localized).
--- @return table Single disabled menu item.
function M.build_section_header(label)
	return { title = "— " .. label .. " —", disabled = true }
end

--- Builds a filtered and grouped picker submenu for a list of named actions.
--- @param actions table List of { id, label, category, holdable?, tappable? }.
--- @param current_id string Currently selected action id.
--- @param on_select function Callback receiving the selected action id.
--- @param filter function|nil Optional predicate (action) -> bool to exclude items.
--- @return table List of hs.menubar items with category headers and checkmarks.
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
			title   = action.label,
			checked = (aid == current_id),
			fn      = function() on_select(aid) end,
		}
		::continue::
	end
	return items
end

return M

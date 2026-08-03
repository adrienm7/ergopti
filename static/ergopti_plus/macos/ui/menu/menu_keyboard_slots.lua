--- ui/menu/menu_keyboard_slots.lua

--- ==============================================================================
--- MODULE: Menu Keyboard Slots
--- DESCRIPTION:
--- Renders the configurable keyboard-shortcut groups in the Shortcuts submenu:
--- one submenu per modifier group, listing every slot the user has assigned, plus
--- a row that offers the unassigned ones.
---
--- The module underneath (modules/shortcuts/keyboard_shortcuts.lua) has always
--- bound, persisted and released these shortcuts; what it never had was a way to
--- create one. Its whole configuration surface — get_action, get_slot_label,
--- get_assignments — had zero readers, and its only writer was a reset routine
--- clearing settings that could not exist. This file is the missing half.
---
--- FEATURES & RATIONALE:
--- 1. Two pickers, not one dialog: choosing WHICH chord and choosing WHAT it does
---    are separate questions, and the shared webview picker already answers both
---    shapes. Adding a binding asks for the chord first because that is the choice
---    the user arrives with.
--- 2. Assigned rows only: the group lists what is bound, not the 40 slots that
---    could be. A submenu of forty mostly-empty rows is a list nobody reads.
--- 3. Unbinding is picking "none": the action picker injects its own disabled row,
---    so removal needs no separate affordance and cannot drift from assignment.
--- ==============================================================================

local M = {}

local hs           = hs
local i18n         = require("infra.i18n")
local Logger       = require("infra.logger")
local ActionPicker = require("ui.action_picker")
local KbShortcuts  = require("modules.shortcuts")

local LOG = "menu.keyboard_slots"

-- The picker's own sentinel for "no action". Declared once because the add-flow
-- and the edit-flow both have to recognise it, and a second spelling would make
-- one of them silently bind an action literally named "none".
local NONE_ID = "none"




-- ==========================================
-- ==========================================
-- ======= 1/ Picker Item Building ==========
-- ==========================================
-- ==========================================

--- Builds the picker item list of the actions a slot may be given.
--- Reuses the gesture registry's ordered names so the keyboard slots and the
--- gesture slots offer exactly the same catalogue, in the same order.
--- @param gestures table The gestures module from the menu context.
--- @return table items Array of heading/action tables for the shared picker.
local function build_action_items(gestures)
	local items = {}
	local names = type(gestures) == "table" and type(gestures.get_sg_names) == "function"
		and gestures.get_sg_names() or nil
	if type(names) ~= "table" then
		Logger.error(LOG, "The gesture registry offered no action names — the picker would be empty.")
		return items
	end

	for _, name in ipairs(names) do
		if name == "-" or name == "--" or name == NONE_ID then
			-- Separators and the none sentinel are the picker's own to draw
		elseif name:sub(1, 1) == "#" then
			local hashes = name:match("^#+")
			items[#items + 1] = { type = "heading", level = #hashes, text = name:sub(#hashes + 1) }
		else
			local label = type(gestures.get_action_label) == "function" and gestures.get_action_label(name) or name
			items[#items + 1] = { type = "action", id = name, label = label }
		end
	end
	return items
end

--- Builds the picker item list of the slots a group can still offer.
--- Already-assigned slots are excluded: this list answers "which chord shall I
--- add", and offering a bound one would silently overwrite it from a row that
--- looked like a fresh binding.
--- @param prefix string The group's slot prefix.
--- @return table items
local function build_free_slot_items(prefix)
	local taken = {}
	for _, slot in ipairs(KbShortcuts.assigned_keyboard_slots(prefix)) do taken[slot.id] = true end

	local items = {}
	for _, slot in ipairs(KbShortcuts.available_keyboard_slots(prefix)) do
		if not taken[slot.id] then
			items[#items + 1] = { type = "action", id = slot.id, label = KbShortcuts.get_keyboard_slot_label(slot.id) }
		end
	end
	return items
end




-- ==========================================
-- ==========================================
-- ======= 2/ Picker Flows ==================
-- ==========================================
-- ==========================================

--- Opens the action picker for one slot and applies the choice.
--- @param slot_id string
--- @param ctx table The menu context (needs gestures and updateMenu).
local function choose_action_for(slot_id, ctx)
	ActionPicker.open({
		title   = i18n.get("dialog.keyboard_shortcut.title_prefix") .. KbShortcuts.get_keyboard_slot_label(slot_id),
		label   = i18n.get("dialog.action_picker.label"),
		current = KbShortcuts.get_keyboard_action(slot_id),
		items   = build_action_items(ctx.gestures),
	}, function(action_id)
		if type(action_id) ~= "string" then return end
		KbShortcuts.set_keyboard_action(slot_id, action_id)
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end)
end

--- Opens the slot picker for a group, then the action picker for what was picked.
--- @param prefix string
--- @param ctx table
local function add_binding_to(prefix, ctx)
	local items = build_free_slot_items(prefix)
	if #items == 0 then
		Logger.warn(LOG, "Every slot of '%s' is already assigned — nothing to offer.", prefix)
		return
	end

	ActionPicker.open({
		title   = i18n.get("dialog.keyboard_shortcut.title_prefix"),
		label   = i18n.get("dialog.keyboard_shortcut.prompt"),
		current = NONE_ID,
		items   = items,
	}, function(slot_id)
		if type(slot_id) ~= "string" or slot_id == NONE_ID then return end
		-- The second picker is opened on the next tick: the shared webview needs
		-- the first window torn down before it will build another, and chaining
		-- them synchronously leaves the user staring at nothing.
		hs.timer.doAfter(0.05, function() choose_action_for(slot_id, ctx) end)
	end)
end




-- ==========================================
-- ==========================================
-- ======= 3/ Group Rendering ===============
-- ==========================================
-- ==========================================

--- Builds the row data for one group.
--- Returns DATA, not menu rows: the manifest renderer owns the hs.menubar shape,
--- so a change to how a row is drawn happens in one file rather than in every
--- module that produces one.
--- @param group table An entry of KbShortcuts.SLOT_GROUPS.
--- @param ctx table
--- @param disabled boolean|nil Whether the rows should render greyed out.
--- @return table rows
local function build_group_rows(group, ctx, disabled)
	local rows = {}
	local gestures = ctx.gestures

	for _, slot in ipairs(KbShortcuts.assigned_keyboard_slots(group.prefix)) do
		local action_label = slot.action
		if type(gestures) == "table" and type(gestures.get_action_label) == "function" then
			action_label = gestures.get_action_label(slot.action) or slot.action
		end
		rows[#rows + 1] = {
			label    = KbShortcuts.get_keyboard_slot_label(slot.id) .. " : " .. action_label,
			disabled = disabled or nil,
			action   = function() choose_action_for(slot.id, ctx) end,
		}
	end

	rows[#rows + 1] = {
		label    = i18n.get(group.add_key),
		disabled = disabled or nil,
		action   = function() add_binding_to(group.prefix, ctx) end,
	}
	return rows
end

--- The list provider for the manifest's "keyboard_slots" entry.
--- One row per group, each carrying its own rows as nested data.
--- @param ctx table The menu context.
--- @param disabled boolean|nil
--- @return table rows
function M.provide_rows(ctx, disabled)
	local rows = {}
	for _, group in ipairs(KbShortcuts.get_keyboard_slot_groups()) do
		rows[#rows + 1] = {
			label    = i18n.get(group.group_key),
			disabled = disabled or nil,
			items    = build_group_rows(group, ctx, disabled),
		}
	end
	return rows
end

return M

--- ui/menu/menu_gestures.lua

--- ==============================================================================
--- MODULE: Menu Gestures
--- DESCRIPTION:
--- Orchestrates the gestures submenu interface.
--- ==============================================================================

local M = {}
local hs = hs

local gestures_mod = require("modules.gestures")
local dialog       = require("lib.dialog_util")
local i18n         = require("lib.i18n")





-- ================================
--- ================================
-- ======= 1/ Default State =======
--- ================================
-- ================================

M.DEFAULT_STATE = {
	gestures = gestures_mod.DEFAULT_STATE.gestures
}





-- ====================================
--- ====================================
-- ======= 2/ Menu Construction =======
--- ====================================
-- ====================================

--- Returns the translated label for a gesture slot identifier.
--- Falls back to the raw slot id when the key is missing from the locale file.
--- @param slot string Internal slot id, e.g. ``"tap_3"`` or ``"swipe_2_left"``.
--- @return string
local function slot_label(slot)
	return i18n.get("gesture.slots." .. slot)
end

local DISABLED_GESTURE_ACTION = "none"

--- Builds the gestures sub-menu.
--- @param ctx table Context containing state, updateMenu, save_prefs, etc.
--- @return table|nil The menu definition table.
function M.build(ctx)
	local gestures = ctx.gestures
	if not gestures then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	local item = {
		title   = i18n.get("menu.gestures.title"),
		checked = (state.gestures and not paused) or nil,
		fn      = function()
			local new_state = not state.gestures
			if new_state then
				-- Show warning when activating gestures
				local warnMsg = i18n.get("dialog.gestures.warning_msg")
				local res = dialog.block_alert(i18n.get("dialog.gestures.warning_title"), warnMsg, i18n.get("button.activate"), i18n.get("button.cancel"), "warning")
				if res ~= i18n.get("button.activate") then return end
			end
			state.gestures = new_state
			if gestures then
				if state.gestures then 
					if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end 
				else 
					if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end 
				end
			end
			ctx.save_prefs()
			ctx.notify_feature(i18n.get("menu.gestures.notify_title"), state.gestures)
			ctx.updateMenu()
		end,
	}



	-- =================================
	-- ===== 2.1) Helper Functions =====
	-- =================================

	--- Builds hs.chooser choices from the SG names list, grouping by category.
	--- Each choice carries text (action label), subText (category name), and id (action name).
	--- @param names table Ordered list of action names and sentinels from get_sg_names().
	--- @param current string|nil Currently assigned action name.
	--- @return table choices, number selectedIdx
	local function build_chooser_choices(names, current)
		local choices     = {}
		local selected    = 1
		local current_cat = ""

		-- "Désactivé" entry first
		local disabled_lbl = i18n.get("menu.gestures.action_disabled") ~= "menu.gestures.action_disabled"
			and i18n.get("menu.gestures.action_disabled")
			or i18n.get("dialog.action_picker.disabled")
		table.insert(choices, { text = disabled_lbl, subText = "", id = "none" })
		if current == "none" or current == nil then selected = 1 end

		if type(names) == "table" then
			for _, aname in ipairs(names) do
				if aname == "-" or aname == "--" then
					-- skip separators — categories provide visual grouping
				elseif aname == "none" then
					-- "none" is already inserted above — skip to avoid a duplicate entry
				elseif aname:sub(1, 1) == "#" then
					current_cat = aname:sub(2)
				else
					local lbl = type(gestures.get_action_label) == "function"
						and gestures.get_action_label(aname) or aname
					table.insert(choices, { text = lbl, subText = current_cat, id = aname })
					if aname == current then selected = #choices end
				end
			end
		end
		return choices, selected
	end

	--- Opens a hs.chooser to pick an action for a gesture slot.
	--- Applies the chosen action, saves prefs, and handles conflict dialogs.
	--- @param slot string The internal slot identifier.
	--- @param names table Ordered names list from get_sg_names().
	--- @param current string|nil Currently assigned action name.
	local function open_action_chooser(slot, names, current)
		local choices, selected = build_chooser_choices(names, current)
		local picker = hs.chooser.new(function(choice)
			if not choice then return end
			local a = choice.id
			if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, a) end
			local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
			ctx.save_prefs()
			ctx.updateMenu()
			if type(conflict) == "table" then
				hs.timer.doAfter(0.3, function()
					local ok_c, clicked = pcall(dialog.block_alert,
						i18n.get("menu.gestures.conflict_title"), conflict.msg or "",
						i18n.get("menu.gestures.open_settings"), "OK", "warning")
					if ok_c and clicked == i18n.get("menu.gestures.open_settings") then
						pcall(hs.execute, string.format("open \"%s\"", conflict.url or ""))
					end
				end)
			end
		end)
		picker:choices(choices)
		picker:searchSubText(true)
		picker:select(selected)
		picker:show()
	end

	--- Generates a menu item for a specific gesture slot.
	--- @param slot string The internal slot identifier.
	--- @return table The slot menu definition.
	local function slotItem(slot)
		local current     = type(gestures.get_action) == "function" and gestures.get_action(slot) or nil
		local currentMode = type(gestures.get_mode) == "function" and gestures.get_mode(slot) or "x1"
		local currentSens = type(gestures.get_sensitivity) == "function" and gestures.get_sensitivity(slot) or 3.5

		local slotLbl   = slot_label(slot)
		local actionLbl = type(gestures.get_action_label) == "function" and gestures.get_action_label(current)
			or (current or "none")

		local names = type(gestures.get_sg_names) == "function" and gestures.get_sg_names() or gestures.SG_NAMES

		local modeSubmenu = {
			{
				title = i18n.get("menu.gestures.mode_single"),
				checked = (currentMode == "x1") or nil,
				fn = function()
					if type(gestures.set_mode) == "function" then pcall(gestures.set_mode, slot, "x1") end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			},
			{
				title = i18n.get("menu.gestures.mode_incremental"),
				checked = (currentMode == "incremental") or nil,
				fn = function()
					if type(gestures.set_mode) == "function" then pcall(gestures.set_mode, slot, "incremental") end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			}
		}

		local sensSubmenu = {
			{ title = i18n.section("menu.gestures.sensitivity_label"), disabled = true },
			{ title = i18n.get("menu.gestures.sensitivity_hint"),  disabled = true },
			{ title = "-" },
		}
		local sensitivities = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0 }
		for _, s in ipairs(sensitivities) do
			local label = string.format("%.1f", s)
			if s == 3.5 then label = label .. " " .. i18n.get("menu.gestures.default_sensitivity") end

			table.insert(sensSubmenu, {
				title = label,
				checked = (currentSens == s) or nil,				fn = function()
					if type(gestures.set_sensitivity) == "function" then pcall(gestures.set_sensitivity, slot, s) end
					ctx.save_prefs()
					ctx.updateMenu()
				end
			})
		end

		local mode_display = currentMode == "incremental"
			and i18n.get("menu.gestures.mode_incremental")
			or  i18n.get("menu.gestures.mode_single")

		local change_action_item = {
			title = i18n.get("menu.gestures.change_action"),
			fn    = (state.gestures and not paused) and function()
				hs.timer.doAfter(0.05, function() open_action_chooser(slot, names, current) end)
			end or nil,
			disabled = not state.gestures or paused or nil,
		}

		-- Swipe slots expose an action-picker entry + mode + sensitivity in a sub-menu.
		if slot:match("swipe") then
			local swipeSubmenu = {
				change_action_item,
				{ title = "-" },
				{ title = i18n.get("menu.gestures.mode_prefix") .. mode_display, menu = modeSubmenu },
				{ title = i18n.get("menu.gestures.sensitivity_prefix") .. string.format("%.1f", currentSens), menu = sensSubmenu, disabled = (currentMode ~= "incremental") or nil },
			}
			return {
				title    = slotLbl .. " : " .. actionLbl,
				disabled = not state.gestures or paused or nil,
				menu     = swipeSubmenu,
			}
		end

		-- Tap slots: only the action matters, open the chooser directly.
		return {
			title    = slotLbl .. " : " .. actionLbl,
			disabled = not state.gestures or paused or nil,
			menu     = { change_action_item },
		}
	end

	--- Generates a section of gesture items.
	--- @param slots table List of slot identifiers.
	--- @return table The section menu items.
	local function section(slots)
		local its = {}
		for _, slot in ipairs(slots) do table.insert(its, slotItem(slot)) end
		return its
	end

	local gm = {}

	-- Quick-action buttons at the top, mirroring the karabiner menu pattern
	table.insert(gm, {
		title = i18n.get("menu.gestures.disable_all"),
		fn    = function()
			local gestures_enabled = state.gestures == true
			local all_slots = gestures_mod.SINGLE_SLOTS or {}
			for _, slot in ipairs(all_slots) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, DISABLED_GESTURE_ACTION) end
			end
			state.gestures = gestures_enabled
			if gestures_enabled then
				if type(gestures.enable_all) == "function" then pcall(gestures.enable_all) end
			else
				if type(gestures.disable_all) == "function" then pcall(gestures.disable_all) end
			end
			ctx.save_prefs()
			ctx.updateMenu()
		end,
	})
	table.insert(gm, {
		title = i18n.get("menu.gestures.restore_defaults"),
		fn    = function()
			local defaults = gestures_mod.DEFAULT_GESTURES or {}
			for slot, action in pairs(defaults) do
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
			end
			ctx.save_prefs()
			ctx.updateMenu()
		end,
	})
	table.insert(gm, { title = "-" })

	-- Global Settings
	table.insert(gm, {
		title = i18n.get("menu.gestures.circular_spaces"),
		checked = (type(gestures.get_space_wrap) == "function" and gestures.get_space_wrap()) or nil,
		disabled = not state.gestures or paused or nil,
		fn = function()
			if type(gestures.get_space_wrap) == "function" and type(gestures.set_space_wrap) == "function" then
				pcall(gestures.set_space_wrap, not gestures.get_space_wrap())
				ctx.save_prefs()
				ctx.updateMenu()
			end
		end
	})
	table.insert(gm, { title = "-" })

	-- 2 Fingers
	table.insert(gm, slotItem("tap_2"))
	for _, it in ipairs(section({"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })

	-- 3 Fingers
	table.insert(gm, slotItem("tap_3"))
	for _, it in ipairs(section({"swipe_3_left", "swipe_3_right", "swipe_3_up", "swipe_3_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })
	
	-- 4 Fingers
	table.insert(gm, slotItem("tap_4"))
	for _, it in ipairs(section({"swipe_4_left", "swipe_4_right", "swipe_4_up", "swipe_4_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down"})) do table.insert(gm, it) end
	table.insert(gm, { title = "-" })
	
	-- 5 Fingers
	table.insert(gm, slotItem("tap_5"))
	for _, it in ipairs(section({"swipe_5_left", "swipe_5_right", "swipe_5_up", "swipe_5_down"})) do table.insert(gm, it) end
	for _, it in ipairs(section({"swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down"})) do table.insert(gm, it) end
	
	item.menu = gm
	return item
end

return M

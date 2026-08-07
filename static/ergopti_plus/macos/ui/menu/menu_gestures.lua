--- ui/menu/menu_gestures.lua

--- ==============================================================================
--- MODULE: Menu Gestures
--- DESCRIPTION:
--- Orchestrates the gestures submenu interface.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-Driven: Structure (slot groups, separators, action buttons) is
---    read from ``_shared/menu_manifest.json`` via ``infra/manifest_menu``.
---    Dynamic blocks (slot items, disable_all, restore_defaults) are supplied
---    as handlers so runtime state stays in Lua.
--- ==============================================================================

local M = {}
local hs = hs

local gestures_mod  = require("modules.gestures")
local MenuUtils = require("ui.menu.menu_utils")
local dialog        = require("infra.dialog_util")
local i18n          = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")
local ActionPicker  = require("ui.action_picker")
local shortcut_utils = require("ui.menu.shortcut_utils")





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	gestures = gestures_mod.DEFAULT_STATE.gestures
}





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
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
		checked = state.gestures or nil,
		-- Disabled while the script is paused. The gesture engine's only gate is the
		-- shared CoreState.enabled flag, which pause_all() drives via disable_all().
		-- Toggling the feature during pause would write that SAME flag: enabling it
		-- makes gestures fire while « tout est éteint », and disabling it desyncs the
		-- pre-pause snapshot so resume_all() re-enables against the user's intent.
		-- Pause owns the gesture state until resume restores it — mirror the
		-- hotstrings master toggle, which is likewise pause-gated.
		disabled = paused or nil,
		fn      = (not paused) and function()
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
		end or nil,
	}



	-- =================================
	-- ===== 2.1) Helper Functions =====
	-- =================================

	--- Builds the ordered item list for the shared picker from the SG names.
	--- Each entry is either a heading ({type="heading", level, text}) or an action
	--- ({type="action", id, label}); the number of leading "#" on a header encodes
	--- its level (h1/h2/…) so the picker can render a foldable hierarchy + TOC.
	--- Separators and the "none" sentinel (the picker injects its own disabled row)
	--- are dropped.
	--- @param names table Ordered list of action names and sentinels.
	--- @return table items Array of heading/action tables.
	local function build_items(names)
		local items = {}
		if type(names) == "table" then
			for _, aname in ipairs(names) do
				if aname == "-" or aname == "--" or aname == "none" then
					-- skip separators + the none sentinel (the picker adds its own)
				elseif aname:sub(1, 1) == "#" then
					local hashes = aname:match("^#+")
					table.insert(items, { type = "heading", level = #hashes, text = aname:sub(#hashes + 1) })
				else
					local lbl = type(gestures.get_action_label) == "function"
						and gestures.get_action_label(aname) or aname
					table.insert(items, { type = "action", id = aname, label = lbl })
				end
			end
		end
		return items
	end

	--- Opens the shared webview picker to pick an action for a gesture slot.
	--- Applies the chosen action, saves prefs, and handles conflict dialogs.
	--- @param slot string The internal slot identifier.
	--- @param names table Ordered names list from get_sg_names().
	--- @param current string|nil Currently assigned action name.
	local function open_action_chooser(slot, names, current)
		ActionPicker.open({
			title   = slot_label(slot),
			label   = i18n.get("dialog.action_picker.label"),
			current = current or "none",
			items   = build_items(names),
		}, function(a)
			local function apply_action()
				if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, a) end
				local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
				ctx.save_prefs()
				ctx.updateMenu()
				return conflict
			end
			local spec = type(gestures.get_action_parameter_spec) == "function" and gestures.get_action_parameter_spec(a) or nil
			if spec then
				hs.timer.doAfter(0.05, function()
					local prior = type(gestures.get_action_parameter) == "function" and gestures.get_action_parameter(slot, a) or ""
					-- The %s inside the search-URL prompt is LITERAL — it is the
					-- placeholder the user has to type — so this string is never run
					-- through string.format. The title uses {1} so the two cannot be
					-- confused.
					local prompt = i18n.get(spec == "search_url"
						and "dialog.gestures.param_search_url"
						or  "dialog.gestures.param_link")
					local title    = shortcut_utils.action_parameter_title(gestures.get_action_label(a) or a)
					local save_btn = i18n.get("button.save")
					while true do
						local button, value = dialog.text_prompt(title, prompt, prior, save_btn, i18n.get("button.cancel"))
						if button ~= save_btn then return end
						if type(gestures.validate_action_parameter) == "function" and gestures.validate_action_parameter(a, value) then
							pcall(gestures.set_action_parameter, slot, a, value)
							local conflict = apply_action()
							if type(conflict) == "table" then
								hs.timer.doAfter(0.3, function()
									pcall(dialog.block_alert, i18n.get("menu.gestures.conflict_title"), conflict.msg or "", i18n.get("menu.gestures.open_settings"), "OK", "warning")
								end)
							end
							return
						end
						pcall(dialog.block_alert, i18n.get("dialog.gestures.param_error_title"),
							i18n.get("dialog.gestures.param_err_url")
							.. (spec == "search_url" and (" " .. i18n.get("dialog.gestures.param_err_many_placeholders")) or ""),
							"OK", nil, "warning")
						prior = value or prior
					end
				end)
				return
			end
			local conflict = apply_action()
			if type(conflict) == "table" then
				hs.timer.doAfter(0.3, function()
					local ok_c, clicked = pcall(dialog.block_alert,
						i18n.get("menu.gestures.conflict_title"), conflict.msg or "",
						i18n.get("menu.gestures.open_settings"), "OK", "warning")
					if ok_c and clicked == i18n.get("menu.gestures.open_settings") then
						pcall(hs.execute, "open " .. text_utils.shell_quote(conflict.url or ""))
					end
				end)
			end
		end)
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
		local parameter = type(gestures.get_action_parameter) == "function" and gestures.get_action_parameter(slot, current) or ""
		if parameter ~= "" then actionLbl = actionLbl .. " (" .. parameter .. ")" end

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

	-- Dynamic handlers — each appends its items to the list it receives.

	-- `command` since 2026-08-07: the renderer builds the row and its label from
	-- the declaration, so this supplies only what the click does.
	local function cmd_disable_all()
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
	end

	local function cmd_restore_defaults()
		local defaults = gestures_mod.DEFAULT_GESTURES or {}
		for slot, action in pairs(defaults) do
			if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
		end
		ctx.save_prefs()
		ctx.updateMenu()
	end

	-- The row itself is `type = "check"` in the manifest now: the label, the tick
	-- predicate and the greying predicate are declared, and this is only what the
	-- row DOES.
	local function cmd_circular_spaces()
		if type(gestures.get_space_wrap) == "function" and type(gestures.set_space_wrap) == "function" then
			pcall(gestures.set_space_wrap, not gestures.get_space_wrap())
			ctx.save_prefs()
			ctx.updateMenu()
		end
	end

	-- Build a slot group from the manifest gesture_slots table.
	-- One provider per finger count. The slot ids come from the manifest's own
	-- `gesture_slots` table, so these rows were already manifest DATA appended by
	-- hand — the shared renderer materialises them now.
	local function slots_provider(finger_count)
		return function()
			local root = ManifestMenu.get_root()
			local slots = (type(root) == "table"
				and type(root.gesture_slots) == "table"
				and root.gesture_slots[tostring(finger_count)]) or {}
			local rows = {}
			for _, slot_id in ipairs(slots) do
				rows[#rows + 1] = MenuUtils.as_provider_row(slotItem(slot_id))
			end
			return rows
		end
	end

	local dyn_handlers = {
	}

	local providers = {
		["gesture_slots_2"] = slots_provider(2),
		["gesture_slots_3"] = slots_provider(3),
		["gesture_slots_4"] = slots_provider(4),
		["gesture_slots_5"] = slots_provider(5),
	}

	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = { ["circular_spaces"] = cmd_circular_spaces }
	render_ctx.state_getters = {
		gesture_space_wrap = function()
			return type(gestures.get_space_wrap) == "function" and gestures.get_space_wrap() or false
		end,
		-- disabled_when is an AND of things that must be TRUE for the row to be
		-- live, so this answers "are gestures usable", not "are they off".
		gestures_enabled = function() return (state.gestures and not paused) and true or false end,
	}

	-- The two whole-tree actions are `command` rows: the renderer builds them from
	-- the declaration and this driver registers only the behaviour.
	render_ctx.commands = render_ctx.commands or {}
	render_ctx.commands["disable_all"] = cmd_disable_all
	render_ctx.commands["restore_defaults"] = cmd_restore_defaults

	local gm = ManifestMenu.build("gestures_menu", "Gestures", dyn_handlers, nil, render_ctx, providers)
	item.menu = gm
	return item
end

return M

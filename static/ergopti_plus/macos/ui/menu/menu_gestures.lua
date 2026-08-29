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
local Logger         = require("infra.logger")
local DeferredWork   = require("infra.deferred_work")

local LOG = "menu.gestures"
local gesture_toggle_debt = nil





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

	--- Applies one exact gesture lifecycle edge and restores the previously
	--- committed posture when the edge mutates native state before refusing.
	--- @param enabled boolean Desired feature posture.
	--- @param previous boolean Previously published posture.
	--- @return boolean committed
	local function apply_gesture_posture(enabled, label)
		local lifecycle = enabled and gestures.enable_all or gestures.disable_all
		if type(lifecycle) ~= "function" then
			Logger.error(LOG, "Gesture toggle refused because its lifecycle contract is incomplete.")
			return false
		end
		local apply_ok, result_or_err = xpcall(lifecycle, debug.traceback)
		if apply_ok and result_or_err == true then return true end
		Logger.error(LOG, "Gesture runtime %s did not commit: %s.",
			tostring(label), tostring(result_or_err))
		return false
	end

	local function commit_gestures_runtime(enabled, previous)
		if apply_gesture_posture(enabled, "toggle") == true then return true end
		if apply_gesture_posture(previous, "rollback") ~= true then
			gesture_toggle_debt = { restore_enabled = previous }
		end
		return false
	end

	local function settle_gesture_toggle_debt()
		local debt = gesture_toggle_debt
		if not debt then return true end
		if apply_gesture_posture(debt.restore_enabled, "rollback retry") ~= true then
			return false
		end
		if gesture_toggle_debt == debt then gesture_toggle_debt = nil end
		return true
	end

	--- Applies one per-slot value and rolls it back if persistence refuses.
	--- @param getter_name string Runtime getter name.
	--- @param setter_name string Runtime setter name.
	--- @param slot string Gesture slot identifier.
	--- @param value any Desired runtime value.
	--- @param label string Diagnostic setting label.
	--- @return boolean committed
	local function commit_gesture_row_value(getter_name, setter_name, slot, value, label)
		local getter = gestures[getter_name]
		local setter = gestures[setter_name]
		if type(getter) ~= "function" or type(setter) ~= "function" then
			Logger.error(LOG, "Gesture %s mutation refused because its runtime contract is incomplete.",
				tostring(label))
			return false
		end

		local read_ok, previous = xpcall(getter, debug.traceback, slot)
		if not read_ok or previous == nil then
			Logger.error(LOG, "Gesture %s posture could not be read for '%s': %s.",
				tostring(label), tostring(slot), tostring(previous))
			return false
		end

		local apply_ok, apply_result = xpcall(setter, debug.traceback, slot, value)
		if not apply_ok or apply_result ~= true then
			local rollback_ok, rollback_result = xpcall(setter, debug.traceback, slot, previous)
			if not rollback_ok or rollback_result ~= true then
				Logger.error(LOG, "Gesture %s rollback did not commit for '%s': %s.",
					tostring(label), tostring(slot), tostring(rollback_result))
			end
			Logger.error(LOG, "Gesture %s mutation did not commit for '%s': %s.",
				tostring(label), tostring(slot), tostring(apply_result))
			return false
		end

		local save_ok, save_result = xpcall(ctx.save_prefs, debug.traceback)
		if not save_ok or save_result ~= true then
			local rollback_ok, rollback_result = xpcall(setter, debug.traceback, slot, previous)
			if not rollback_ok or rollback_result ~= true then
				Logger.error(LOG, "Gesture %s rollback did not commit for '%s': %s.",
					tostring(label), tostring(slot), tostring(rollback_result))
			end
			Logger.error(LOG, "Gesture %s preference publication did not commit for '%s': %s.",
				tostring(label), tostring(slot), tostring(save_result))
			return false
		end

		ctx.updateMenu()
		return true
	end

	local item = {
		label   = i18n.get("menu.gestures.title"),
		checked = state.gestures or nil,
		-- Disabled while the script is paused. The gesture engine's only gate is the
		-- shared CoreState.enabled flag, which pause_all() drives via disable_all().
		-- Toggling the feature during pause would write that SAME flag: enabling it
		-- makes gestures fire while « tout est éteint », and disabling it desyncs the
		-- pre-pause snapshot so resume_all() re-enables against the user's intent.
		-- Pause owns the gesture state until resume restores it — mirror the
		-- hotstrings master toggle, which is likewise pause-gated.
		disabled = paused or nil,
		action  = (not paused) and function()
			if settle_gesture_toggle_debt() ~= true then return false end
			local previous = state.gestures == true
			local desired = not previous
			if desired then
				-- Show warning when activating gestures
				local warnMsg = i18n.get("dialog.gestures.warning_msg")
				local res = dialog.block_alert(i18n.get("dialog.gestures.warning_title"), warnMsg, i18n.get("button.activate"), i18n.get("button.cancel"), "warning")
				if res ~= i18n.get("button.activate") then return end
			end
			if commit_gestures_runtime(desired, previous) ~= true then return false end
			state.gestures = desired
			local save_ok, save_result = xpcall(ctx.save_prefs, debug.traceback)
			if not save_ok or save_result ~= true then
				state.gestures = previous
				if apply_gesture_posture(previous, "preference rollback") ~= true then
					gesture_toggle_debt = { restore_enabled = previous }
				end
				Logger.error(LOG, "Gesture preference publication did not commit: %s.",
					tostring(save_result))
				return false
			end
			ctx.notify_feature(i18n.get("menu.gestures.notify_title"), state.gestures)
			ctx.updateMenu()
			return true
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
				if ctx.save_prefs() ~= true then return false end
				ctx.updateMenu()
				return conflict
			end
			local spec = type(gestures.get_action_parameter_spec) == "function" and gestures.get_action_parameter_spec(a) or nil
			if spec then
				DeferredWork.after(0.05, function()
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
								DeferredWork.after(0.3, function()
									pcall(dialog.block_alert, i18n.get("menu.gestures.conflict_title"), conflict.msg or "", i18n.get("menu.gestures.open_settings"), "OK", "warning")
								end, "menu_gestures.parameter_conflict")
							end
							return
						end
						pcall(dialog.block_alert, i18n.get("dialog.gestures.param_error_title"),
							i18n.get("dialog.gestures.param_err_url")
							.. (spec == "search_url" and (" " .. i18n.get("dialog.gestures.param_err_many_placeholders")) or ""),
							"OK", nil, "warning")
						prior = value or prior
					end
				end, "menu_gestures.action_parameter")
				return
			end
			local conflict = apply_action()
			if type(conflict) == "table" then
				DeferredWork.after(0.3, function()
					local ok_c, clicked = pcall(dialog.block_alert,
						i18n.get("menu.gestures.conflict_title"), conflict.msg or "",
						i18n.get("menu.gestures.open_settings"), "OK", "warning")
					if ok_c and clicked == i18n.get("menu.gestures.open_settings") then
						pcall(hs.execute, "open " .. text_utils.shell_quote(conflict.url or ""))
					end
				end, "menu_gestures.action_conflict")
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

		-- Provider data from here down: `label` / `action` / `items`, which the
		-- renderer materialises. These rows used to be built in this driver's own
		-- dialect and translated one by one on the way out, so the tree was still
		-- assembled here and every row of it counted as built outside the renderer.
		local modeSubmenu = {
			{
				label = i18n.get("menu.gestures.mode_single"),
				checked = (currentMode == "x1") or nil,
				action = function()
					return commit_gesture_row_value("get_mode", "set_mode", slot, "x1", "mode")
				end
			},
			{
				label = i18n.get("menu.gestures.mode_incremental"),
				checked = (currentMode == "incremental") or nil,
				action = function()
					return commit_gesture_row_value("get_mode", "set_mode", slot, "incremental", "mode")
				end
			}
		}

		local sensSubmenu = {
			{ label = i18n.section("menu.gestures.sensitivity_label"), disabled = true },
			{ label = i18n.get("menu.gestures.sensitivity_hint"),  disabled = true },
			{ separator = true },
		}
		local sensitivities = { 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0 }
		for _, s in ipairs(sensitivities) do
			local label = string.format("%.1f", s)
			if s == 3.5 then label = label .. " " .. i18n.get("menu.gestures.default_sensitivity") end

			table.insert(sensSubmenu, {
				label = label,
				checked = (currentSens == s) or nil,
				action = function()
					return commit_gesture_row_value(
						"get_sensitivity", "set_sensitivity", slot, s, "sensitivity")
				end
			})
		end

		local mode_display = currentMode == "incremental"
			and i18n.get("menu.gestures.mode_incremental")
			or  i18n.get("menu.gestures.mode_single")

		local change_action_item = {
			label  = i18n.get("menu.gestures.change_action"),
			action = (state.gestures and not paused) and function()
				DeferredWork.after(0.05,
					function() open_action_chooser(slot, names, current) end,
					"menu_gestures.action_chooser")
			end or nil,
			disabled = not state.gestures or paused or nil,
		}

		-- Swipe slots expose an action-picker entry + mode + sensitivity in a sub-menu.
		if slot:match("swipe") then
			local swipeSubmenu = {
				change_action_item,
				{ separator = true },
				{ label = i18n.get("menu.gestures.mode_prefix") .. mode_display, items = modeSubmenu },
				{ label = i18n.get("menu.gestures.sensitivity_prefix") .. string.format("%.1f", currentSens), items = sensSubmenu, disabled = (currentMode ~= "incremental") or nil },
			}
			return {
				label    = slotLbl .. " : " .. actionLbl,
				disabled = not state.gestures or paused or nil,
				items    = swipeSubmenu,
			}
		end

		-- Tap slots: only the action matters, open the chooser directly.
		return {
			label    = slotLbl .. " : " .. actionLbl,
			disabled = not state.gestures or paused or nil,
			items    = { change_action_item },
		}
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
		if ctx.save_prefs() ~= true then return false end
		ctx.updateMenu()
	end

	local function cmd_restore_defaults()
		local defaults = gestures_mod.DEFAULT_GESTURES or {}
		for slot, action in pairs(defaults) do
			if type(gestures.set_action) == "function" then pcall(gestures.set_action, slot, action) end
		end
		if ctx.save_prefs() ~= true then return false end
		ctx.updateMenu()
	end

	-- The row itself is `type = "check"` in the manifest now: the label, the tick
	-- predicate and the greying predicate are declared, and this is only what the
	-- row DOES.
	local function cmd_circular_spaces()
		if type(gestures.get_space_wrap) == "function" and type(gestures.set_space_wrap) == "function" then
			pcall(gestures.set_space_wrap, not gestures.get_space_wrap())
			if ctx.save_prefs() ~= true then return false end
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
				rows[#rows + 1] = slotItem(slot_id)
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
	item.submenu = gm
	return item
end

return M

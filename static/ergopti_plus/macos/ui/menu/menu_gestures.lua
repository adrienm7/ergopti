--- ui/menu/menu_gestures.lua

--- ==============================================================================
--- MODULE: Menu Gestures
--- DESCRIPTION:
--- Orchestrates the gestures submenu interface.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-Driven: Structure (slot groups, separators, action buttons) is
---    read from ``_shared/menu_manifest.json`` via ``infra/manifest_menu``.
---    Dynamic blocks (slot items) and the scope rows' behaviour (scope_restore,
---    scope_clear) are supplied as handlers so runtime state stays in Lua.
--- ==============================================================================

local M = {}

local gestures_mod  = require("modules.gestures")
local MenuUtils = require("ui.menu.menu_utils")
local dialog        = require("infra.dialog_util")
local i18n          = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")
local ActionPicker  = require("ui.action_picker")
local shortcut_utils = require("ui.menu.shortcut_utils")
local Logger         = require("infra.logger")
local DeferredWork   = require("infra.deferred_work")
local ParameterLabel = require("action_parameter_label")

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

	--- The category switch: the gestures submenu's first row (the manifest's
	--- gestures_toggle). It used to be the parent row's action, which AppKit
	--- never sends for an item that opens a submenu, so Gestures could not be
	--- switched on from the menu bar at all.
	---
	--- Refused while the script is paused. The gesture engine's only gate is the
	--- shared CoreState.enabled flag, which pause_all() drives via disable_all().
	--- Toggling the feature during pause would write that SAME flag: enabling it
	--- makes gestures fire while « tout est éteint », and disabling it desyncs the
	--- pre-pause snapshot so resume_all() re-enables against the user's intent.
	--- Pause owns the gesture state until resume restores it.
	--- @return boolean|nil committed
	local function toggle_gestures()
		if paused then
			Logger.warn(LOG, "Gestures switch refused: the script is paused.")
			return false
		end
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
	end

	local item = {
		label    = i18n.get("menu.gestures.title"),
		checked  = state.gestures or nil,
		disabled = paused or nil,
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
		local items = build_items(names)
		local editor = shortcut_utils.picker_parameter_fields(gestures, items, slot)
		local function show_conflict(conflict)
			if type(conflict) ~= "table" then return end
			return require("ui.gesture_conflict_notice").show(conflict)
		end
		ActionPicker.open({
			title   = slot_label(slot),
			label   = i18n.get("dialog.action_picker.label"),
			current = current or "none",
			items   = items,
			send_vocabulary   = editor.send_vocabulary,
			parameter_strings = editor.parameter_strings,
			prompt_choices    = editor.prompt_choices,
			default_count     = editor.default_count,
			vision_choices    = editor.vision_choices,
			language_choices  = editor.language_choices,
			edit_current_label = editor.edit_current_label,
		}, function(a, picked)
			local function apply_action()
				if not commit_gesture_row_value("get_action", "set_action", slot, a, "action") then return false end
				local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
				ctx.updateMenu()
				return conflict
			end
			local spec = type(gestures.get_action_parameter_spec) == "function" and gestures.get_action_parameter_spec(a) or nil
			if spec == "program" then
				DeferredWork.after(0.05, function()
					local committed = shortcut_utils.prompt_action_parameter(gestures, slot, a, spec, picked, {
						section = "gestures", key = slot,
						read = function() return gestures.get_action(slot) end,
						apply = function() return gestures.set_action(slot, a) == true end,
						restore = function(previous) return gestures.set_action(slot, previous) == true end,
					}, ctx.commit_program_parameter)
					if committed then
						local conflict = type(gestures.on_action_changed) == "function" and gestures.on_action_changed(slot, a) or nil
						ctx.updateMenu()
						show_conflict(conflict)
					end
				end, "menu_gestures.action_parameter")
				return
			end
			if spec then
				DeferredWork.after(0.05, function()
					local prior = type(gestures.get_action_parameter) == "function" and gestures.get_action_parameter(slot, a) or ""
					local title    = shortcut_utils.action_parameter_title(gestures.get_action_label(a) or a)
					-- A value the picker's editor collected is stored without asking.
					local value = type(picked) == "string" and picked or nil
					while true do
						if value == nil then
							-- The prompt (or the application chooser) and its refusal
							-- text belong to the parameter kind.
							value = shortcut_utils.ask_parameter_value(gestures, a, spec, title, prior)
							if value == nil then return end
						end
						if type(gestures.validate_action_parameter) == "function" and gestures.validate_action_parameter(a, value) then

							local stored_ok, stored = xpcall(gestures.set_action_parameter, debug.traceback, slot, a, value)
							if not stored_ok or stored ~= true then
								Logger.error(LOG, "Gesture parameter edit did not commit for '%s': %s.", tostring(slot), tostring(stored))
								return
							end
							local conflict = apply_action()
							show_conflict(conflict)
							return
						end
						pcall(dialog.block_alert, i18n.get("dialog.gestures.param_error_title"),
							gestures.parameter_error(a), "OK", nil, "warning")
						prior = value or prior
						value = nil
					end
				end, "menu_gestures.action_parameter")
				return
			end
			local conflict = apply_action()
			show_conflict(conflict)
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
		if type(gestures.get_action_parameter_spec) ~= "function"
			or gestures.get_action_parameter_spec(current) ~= "program" then
			actionLbl = ParameterLabel.format(actionLbl, parameter)
		end

		local names = type(gestures.get_sg_names) == "function" and gestures.get_sg_names() or gestures.SG_NAMES

		-- Provider data from here down: `label` / `action` / `items`, which the
		-- renderer materialises. These rows used to be built in this driver's own
		-- dialect and translated one by one on the way out, so the tree was still
		-- assembled here and every row of it counted as built outside the renderer.
		local modeSubmenu
		if slot:match("swipe") then
			modeSubmenu = ManifestMenu.template_rows("gesture_slot_mode_commands", {
				["gesture_mode_single"] = function()
					return commit_gesture_row_value("get_mode", "set_mode", slot, "x1", "mode")
				end,
				["gesture_mode_incremental"] = function()
					return commit_gesture_row_value("get_mode", "set_mode", slot, "incremental", "mode")
				end,
			}, {
				["gesture_mode_is_single"] = function() return currentMode == "x1" end,
				["gesture_mode_is_incremental"] = function() return currentMode == "incremental" end,
			})
		end

		local sensSubmenu = {}
		if slot:match("swipe") then
			sensSubmenu = ManifestMenu.template_rows("gesture_sensitivity_head")
			if not sensSubmenu then return nil end
		end
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

		local slot_commands = {
			["gesture_slot_change_action"] = function()
				DeferredWork.after(0.05,
					function() open_action_chooser(slot, names, current) end,
					"menu_gestures.action_chooser")
			end,
		}
		local slot_getters = {
			["gesture_slot_choice_ready"] = function() return state.gestures and not paused end,
			["gesture_mode_current_label"] = function() return mode_display end,
			["gesture_sensitivity_current_label"] = function() return string.format("%.1f", currentSens) end,
			["gesture_mode_incremental_ready"] = function() return currentMode == "incremental" end,
		}

		-- Swipe slots expose an action-picker entry + mode + sensitivity in a sub-menu.
		if slot:match("swipe") then
			local swipeSubmenu = ManifestMenu.template_rows("gesture_swipe_slot_menu", slot_commands, slot_getters, {
				["gesture_mode_options"] = modeSubmenu,
				["gesture_sensitivity_options"] = sensSubmenu,
			})
			if not swipeSubmenu then return nil end
			return {
				label    = slotLbl .. " : " .. actionLbl,
				disabled = not state.gestures or paused or nil,
				items    = swipeSubmenu,
			}
		end

		-- Tap slots: only the action matters, open the chooser directly.
		local change_action_rows = ManifestMenu.template_rows("gesture_change_action", slot_commands, slot_getters)
		if not change_action_rows then return nil end
		return {
			label    = slotLbl .. " : " .. actionLbl,
			disabled = not state.gestures or paused or nil,
			items    = change_action_rows,
		}
	end

	-- Dynamic handlers — each appends its items to the list it receives.

	-- `command` since 2026-08-07: the renderer builds the row and its label from
	-- the declaration, so this supplies only what the click does.
	local function apply_scope(mode)
		if ctx.paused or type(ctx.apply_gesture_scope) ~= "function" then return false end
		if gesture_toggle_debt ~= nil then
			Logger.warn(LOG, "Gesture scope refused while the previous toggle rollback remains pending.")
			return false
		end
		return ctx.apply_gesture_scope(mode) == true
	end
	local function cmd_scope_clear() return apply_scope("clear") end
	local function cmd_scope_restore() return apply_scope("recommended") end

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
		["system_gesture_status"] = function()
			local conflicts = gestures.system_gesture_conflicts()
			local rows = {}
			for _, conflict in ipairs(conflicts) do
				rows[#rows + 1] = { label = conflict.label, action = gestures.open_system_gestures }
			end
			local pinch = gestures.system_pinch_enabled()
			local open_settings = gestures.open_system_gestures
			local children = ManifestMenu.template_rows("gesture_system_macos_children", {
				["gesture_system_open_enabled_pinch"] = function(...) return open_settings(...) end,
				["gesture_system_open_disabled_pinch"] = function(...) return open_settings(...) end,
				["gesture_system_open_unknown_pinch"] = function(...) return open_settings(...) end,
				["gesture_system_refresh"] = function()
					return gestures.refresh_system_gestures(ctx.updateMenu)
				end,
			}, {
				["gesture_system_pinch_is_enabled"] = function() return pinch ~= nil and not not pinch end,
				["gesture_system_pinch_is_disabled"] = function() return pinch ~= nil and not pinch end,
				["gesture_system_pinch_is_unknown"] = function() return pinch == nil end,
			}, {
				["gesture_system_cached_conflicts"] = function() return rows end,
			})
			if type(children) ~= "table" then return {} end
			local status = ManifestMenu.template_rows("gesture_system_status_macos_frame", {}, {
				["gesture_system_is_clear"] = function() return #conflicts == 0 end,
				["gesture_system_has_conflicts"] = function() return #conflicts > 0 end,
				["gesture_system_conflict_count"] = function() return tostring(#conflicts) end,
			}, {
				["gesture_system_clear_children"] = function() return children end,
				["gesture_system_conflict_children"] = function() return children end,
			})
			if type(status) ~= "table" or #status ~= 1 then return {} end
			return status
		end,
		["gesture_slots_2"] = slots_provider(2),
		["gesture_slots_3"] = slots_provider(3),
		["gesture_slots_4"] = slots_provider(4),
		["gesture_slots_5"] = slots_provider(5),
	}

	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.state_getters = {
		-- The switch's tick answers the stored preference. The pause greys the
		-- whole submenu from its parent row, and the switch refuses while paused.
		gestures_enabled = function() return state.gestures == true end,
	}

	-- The scope's restore and clear are `command` rows of the first group: the
	-- renderer builds them from the declaration, right after the switch, and
	-- this driver registers only the behaviour.
	render_ctx.commands = {}
	render_ctx.commands["gestures_toggle"] = toggle_gestures
	render_ctx.commands["scope_restore"] = cmd_scope_restore
	render_ctx.commands["scope_clear"] = cmd_scope_clear
	render_ctx.commands["system_gesture_settings"] = gestures.open_system_gestures

	local gm = ManifestMenu.build("gestures_menu", "Gestures", dyn_handlers, nil, render_ctx, providers)
	item.submenu = gm
	return item
end

return M

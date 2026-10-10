--- ui/menu/menu_tap_keys.lua

--- ==============================================================================
--- MODULE: Menu Tap Keys
--- DESCRIPTION:
--- Renders the three number-row tap keys in the Shortcuts submenu: one row per
--- key, named by the character the current input source puts on it, followed by
--- its action; a click opens the shared action picker.
---
--- FEATURES & RATIONALE:
--- 1. Live names: each rebuild asks the input source what the key types, and an
---    input-source switch rebuilds the menu (one broker subscription, taken at the
---    first render), so the row never shows a legend the keyboard no longer has.
--- 2. Row data only: the manifest renderer owns the hs.menubar shape.
--- 3. The action picker and the parameter prompt are the keyboard slots' own, so
---    a tap key offers exactly the catalogue a keyboard slot does.
--- ==============================================================================

local M = {}
local ParameterLabel = require("action_parameter_label")

local i18n              = require("infra.i18n")
local Logger            = require("infra.logger")
local DeferredWork      = require("infra.deferred_work")
local InputSourceBroker = require("adapters.input_source_broker")
local ActionPicker      = require("ui.action_picker")
local ShortcutUtils     = require("ui.menu.shortcut_utils")
local KeyboardSlots     = require("ui.menu.menu_keyboard_slots")
local TapKeys           = require("modules.shortcuts.tap_keys")
local Bindings          = require("modules.shortcuts.bindings")

local LOG = "menu.tap_keys"

-- The broker subscriber id; one subscription for the process.
local SUBSCRIBER_ID = "menu.tap_keys"

-- The latest menu rebuild function, read by the input-source callback.
local _update_menu = nil
local _subscribed = false




-- ==========================================
-- ==========================================
-- ======= 1/ Picker flow ===================
-- ==========================================
-- ==========================================

--- Opens the action picker for one tap key and applies the choice.
--- @param id string
--- @param name string The key's live name, for the picker title.
--- @param ctx table The menu context (gestures, updateMenu).
local function choose_action_for(id, name, ctx)
	local items = KeyboardSlots.build_action_items(ctx.gestures)
	local editor = ShortcutUtils.picker_parameter_fields(ctx.gestures, items, TapKeys.binding_id(id))
	ActionPicker.open({
		title   = name,
		current = TapKeys.get_action(id),
		items   = items,
		send_vocabulary   = editor.send_vocabulary,
		parameter_strings = editor.parameter_strings,
		prompt_choices    = editor.prompt_choices,
		default_count     = editor.default_count,
		vision_choices    = editor.vision_choices,
		language_choices  = editor.language_choices,
		edit_current_label = editor.edit_current_label,
	}, function(action_id, picked)
		if type(action_id) ~= "string" then return end
		local function bind()
			if TapKeys.set_action(id, action_id, ctx.gestures.is_assignable) ~= true then
				Logger.error(LOG, "Tap key edit refused for '%s'.", tostring(id))
				return false
			end
			if Bindings.reconcile_tap_keys() ~= true then
				Logger.error(LOG, "Tap key dispatcher reconciliation refused for '%s'.", tostring(id))
				return false
			end
			if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
			return true
		end
		local spec = ctx.gestures.get_action_parameter_spec(action_id)
		if not spec then return bind() end
		-- Asked after the picker window has closed, unless the picker's editor
		-- collected it, under the binding the key dispatches with, and bound only
		-- once the value is stored.
		DeferredWork.after(0.05, function()
			if spec == "program" then
				local committed = ShortcutUtils.prompt_action_parameter(ctx.gestures, TapKeys.binding_id(id), action_id, spec,
					picked, {
						publishes_assignment = true, section = "shortcuts.tap_keys", key = id,
						read = function() return TapKeys.get_action(id) end,
						apply = function(on_error, publication_observer)
							if TapKeys.set_action(id, action_id, ctx.gestures.is_assignable, on_error, publication_observer) ~= true then return false end
							return Bindings.reconcile_tap_keys() == true
						end,
						restore = function(previous, on_error, publication_observer)
							if TapKeys.set_action(id, previous, ctx.gestures.is_assignable, on_error, publication_observer) ~= true then return false end
							return Bindings.reconcile_tap_keys() == true
						end,
					}, ctx.commit_program_parameter)
				if committed and type(ctx.updateMenu) == "function" then ctx.updateMenu() end
				return committed
			end
			if ShortcutUtils.prompt_action_parameter(ctx.gestures, TapKeys.binding_id(id), action_id, spec,
				picked) then
				bind()
			end
		end, "menu_tap_keys.action_parameter")
		return true
	end)
end




-- ==========================================
-- ==========================================
-- ======= 2/ Rows ==========================
-- ==========================================
-- ==========================================

--- Rebuilds the menu when the input source changes, so the key names follow it.
--- Subscribed once; the callback reads the latest rebuild function.
local function watch_input_source()
	if _subscribed then return end
	Logger.start(LOG, "Watching input-source changes for the tap-key names…")
	local ok = InputSourceBroker.subscribe(SUBSCRIBER_ID, function()
		if type(_update_menu) == "function" then _update_menu() end
	end)
	if ok ~= true then
		Logger.error(LOG, "Input-source watch refused — tap-key names refresh on the next menu build only.")
		return
	end
	_subscribed = true
	Logger.success(LOG, "Watching input-source changes for the tap-key names.")
end

--- The list provider for the manifest's "tap_keys" entry.
--- @param ctx table The menu context.
--- @param disabled boolean|nil Whether the rows render greyed out.
--- @return table rows
function M.provide_rows(ctx, disabled)
	local gestures = ctx.gestures
	if type(gestures) ~= "table" or type(gestures.is_assignable) ~= "function"
		or type(gestures.get_action_label) ~= "function" then
		Logger.error(LOG, "The gesture registry is unavailable — the tap keys cannot be listed.")
		return {}
	end
	_update_menu = ctx.updateMenu
	watch_input_source()
	TapKeys.ensure_loaded(gestures.is_assignable)
	local rows = {}
	for _, key in ipairs(TapKeys.keys()) do
		local action = TapKeys.get_action(key.id)
		local action_label = action ~= "none" and gestures.get_action_label(action)
			or i18n.get("menu.shortcuts.tap_keys.unassigned")
		action_label = ParameterLabel.for_binding(action_label, gestures, TapKeys.binding_id(key.id), action)
		local name = TapKeys.display_name(key.id, i18n)
		rows[#rows + 1] = {
			label    = name .. " : " .. action_label,
			disabled = disabled or nil,
			action   = function() choose_action_for(key.id, name, ctx) end,
		}
	end
	return rows
end

return M

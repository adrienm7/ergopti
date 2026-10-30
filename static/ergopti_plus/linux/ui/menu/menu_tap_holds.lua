--- ui/menu/menu_tap_holds.lua

--- ==============================================================================
--- MODULE: Linux Menu Tap-Hold Submenu
--- DESCRIPTION:
--- Builds the tray's tap-hold submenu: one row per key of the shared catalogue
--- with its tap and hold actions and threshold, edited through the tap-hold
--- writer.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local prompt_text = require("ui.menu.menu_dialogs").prompt_text
local show_error = require("ui.menu.menu_dialogs").show_error

local LOG = "ui.menu.menu_tap_holds"

--- Display name of a tap-hold key: the label key the shared key catalogue
--- gives it, the one the Windows and macOS menus show.
--- @param entry table One entry of the manager's key_catalog().
--- @return string
local function _tap_hold_key_label(entry)
	local label = i18n_safe(entry.label_key)
	if label == entry.label_key then return entry.id end
	return label
end

--- Display name of a tap action: the key itself for "", else the catalogue's.
--- @param action string|nil
--- @param gestures table|nil The gestures manager, for the actions it labels.
--- @return string
local function _tap_hold_action_label(action, gestures)
	if type(action) ~= "string" or action == "" then return i18n_safe("tap_hold.tap.none") end
	local label = i18n_safe("sg_actions." .. action)
	if label ~= "sg_actions." .. action then return label end
	if gestures and type(gestures.get_action_label) == "function" then
		local ok, named = pcall(gestures.get_action_label, action)
		if ok and type(named) == "string" and named ~= "" then return named end
	end
	return action
end

--- The hold option a key's entry matches.
--- @param options table From the manager's hold_options().
--- @param entry table The key's configuration.
--- @return table|nil
local function _tap_hold_current_hold(options, entry)
	local modifier = type(entry.hold_modifier) == "string" and entry.hold_modifier or ""
	local layer = type(entry.hold_layer) == "string" and entry.hold_layer or ""
	for _, option in ipairs(options) do
		if (option.kind == "none" and modifier == "" and layer == "")
			or (option.kind == "modifier" and option.id == modifier and layer == "")
			or (option.kind == "layer" and option.id == layer) then
			return option
		end
	end
	return nil
end

--- Builds the Tap-Holds submenu: the feature switch, reset and disable-all,
--- then one row per key with its tap picker, hold picker and delay — the
--- Windows menu, on the engine this daemon runs. Every change writes the
--- user's tap_hold.toml and reloads the engine, so it is in force at once.
--- @param ctx table Menu context (ctx.tap_holds is the tap-hold manager).
--- @return table One menu entry with its submenu.
local function _build_tap_holds(ctx)
	local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "tap_holds")
	if not receive then return nil end
	local th = ctx.tap_holds
	if not th then
		local declared = ManifestMenu.template_rows("linux_tap_holds_absent_parent", {}, {}, {})
		if not declared or #declared ~= 1 then return nil end
		return declared[1]
	end
	local Writer = require("platform.remap.tap_hold_writer")
	local HoldOptions = require("tap_hold.hold_options")
	local KeyCatalog = require("tap_hold.key_catalog")

	local function changed(ok)
		if not ok then show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title")) end
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	end

	local keys = th.keys()
	local options = th.hold_options()
	local feature_on = th.file_enabled() and th.is_enabled()

	local capture_edit = th.capture_configuration_edit
	local function edit_guard(setter_name)
		local setter, is_paused = Writer[setter_name], ctx.is_paused
		if type(capture_edit) ~= "function" or type(setter) ~= "function" then return nil end
		local ok, scope = pcall(capture_edit)
		if not ok or type(scope) ~= "function" then return nil end
		local function ports_current()
			return ctx.tap_holds == th and th.capture_configuration_edit == capture_edit
				and package.loaded["platform.remap.tap_hold_writer"] == Writer and Writer[setter_name] == setter
				and type(is_paused) == "function" and ctx.is_paused == is_paused
		end
		local function current()
			if not ports_current() then return false end
			local called, paused = pcall(is_paused)
			if not called or paused ~= false or not ports_current() then return false end
			local checked, live = pcall(scope)
			return checked and live == true and ports_current()
		end
		if not current() then return nil end
		return current, setter
	end

	--- Opens the searchable action picker for a key's tap.
	--- @param catalog_entry table The key's entry of the manager's key_catalog().
	--- @param current string The key's tap now.
	local function pick_tap(catalog_entry, current)
		local guard, setter = edit_guard("set_tap")
		if not guard then changed(false); return false end
		local key_id = catalog_entry.id
		local ok_picker, Picker = pcall(require, "ui.action_picker.bridge")
		if not ok_picker or type(Picker.open) ~= "function" then
			Logger.error(LOG, "Action picker is unavailable for the tap of '%s'.", key_id)
			return
		end
		local items = {}
		for _, id in ipairs(th.tap_actions()) do
			items[#items + 1] = { type = "action", id = id, label = _tap_hold_action_label(id, ctx.gestures) }
		end
		table.sort(items, function(left, right) return left.label < right.label end)
		if guard() ~= true then changed(false); return false end
		Picker.open({
			presentation_id = "tap_hold_action",
			presentation_suffix = _tap_hold_key_label(catalog_entry),
			current = current == "" and "__native__" or current,
			allow_native = true,
			native_label = i18n_safe("tap_hold.tap.none"),
			items = items,
		}, function(option)
			if guard() ~= true then changed(false); return false end
			local called, persisted = pcall(setter, key_id, option == "__native__" and "" or option, guard)
			local accepted = called and persisted == true
			changed(accepted)
			return accepted
		end)
	end

	--- Opens the shared action picker on a key's hold, listing what a hold can
	--- be: the options of [tap_hold.hold_picker] (the modifiers, their
	--- combinations and the navigation layer). A pick is written by the same
	--- set_hold as the former submenu; an id the hold does not offer, or a
	--- refused write, keeps the picker open.
	--- @param catalog_entry table The key's entry of the manager's key_catalog().
	--- @param current table|nil The key's hold option now.
	--- @return boolean opened
	local function pick_hold(catalog_entry, current)
		local key_id = catalog_entry.id
		local ok_picker, Picker = pcall(require, "ui.action_picker.bridge")
		if not ok_picker or type(Picker.open) ~= "function" then
			Logger.error(LOG, "Action picker is unavailable for the hold of '%s'.", key_id)
			return false
		end
		local items, by_id = HoldOptions.picker_items(options, i18n_safe)
		local opened = Picker.open({
			presentation_id = "tap_hold_hold_action",
			presentation_suffix = _tap_hold_key_label(catalog_entry),
			current = current and HoldOptions.picker_id(current) or "none",
			items = items,
		}, function(picked)
			local option = type(picked) == "string" and by_id[picked] or nil
			if not option then
				Logger.error(LOG, "The hold of '%s' does not offer the picked action '%s'.", key_id, tostring(picked))
				return false
			end
			local called, persisted = pcall(Writer.set_hold, key_id, option.kind, option.id)
			local accepted = called and persisted == true
			changed(accepted)
			return accepted
		end)
		if opened ~= true then
			Logger.error(LOG, "The hold picker of '%s' did not open.", key_id)
			return false
		end
		return true
	end

	--- Asks for a key's own delay, in milliseconds.
	local function ask_delay(key_id, current_ms)
		local guard, setter = edit_guard("set_threshold")
		if not guard then changed(false); return false end
		local value = prompt_text(i18n_safe("menu.tapholds.key_tap_delay_dialog_title"),
			string.format(i18n_safe("menu.tapholds.key_tap_delay_dialog_prompt_current"), current_ms),
			tostring(current_ms))
		if value == nil then return false end
		local ms = tonumber(value)
		if not ms or ms ~= ms or ms == math.huge or ms <= 0 or math.floor(ms + 0.5) <= 0 then
			Logger.warn(LOG, "Invalid tap-hold delay '%s' — ignored.", tostring(value))
			show_error(tostring(value), i18n_safe("dialog.gestures.param_error_title"))
			return false
		end
		if guard() ~= true then changed(false); return false end
		local call_ok, persisted = pcall(setter, key_id, math.floor(ms + 0.5) / 1000, guard)
		if not call_ok or persisted ~= true then
			changed(false)
			return false
		end
		changed(true)
		return true
	end

	--- Asks for the GLOBAL delay, in milliseconds: the delay of every key that has
	--- none of its own. A key with a delay of its own keeps it.
	local function ask_global_delay(current_ms)
		local guard, setter = edit_guard("set_global_threshold")
		if not guard then changed(false); return false end
		local default_ms = math.floor(require("platform.remap.tap_hold_loader").GLOBAL_DEFAULT_SECONDS * 1000 + 0.5)
		local value = prompt_text(i18n_safe("menu.tapholds.tap_hold_dialog_title"),
			string.format(i18n_safe("menu.tapholds.tap_hold_dialog_prompt"), default_ms),
			tostring(current_ms))
		if value == nil then return false end
		local ms = tonumber(value)
		if not ms or ms ~= ms or ms == math.huge or ms <= 0 or math.floor(ms + 0.5) <= 0 then
			Logger.warn(LOG, "Invalid global tap-hold delay '%s' — ignored.", tostring(value))
			show_error(tostring(value), i18n_safe("dialog.gestures.param_error_title"))
			return false
		end
		if guard() ~= true then changed(false); return false end
		local call_ok, persisted = pcall(setter, math.floor(ms + 0.5) / 1000, guard)
		if not call_ok or persisted ~= true then
			changed(false)
			return false
		end
		changed(true)
		return true
	end

	--- Removes a key's own delay, so it follows the global delay again.
	local function reset_delay(key_id)
		local guard, setter = edit_guard("set_threshold")
		if not guard then changed(false); return false end
		local call_ok, persisted = pcall(setter, key_id, nil, guard)
		if not call_ok or persisted ~= true then
			changed(false)
			return false
		end
		changed(true)
		return true
	end

	--- The rows of one hand: its keys in the shared catalogue's order, each
	--- with its disable, tap, hold and delay rows. The manifest draws the two
	--- hand headers and the separator between the hands around them.
	--- @param hand string "left" or "right".
	--- @return table
	local function hand_rows(hand)
		local rows = {}
		for _, catalog_entry in ipairs(KeyCatalog.of_hand(th.key_catalog(), hand)) do
			local key_id = catalog_entry.id
			local entry = keys[key_id] or {}
			local active = keys[key_id] ~= nil and entry.enabled ~= false
			local tap = active and type(entry.tap_action) == "string" and entry.tap_action or ""
			local hold = active and _tap_hold_current_hold(options, entry) or options[1]
			local tap_label = _tap_hold_action_label(tap, ctx.gestures)
			local hold_label = hold and HoldOptions.label(hold, i18n_safe) or i18n_safe("tap_hold.hold.none")
			local configured = tap ~= "" or (hold ~= nil and hold.kind ~= "none")
			-- A key follows the global delay until the user gives it one of its own;
			-- `entry` carries the effective value either way.
			local own_delay = th.has_own_delay(key_id)
			local global_ms = math.floor(th.global_seconds() * 1000 + 0.5)
			local ms = own_delay and math.floor((tonumber(entry.time_activation_seconds) or 0) * 1000 + 0.5) or global_ms

			local key_rows = ManifestMenu.template_rows("tap_hold_key_rows", {
				[require("config_keys").COMMAND.TAP_HOLD_KEY_NATIVE] = function() changed(Writer.set_native(key_id)) end,
				[require("config_keys").COMMAND.TAP_HOLD_KEY_TAP] = function() pick_tap(catalog_entry, tap) end,
				[require("config_keys").COMMAND.TAP_HOLD_KEY_HOLD_ACTION] = function() return pick_hold(catalog_entry, hold) end,
				[require("config_keys").COMMAND.TAP_HOLD_KEY_DELAY] = function() return ask_delay(key_id, ms) end,
				[require("config_keys").COMMAND.TAP_HOLD_KEY_DELAY_USE_GLOBAL] = function() return reset_delay(key_id) end,
			}, {
				["tap_hold_key_configured"] = function() return configured end,
				["tap_hold_key_tap_caption"] = function() return tap_label end,
				["tap_hold_key_hold_caption"] = function() return hold_label end,
				["tap_hold_key_delay_caption"] = function()
					if own_delay then return ms .. " ms" end
					return string.format(i18n_safe("menu.tapholds.key_tap_delay_inherited"), global_ms .. " ms")
				end,
				["tap_hold_key_global_delay_caption"] = function() return global_ms .. " ms" end,
				["tap_hold_key_delay_is_global"] = function() return not own_delay end,
				["tap_hold_key_delay_has_override"] = function() return own_delay end,
			}, {})
			if key_rows then

				rows[#rows + 1] = {
					label = _tap_hold_key_label(catalog_entry) .. "  :  "
						.. (configured and (tap_label .. "  /  " .. hold_label) or "—"),
					checked = configured or nil,
					items = key_rows,
				}
			end
		end
		return rows
	end

	local providers = {
		["tap_hold_global_delay"] = function()
			local global_ms = math.floor(th.global_seconds() * 1000 + 0.5)
			return { {
				label = string.format(i18n_safe("menu.tapholds.tap_hold_title"), global_ms .. " ms"),
				action = function() return ask_global_delay(global_ms) end,
			} }
		end,
		["tap_hold_keys_left"] = function() return hand_rows("left") end,
		["tap_hold_keys_right"] = function() return hand_rows("right") end,
	}

	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do render_ctx.commands[key] = value end
	-- The feature switch is persisted in the file ([tap_hold] enabled), as the
	-- Windows toggle is in its config; turning it on also lifts a runtime
	-- « Disable all ».
	render_ctx.commands[require("config_keys").COMMAND.TAPHOLDS_TOGGLE] = function()
		local want = not feature_on
		local ok = Writer.set_enabled(want)
		if ok and want then ok = th.set_enabled(true) end
		changed(ok)
	end
	-- The scope's restore and clear, the first group after the switch, run the
	-- shared scope transaction at once: both files backed up, the engine
	-- acknowledging the candidate before it is published.
	local function apply_scope(mode)
		if ctx.paused == true then return false end
		local committed = require("infra.tap_hold_scope").apply(mode, function() return ctx.paused == true end)
		changed(committed)
		return committed
	end
	render_ctx.commands[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_scope("recommended") end
	render_ctx.commands[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_scope("clear") end
	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	render_ctx.state_getters["tapholds_enabled"] = function() return feature_on end

	-- The navigation layer editor: the shared page, saved and applied by
	-- ui/layer_editor/bridge.lua.
	render_ctx.commands[require("config_keys").COMMAND.EDIT_NAV_LAYER] = function()
		if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
			Logger.error(LOG, "No webview manager in the menu context — the layer editor cannot open.")
			return
		end
		ctx.webview.show("layer_editor")
	end

	local rows = ManifestMenu
		and ManifestMenu.build("tap_holds_menu", "TapHolds", nil, nil, render_ctx, providers)
		or {}
	return receive(rows, { tapholds_enabled = function() return nil end })
end

M.build = _build_tap_holds

return M

--- ui/menu/menu_gestures.lua

--- ==============================================================================
--- MODULE: Linux Menu Gestures Submenu
--- DESCRIPTION:
--- Builds the tray's touchpad gestures submenu: one row per gesture slot with
--- its bound action, the recommended defaults and the scope commands.
--- ==============================================================================

local M = {}

local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local show_info = require("ui.menu.menu_dialogs").show_info
local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain
local assign_parameterized_action = require("ui.menu.menu_dialogs").assign_parameterized_action
local slot_binding_rows = require("ui.menu.menu_dialogs").slot_binding_rows

local function gesture_slot_label(slot)
	local fingers, direction = tostring(slot):match("^swipe_(%d+)_(.+)$")
	if fingers and direction then
		local directions = {
			left = "gauche", right = "droite", up = "haut", down = "bas",
			up_left = "haut-gauche", up_right = "haut-droite",
			down_left = "bas-gauche", down_right = "bas-droite",
		}
		return "Balayage " .. fingers .. " doigts vers " .. (directions[direction] or direction)
	end
	local tap_fingers = tostring(slot):match("^tap_(%d+)$")
	if tap_fingers then return "Tap " .. tap_fingers .. " doigts" end
	return tostring(slot)
end

--- Builds the gestures submenu.
local function _build_gestures(ctx)
	local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "gestures")
	if not receive then return nil end
	local ge = ctx.gestures
	if not ge then
		local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_gestures_absent_rows", {}, {}, {})
		if not status_rows then return {} end
		return receive(ManifestMenu.render_rows(status_rows, "linux_gestures_absent_rows"), { gestures_enabled = function() return nil end })
	end

	local enabled = ge.is_enabled()

	-- Keyed by the manifest's own row ids. Each handler appends to the table the
	-- renderer HANDS IT, never to one closed over from here: the renderer builds
	-- its own result and passes it in, so a handler writing to an outer table
	-- would emit its rows into a menu the renderer never returns — every gesture
	-- row silently missing, with nothing failing.
	local gesture_rows = {}
	local function apply_scope(mode)
		if ctx.paused == true then return false end
		local committed = ge.apply_scope(mode)
		if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return committed
	end

	-- The scope's restore and clear are `command` rows of the first group: the
	-- renderer builds each row and its label from the declaration, right after
	-- the switch, and this driver registers only what the click does.
	local gesture_commands = {
		[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_scope("recommended") end,
		[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_scope("clear") end,
	}

	-- The master toggle's BEHAVIOUR. Its label, its position and the two i18n keys
	-- that distinguish on from off are the manifest's, and the shared renderer
	-- draws it — which also retires the " ✓" this driver glued to a translated
	-- label, a mark that belonged to the tray rather than to the string.
	local gestures_on = enabled
	local function master_toggle_action()
		local before = ge.is_enabled()
		local after = ge.toggle()
		if after ~= before then require("ui.menu.feature_notice").feature(i18n_safe("menu.gestures.notify_title"), after == true) end
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	end

	local function assign_action(slot, action, picked)
		local committed = assign_parameterized_action(
			ctx,
			ge,
			slot,
			action,
			function() return ge.set_action(slot, action) end,
			picked
		)
		if committed and action ~= "none" then
			local group = slot:match("^(%a+_%d+)")
			if group then require("ui.gesture_conflicts").show({ key = group, slot = slot }) end
		end
		return committed
	end

	-- The manifest's `gesture_slots_linux` row. One flat list rather than the
	-- per-finger-count groups macOS splits into (gesture_slots_2 … _5): the slots
	-- come from ge.DEFAULT_GESTURES, which is keyed by slot name and not by finger
	-- count, so grouping would mean parsing the names apart only to regroup them.
	local providers = {}
	providers["system_gesture_status"] = function() return require("ui.gesture_conflicts").rows(ge) end
	-- The recommended-defaults rule and why Linux recommends no swipe, behind
	-- the menu's « Infos… » row: several sentences do not fit a menu row.
	gesture_commands[require("config_keys").COMMAND.GESTURE_RECOMMENDED_INFO] = function()
		show_info(i18n_safe("menu.gestures.notify_title"), zenity_plain(i18n_safe("menu.gestures.recommended_note")
			.. "\n\n" .. i18n_safe("menu.gestures.recommended_reason_linux")))
		return true
	end
	gesture_commands[require("config_keys").COMMAND.SYSTEM_GESTURE_SETTINGS] = function() return require("ui.gesture_conflicts").open_settings() end
	providers["gesture_slots_linux"] = function()
		local out = {}
		-- Every known slot is configurable here. A partial quick list made
		-- parameterized actions unreachable for the omitted gesture bindings.
		local slots = require("table_util").sorted_keys(ge.DEFAULT_GESTURES or {})

		-- What this machine's touchpad can physically express. The kernel only
		-- advertises BTN_TOOL_QUADTAP at four slots and QUINTTAP at five, so a pad
		-- that stops at three — which the Precision Touchpad spec permits — can
		-- never fire twenty of these rows. Offering them anyway is the dead-line
		-- delivery the manifest's reason mechanism exists to avoid.
		--
		-- nil when no touchpad was found or its capability could not be read, and
		-- slot_is_reachable answers TRUE for everything in that case: a probe that
		-- could not read the hardware must never take a working gesture away.
		local touchpad = type(ge.touchpad) == "function" and ge.touchpad() or nil
		local max_fingers = touchpad and touchpad.max_fingers or nil
		local ok_finder, Finder = pcall(require, "modules.gestures.touchpad_finder")

		for _, slot in ipairs(slots) do
			local reachable = true
			if ok_finder and type(Finder.slot_is_reachable) == "function" then
				reachable = Finder.slot_is_reachable(slot, max_fingers)
			end
			if not reachable then
				-- Greyed with its reason rather than hidden: a row that vanishes
				-- reads as a bug, and the user cannot tell "this hardware cannot"
				-- from "this driver forgot".
				out[#out + 1] = {
					label    = gesture_slot_label(slot) .. " — "
						.. i18n_safe("platform_reason.touchpad_cannot_count_that_many"),
					disabled = true,
				}
				goto continue
			end

			local action = ge.get_action(slot) or "none"
			local label = ge.get_action_display_label and ge.get_action_display_label(slot)
				or ge.get_action_label(action)
			local slot_label = gesture_slot_label(slot)
			local choices = slot_binding_rows(slot_label, action, slot, function(option, picked)
				local assigned = assign_action(slot, option, picked)
				if assigned and type(ctx.on_menu_changed) == "function" then
					ctx.on_menu_changed()
				end
				return assigned
			end)
			out[#out + 1] = {
				label = slot_label .. " → " .. label,
				items = choices,
			}
			::continue::
		end
		return out
	end

	-- Declared in the manifest since 2026-08-04. Linux reads gestures from
	-- libinput, which macOS gets from the OS and Windows does not have at all, so
	-- the reader is startable here and has no counterpart elsewhere. Its label was
	-- a hardcoded French string, which every non-French user read in French — and
	-- being in no manifest, no gate could see either that or the row itself.
	providers["gesture_reading_linux"] = function()
		return {
			{
				label  = i18n_safe(ge.is_reading() and "menu.gestures.reading_on" or "menu.gestures.reading_off"),
				action = function()
					if ge.is_reading() then ge.stop_reading() else ge.start_reading() end
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				end,
			},
		}
	end

	-- The master toggle is the manifest's first row and the renderer builds it,
	-- from the command registered here — the same mechanism as the two whole-tree
	-- actions below it, which have been `command` rows since 2026-08-06.
	local gesture_ctx = {}
	for key, value in pairs(ctx) do gesture_ctx[key] = value end
	gesture_ctx.commands = {}
	for key, value in pairs(gesture_commands or {}) do gesture_ctx.commands[key] = value end
	gesture_ctx.commands[require("config_keys").COMMAND.GESTURES_TOGGLE] = master_toggle_action
	gesture_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do gesture_ctx.state_getters[key] = value end
	gesture_ctx.state_getters["gestures_enabled"] = function() return gestures_on end

	local rendered = ManifestMenu.build("gestures_menu", "Gestures", gesture_rows, nil, gesture_ctx, providers)
	local menu = {}
	for _, row in ipairs(rendered or {}) do menu[#menu + 1] = row end

	return receive(menu, { gestures_enabled = function() return gestures_on end })
end

M.build = _build_gestures

return M

--- ui/menu/menu_shortcuts.lua

--- ==============================================================================
--- MODULE: Linux Menu Shortcuts Submenu
--- DESCRIPTION:
--- Builds the tray's shortcuts submenu: the keyboard shortcut slots with their
--- bound actions, the extension shortcuts, the key combinations and the script
--- chords.
--- ==============================================================================

local M = {}

local ParameterLabel = require("action_parameter_label")
local RowDialect = require("menu.row_dialect")
local Logger = require("logger.shim")
local Extensions = require("hotstrings.extensions")
local MagicKey = require("modules.hotstrings.magic_key")
local TextPrompt = require("ui.text_prompt")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local _fill = require("ui.menu.menu_dialogs")._fill
local prompt_text = require("ui.menu.menu_dialogs").prompt_text
local show_error = require("ui.menu.menu_dialogs").show_error
local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain
local assign_parameterized_action = require("ui.menu.menu_dialogs").assign_parameterized_action
local open_action_picker = require("ui.menu.menu_dialogs").open_action_picker
local slot_binding_rows = require("ui.menu.menu_dialogs").slot_binding_rows

local LOG = "ui.menu.menu_shortcuts"

--- Keeps private executable/argv data out of persistent menu presentation.
local function binding_label(label, registry, binding, action)
	if type(registry.get_action_parameter_spec) == "function" and registry.get_action_parameter_spec(action) == "program" then return label end
	return ParameterLabel.for_binding(label, registry, binding, action)
end

--- Builds the shortcuts submenu.
--- One menu row per installed extension that ships `shortcuts/menu.lua`.
---
--- The file is executed in a sandbox exposing exactly what the macOS host
--- exposes — `add_item`, `t` and `ext_name` — with the standard library reachable
--- through __index so an author can use `string` and `table` without either host
--- listing them. Anything the extension collects becomes a submenu under its own
--- name.
---
--- setfenv rather than a _ENV upvalue: this driver runs LuaJIT, which is 5.1, and
--- setfenv is the 5.1 spelling. The macOS host uses the same call.
--- @return table Array of menu rows, empty when nothing is installed.
--- Converts a row written in this driver's dialect into the provider data a
--- `list` row takes, recursively.
--- Converts a LIST of driver-dialect rows, for a caller that emits its own row
--- as provider data and only adapts what an extension handed it.
--- @param list table Array of rows in the driver dialect.
--- @return table Array of provider rows.
local function _as_provider_row_list(list)
	return RowDialect.rows(list)
end


local function _extension_shortcut_rows()
	local rows = {}

	local ok_paths, Paths = pcall(require, "infra.paths")
	local ok_loader, Loader = pcall(require, "modules.hotstrings.loader")
	if not ok_paths or not ok_loader or type(Paths.extension_roots) ~= "function" then return rows end

	-- The same io functions hotstrings_config.extension_packs() injects. The
	-- scanner takes them rather than reaching for the filesystem itself, which is
	-- what lets it be shared and tested; passing nil returns an empty list, so
	-- this is not optional.
	local ok_scan, packs = pcall(Extensions.scan, Paths.extension_roots(), {
		list_dirs  = Loader.list_subdirs,
		list_files = Loader.find_toml_files,
		read_file  = Loader.read_file,
	})
	if not ok_scan or type(packs) ~= "table" then return rows end

	-- One entry per extension: the scanner already collapses an id that appears
	-- under more than one root (bundled and user-installed).
	for _, pack in ipairs(packs) do
		local id, dir = pack.id, pack.dir
		if id and dir then
			local menu_path = dir .. "/shortcuts/menu.lua"
			local chunk = loadfile(menu_path)
			if chunk then
				local collected = {}
				local sandbox = {
					add_item = function(item)
						if type(item) == "table" then collected[#collected + 1] = item end
					end,
					t        = i18n_safe,
					ext_name = pack.name or id,
				}
				setmetatable(sandbox, { __index = _G })
				sandbox._G = sandbox

				if setfenv then setfenv(chunk, sandbox) end
				local ok_run, err = pcall(chunk)
				if not ok_run then
					-- Surfaced as a row, not only logged: an extension whose menu
					-- throws would otherwise be indistinguishable from one that
					-- declares nothing, and its author would have no way to tell.
					Logger.warn(LOG, "Extension '%s' shortcuts/menu.lua failed: %s", id, tostring(err))
					local marker_rows = ManifestMenu.template_rows("shortcut_extension_error_frame", {}, {
						shortcut_extension_name = function() return pack.name or id end,
					}, {})
					if not marker_rows or #marker_rows == 0 then return {} end
					for _, row in ipairs(marker_rows) do rows[#rows + 1] = row end
				elseif #collected > 0 then
					-- The extension's OWN rows are still adapted: an author writes
					-- them in the host dialect both Lua drivers expose (`add_item`
					-- with `title`/`fn`), and that is a published surface. This row —
					-- the pack's own entry — is ours, so it is provider data.
					local external_rows = _as_provider_row_list(collected)
					if external_rows then rows[#rows + 1] = { label = pack.name or id, items = external_rows } end
				end
			end
		end
	end

	return rows
end

--- Builds the shortcuts submenu: this driver's own rows, then the manifest's.
---
--- Hand-rolled until 2026-08-05, which is what kept `extensions_shortcuts`
--- restricted to Windows in the manifest even after both Lua drivers had
--- implemented it: a menu that dispatches nothing by id cannot be promised a row
--- by id, and the handler-bijection ratchet says so. It dispatches now, and the
--- restriction is gone.
---
--- The rows above the manifest section are this driver's own — CapsWord, the
--- selection transforms, the wrap pairs — and no manifest entry describes them
--- yet. macOS is in the same position with `at_hash`, and prepends it the
--- same way.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_shortcuts(ctx)
	local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "shortcuts")
	if not receive then return nil end
	local sc = ctx.shortcuts
	if not sc then
		local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_shortcuts_absent_rows", {}, {}, {})
		if not status_rows then return {} end
		return receive(ManifestMenu.render_rows(status_rows, "linux_shortcuts_absent_rows"), { shortcuts_enabled = function() return nil end })
	end

	local enabled = sc.is_enabled()
	local items = {}

	-- The gate row is the manifest's first row and the shared renderer builds it,
	-- from the command and the state getter registered below.

	-- The seven operations this driver performs on the current selection. Held
	-- for the `selection_operations` provider below rather than appended here:
	-- they were seven rows of a SHARED menu that no manifest described, so no
	-- gate could compare them with what the other two drivers offer, and the
	-- renderer had nothing to place.
	local function caps_word_ready()
		return type(sc.configuration_admitted) == "function" and sc.configuration_admitted() == true
			and type(sc.toggle_caps_word) == "function" and type(sc.is_caps_word_active) == "function"
			and type(sc.is_caps_word_active()) == "boolean"
	end
	local selection_rows = {}
	local caps_row = ManifestMenu.check_row("selection_caps_word_control", require("config_keys").COMMAND.SELECTION_CAPS_WORD, {
		[require("config_keys").COMMAND.SELECTION_CAPS_WORD] = function()
			if not caps_word_ready() or sc.toggle_caps_word() ~= true then return false end
			Logger.info(LOG, "CapsWord toggled: %s", tostring(sc.is_caps_word_active()))
			require("ui.menu.feature_notice").feature(i18n_safe("sg_actions.caps_word"), sc.is_caps_word_active() == true)
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end,
	}, {
		["selection_caps_word_active"] = function()
			return type(sc.is_caps_word_active) == "function" and sc.is_caps_word_active() == true
		end,
		["selection_caps_word_ready"] = caps_word_ready,
	})
	if caps_row then selection_rows[#selection_rows + 1] = caps_row end
	local case_boundary = ManifestMenu.template_rows("selection_case_boundary", {}, {}, {})
	if not case_boundary then return {} end
	for _, row in ipairs(case_boundary) do selection_rows[#selection_rows + 1] = row end
	local case_methods = {
		uppercase_selection = "transform_uppercase",
		selection_lowercase = "transform_lowercase",
		titlecase_selection = "transform_titlecase",
	}
	local function case_ready(method)
		return type(sc.configuration_admitted) == "function" and sc.configuration_admitted() == true
			and type(sc[method]) == "function"
	end
	local case_getters = {
		uppercase_selection_ready = function() return case_ready(case_methods.uppercase_selection) end,
		selection_lowercase_ready = function() return case_ready(case_methods.selection_lowercase) end,
		titlecase_selection_ready = function() return case_ready(case_methods.titlecase_selection) end,
	}
	for _, command in ipairs(ManifestMenu.get_array("selection_case_commands")) do
		local id, method = command.id, case_methods[command.id]
		local ready = assert(case_getters[id .. "_ready"], "Selection case command has no native owner")
		local row = ManifestMenu.command_row("selection_case_commands", id, {
			[id] = function()
				if not ready() or sc[method]() ~= true then return false end
				return true
			end,
		}, case_getters)
		if row then selection_rows[#selection_rows + 1] = row end
	end
	local helper_boundary = ManifestMenu.template_rows("selection_helper_boundary", {}, {}, {})
	if not helper_boundary then return {} end
	for _, row in ipairs(helper_boundary) do selection_rows[#selection_rows + 1] = row end
	local helper_methods = {
		[require("config_keys").COMMAND.SELECTION_SELECT_WORD] = "select_word",
		[require("config_keys").COMMAND.SELECTION_SELECT_LINE] = "select_line",
		[require("config_keys").COMMAND.SELECTION_PASTE_PLAIN] = "paste_plain",
	}
	local helper_getters = {
		selection_select_word_ready = function() return case_ready(helper_methods.selection_select_word) end,
		selection_select_line_ready = function() return case_ready(helper_methods.selection_select_line) end,
		selection_paste_plain_ready = function() return case_ready(helper_methods.selection_paste_plain) end,
	}
	for _, command in ipairs(ManifestMenu.get_array("selection_helper_commands")) do
		local id, method = command.id, helper_methods[command.id]
		local ready = assert(helper_getters[id .. "_ready"], "Selection helper command has no native owner")
		local row = ManifestMenu.command_row("selection_helper_commands", id, {
			[id] = function()
				if not ready() or sc[method]() ~= true then return false end
				return true
			end,
		}, helper_getters)
		if row then selection_rows[#selection_rows + 1] = row end
	end

	-- Wrap symbols submenu. Ordered, because `get_wrap_pairs` returns a map and
	-- `pairs` would give the user a different order on every rebuild.
	local wrap_items = {}
	local opening = {}
	for ch, pair in pairs(sc.get_wrap_pairs()) do
		-- Only the opening character: each pair is stored under both of its ends.
		if ch == pair.left then opening[#opening + 1] = { ch = ch, pair = pair } end
	end
	table.sort(opening, function(a, b) return a.ch < b.ch end)
	for _, entry in ipairs(opening) do
		local pair = entry.pair
		-- The pair around an ellipsis, and nothing else. This used to append a
		-- second illustration, "(«texte»)", whose only content was a French word —
		-- so the row was a translated label followed by an untranslated one, and
		-- the ellipsis had already said the same thing in every language.
		wrap_items[#wrap_items + 1] = {
			label  = string.format("%s … %s", entry.ch, pair.right),
			action = function() sc.wrap_selection(pair.left, pair.right) end,
		}
	end

	local handlers = {}

	-- The manifest's `keyboard_slots` row, which this driver could not answer
	-- until it had a chord capture and somewhere to store an assignment. One
	-- submenu per modifier group, each listing every key in the shared catalogue
	-- with whatever the user has bound to it — the same shape the gesture slots
	-- use, for the same reason: the slot space is fixed and the assignment is the
	-- user's, so a static entry cannot enumerate the rows.
	local providers = {}
	providers["keyboard_slots"] = function()
		local ok_kbd, Keyboard = pcall(require, "modules.shortcuts.keyboard_shortcuts")
		local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
		if not ok_kbd or not ok_gestures then
			Logger.error(LOG, "Keyboard slots unavailable — the shortcuts submenu loses its bindings.")
			return {}
		end

		-- The action catalogue is the gestures manager's, and the labels with it:
		-- the picker opened below lists it with its headings.
		local out = {}
		local skipped = {}
		local function assign_slot(slot, option, picked)
			local assigned = assign_parameterized_action(
				ctx,
				Gestures,
				Keyboard.binding_id(slot),
				option,
				function() return Keyboard.set_action(slot, option) end,
				picked
			)
			if assigned and type(ctx.on_menu_changed) == "function" then
				ctx.on_menu_changed()
			end
			return assigned
		end
		-- The restore and the clear at the top of a bindable group: the
		-- Shortcuts scope narrowed to that group's slots and parameters, at once
		-- and without a question, like every scope row.
		local function group_scope_rows(prefix)
			local function apply_group_scope(mode)
				if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
				local committed = require("infra.shortcuts_scope").apply(mode, ctx.is_paused, "keyboard_group:" .. prefix)
				if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return committed
			end
			local rows = ManifestMenu.template_rows("keyboard_group_scope_controls", {
				[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_group_scope("recommended") end,
				[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_group_scope("clear") end,
			}, {
				["keyboard_group_ready"] = function()
					return ctx.paused ~= true and type(ctx.is_paused) == "function" and ctx.is_paused() == false
				end,
			}, {})
			-- A withdrawn declaration withdraws both rows: no half-declared group.
			if type(rows) ~= "table" or #rows ~= 3 then
				Logger.error(LOG, "Keyboard group '%s' scope rows refused by the manifest.", prefix)
				return {}
			end
			return rows
		end
		for _, group in ipairs(Keyboard.SLOT_GROUPS) do
			local rows = {}
			for _, slot in ipairs(Keyboard.available_slots(group.prefix)) do
				local bound = Keyboard.get_action(slot) or "none"
				local reason
				if slot == require("shortcuts.magic_editor").SLOT_ID then
					local gate = ctx.input_capture_gate
					reason = Keyboard.magic_editor_decision({ master = enabled == true,
						paused = ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused() == true),
						inhibited = type(gate) == "table" and type(gate.blocks_text) == "function" and gate.blocks_text() == true }).reason
				end
				local slot_label = Keyboard.get_slot_label(slot, reason)
				local choices = slot_binding_rows(slot_label, bound, Keyboard.binding_id(slot),
					function(option, picked) return assign_slot(slot, option, picked) end)
				rows[#rows + 1] = {
					label = slot_label
						.. " → " .. binding_label(Gestures.get_action_label(bound),
							Gestures, Keyboard.binding_id(slot), bound),
					items = choices,
				}
			end
			-- A group with no slot is the key catalogue failing to load: drawing it
			-- anyway put three submenus that open onto nothing in the tray.
			if #rows > 0 then
				if group.add_key ~= nil then
					local scope_rows = group_scope_rows(group.prefix)
					for index = #scope_rows, 1, -1 do table.insert(rows, 1, scope_rows[index]) end
				end
				out[#out + 1] = { label = i18n_safe(group.group_key), items = rows }
			else
				skipped[#skipped + 1] = group.prefix
			end
		end
		if #skipped > 0 then
			Logger.error(LOG, "Keyboard slot group(s) %s not drawn: the key catalogue offered no slot.",
				table.concat(skipped, ", "))
		end
		return out
	end

	-- The number-row tap keys: one row per key, named by what a tap on it types
	-- under the loaded XKB keymap, then its action; the submenu opens the picker.
	providers["tap_keys"] = function()
		local ok_tap, TapKeys = pcall(require, "modules.shortcuts.tap_keys")
		local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
		if not ok_tap or not ok_gestures then
			Logger.error(LOG, "Tap keys unavailable — the shortcuts submenu loses them.")
			return {}
		end
		local ok_layout, Layout = pcall(require, "adapters.keyboard_layout")
		local labels = { get = i18n_safe }
		-- An action on the key chosen as the physical magic key takes its press;
		-- the row says so, and so does the log when the assignment is made.
		local Source = type(ctx.magic_key_source) == "table" and ctx.magic_key_source or nil
		local rows = {}
		for _, key in ipairs(TapKeys.keys()) do
			local bound = TapKeys.get_action(key.id)
			local name = TapKeys.display_name(key.id, ok_layout and Layout or nil, labels)
			local function assign(option, picked)
				local assigned = assign_parameterized_action(ctx, Gestures, TapKeys.binding_id(key.id),
					option, function() return TapKeys.set_action(key.id, option) end, picked)
				if assigned and Source and Source.tap_override_reason(key.linux, option) ~= nil then
					Logger.warn(LOG, "Tap key '%s' → '%s' takes the physical magic key %s: that key no longer types "
						.. "the magic key.", key.id, tostring(option), tostring(Source.get()))
				end
				if assigned and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return assigned
			end
			local override = Source and Source.tap_override_reason(key.linux, bound) or nil
			rows[#rows + 1] = {
				label = name .. " → " .. (bound ~= "none" and binding_label(
					Gestures.get_action_label(bound), Gestures, TapKeys.binding_id(key.id), bound)
					or i18n_safe("menu.shortcuts.tap_keys.unassigned"))
					.. (override and (" — " .. i18n_safe(override)) or ""),
				items = slot_binding_rows(name, bound, TapKeys.binding_id(key.id), assign),
			}
		end
		return rows
	end

	-- « Raccourcis de gestion du script », declared by script_control_group as
	-- on every driver: the chords' switch, the restore of their preset, the
	-- clear to the system's behaviour, then one row per slot. The restore and
	-- the clear apply at once, without a question, through the Shortcuts scope
	-- narrowed to the chords; the clear writes "none" in every slot, since an
	-- absent slot starts with its preset. The title is ticked from the switch.
	local group_builders = {}
	group_builders["key_combinations"] = function()
		return require("ui.menu.key_combinations").build(ctx, {
			manifest = ManifestMenu, get = i18n_safe, key_label = function(entry)
				local label = i18n_safe(entry.label_key); return label == entry.label_key and entry.id or label
			end,
			action_label = function(action, gestures) return gestures.get_action_label(action) end,
			open_picker = open_action_picker, error = show_error,
			prompt_delay = function(current, declared)
				return TextPrompt.ask(i18n_safe("menu.tapholds.simultaneous_dialog_title"),
					zenity_plain(string.format(i18n_safe("menu.tapholds.simultaneous_dialog_prompt"), declared)), tostring(current))
			end,
			-- A pair's hold opens the shared action picker, titled by its slot
			-- and the pair, with the hold options the provider lists.
			open_hold_picker = function(pair_label, current, items, on_confirm)
				local ok_picker, Picker = pcall(require, "ui.action_picker.bridge")
				if not ok_picker or type(Picker.open) ~= "function" then
					Logger.error(LOG, "Action picker is unavailable for the hold of '%s'.", tostring(pair_label))
					return false
				end
				return Picker.open({
					presentation_id = "key_combination_hold_action",
					presentation_suffix = pair_label,
					current = current,
					items = items,
				}, function(picked) return on_confirm(picked) end) == true
			end,
			parameter = function(context, gestures, binding, action, spec)
				local prior = gestures.get_action_parameter(binding, action)
				if type(context.prompt_action_parameter) == "function" then
					return context.prompt_action_parameter(binding, action, spec, prior)
				end
				if spec == "program" then return nil end
				if spec == "app" then
					return require("ui.app_chooser").pick(require("adapters.shell_runner"), gestures.get_action_parameter_prompt(action))
				end
				local title = _fill(i18n_safe("dialog.gestures.param_title"), "{1}", gestures.get_action_label(action))
				-- A backend is picked from a list, as on the action picker page.
				if spec == "llm_vision" then return require("ui.vision_parameter_prompt").ask(title, prior) end
				return prompt_text(title, zenity_plain(gestures.get_action_parameter_prompt(action)), prior)
			end,
		})
	end
	group_builders[require("config_keys").LEAF.SCRIPT_CONTROL] = function()
		local ok_chords, Chords = pcall(require, "modules.shortcuts.script_chords")
		local ok_gestures, Gestures = pcall(require, "modules.gestures.manager")
		if not ok_chords or not ok_gestures then
			Logger.error(LOG, "Script chords unavailable — the shortcuts submenu loses them.")
			return nil
		end
		local chords_on = Chords.chords_enabled()
		local chord_providers = {}
		chord_providers["script_control_shortcuts"] = function()
			local rows = {}
			for _, slot in ipairs(Chords.slots()) do
				local bound = Chords.get_action(slot.id)
				local name = i18n_safe("sg_labels." .. slot.id)
				local function assign(option, picked)
					local assigned = assign_parameterized_action(ctx, Gestures, Chords.binding_id(slot.id),
						option, function() return Chords.set_action(slot.id, option) end, picked)
					if assigned and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return assigned
				end
				rows[#rows + 1] = {
					label = name .. " → " .. binding_label(Gestures.get_action_label(bound),
						Gestures, Chords.binding_id(slot.id), bound),
					items = slot_binding_rows(name, bound, Chords.binding_id(slot.id), assign),
				}
			end
			return rows
		end
		local function apply_chords_scope(mode)
			if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
			local committed = require("infra.shortcuts_scope").apply(mode, ctx.is_paused, "script_chords")
			if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return committed
		end
		local chords_ctx = {}
		for key, value in pairs(ctx) do chords_ctx[key] = value end
		chords_ctx.commands = {}
		for key, value in pairs(ctx.commands or {}) do chords_ctx.commands[key] = value end
		chords_ctx.commands[require("config_keys").COMMAND.SCRIPT_CONTROL_TOGGLE] = function()
			local read, current = false, nil
			if type(Chords.chords_enabled) == "function" then read, current = pcall(Chords.chords_enabled) end
			local called, committed = false, false
			if read and type(current) == "boolean" and type(Chords.set_chords_enabled) == "function" then
				called, committed = pcall(Chords.set_chords_enabled, not current)
			end
			if not called or committed ~= true then
				Logger.error(LOG, "The script chord switch did not acknowledge durable publication.")
				show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
				return false
			end
			require("ui.menu.feature_notice").feature(i18n_safe("notify.script_control"), not current)
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end
		chords_ctx.commands[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_chords_scope("recommended") end
		chords_ctx.commands[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_chords_scope("clear") end
		chords_ctx.state_getters = {}
		for key, value in pairs(ctx.state_getters or {}) do chords_ctx.state_getters[key] = value end
		chords_ctx.state_getters["script_control_enabled"] = function() return chords_on end
		-- Already rendered: the group row takes the rows as its finished submenu.
		return ManifestMenu.build("script_control_group", "Shortcuts", nil, nil, chords_ctx, chord_providers)
	end

	-- « CapsWord : désactivation automatique », declared by
	-- caps_word_auto_off_group: the delay choice, one checkbox per delimiter of
	-- the hotstring catalogue (in its order, with its separators and labels) and
	-- one per declared pointer kind. Each change is published, then cached, and
	-- applies to the CapsWord running now from its next event.
	group_builders["caps_word_auto_off"] = function()
		local ok_settings, AutoOff = pcall(require, "modules.shortcuts.caps_word_auto_off")
		local ok_policy, Policy = pcall(require, "caps_word.auto_off")
		if not ok_settings or not ok_policy then
			Logger.error(LOG, "CapsWord auto-off settings unavailable — the shortcuts submenu loses them.")
			return nil
		end
		-- Read once per build: a scope restore or a hand edit shows here.
		AutoOff.refresh()
		local settings = AutoOff.settings()
		local function changed(committed)
			if committed ~= true then
				show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
				return false
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return true
		end
		local checked = {}
		for _, key in ipairs(settings.terminators) do checked[key] = true end
		local boundaries = ManifestMenu.template_rows("hotstrings_parameter_boundary", {}, {}, {})
		local providers_cw = {}
		providers_cw["caps_word_terminators"] = function()
			local rows = {}
			for _, row in ipairs(Policy.terminator_rows()) do
				if row.separator then
					for _, boundary in ipairs(boundaries or {}) do rows[#rows + 1] = boundary end
				else
					local key = row.key
					rows[#rows + 1] = {
						label = (i18n_safe(row.label_key):gsub("★", MagicKey.get())),
						checked = checked[key] == true,
						action = function() return changed(AutoOff.set_terminator(key, not checked[key])) end,
					}
				end
			end
			return rows
		end
		local cw_ctx = {}
		for key, value in pairs(ctx) do cw_ctx[key] = value end
		cw_ctx.commands = {}
		for key, value in pairs(ctx.commands or {}) do cw_ctx.commands[key] = value end
		cw_ctx.state_getters = {}
		for key, value in pairs(ctx.state_getters or {}) do cw_ctx.state_getters[key] = value end
		cw_ctx.commands[require("config_keys").COMMAND.CAPS_WORD_IDLE_TIMEOUT] = function(seconds)
			return changed(AutoOff.set_idle_timeout_seconds(seconds))
		end
		cw_ctx.state_getters[require("config_keys").KEY.SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS] = function()
			return settings.idle_timeout_seconds
		end
		-- One checkbox per kind the manifest declares, in its order; a kind
		-- this driver cannot see is drawn greyed with its own reason.
		providers_cw["caps_word_pointer_kinds"] = function()
			local rows = {}
			for _, entry in ipairs(AutoOff.pointer_kind_rows()) do
				local kind = entry.kind
				local row = { label = i18n_safe(entry.label_key), checked = settings.pointer[kind] == true }
				if entry.available then
					row.action = function() return changed(AutoOff.set_pointer(kind, not settings.pointer[kind])) end
				else
					row.checked, row.disabled, row.disabled_reason_key = false, true, entry.reason_key
				end
				rows[#rows + 1] = row
			end
			return rows
		end
		return ManifestMenu.build("caps_word_auto_off_group", "Shortcuts", nil, nil, cw_ctx, providers_cw)
	end

	-- The wrap-symbol picker. The manifest called it Windows-only until
	-- 2026-08-06 while this driver had been drawing it all along; it is a shared
	-- `list` row now, in the same position on all three drivers.
	providers["wrap_symbols_menu"] = function()
		return ManifestMenu.template_rows("shortcut_wrap_frame", {}, {}, {
			shortcut_wrap_symbols_linux = function() return wrap_items end,
		})
	end

	providers["selection_operations"] = function()
		return selection_rows
	end

	-- One row per installed extension that ships shortcuts/menu.lua.
	--
	-- An extension author writes that file and it appears under Raccourcis on
	-- macOS and, as menu.ahk, on Windows. On Linux nothing appeared, so every
	-- action an extension declared was unreachable — and the bundled demo
	-- extension carries the file, so this reproduced out of the box.
	--
	-- Provider data since 2026-08-07: the rows are the renderer's to build, and
	-- only the submenu each extension declares for itself stays this driver's.
	providers["extensions_shortcuts"] = function()
		return _extension_shortcut_rows()
	end

	-- `shortcuts_toggle` is the submenu's first row: appindicator binds item.fn
	-- only on a row with no submenu, so the parent cannot carry the switch.
	local sc_ctx = {}
	for key, value in pairs(ctx) do sc_ctx[key] = value end
	sc_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do sc_ctx.commands[key] = value end
	local function apply_shortcuts_scope(mode)
		if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
		local committed = require("infra.shortcuts_scope").apply(mode, ctx.is_paused)
		if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return committed
	end
	sc_ctx.commands[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_shortcuts_scope("recommended") end
	sc_ctx.commands[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_shortcuts_scope("clear") end
	sc_ctx.commands[require("config_keys").COMMAND.SHORTCUTS_TOGGLE] = function()
		local read, current = false, nil
		if type(sc.is_enabled) == "function" then read, current = pcall(sc.is_enabled) end
		local called, committed = false, false
		if read and type(current) == "boolean" and type(sc.set_enabled) == "function" then
			called, committed = pcall(sc.set_enabled, not current)
		end
		if not called or committed ~= true then
			Logger.error(LOG, "The shortcuts master did not acknowledge durable publication.")
			show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
			return false
		end
		require("ui.menu.feature_notice").feature(i18n_safe("menu.shortcuts.title"), not current)
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return true
	end
	sc_ctx.commands[require("config_keys").COMMAND.EDIT_CHATGPT_URL] = function()
		local ok_chatgpt, ChatGPT = pcall(require, "modules.shortcuts.chatgpt")
		if not ok_chatgpt or type(ChatGPT.get_url) ~= "function"
			or type(ChatGPT.set_url) ~= "function" then
			Logger.error(LOG, "ChatGPT URL settings are unavailable — the value cannot be edited.")
			return
		end
		local value = prompt_text(
			i18n_safe("dialog.shortcuts.chatgpt_title"),
			i18n_safe("dialog.shortcuts.chatgpt_prompt"),
			ChatGPT.get_url())
		if value == nil then return end
		if type(ChatGPT.is_valid) ~= "function" or not ChatGPT.is_valid(value) then
			show_error(i18n_safe("dialog.gestures.param_err_url"))
			return
		end
		if ChatGPT.set_url(value) and type(ctx.on_menu_changed) == "function" then
			ctx.on_menu_changed()
		end
	end
	sc_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do sc_ctx.state_getters[key] = value end
	local physical_editor = require("shortcuts.physical_editor_menu").new({
		paused = function()
			if ctx.paused == true or type(ctx.is_paused) ~= "function" then return nil end
			return ctx.is_paused()
		end,
		scope = function() return require("infra.shortcuts_scope").editor_owner(ctx.is_paused) end,
		host = function() return require("ui.physical_shortcuts.bridge") end,
		refused = function() show_error(i18n_safe("physical_shortcuts.window_unavailable")) end,
	})
	sc_ctx.commands[require("config_keys").COMMAND.PHYSICAL_SHORTCUTS_EDITOR] = physical_editor.open
	sc_ctx.state_getters["physical_shortcuts_editor_ready"] = physical_editor.ready
	sc_ctx.state_getters["shortcuts_enabled"] = function() return enabled end
	sc_ctx.state_getters["key_combinations_enabled"] = function()
		return require("modules.shortcuts.key_combinations").is_enabled() == true
	end
	-- Ticks « Raccourcis de gestion du script » while its switch is on.
	sc_ctx.state_getters["script_control_enabled"] = function()
		local ok_chords, Chords = pcall(require, "modules.shortcuts.script_chords")
		return ok_chords and Chords.chords_enabled() == true
	end
	-- The manifest's `feature` row for wrap-on-type, drawn where the manifest
	-- hangs it (just above the wrap-symbol picker). Its label is the feature's
	-- own description key, as on Windows.
	sc_ctx.feature_rows = {}
	for key, value in pairs(ctx.feature_rows or {}) do sc_ctx.feature_rows[key] = value end
	local function wrap_on_type_ready()
		return type(sc.is_enabled) == "function" and sc.is_enabled() == true
			and type(sc.configuration_admitted) == "function" and sc.configuration_admitted() == true
			and type(sc.is_wrap_on_type_enabled) == "function" and type(sc.set_wrap_on_type_enabled) == "function"
	end
	if type(sc.is_wrap_on_type_enabled) == "function" then
		sc_ctx.feature_rows[require("config_keys").KEY.SHORTCUTS_WRAP_TEXT_IF_SELECTED] = function()
			local on = sc.is_wrap_on_type_enabled()
			local rows = ManifestMenu.template_rows("shortcut_wrap_live_control", {
				[require("config_keys").COMMAND.SHORTCUT_WRAP_ON_TYPE] = function()
					if not wrap_on_type_ready() then return false end
					local current = sc.is_wrap_on_type_enabled()
					if type(current) ~= "boolean" or not wrap_on_type_ready() then return false end
					if sc.set_wrap_on_type_enabled(not current) ~= true then return false end
					require("ui.menu.feature_notice").feature(i18n_safe("shortcuts.label_wrap_text"), not current)
					if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					return true
				end,
			}, {
				shortcut_wrap_on_type_checked = function() return on == true end,
				shortcut_wrap_on_type_ready = function() return wrap_on_type_ready() and type(on) == "boolean" end,
			}, {})
			if not rows or #rows ~= 1 then return nil end
			return rows[1]
		end
	end

	local manifest_rows = ManifestMenu
		and ManifestMenu.build("shortcuts_menu", "Shortcuts", handlers, group_builders, sc_ctx, providers)
		or {}
	if #manifest_rows > 0 then
		for _, row in ipairs(manifest_rows) do items[#items + 1] = row end
	end

	return receive(items, { shortcuts_enabled = function() return enabled end })
end

M.build = _build_shortcuts

return M

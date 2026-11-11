--- ui/menu/menu_layouts.lua

--- ==============================================================================
--- MODULE: Linux Menu Keyboard Layout Submenu
--- DESCRIPTION:
--- Builds the tray's keyboard layout submenu: the installed layouts with the
--- active one ticked, the custom layouts, the desktop's input sources, the
--- number-row policy and the pause layout rows, with the notices a layout
--- switch shows.
--- ==============================================================================

local M = {}

local NativePresentation = require("infra.native_presentation")
local PrepareNativePresentation, NativePresentationTitle = NativePresentation.prepare, NativePresentation.title
local NumberRowPolicy = require("layout.number_row_policy")
local Logger = require("logger.shim")
local MagicKeySourceRows = require("keymap.magic_key_source")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local show_error = require("ui.menu.menu_dialogs").show_error

local LOG = "ui.menu.menu_layouts"

--- Builds the layout selection submenu.
---
--- The rows were two names written out here — "qwerty" and "azerty" — while the
--- decoder already owned the list. `input_reader.get_layouts()` is the very table
--- it resolves keycodes through, so a menu that enumerates it by hand goes stale
--- the day a third one is added, and says nothing about which the driver can
--- actually decode.
local function _build_layouts(ctx)
	local receive = ManifestMenu and ManifestMenu.group_receiver("top_level", "keyboard_layout")
	if not receive then return nil end
	local current = ctx.layout or "qwerty"
	local on_change = ctx.on_layout_change

	-- Layout selection controls character interpretation here; the manifest
	-- restricts the layout emulation switch to Windows with its reason.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	-- The "Manage layouts…" row opens the shared layout manager window.
	render_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do render_ctx.commands[key] = value end
	render_ctx.commands[require("config_keys").COMMAND.LAYOUT_MANAGER] = function()
		if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
			Logger.error(LOG, "No webview manager in the menu context — the layout manager cannot open.")
			return false
		end
		return ctx.webview.show(require("config_keys").COMMAND.LAYOUT_MANAGER)
	end
	-- « Create or edit a layout… »: the same window, straight on the layout editor
	-- (ui/layout_manager/bridge.lua open_editor answers once the page is ready).
	render_ctx.commands[require("config_keys").COMMAND.LAYOUT_EDITOR] = function()
		if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
			Logger.error(LOG, "No webview manager in the menu context — the layout editor cannot open.")
			return false
		end
		local shown = ctx.webview.show(require("config_keys").COMMAND.LAYOUT_MANAGER)
		if shown == false then return false end
		return require("ui.layout_manager.bridge").open_editor()
	end


	local providers = {
		-- The custom layout picker: the registry layouts the layout manager
		-- installed, the one this session activated checked; choosing one makes
		-- it the first input source of the desktop session.
		["custom_layouts"] = function()
			local ok_registry, LayoutRegistry = pcall(require, "modules.keymap.layout_registry")
			if not ok_registry then
				Logger.error(LOG, "The layout registry client is unavailable: %s.", tostring(LayoutRegistry))
				return {}
			end
			local snapshot = LayoutRegistry.snapshot()
			local entries = {}
			for _, entry in pairs(snapshot.installed or {}) do entries[#entries + 1] = entry end
			table.sort(entries, function(a, b) return tostring(a.name) < tostring(b.name) end)
			local rows = {}
			for _, entry in ipairs(entries) do
				local id = entry.id
				rows[#rows + 1] = {
					label   = type(entry.name) == "string" and entry.name or id,
					checked = snapshot.active == id,
					action  = function()
						LayoutRegistry.select(id, function(selected, _, detail)
							if not selected then
								Logger.error(LOG, "The '%s' layout could not be activated: %s.", id, tostring(detail))
							elseif type(ctx.on_menu_changed) == "function" then
								ctx.on_menu_changed()
							end
						end)
					end,
				}
			end
			if #rows == 0 then
				if type(ManifestMenu) ~= "table" or type(ManifestMenu.status_rows) ~= "function" then return {} end
				local status = ManifestMenu.status_rows("layout_menu", "custom_layouts", "none_installed")
				return type(status) == "table" and status or {}
			end
			return rows
		end,
		["base_layouts"] = function()
			local ok_reader, reader = pcall(require, "modules.hotstrings.input_reader")
			if not ok_reader or type(reader.get_layouts) ~= "function" then
				Logger.error(LOG, "The input reader exposes no layout table — no layout can be offered.")
				return {}
			end
			local known = reader.get_layouts()
			if type(known) ~= "table" then
				Logger.error(LOG, "The layout table is not a table — no layout can be offered.")
				return {}
			end

			-- Ordered: `pairs` would reshuffle the list on every menu build.
			local names = require("table_util").sorted_keys(known)

			local rows = {}
			for _, name in ipairs(names) do
				local chosen = name
				rows[#rows + 1] = {
					label   = name,
					-- The tray draws its own mark. The glued "✓" this used to carry
					-- puts one platform's convention inside a string, and the row was
					-- not even a check item.
					checked = current == name,
					action  = function()
						if type(on_change) ~= "function" then
							Logger.error(LOG, "ctx.on_layout_change is absent — '%s' cannot be selected.", chosen)
							return
						end
						on_change(chosen)
					end,
				}
			end
			return rows
		end,
	}

	-- The layout emulation (modules/keymap/layout_emulation.lua): the layout it
	-- types over the session's XKB layout, its two layers and its four rows. A
	-- change is stored, then the emulation reloads it at once.
	local function emulation_changed(committed)
		if not committed then show_error(i18n_safe("menu.layout.emulation_not_saved")) end
		local reloaded = require("modules.keymap.layout_emulation").reload_if_started()
		if committed and reloaded == false then show_error(i18n_safe("menu.layout.emulation_failed")) end
		if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
	end
	local EmulationRows = require("layouts.emulation_menu")
	providers["layout_emulation"] = function()
		local Preferences = require("infra.layout_emulation_preferences")
		local Registry = require("modules.keymap.layout_registry")
		return EmulationRows.choice_rows({
			t = i18n_safe,
			settings = Preferences.settings(),
			status = require("modules.keymap.layout_emulation").status(),
			snapshot = Registry.snapshot(),
			choose = function(choice) emulation_changed(Preferences.choose(choice)) end,
		})
	end
	local function switch_rows(path, label_key)
		local Preferences = require("infra.layout_emulation_preferences")
		return EmulationRows.switch_row({
			t = i18n_safe, label_key = label_key, checked = Preferences.switch(path),
			toggle = function(value) emulation_changed(Preferences.set_switch(path, value)) end,
		})
	end
	providers["layout_features_base"] = function()
		return { switch_rows(require("config_keys").KEY.LAYOUT_ERGOPTI_BASE, "layout.ergoptibase") }
	end
	providers["layout_features_altgr"] = function()
		return { switch_rows(require("config_keys").KEY.LAYOUT_ERGOPTI_ALT_GR, "layout.ergoptialtgr") }
	end
	render_ctx.feature_rows = {}
	for path, row in pairs(ctx.feature_rows or {}) do render_ctx.feature_rows[path] = row end
	for _, row in ipairs({ "number_row", "top_row", "home_row", "bottom_row" }) do
		local path = "layout.emulate_" .. row
		render_ctx.feature_rows[path] = function() return switch_rows(path, "menu.layout.emulate_" .. row) end
	end

	-- The physical magic key: the key typing the magic key, chosen by pressing it
	-- or from the candidates (modules/hotstrings/magic_key_source.lua); the rows
	-- are the shared ones macOS draws too.
	providers[require("config_keys").LEAF.MAGIC_KEY_SOURCE] = function()
		local Source = ctx.magic_key_source
		if type(Source) ~= "table" then
			Logger.error(LOG, "No physical magic-key owner in the menu context — its row cannot be built.")
			return {}
		end
		local function notify(key, level)
			local ok_notifier, Notifier = pcall(require, "adapters.application_notifier")
			if ok_notifier then
				local body = i18n_safe(key)
				local receipt = PrepareNativePresentation("magic_key_source_notice", "notification")
				local title = receipt and NativePresentationTitle(receipt) or nil
				if title == nil then return false end
				Notifier.send(body, { title = title, level = level })
			else
				Logger.error(LOG, "No notifier: %s.", i18n_safe(key))
			end
		end
		local function changed()
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end
		return MagicKeySourceRows.menu_rows(Source.resolver(), {
			manifest = ManifestMenu,
			t = i18n_safe,
			current = Source.get(),
			key_text = Source.key_text,
			reason = Source.choice_reason,
			choose = function(value)
				local ok, reason = Source.set(value)
				if not ok then
					show_error(i18n_safe(reason))
					return
				end
				changed()
			end,
			capture = Source.can_capture() and function()
				local started = Source.capture({
					on_chosen = changed,
					on_refused = function(reason) notify(reason, "warning") end,
				})
				if started then notify("dialog.magic_key_source.prompt", "info") end
			end or nil,
		})
	end

	-- The scope's restore and clear: the layout rows of config.toml (number-row
	-- ordering and edges), loaded by the session before they settle.
	local function apply_layout_scope(mode)
		if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
		local settled, committed = false, nil
		require("infra.keyboard_layout_scope").request(mode, ctx.is_paused, function(ok, detail)
			settled, committed = true, ok
			if not ok then
				Logger.error(LOG, "Keyboard layout scope '%s' was not applied: %s.", mode, tostring(detail))
				show_error(i18n_safe("layouts.linux_rows_not_applied"))
			end
			-- The scope holds the emulation's rows too: it types what was restored.
			require("modules.keymap.layout_emulation").reload_if_started()
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end)
		-- The session may answer later: a dispatched request is accepted now and
		-- its refusal is told when it settles.
		return not settled or committed == true
	end
	render_ctx.commands[require("config_keys").COMMAND.SCOPE_RESTORE] = function()
		return apply_layout_scope("recommended")
	end
	render_ctx.commands[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_layout_scope("clear") end

	-- Native-only status never acquires a preference or forced-input writer.
	render_ctx.commands[require("config_keys").COMMAND.NUMBER_ROW_MODE] = function() return false end
	render_ctx.commands[require("config_keys").COMMAND.NUMBER_ROW_EDGES] = function() return false end
	providers["number_row_policy"] = function()
		local NumberRowLive = require("modules.keymap.number_row_live")
		local available, reason = NumberRowLive.available()
		-- An emulation typing the number row applies the ordering itself.
		local emulating = require("modules.keymap.layout_emulation").status().active == true
		available = available or emulating
		local stored = NumberRowLive.stored()
		-- The choice is stored first; a refusal after that is told, except the two the
		-- greyed row already explains.
		local function applied(ok, code)
			if emulating then require("modules.keymap.layout_emulation").reload_if_started() end
			if not ok and code ~= "session_unsupported" and code ~= "no_source_layout" then
				show_error(i18n_safe("layouts.linux_rows_not_applied"))
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end
		return NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands, {
			available = available,
			reason_key = reason == "no_source_layout" and "platform_reason.number_row_live_no_layout"
				or "platform_reason.number_row_live_session",
			get_order = function() return stored.order end,
			get_edges = function() return stored.edges end,
			set_order = function(value) return NumberRowLive.set("order", value, applied) end,
			set_edges = function(value) return NumberRowLive.set("edges", value, applied) end,
		})
	end
	-- Layout on pause / resume: the shared frames macOS draws, listing the
	-- desktop's own layouts (ui/menu/pause_layout_rows.lua).
	providers["layout_switching"] = function()
		if type(ctx.pause_layout) ~= "table" then
			Logger.error(LOG, "No pause layout switch in the menu context — its rows cannot be built.")
			return {}
		end
		return require("ui.menu.pause_layout_rows").rows({
			paused = ctx.paused == true,
			t = i18n_safe,
			show_error = show_error,
			on_changed = function()
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end,
			preferences = require("infra.pause_layout_preferences"),
			switch = ctx.pause_layout,
		})
	end
	-- Input sources: the desktop's layouts, the active one ticked; choosing one
	-- switches the desktop (ui/menu/active_layout_rows.lua), as macOS does.
	providers["active_layouts"] = function()
		if type(ctx.pause_layout) ~= "table" then
			Logger.error(LOG, "No layout switch in the menu context — the input sources cannot be listed.")
			return {}
		end
		return require("ui.menu.active_layout_rows").rows({
			t = i18n_safe,
			show_error = show_error,
			on_changed = function()
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			end,
			switch = ctx.pause_layout,
		})
	end
	-- « Raccourcis sur les lettres accentuées », the Windows letter pickers:
	-- one submenu per letter, « Désactivé » then the 26 target letters.
	local group_builders = {}
	group_builders["accented_letters"] = function()
		local Accented = require("modules.shortcuts.accented_shortcuts")
		local settings = Accented.settings()
		if not settings then
			Logger.error(LOG, "The accented shortcuts cannot be read — their submenu is empty.")
			return nil
		end
		local function choose(id, letter)
			if not Accented.set(id, letter) then
				require("config_save_failure").present(i18n_safe, function(message)
					show_error(message, i18n_safe("common.error_title"))
				end)
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end
		local items = {}
		for _, id in ipairs(Accented.IDS) do
			local entry = settings[id]
			local choices = {}
			for code = string.byte("a"), string.byte("z") do
				local letter = string.char(code)
				choices[#choices + 1] = { label = letter:upper(), checked = entry.enabled and entry.letter == letter,
					action = function() choose(id, letter) end }
			end
			local letters = ManifestMenu.template_rows("accented_letter_picker_frame", {
				[require("config_keys").COMMAND.ACCENTED_LETTER_OFF] = function() choose(id, nil) end,
			}, {
				["accented_letter_off_checked"] = function() return not entry.enabled end,
			}, { ["accented_letter_choices"] = function() return choices end }) or {}
			-- The Windows title: « Tous les raccourcis sur la touche É correspondent
			-- à ceux de » and the current letter (GetMenuTitleByPath).
			local caption = i18n_safe("shortcuts." .. id:gsub("_", "")) .. entry.letter:upper()
			items[#items + 1] = { label = caption, checked = entry.enabled, items = letters }
		end
		return { items = items }
	end
	-- « Rangées émulées »: the four layout.emulate_<row> switches of the
	-- manifest's layout_emulated_rows_group, as Windows builds them. The
	-- renderer hands back finished tray rows while `items` takes row data, so
	-- they convert back first: passed as is, every row lacked a label and the
	-- submenu opened onto nothing.
	group_builders["layout_emulated_rows"] = function()
		local rendered = ManifestMenu.build("layout_emulated_rows_group", "Layout", nil, nil, render_ctx, providers)
		local child_rows = ManifestMenu.native_child_rows(rendered)
		if child_rows == nil then
			Logger.error(LOG, "The emulated rows could not be converted — their submenu is left out.")
			return nil
		end
		return { items = child_rows }
	end
	local rows = ManifestMenu
		and ManifestMenu.build("layout_menu", "Layout", nil, group_builders, render_ctx, providers)
		or {}
	return receive(rows, { layout_enabled = function() return nil end })
end

M.build = _build_layouts

return M

--- ui/menu/menu_metrics.lua

--- ==============================================================================
--- MODULE: Linux Menu Metrics Submenu
--- DESCRIPTION:
--- Builds the tray's Metrics submenu from the shared manifest section:
--- collection suspend and reset, the statistics windows and the legacy-data
--- migration rows.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ParentSource = require("menu.frames.parent_source")
local TextPrompt = require("ui.text_prompt")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local zenity_plain = require("ui.menu.menu_dialogs").zenity_plain

local LOG = "ui.menu.menu_metrics"

--- Builds the metrics/keystats submenu.
--- Reports the at-rest migration and offers to stop it.
--- Converting a year of stored rows takes minutes, and without this entry the
--- user ticks menu.metrics.encrypt_at_rest and sees nothing happen at all.
---
--- PROVIDER data — the `metrics_migration` list declares the slot and the shared
--- renderer draws the row. A `list` and not a `command`, because the label IS the
--- progress: "n / total", which no static declaration can spell.
--- @param k table The keystats module.
--- @return table One provider row.
local function _migration_row(k)
	if type(k.get_migration_progress) ~= "function" then
		local rows = ManifestMenu.template_rows("metrics_migration_unavailable_rows")
		return rows and rows[1] or nil
	end
	local progress = k.get_migration_progress()
	if not progress.running then
		local rows = ManifestMenu.template_rows("metrics_migration_idle_rows")
		return rows and rows[1] or nil
	end
	return {
		label = string.format(i18n_safe("menu.metrics.migration_progress"),
			progress.scanned, progress.total),
		action = function()
			if type(k.cancel_migration) == "function" then k.cancel_migration() end
		end,
	}
end

--- Renders the rows of the metrics submenu that the manifest describes.
---
--- Defined BEFORE its caller: a `local function` is not hoisted, so calling it
--- above its definition would bind the nil global
--- (project-lua-closure-before-local-nil-global).
--- @param ctx table Menu context; ctx.webview opens the two metrics windows.
--- @param k table The keystats module.
--- @return table Menu rows, empty when the renderer could not be bound.
local function _manifest_metrics_rows(ctx, k)
	if not ManifestMenu then
		Logger.warn(LOG, "Manifest renderer unavailable — the metrics submenu loses its declared rows.")
		return {}
	end

	--- Reads one flag out of the keystats's privacy state.
	--- @param key string
	--- @return function
	local function privacy(key)
		return function()
			if type(k.get_privacy_state) ~= "function" then return false end
			return k.get_privacy_state()[key] == true
		end
	end

	--- The floating WPM pill, loaded lazily so a driver whose GTK surface is
	--- missing still builds its menu — the row then reports the widget as off,
	--- which is what it is.
	--- @return table|nil
	local function wpm_widget()
		local ok, widget = pcall(require, "ui.wpm.widget")
		return ok and widget or nil
	end


	-- The canonical state keys the manifest's disabled_when / checked_when arrays
	-- name. A key declared there with no getter here is an ERROR in the renderer,
	-- not a silent always-enabled row — which is the whole point of resolving them
	-- declaratively instead of re-deriving the condition at each call site.
	local getters = {
		keystats_enabled      = function() return type(k.is_enabled) == "function" and k.is_enabled() end,
		metrics_filter_private = privacy(require("config_keys").LEAF.PRIVATE_FILTER_ENABLED),
		metrics_filter_secure  = privacy(require("config_keys").LEAF.SECURE_FILTER_ENABLED),
		metrics_filter_sysauth = privacy(require("config_keys").LEAF.SYSTEM_AUTH_FILTER_ENABLED),
		-- The manifest gates the colour row on the widget being visible: choosing
		-- how to colour something that is not on screen is a control with no
		-- subject. Without this getter the resolver logs an error and falls back to
		-- the safe answer, so the row would be permanently greyed — right by
		-- accident, and wrong the moment the widget is shown.
		metrics_suspended      = function()
			return type(k.is_collection_suspended) == "function" and k.is_collection_suspended() or false
		end,
		wpm_widget_visible     = function()
			local widget = wpm_widget()
			return widget ~= nil and widget.is_running()
		end,
		metrics_widget_colors  = function()
			local widget = wpm_widget()
			return widget ~= nil and widget.uses_source_colors()
		end,
		metrics_widget_graph   = function()
			local widget = wpm_widget()
			return widget ~= nil and widget.uses_graph()
		end,
		-- The tray readout: the Linux counterpart of the macOS menu bar one.
		metrics_menubar_wpm    = function()
			local ok, readout = pcall(require, "ui.wpm.tray_readout")
			return ok and readout.is_running() or false
		end,
		metrics_menubar_colors = function()
			local ok, readout = pcall(require, "ui.wpm.tray_readout")
			return ok and readout.uses_source_colors() or false
		end,
		wpm_menubar_visible    = function()
			local ok, readout = pcall(require, "ui.wpm.tray_readout")
			return ok and readout.is_running() or false
		end,
	}

	--- Opens one of the two metrics windows through the webview manager.
	--- @param app string Window id, e.g. "metrics_typing".
	--- @return function
	local function open_window(app)
		return function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager in the menu context — cannot open '%s'.", app)
				return
			end
			ctx.webview.show(app)
		end
	end

	--- Flips one privacy flag.
	--- @param key string Privacy-state key.
	--- @param setter function|nil
	--- @return function
	local function toggle(key, setter)
		return function()
			if type(setter) ~= "function" then
				Logger.error(LOG, "No setter for privacy flag '%s' — the row does nothing.", key)
				return
			end
			local result = setter(not privacy(key)())
			-- Encryption returns its posture, so false can also acknowledge OFF.
			-- Re-read the owner after either outcome; never publish an optimistic tick.
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
			return result
		end
	end


	local function cmd_wpm_widget()
		local widget = wpm_widget()
		if not widget then
			Logger.error(LOG, "No WPM widget module — the row cannot toggle anything.")
			return false
		end
		local changed
		if widget.is_running() then
			changed = widget.stop()
		else
			changed = widget.start()
		end
		if changed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return changed == true
	end

	local function cmd_widget_colors()
		local widget = wpm_widget()
		if not widget then
			Logger.error(LOG, "No WPM widget module — colors cannot change.")
			return false
		end
		local changed = widget.set_use_source_colors(not widget.uses_source_colors())
		if changed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return changed == true
	end

	local function cmd_include_realtime()
		local widget = wpm_widget()
		if not widget then
			Logger.error(LOG, "No WPM widget module — graph cannot change.")
			return false
		end
		local changed = widget.set_graph(not widget.uses_graph())
		if changed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return changed == true
	end

	local handlers = {}

	-- The declarative rows read their state and their behaviour off the context:
	-- `state_getters` answers the manifest's checked_when / disabled_when keys,
	-- `commands` answers its `command` (defaulting to the row id). Passing them
	-- on a COPY of ctx keeps the caller's table untouched — the same ctx is
	-- handed to every other submenu builder in this file.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	-- The restore alone: the maintainer retired the Metrics clear on 2026-09-30.
	-- The Configuration clear still composes the metrics scope owner.
	local function restore_metrics_scope()
		if ctx.paused == true or type(ctx.is_paused) ~= "function" or ctx.is_paused() then return false end
		local committed = require("infra.metrics_scope").apply("recommended", ctx.is_paused)
		if committed == true and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		return committed
	end
	getters["metrics_encrypt_enabled"] = privacy("encrypt")
	render_ctx.state_getters = getters
	-- Bracketed keys on purpose: the bijection gate resolves "does this driver
	-- handle the row" by looking for the quoted id, and a bare key is invisible
	-- to it — which would report three declared rows as unhandled while they work.
	render_ctx.commands = {
		[require("config_keys").COMMAND.WPM_WIDGET] = cmd_wpm_widget,
		[require("config_keys").COMMAND.WIDGET_COLORS] = cmd_widget_colors,
		[require("config_keys").COMMAND.INCLUDE_REALTIME] = cmd_include_realtime,
		-- The category switch, the submenu's first row: appindicator binds
		-- item.fn only on a row with no submenu, so the parent cannot carry it.
		[require("config_keys").COMMAND.SCOPE_RESTORE] = restore_metrics_scope,
		[require("config_keys").COMMAND.METRICS_TOGGLE] = function()
			if type(k.set_enabled) ~= "function" then
				Logger.error(LOG, "The keystats exposes no set_enabled — the gate does nothing.")
				return
			end
			k.set_enabled(not (type(k.is_enabled) == "function" and k.is_enabled()))
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		-- `command` rows since 2026-08-07: the label and the greying are the
		-- manifest's, so this driver supplies only the window each one opens.
		-- `check` since 2026-08-07: the label and the tick are the manifest's, so
		-- this supplies only the toggle. The row used to carry a DIFFERENT label
		-- here than on the other two drivers — one switch, two names.
		["encryption"]     = toggle("encrypt", k.set_encrypt_enabled),
		[require("config_keys").COMMAND.SHOW_TYPING]    = open_window("metrics_typing"),
		[require("config_keys").COMMAND.SHOW_APPS]      = open_window("metrics_apps"),

		[require("config_keys").COMMAND.FILTER_PRIVATE] = toggle(require("config_keys").LEAF.PRIVATE_FILTER_ENABLED, k.set_private_filter_enabled),
		[require("config_keys").COMMAND.FILTER_SECURE]  = toggle(require("config_keys").LEAF.SECURE_FILTER_ENABLED, k.set_secure_filter_enabled),
		[require("config_keys").COMMAND.FILTER_SYSAUTH] = toggle(require("config_keys").LEAF.SYSTEM_AUTH_FILTER_ENABLED, k.set_system_auth_filter_enabled),

		-- This driver answers these five in its log rather than in a window; the
		-- other two open a metrics WINDOW for the same figures. Declared rows
		-- since 2026-08-06, so the manifest can describe a driver-specific row
		-- rather than the driver keeping it to itself.
		[require("config_keys").COMMAND.METRICS_SUSPEND] = function()
			if type(k.is_collection_suspended) ~= "function" then
				Logger.error(LOG, "Keystats exposes no is_collection_suspended — the row cannot toggle anything.")
				return
			end
			if k.is_collection_suspended() then k.resume_collection() else k.suspend_collection() end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		[require("config_keys").COMMAND.RESET_WPM_POSITION] = function()
			local widget = wpm_widget()
			if not widget then
				Logger.error(LOG, "No WPM widget module — its place cannot be reset.")
				return
			end
			widget.reset_position()
		end,
		[require("config_keys").COMMAND.WPM_MENUBAR] = function()
			local ok, readout = pcall(require, "ui.wpm.tray_readout")
			if not ok then
				Logger.error(LOG, "No WPM tray readout module — the row cannot toggle anything.")
				return
			end
			local changed = readout.is_running() and readout.stop() or readout.start()
			if changed and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		[require("config_keys").COMMAND.MENUBAR_COLORS] = function()
			local ok, readout = pcall(require, "ui.wpm.tray_readout")
			if not ok then return end
			local changed = readout.set_use_source_colors(not readout.uses_source_colors())
			if changed and type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end,
		[require("config_keys").COMMAND.METRICS_RESET_SESSION] = function()
			if type(k.request_session_reset) ~= "function" then
				Logger.error(LOG, "Keystats exposes no request_session_reset — the row does nothing.")
				return false
			end
			local completed = nil
			local accepted = k.request_session_reset(function(success)
				completed = success
				if success == true then
					Logger.info(LOG, "Metrics session reset.")
				else
					Logger.error(LOG, "Metrics session reset was refused; the session is unchanged.")
				end
			end)
			if accepted ~= true then
				Logger.error(LOG, "Metrics session reset was refused; the session is unchanged.")
				return false
			end
			return completed ~= false
		end,
	}

	-- The migration readout, as the one row a `list` provider returns: its label
	-- is the progress itself.
	local providers = {
		["metrics_migration"] = function() return { _migration_row(k) } end,
		-- The applications whose typing is never recorded: the same submenu the
		-- other two drivers draw, over this driver's own keystats list.
		["exclude_apps"] = function()
			local AppRows = require("ui.menu.app_exclusion_rows")
			local count = #k.get_disabled_apps()
			local on = type(k.is_enabled) == "function" and k.is_enabled() == true
			-- The add-application prompt's caption, not a row label.
			local prompt_title = i18n_safe("menu.metrics.exclude_apps")
			return { {
				label = AppRows.caption(count),
				disabled = on,
				items = AppRows.rows({
					get = k.get_disabled_apps,
					set = k.set_disabled_apps,
					current = k.last_app,
					prompt = function(title, text, initial, hidden, choices)
						return TextPrompt.ask(title, zenity_plain(text), initial, hidden, choices)
					end,
					title = prompt_title,
					changed = function()
						if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
					end,
				}),
			} }
		end,
	}

	return ManifestMenu.build("metrics_menu", "Metrics", handlers, nil, render_ctx, providers)
end

--- Builds the metrics submenu, with the rows the manifest describes rendered by
--- the shared renderer and the rest appended after.
---
--- THE FIRST SUBMENU ON THIS DRIVER TO READ THE MANIFEST. Until 2026-08-04 Linux
--- opened `menu_manifest.json` nowhere at all — the top-level parity gate had to
--- parse this file's `_build_*` calls to compare the two, which is how `kanata`,
--- `updates` and `apps` were found built here and undescribed there.
---
--- Six rows now come from the manifest, with their `disabled_when` and
--- `checked_when` predicates resolved declaratively rather than re-derived here.
--- Seven others were removed from this driver's projection in the same pass,
--- because they configure features the FEATURE manifest already declares
--- elsewhere: the WPM widget (it has since come back, see ui/wpm),
--- the two metrics-window shortcuts, and the app-exclusion list, for which this
--- driver's keystats exposes no setter. A row that cannot be rendered is a
--- promise the manifest makes on this driver's behalf and the driver breaks.
---
--- What stays hand-built below is what the manifest does not describe on any
--- driver: this driver's own session-stats, WPM and per-app readouts, the
--- encryption-migration status, and suspend/reset.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
--- Delegates the raw dense-array check to the shared section admission.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function metrics_dense(value, records)
	return ParentSource.dense(value, records)
end

--- Delegates the actual Metrics source admission to the shared section admission.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function metrics_source(renderer, platform)
	return ParentSource.read(renderer, platform, "metrics")
end

--- Delegates the direct parent recheck to the shared section admission.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function metrics_parent_unchanged(parent, fields)
	return ParentSource.unchanged(parent, fields)
end


local function _build_metrics(ctx)
	local root, top, section, parent, fields = metrics_source(ManifestMenu, "linux")
	if root == nil then return nil end
	local k = ctx.keystats
	if type(k) ~= "table" then
		local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_metrics_absent_rows", {}, {}, {})
		if not status_rows then return nil end
		local items = ManifestMenu.render_rows(status_rows, "linux_metrics_absent_rows")
		if not metrics_dense(items, true) then return nil end
		local current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "linux")
		if not rawequal(root, current_root) or not rawequal(top, current_top)
			or not rawequal(section, current_section) or not rawequal(parent, current_parent)
			or not metrics_parent_unchanged(parent, fields) then return nil end
		local projected = ManifestMenu.group_row("top_level", "metrics", items, { keystats_enabled = function() return nil end })
		current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "linux")
		if not rawequal(root, current_root) or not rawequal(top, current_top)
			or not rawequal(section, current_section) or not rawequal(parent, current_parent)
			or not metrics_parent_unchanged(parent, fields) then return nil end
		return projected
	end

	local items = _manifest_metrics_rows(ctx, k)

	-- The collection gate and the migration readout are both the manifest's now —
	-- the gate as the `toggle` row every driver's metrics menu declares, the
	-- readout as a `list`, because its label IS the progress and no static
	-- declaration can spell "n / total".
	local on = type(k.is_enabled) == "function" and k.is_enabled() == true
	if not metrics_dense(items, true) then return nil end
	local current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not metrics_parent_unchanged(parent, fields) then return nil end
	local projected = ManifestMenu.group_row("top_level", "metrics", items, { keystats_enabled = function() return on end })
	current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not metrics_parent_unchanged(parent, fields) then return nil end
	return projected
end

M.build = _build_metrics

return M

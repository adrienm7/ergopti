--- ui/menu/menu_debug.lua

--- ==============================================================================
--- MODULE: Linux Menu Debug Submenu
--- DESCRIPTION:
--- Builds the tray's Debug submenu from the shared manifest section, with the
--- log, healthcheck, composer, network and report commands and the log-level
--- and error-dialog states.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ParentSource = require("menu.frames.parent_source")
local COMMAND = require("config_keys").COMMAND
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local LOG = "ui.menu.menu_debug"

--- Delegates the raw dense-array check to the shared section admission.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function debug_dense(value, records)
	return ParentSource.dense(value, records)
end

--- Delegates the actual Debug source admission to the shared section admission.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function debug_source(renderer, platform)
	return ParentSource.read(renderer, platform, "debug")
end

--- Delegates the direct parent recheck to the shared section admission.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function debug_parent_unchanged(parent, fields)
	return ParentSource.unchanged(parent, fields)
end

--- Builds the debug submenu from the shared manifest.
---
--- WHAT THIS REPLACED. Three rows written out by hand, while the manifest
--- declared five for this platform: `open_today_log` and `open_error_log` were
--- described in `debug_menu`, translated in all 21 locales, offered on Windows
--- and macOS, and simply absent here. Nothing reported it, because a driver that
--- does not read a manifest section cannot notice a row it does not build.
---
--- Windows and macOS each have their OWN reader for this same section
--- (`infra/menu_manifest.ahk`, `ui/menu/builder.lua`) and key on `id` alone, so
--- typing the rows costs them nothing and buys this driver the shared renderer.
--- @param ctx table Menu context.
--- @return table One menu entry with its submenu.
local function _build_debug(ctx)
	local root, top, section, parent, fields = debug_source(ManifestMenu, "linux")
	if root == nil then return nil end

	--- Calls one of the context's optional callbacks, saying so when it is absent.
	--- @param name string The ctx field to invoke.
	--- @return function
	local function call_ctx(name)
		return function()
			if type(ctx[name]) ~= "function" then
				Logger.error(LOG, "Debug menu: ctx.%s is absent — the row does nothing.", name)
				return
			end
			ctx[name]()
		end
	end

	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		[require("config_keys").LEAF.LOG_LEVEL]      = ctx.on_set_log_level,
		[require("config_keys").COMMAND.OPEN_LOGS]      = call_ctx("on_open_logs"),
		[require("config_keys").COMMAND.OPEN_TODAY_LOG] = call_ctx("on_open_today_log"),
		[require("config_keys").COMMAND.OPEN_ERROR_LOG] = call_ctx("on_open_error_log"),
		["healthcheck"]    = call_ctx("on_healthcheck"),
		[COMMAND.COMPOSER_CHECK] = call_ctx("on_composer_check"),
		-- Self-contained like the report rows: the check reads its own settings and ports
		[COMMAND.FIELD_CHECK_NETWORK] = function() require("ui.field_check.network_check").run() end,
		-- Self-contained: the report reads the daemon state the webview manager
		-- already holds, so the daemon supplies no callback for them
		[require("config_keys").COMMAND.REPORT_BUG]      = function() require("ui.healthcheck.report").report_bug() end,
		[require("config_keys").COMMAND.SUGGEST_FEATURE] = function() require("ui.healthcheck.report").suggest_feature() end,
		[require("config_keys").LEAF.SHOW_ERROR_DIALOG] = call_ctx("on_toggle_error_dialog"),
	}
	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	render_ctx.state_getters[require("config_keys").KEY.SCRIPT_LOG_LEVEL] = function() return ctx.log_level end
	render_ctx.state_getters["error_dialog_enabled"] = function()
		return require("ui.error_dialog.bridge").is_enabled()
	end

	local rows = ManifestMenu.build("debug_menu", "Debug", nil, nil, render_ctx, {})
	if not debug_dense(rows, true) then return nil end
	local current_root, current_top, current_section, current_parent = debug_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not debug_parent_unchanged(parent, fields) then return nil end
	return ManifestMenu.group_row("top_level", "debug", rows, render_ctx.state_getters)
end

M.build = _build_debug

return M

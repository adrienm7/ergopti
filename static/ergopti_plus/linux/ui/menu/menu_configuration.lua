--- ui/menu/menu_configuration.lua

--- ==============================================================================
--- MODULE: Linux Menu Configuration Submenu
--- DESCRIPTION:
--- Builds the tray's Configuration submenu from the shared manifest section:
--- the configuration folders, the global restore and reset commands and their
--- confirmations.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ParentSource = require("menu.frames.parent_source")
local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")
if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end

local _fill = require("ui.menu.menu_dialogs")._fill
local show_error = require("ui.menu.menu_dialogs").show_error

local LOG = "ui.menu.menu_configuration"

--- Delegates the raw dense-array check to the shared section admission.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function configuration_dense(value, records)
	return ParentSource.dense(value, records)
end

--- Delegates the actual Configuration source admission to the shared section admission.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function configuration_source(renderer, platform)
	return ParentSource.read(renderer, platform, "configuration")
end

--- Delegates the direct parent recheck to the shared section admission.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function configuration_parent_unchanged(parent, fields)
	return ParentSource.unchanged(parent, fields)
end

--- Builds the Configuration submenu.
---
--- Everything about the configuration itself, never one feature: the
--- recommended values, the file, the folders editor and the setup wizard. It
--- replaced « Actions globales » and the two top-level rows that opened the
--- folder and the wizard, and the Applications submenu whose only row was
--- that same folder.
local function _build_configuration(ctx)
	local root, top, section, parent, fields = configuration_source(ManifestMenu, "linux")
	if root == nil then return nil end

	--- Calls one of the context's optional callbacks, saying so when it is absent.
	--- @param name string
	--- @return function
	local function call_ctx(name)
		return function()
			if type(ctx[name]) ~= "function" then
				Logger.error(LOG, "Configuration: ctx.%s is absent — the row does nothing.", name)
				return
			end
			ctx[name]()
		end
	end

	-- The global restore and clear compose every category's own scope owner,
	-- all of them or none of them, at once: each owner backs up first, so
	-- neither asks (the maintainer retired the clear's question on 2026-09-30).
	local function apply_global_scope(mode)
		if ctx.paused == true or (type(ctx.is_paused) == "function" and ctx.is_paused()) then return false end
		local GlobalScope = require("infra.global_scope")
		-- The layout category settles once the session holds its layout, after a
		-- child answers: the outcome is shown from the continuation.
		return GlobalScope.apply(mode, GlobalScope.participants(ctx), function(committed, report)
			-- The refusal names its typed failure point, as the Windows reset does:
			-- the generic « could not be saved, it has been reverted » claimed a
			-- revert for a pending rollback or finalization, where none took place.
			if not committed then
				local title, message = require("config_reset_failure").message(report, i18n_safe)
				show_error(message, title)
			end
			if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
		end)
	end

	-- Every row is `type = "command"` in the manifest, and so is the separator
	-- between them: labels, order and spacing declared once, with this driver
	-- supplying only what each row does.
	local render_ctx = {}
	for key, value in pairs(ctx) do render_ctx[key] = value end
	render_ctx.commands = {
		-- Every category through its own scope owner, hotstrings included: the
		-- recommended hotstrings, never the neutral state where every catalogue is
		-- off, and that neutral state for the clear.
		[require("config_keys").COMMAND.SCOPE_RESTORE] = function() return apply_global_scope("recommended") end,
		[require("config_keys").COMMAND.SCOPE_CLEAR] = function() return apply_global_scope("clear") end,
		-- The cleanup needs no daemon state: it reads config.toml itself and
		-- opens the shared review page through the driver's WebView owner.
		[require("config_keys").COMMAND.CLEAN_UNUSED_KEYS] = function()
			local ok_cleanup, Cleanup = pcall(require, "ui.menu.unused_keys_cleanup")
			if not ok_cleanup or type(Cleanup) ~= "table" then
				Logger.error(LOG, "Unused-settings cleanup is unavailable: %s.", tostring(Cleanup))
				show_error(_fill(i18n_safe("dialog.unused_keys.failed"), "{1}",
					i18n_safe("dialog.unused_keys.reason.unreadable")),
					i18n_safe("dialog.unused_keys.title"))
				return
			end
			return Cleanup.run_from_menu()
		end,
		-- The folders editor, as on the other two drivers. This row used to open
		-- the hotstrings folder in the file manager, a second meaning for one
		-- label.
		[require("config_keys").COMMAND.CONFIG_FOLDER] = function()
			if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
				Logger.error(LOG, "No webview manager — the folders editor cannot open.")
				return
			end
			ctx.webview.show("paths_editor")
		end,
		[require("config_keys").COMMAND.SETUP_WIZARD] = call_ctx("on_show_setup_wizard"),
	}

	render_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
	local rows = ManifestMenu.build("configuration_menu", "Configuration", nil, nil, render_ctx)
	if not configuration_dense(rows, true) then return nil end
	local current_root, current_top, current_section, current_parent = configuration_source(ManifestMenu, "linux")
	if not rawequal(root, current_root) or not rawequal(top, current_top)
		or not rawequal(section, current_section) or not rawequal(parent, current_parent)
		or not configuration_parent_unchanged(parent, fields) then return nil end
	return ManifestMenu.group_row("top_level", "configuration", rows, render_ctx.state_getters)
end

M.build = _build_configuration

return M

--- ui/menu/active_layout_rows.lua

--- ==============================================================================
--- MODULE: Active Layout Rows (Linux)
--- DESCRIPTION:
--- Builds Layout > « Input sources »: the desktop's own keyboard layouts with
--- the active one ticked, choosing one switching the desktop to it, as the
--- macOS menu lists and selects its input sources.
---
--- FEATURES & RATIONALE:
--- 1. One owner of the desktop's layouts: the input source adapter the pause
---    switch already holds (GNOME gsettings, the KDE keyboard daemon or
---    setxkbmap). Each build draws its last reading and asks for a fresh one;
---    the tray is rebuilt only when the desktop's list or active layout changed.
--- 2. A desktop with no supported backend shows the declared status line, and
---    an empty list the shared « Open Keyboard Settings… » row.
--- 3. A refused switch is told: the tick would otherwise stay on the old
---    layout with no reason given.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ManifestMenu = require("infra.manifest_menu")
local Shell = require("adapters.shell_runner")
local COMMAND = require("settings.engine.keys").COMMAND

local LOG = "ui.menu.active_layout_rows"

-- The keyboard settings panel of each supported backend.
local SETTINGS_COMMANDS = {
	gnome = "gnome-control-center keyboard",
	kde = "systemsettings kcm_keyboard",
}

--- The command that opens the keyboard settings of a backend, nil without one.
--- @param backend string|nil Input source backend ("gnome", "kde", "x11").
--- @return string|nil command
function M.settings_command(backend)
	return SETTINGS_COMMANDS[backend]
end

--- Opens the desktop's keyboard settings; never guesses an unrelated app.
--- @param backend string|nil
--- @param shell table|nil Shell port { has_command, run } (adapters.shell_runner).
--- @return boolean started
function M.open_settings(backend, shell)
	shell = shell or Shell
	local command = M.settings_command(backend)
	if command == nil then
		Logger.warn(LOG, "This desktop exposes no supported keyboard settings command.")
		return false
	end
	if not shell.has_command(command:match("^%S+")) then
		Logger.error(LOG, "The desktop keyboard settings executable is unavailable.")
		return false
	end
	local started = shell.run(command .. " >/dev/null 2>&1 &")
	if not started then Logger.error(LOG, "The keyboard settings process could not start.") end
	return started == true
end

--- Builds the rows.
--- @param ctx table { t, on_changed, show_error, switch, shell? }: switch is the
---   initialised modules.keymap.pause_layout_switch.
--- @return table rows
function M.rows(ctx)
	local switcher = ctx.switch.switcher()
	local backend = switcher.backend()
	if backend == nil then
		return ManifestMenu.status_rows("layout_menu", "active_layouts", "unsupported_desktop") or {}
	end
	local choices = switcher.choices()
	switcher.refresh(function(changed)
		if changed then ctx.on_changed() end
	end)
	if #choices == 0 then
		return ManifestMenu.template_rows("layout_active_source_empty_commands", {
			[COMMAND.LAYOUT_OPEN_PREFERENCES] = function() return M.open_settings(backend, ctx.shell) end,
		}, {}, {}) or {}
	end
	local rows = {}
	for _, choice in ipairs(choices) do
		local id = choice.id
		rows[#rows + 1] = {
			label = choice.label,
			checked = choice.active == true,
			disabled = choice.active == true,
			action = function()
				Logger.start(LOG, "Switching the keyboard layout to '%s' from the menu…", id)
				switcher.select(id, function(ok, detail)
					if ok then
						Logger.success(LOG, "Keyboard layout switched to '%s' from the menu.", id)
					else
						Logger.error(LOG, "Keyboard layout not switched to '%s': %s.", id, tostring(detail))
						ctx.show_error(ctx.t("menu.layout.select_failed"), ctx.t("common.error_title"))
					end
					switcher.refresh(function() ctx.on_changed() end)
				end)
			end,
		}
	end
	return rows
end

return M

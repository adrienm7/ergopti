--- ui/app_chooser.lua

--- ==============================================================================
--- MODULE: Native Application Chooser
--- DESCRIPTION:
--- Lets the user pick the application an open_app binding launches: a zenity
--- or kdialog file dialog over the system's desktop entries, answered with the
--- desktop-file id gtk-launch takes (firefox, org.gnome.Nautilus).
---
--- FEATURES & RATIONALE:
--- 1. A desktop entry, not an executable: gtk-launch starts it the way the
---    desktop's own launcher does (its Exec line, environment and startup
---    notification), which a bare binary path would bypass.
--- 2. Through ui/modal, like every dialog the tray opens, so the grabbed
---    keyboard is handed to the desktop while the dialog is open.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")

--- Where the system installs its desktop entries.
M.APPLICATIONS_DIR = "/usr/share/applications/"

--- The extension of a desktop entry, stripped to form its id.
local DESKTOP_SUFFIX = ".desktop"

--- The desktop-file id a chosen desktop entry path names.
--- @param path any The path the dialog printed.
--- @return string|nil id Nil when the path is not a desktop entry.
function M.desktop_id(path)
	if type(path) ~= "string" then return nil end
	local name = path:match("([^/]+)$")
	if not name or name:sub(-#DESKTOP_SUFFIX) ~= DESKTOP_SUFFIX or #name == #DESKTOP_SUFFIX then return nil end
	return name:sub(1, #name - #DESKTOP_SUFFIX)
end

--- Opens the first available file dialog over the desktop entries.
--- @param shell table Shell-runner authority (has_command, exec_line, quote).
--- @param title string Already-translated dialog title.
--- @return string|nil id The chosen desktop-file id.
--- @return string|nil error_message Why nothing was chosen.
function M.pick(shell, title)
	if type(shell) ~= "table" or type(shell.has_command) ~= "function"
		or type(shell.exec_line) ~= "function" or type(shell.quote) ~= "function" then
		return nil, "shell runner is unavailable"
	end
	title = WindowTitles.compose(title)
	local command
	if shell.has_command("zenity") then
		command = "zenity --file-selection --title=" .. shell.quote(title)
			.. " --filename=" .. shell.quote(M.APPLICATIONS_DIR)
			.. " --file-filter=" .. shell.quote("*" .. DESKTOP_SUFFIX) .. " 2>/dev/null"
	elseif shell.has_command("kdialog") then
		command = "kdialog --getopenfilename " .. shell.quote(M.APPLICATIONS_DIR)
			.. " " .. shell.quote("*" .. DESKTOP_SUFFIX) .. " --title " .. shell.quote(title) .. " 2>/dev/null"
	else
		return nil, "neither zenity nor kdialog is available"
	end
	local chosen = require("ui.modal").run(function() return shell.exec_line(command) end)
	if not chosen then return nil, "application selection was cancelled" end
	local id = M.desktop_id(chosen)
	if not id then return nil, "the chosen file is not a desktop entry" end
	return id
end

return M

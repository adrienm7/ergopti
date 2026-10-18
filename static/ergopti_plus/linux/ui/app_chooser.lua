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
local ConfigPaths = require("infra.config_paths")
local AppParameter = require("app_parameter")

--- Where the system installs its desktop entries.
M.APPLICATIONS_DIR = "/usr/share/applications/"

--- The extension of a desktop entry, stripped to form its id.
local DESKTOP_SUFFIX = ".desktop"

--- Admits absolute native paths without interpreting traversal through symlinks.
--- @param path any Native path or XDG directory.
--- @return string|nil normalized
local function absolute_path(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%z\1-\31\127]") then return nil end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." then return nil end
		parts[#parts + 1] = part
	end
	return "/" .. table.concat(parts, "/")
end

--- Resolves the effective XDG application directories in native search order.
--- @return table roots Absolute directories with a trailing separator.
local function application_roots()
	local bases = { ConfigPaths.data_home() }
	local system = os.getenv("XDG_DATA_DIRS")
	if system == nil or system == "" then system = "/usr/local/share:/usr/share" end
	for base in system:gmatch("[^:]+") do bases[#bases + 1] = base end
	local roots = {}
	for _, base in ipairs(bases) do
		local normalized = absolute_path(base)
		if normalized then roots[#roots + 1] = (normalized == "/" and "" or normalized) .. "/applications/" end
	end
	return roots
end

--- The desktop-file id of an entry installed beneath an effective XDG root.
--- A nested vendor/editor.desktop has the native id vendor-editor.desktop.
--- @param path any The path the dialog printed.
--- @return string|nil id Nil when no installed desktop-file id can be derived.
function M.desktop_id(path)
	if type(path) ~= "string" or path:sub(-1) == "/" then return nil end
	path = absolute_path(path)
	if not path then return nil end
	local name = path:match("([^/]+)$")
	if not name or name:sub(-#DESKTOP_SUFFIX) ~= DESKTOP_SUFFIX or #name == #DESKTOP_SUFFIX then return nil end
	for _, root in ipairs(application_roots()) do
		if path:sub(1, #root) == root then
			local id = path:sub(#root + 1, -#DESKTOP_SUFFIX - 1):gsub("/", "-")
			return AppParameter.is_valid(id) and id or nil
		end
	end
	return nil
end

--- Opens the first available file dialog over the desktop entries.
--- @param shell table Shell-runner authority (has_command, exec_checked, quote).
--- @param title string Already-translated dialog title.
--- @return string|nil id The chosen desktop-file id.
--- @return string|nil error_message Why nothing was chosen.
function M.pick(shell, title)
	if type(shell) ~= "table" or type(shell.has_command) ~= "function"
		or type(shell.exec_checked) ~= "function" or type(shell.quote) ~= "function" then
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
	local completed, output = require("ui.modal").run(function() return shell.exec_checked(command) end)
	-- Native cancellation or failure can leave partial stdout; only a confirmed
	-- dialog result may become a stored application binding.
	if completed ~= true or type(output) ~= "string" then
		return nil, "application selection was cancelled or refused"
	end
	local chosen = output:match("^([^\r\n]*)")
	if not chosen or chosen == "" then return nil, "application selection was cancelled" end
	local id = M.desktop_id(chosen)
	if not id then return nil, "the chosen file is not a desktop entry" end
	return id
end

return M

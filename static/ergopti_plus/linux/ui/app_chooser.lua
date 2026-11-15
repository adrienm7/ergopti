--- ui/app_chooser.lua

--- ==============================================================================
--- MODULE: Native Application Chooser
--- DESCRIPTION:
--- Lets the user pick the application an open_app binding launches: Ergopti's
--- own file dialog (core/ui/ui/native_dialog.lua) over the system's desktop entries, answered with the
--- desktop-file id gtk-launch takes (firefox, org.gnome.Nautilus). The same
--- dialogs pick the file or folder an open_path binding opens (pick_path).
---
--- FEATURES & RATIONALE:
--- 1. A desktop entry, not an executable: gtk-launch starts it the way the
---    desktop's own launcher does (its Exec line, environment and startup
---    notification), which a bare binary path would bypass.
--- 2. Through ui/modal, like every dialog the tray opens, so the grabbed
---    keyboard is handed to the desktop while the dialog is open.
--- ==============================================================================

local M = {}
local WindowTitles = require("core.ui.engine.window_titles")
local ConfigPaths = require("settings.engine.paths")
local AppParameter = require("apps.engine.parameter")
local NativePath = require("core.fs.engine.native_path")

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
	local name = NativePath.basename(path)
	if not name or name:sub(-#DESKTOP_SUFFIX) ~= DESKTOP_SUFFIX or #name == #DESKTOP_SUFFIX then return nil end
	for _, root in ipairs(application_roots()) do
		if path:sub(1, #root) == root then
			local id = path:sub(#root + 1, -#DESKTOP_SUFFIX - 1):gsub("/", "-")
			return AppParameter.is_valid(id) and id or nil
		end
	end
	return nil
end

--- Opens the file dialog over the desktop entries.
--- @param shell table Shell-runner authority (exec_checked, quote).
--- @param title string Already-translated dialog title.
--- @param opts table|nil Test ports for native resolution and notice.
--- @return string|nil id The chosen desktop-file id.
--- @return string|nil error_message Why nothing was chosen.
function M.pick(shell, title, opts)
	if type(shell) ~= "table" or type(shell.exec_checked) ~= "function" or type(shell.quote) ~= "function" then
		return nil, "shell runner is unavailable"
	end
	title = WindowTitles.compose(title)
	local command = require("core.ui.ui.native_dialog").command() .. " --file-selection --title=" .. shell.quote(title)
		.. " --filename=" .. shell.quote(M.APPLICATIONS_DIR)
		.. " --file-filter=" .. shell.quote("*" .. DESKTOP_SUFFIX) .. " 2>/dev/null"
	local completed, output = require("core.ui.ui.modal").run(function() return shell.exec_checked(command) end)
	-- Native cancellation or failure can leave partial stdout; only a confirmed
	-- dialog result may become a stored application binding.
	if completed ~= true or type(output) ~= "string" then
		return nil, "application selection was cancelled or refused"
	end
	-- Remove the chooser's single LF delimiter before validating the full id.
	-- A line break in a selected filename must never select another desktop file.
	local chosen = output:gsub("\n$", "")
	if not chosen or chosen == "" then return nil, "application selection was cancelled" end
	local id = M.desktop_id(chosen)
	if not id then return nil, "the chosen file is not a desktop entry" end
	local resolve = type(opts) == "table" and opts.resolve or nil
	if resolve == nil then
		local loaded, owner = pcall(require, "ui.desktop_application_resolution")
		resolve = loaded and type(owner) == "table" and owner.resolve or nil
	end
	local called, resolved, status = false, nil, nil
	if type(resolve) == "function" then called, resolved, status = pcall(resolve, id) end
	if not called or status ~= "found" or absolute_path(resolved) ~= absolute_path(chosen) then
		local notify = type(opts) == "table" and opts.notify or function()
			local message = require("core.i18n.engine.i18n").get("dialog.app_picker.selection_unverified")
			local command = require("core.ui.ui.native_dialog").command() .. " --error --no-markup --title="
				.. shell.quote(title) .. " --text=" .. shell.quote(message) .. " 2>/dev/null"
			return require("core.ui.ui.modal").run(function() return shell.exec_checked(command) end) == true
		end
		local delivered, accepted = pcall(notify)
		if not delivered or accepted ~= true then
			require("core.logger.engine.shim").error("ui.app_chooser", "Application selection verification was refused.")
		end
		return nil, "the selected application is not the effective native desktop entry"
	end
	return id
end

--- The picker command line that chooses one file or folder for open_path.
--- @param shell table Shell-runner authority (quote).
--- @param title string Window title, already composed.
--- @param folder boolean True to choose a folder.
--- @param start string The folder the picker opens on.
--- @return string command
function M.path_picker_command(shell, title, folder, start)
	return require("core.ui.ui.native_dialog").command() .. " --file-selection" .. (folder and " --directory" or "")
		.. " --title=" .. shell.quote(title) .. " --filename=" .. shell.quote(start) .. " 2>/dev/null"
end

--- Opens the picker over one file or one folder.
--- @param shell table Shell-runner authority (exec_checked, quote).
--- @param title string Already-translated dialog title.
--- @param folder boolean True to choose a folder.
--- @param start string The folder the picker opens on.
--- @param modal function|nil Test seam replacing ui/modal's run.
--- @return string|nil path The chosen path, as the picker printed it.
--- @return string|nil error_message Why nothing was chosen.
function M.pick_path(shell, title, folder, start, modal)
	if type(shell) ~= "table" or type(shell.exec_checked) ~= "function" or type(shell.quote) ~= "function" then
		return nil, "shell runner is unavailable"
	end
	local command = M.path_picker_command(shell, WindowTitles.compose(title), folder == true, start)
	local completed, output = (modal or require("core.ui.ui.modal").run)(function() return shell.exec_checked(command) end)
	if completed ~= true or type(output) ~= "string" then return nil, "path selection was cancelled or refused" end
	-- Remove the picker's single LF delimiter; a line break inside a chosen
	-- name stays and the open_path validator refuses it.
	local chosen = output:gsub("\n$", "")
	if chosen == "" then return nil, "path selection was cancelled" end
	return chosen
end

return M

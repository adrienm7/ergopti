--- ui/config_dir_picker.lua

--- ==============================================================================
--- MODULE: Native Configuration Directory Picker
--- DESCRIPTION:
--- Owns the Linux zenity/kdialog selection policy shared by onboarding and the
--- paths editor. Returns one normalized absolute directory or a precise refusal.
--- ==============================================================================

local M = {}

--- Normalizes a configuration directory through the canonical XDG default.
--- @param config_paths table Configuration-path authority.
--- @param value any Candidate directory.
--- @return string|nil normalized
function M.normalize(config_paths, value)
	if type(config_paths) ~= "table" or type(config_paths.default_config_dir) ~= "function" then
		return nil
	end
	if value == nil or value == "" then return config_paths.default_config_dir() end
	if type(value) ~= "string" then return nil end
	local normalized = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
	if normalized == "" then return config_paths.default_config_dir() end
	if normalized:sub(1, 1) ~= "/" then return nil end
	return normalized
end

--- Opens the first available native directory picker.
--- @param shell table Shell-runner authority.
--- @param config_paths table Configuration-path authority.
--- @param i18n table|nil Translation authority.
--- @param current any Current directory shown by the caller.
--- @return string|nil selected
--- @return string|nil error_message
function M.pick(shell, config_paths, i18n, current)
	if type(shell) ~= "table" or type(shell.has_command) ~= "function"
		or type(shell.exec_line) ~= "function" or type(shell.quote) ~= "function" then
		return nil, "shell runner is unavailable"
	end
	local seed = M.normalize(config_paths, current)
	if seed == nil and type(config_paths) == "table"
		and type(config_paths.get_config_dir) == "function" then
		seed = config_paths.get_config_dir()
	end
	if seed == nil then return nil, "configuration directory is unavailable" end
	local title = type(i18n) == "table" and type(i18n.get) == "function"
		and i18n.get("dialog.config_folder.select_title") or "Select configuration folder"
	local chosen = nil
	if shell.has_command("zenity") then
		chosen = shell.exec_line("zenity --file-selection --directory --title=" .. shell.quote(title)
			.. " --filename=" .. shell.quote(seed .. "/") .. " 2>/dev/null")
	elseif shell.has_command("kdialog") then
		chosen = shell.exec_line("kdialog --getexistingdirectory " .. shell.quote(seed)
			.. " --title " .. shell.quote(title) .. " 2>/dev/null")
	else
		return nil, "neither zenity nor kdialog is available"
	end
	local normalized = chosen and M.normalize(config_paths, chosen) or nil
	if not normalized then return nil, "folder selection was cancelled" end
	return normalized
end

return M

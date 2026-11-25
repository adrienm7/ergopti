--- diagnostics/ui/log_export.lua

--- ==============================================================================
--- MODULE: Export the Logs (Linux)
--- DESCRIPTION:
--- « Export the logs (zip) » in the Debug menu: one archive a tester sends
--- instead of a folder of files (maintainer decision, 2026-11-25). The shared
--- core/logger/engine/log_export.lua chooses the files and scrubs each copy;
--- this module lists the folders, reads, archives, publishes and reports.
---
--- FEATURES & RATIONALE:
--- 1. The daily logs come from the logs folder the sink writes (LogsDirPath),
---    bootstrap.log from the DEFAULT logs folder, where it is always written.
--- 2. The archive lands in the user's Downloads folder (Desktop when there is
---    none) under a dated name, written to a private temporary file there and
---    moved into place without replacing anything: a refused step leaves no
---    partial archive and no overwritten file.
--- 3. Never silent: success reveals the folder, puts the path on the
---    clipboard and says so; nothing to export or any refusal is a translated
---    notice, and the English reason is logged.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local LOG = "diagnostics.ui.log_export"

--- Owner-only mode of the archive (0600).
local PRIVATE_MODE = 384





-- ===============================
-- ===============================
-- ======= 1/ Native ports =======
-- ===============================
-- ===============================

--- The folder the archive is written to: Downloads, else Desktop.
--- @return string|nil folder, string|nil reason
local function destination_dir()
	local FileSystem = require("core.fs.adapters.file_system")
	local downloads, reason = require("metrics.engine.maintenance").downloads_dir(os.getenv)
	if downloads and FileSystem.exists(downloads) then return downloads end
	local desktop = os.getenv("XDG_DESKTOP_DIR")
	if type(desktop) ~= "string" or desktop == "" then
		local home = os.getenv("HOME")
		desktop = (type(home) == "string" and home ~= "") and (home .. "/Desktop") or nil
	end
	if desktop and FileSystem.exists(desktop) then return desktop end
	return nil, "neither the Downloads nor the Desktop folder exists" .. (reason and (" (" .. reason .. ")") or "")
end

--- Native services, replaceable by tests.
--- @return table
local function native()
	local I18n = require("core.i18n.engine.i18n")
	local Paths = require("settings.engine.paths")
	return {
		logs_dir = function() return require("core.logger.engine.sink").log_dir() end,
		default_dir = function() return Paths.default_logs_dir() end,
		destination_dir = destination_dir,
		now = function() return os.date("*t") end,
		translate = I18n.get,
		notify = function(message, title, level)
			return require("platform.focus.application_notifier").send(message, { title = title, level = level })
		end,
		copy = function(text) return require("clipboard.adapters.clipboard").write(text) end,
		reveal = function(folder)
			return require("apps.adapters.desktop_opener").open(folder, function(result)
				if type(result) ~= "table" or result.ok ~= true then
					Logger.warn(LOG, "The exported logs folder could not be revealed.")
				end
			end, function() return true end)
		end,
	}
end

--- Replaced by tests through M._set_services.
local _services = nil

--- @return table services
local function services()
	return _services or native()
end




-- ===============================
-- ===============================
-- ======= 2/ Archive ============
-- ===============================
-- ===============================

--- The names of the regular files directly in a folder; an absent folder is empty.
--- @param dir string
--- @return table|nil names, string|nil reason
local function regular_names(dir)
	local NativeDirectory = require("core.fs.engine.native_directory")
	local listed, entries, message, code = pcall(NativeDirectory.entries, dir)
	if not listed then return nil, "cannot list " .. dir .. ": " .. tostring(entries) end
	if entries == nil then
		if code == "ENOENT" then return {} end
		return nil, "cannot list " .. dir .. ": " .. tostring(message)
	end
	local names = {}
	for _, entry in ipairs(entries) do
		if entry.kind == "file" then names[#names + 1] = entry.name end
	end
	return names
end

--- Writes the archive to a private temporary file of the folder, then moves
--- it to its name without replacing anything.
--- @param folder string Destination folder.
--- @param name string Archive file name.
--- @param bytes string Archive bytes.
--- @return string|nil path, string|nil reason
local function publish(folder, name, bytes)
	local FileSystem = require("core.fs.adapters.file_system")
	local path = folder .. "/" .. name
	local temporary = string.format("%s/.%s.%d-%d.partial", folder, name, os.time(), math.random(1, 1e9))
	local written, write_reason = FileSystem.write_new(temporary, bytes)
	if not written then
		os.remove(temporary)
		return nil, "cannot write " .. temporary .. ": " .. tostring(write_reason)
	end
	local chmod_ok, chmod_done, chmod_error = pcall(function() return require("luv").fs_chmod(temporary, PRIVATE_MODE) end)
	if not chmod_ok or not chmod_done then
		os.remove(temporary)
		return nil, "cannot restrict " .. temporary .. ": " .. tostring(chmod_ok and chmod_error or chmod_done)
	end
	local moved, move_code = require("core.fs.engine.no_replace_move").move(temporary, path)
	if not moved then
		os.remove(temporary)
		return nil, "cannot move the archive to " .. path .. ": " .. tostring(move_code)
	end
	return path
end

--- Builds the archive bytes of the export.
--- @param env table Services.
--- @return string|nil bytes, string|table|nil names_or_reason, boolean|nil empty
local function build(env)
	local Export = require("core.logger.engine.log_export")
	local AppDirs = require("core.fs.engine.app_dirs")
	local logs_dir, default_dir = env.logs_dir(), env.default_dir()
	local folders = { logs = logs_dir, default = default_dir, crash_reports = logs_dir .. "/" .. AppDirs.crash_reports_dir }
	local listing = { platform = "linux", today = os.date("%Y-%m-%d") }
	for key, dir in pairs(folders) do
		local names, reason = regular_names(dir)
		if not names then return nil, reason end
		listing[key] = names
	end
	local selected = Export.select(listing)
	if #selected == 0 then return nil, nil, true end
	local FileSystem = require("core.fs.adapters.file_system")
	local entries, archived = {}, {}
	for _, file in ipairs(selected) do
		local path = folders[file.folder] .. "/" .. file.name
		local content = FileSystem.read(path)
		if type(content) ~= "string" then return nil, "cannot read " .. path end
		entries[#entries + 1] = { name = file.archive, data = Export.scrub_text(content) }
		archived[#archived + 1] = file.archive
	end
	return require("core.fs.engine.zip_writer").build(entries, env.now()), archived
end




-- ===============================
-- ===============================
-- ======= 3/ Menu action ========
-- ===============================
-- ===============================

--- Exports the logs as one scrubbed zip and reports the outcome.
--- @return boolean exported
function M.run()
	local env = services()
	local t = env.translate
	Logger.start(LOG, "Exporting the logs as one archive.")
	local ok, bytes, detail, empty = pcall(build, env)
	if ok and empty then
		Logger.warn(LOG, "There is no log to export.")
		env.notify(t("log_export.empty"), t("log_export.failed_title"), "warning")
		return false
	end
	local reason
	local path
	if not ok then
		reason = tostring(bytes)
	elseif not bytes then
		reason = tostring(detail)
	else
		local folder, folder_reason = env.destination_dir()
		if not folder then
			reason = folder_reason
		else
			path, reason = publish(folder, require("core.logger.engine.log_export").archive_name(env.now()), bytes)
		end
	end
	if not path then
		Logger.error(LOG, "The logs could not be exported: %s.", tostring(reason))
		env.notify(t("log_export.failed"), t("log_export.failed_title"), "error")
		return false
	end
	Logger.success(LOG, "Exported %d log file(s) to %s.", #detail, path)
	if not env.copy(path) then Logger.warn(LOG, "The exported archive path could not be copied to the clipboard.") end
	if not env.reveal(path:match("^(.*)/[^/]*$")) then Logger.warn(LOG, "The exported logs folder could not be revealed.") end
	env.notify((t("log_export.done"):gsub("%%s", function() return path end)), t("log_export.done_title"), "info")
	return true
end

--- Replaces the native services for a test; nil restores them.
--- @param overrides table|nil
function M._set_services(overrides)
	_services = overrides
end

return M

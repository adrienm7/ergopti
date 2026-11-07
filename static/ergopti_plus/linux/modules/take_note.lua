--- modules/take_note.lua

--- ==============================================================================
--- MODULE: Daily Notes (Linux)
--- DESCRIPTION:
--- Opens the day's plain-text note through the desktop's registered text editor.
--- The canonical data root keeps notes independent of a localized Desktop path;
--- an existing note is opened without replacing any of its bytes.
--- ==============================================================================

local M = {}
local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local Files = require("adapters.file_system")
local Paths = require("infra.config_paths")
local i18n = require("infra.i18n")

local LOG = "modules.take_note"

--- Reports a refused note action without exposing its private path.
--- @param key string Localized explanation.
local function refuse(key)
	require("adapters.application_notifier").send(i18n.get(key), { level = "error" })
	return false
end

--- Opens the current day's note, preserving any existing contents.
--- @param launch function Observed background command launcher.
--- @return boolean started
function M.open(launch)
	assert(type(launch) == "function", "daily notes need a background launcher")
	local ok, handler = Shell.exec_checked("xdg-mime query default text/plain")
	if not ok or not handler:match("%S") then
		Logger.warn(LOG, "Daily note refused: the desktop has no registered text/plain handler.")
		return refuse("notify.take_note_no_text_handler")
	end
	local folder = Paths.data("notes")
	if not Shell.run("mkdir -p -- " .. Shell.quote(folder)) then
		Logger.error(LOG, "Daily note refused: its data directory could not be created.")
		return refuse("notify.take_note_failed")
	end
	local path = folder .. "/Notes_" .. os.date("%d_%m_%Y") .. ".txt"
	-- The regular-file writer refuses symlinks and non-files. Appending no bytes
	-- creates an absent note without truncating an existing one.
	if not Files.append(path, "") then return refuse("notify.take_note_failed") end
	if launch("xdg-open " .. Shell.quote(path)) ~= true then
		return refuse("notify.take_note_failed")
	end
	Logger.info(LOG, "Opening the daily note in the desktop text editor.")
	return true
end

return M

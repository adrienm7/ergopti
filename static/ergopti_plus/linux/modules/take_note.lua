--- modules/take_note.lua

--- ==============================================================================
--- MODULE: Daily Notes (Linux)
--- DESCRIPTION:
--- Opens the day's plain-text note through the desktop's registered text editor.
--- The canonical data root keeps notes independent of a localized Desktop path;
--- an existing note is opened without replacing any of its bytes.
---
--- The registered text/plain handler is launched by its desktop-file id
--- (gtk-launch, as open_app does), not through xdg-open: xdg-open and gio pick
--- the application from the file's content, and the day's first note is empty,
--- which they read as inode/x-empty or application/x-zerosize and hand to a
--- browser or to nothing.
--- ==============================================================================

local M = {}
local Logger = require("core.logger.engine.shim")
local Shell = require("adapters.shell_runner")
local Files = require("core.fs.adapters.file_system")
local Paths = require("infra.config_paths")
local i18n = require("infra.i18n")
local TextUtils = require("core.text.engine.utils_core")

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
	local ok, answer = Shell.exec_checked("xdg-mime query default text/plain")
	local handler = ok and type(answer) == "string" and TextUtils.trim(answer) or ""
	if not require("apps.engine.parameter").is_valid(handler) then
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
	if launch("gtk-launch -- " .. Shell.quote(handler) .. " " .. Shell.quote(path)) ~= true then
		return refuse("notify.take_note_failed")
	end
	Logger.info(LOG, "Opening the daily note in the desktop text editor.")
	return true
end

return M

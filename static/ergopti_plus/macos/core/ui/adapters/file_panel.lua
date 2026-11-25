--- core/ui/adapters/file_panel.lua

--- ==============================================================================
--- MODULE: File Panels (macOS)
--- DESCRIPTION:
--- The native open and save panels a WebView host needs when its page cannot
--- show a file input (WKWebView has none without a UI delegate): one file of
--- the given types to read, one file name to write. Modal, opened from a
--- window's button, never from the keyboard tap.
---
--- FEATURES & RATIONALE:
--- 1. AppKit panels through AppleScript, the way dialog_util opens its path
---    picker, so the panel takes the front and returns a POSIX path.
--- 2. A cancelled panel answers nil; a panel that cannot open raises, since a
---    silent nil would read as a cancellation.
--- ==============================================================================

local Logger = require("core.logger.engine.logger")
local text_utils = require("core.text.engine.utils")
local WindowTitles = require("core.ui.engine.window_titles")

local M = {}

local HOME_DIR = os.getenv("HOME") or "/"

-- The file types an open panel admits, by kind of file.
M.TYPES = { workflows = { "json" }, png = { "png" } }

--- Runs one panel script.
--- @param script string
--- @param caller string For the error.
--- @return string|nil path
local function run(script, caller)
	local ok, path = Logger.run_modal(hs.osascript.applescript, script)
	if ok ~= true then error("file_panel." .. caller .. ": the native panel failed", 3) end
	return type(path) == "string" and path ~= "" and path or nil
end

--- Asks for one file to read.
--- @param title string Translated, brandless.
--- @param kind string A key of M.TYPES.
--- @return string|nil path
function M.choose_file(title, kind)
	local types = assert(M.TYPES[kind], "file_panel.choose_file: unknown kind")
	local quoted = {}
	for index, ext in ipairs(types) do quoted[index] = '"' .. ext .. '"' end
	return run(text_utils.applescript_format([[
use framework "AppKit"
use scripting additions
set panel to current application's NSOpenPanel's openPanel()
panel's setTitle:"%s"
panel's setDirectoryURL:(current application's NSURL's fileURLWithPath:"%s")
panel's setCanChooseFiles:true
panel's setCanChooseDirectories:false
panel's setAllowsMultipleSelection:false
panel's setAllowedFileTypes:{]] .. table.concat(quoted, ", ") .. [[}
set response to panel's runModal()
if response is not (current application's NSModalResponseOK) then return missing value
return ((panel's |URLs|()'s firstObject())'s |path|()) as text
]], WindowTitles.compose(title), HOME_DIR), "choose_file")
end

--- Asks for one file name to write.
--- @param title string Translated, brandless.
--- @param default_name string
--- @return string|nil path
function M.save_file(title, default_name)
	return run(text_utils.applescript_format([[
use framework "AppKit"
use scripting additions
set panel to current application's NSSavePanel's savePanel()
panel's setTitle:"%s"
panel's setDirectoryURL:(current application's NSURL's fileURLWithPath:"%s")
panel's setNameFieldStringValue:"%s"
set response to panel's runModal()
if response is not (current application's NSModalResponseOK) then return missing value
return (panel's |URL|()'s |path|()) as text
]], WindowTitles.compose(title), HOME_DIR, default_name), "save_file")
end

return M

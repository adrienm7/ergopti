--- adapters/screen_text_ports.lua

--- ==============================================================================
--- MODULE: Screen Text Ports (macOS)
--- DESCRIPTION:
--- The Hammerspoon side of the « Capture → texte » action
--- (modules/shortcuts/actions/ocr_capture.lua): the interactive region
--- selection through screencapture and the plain-text clipboard write.
---
--- FEATURES & RATIONALE:
--- 1. The selection is screencapture's own (-i), so Escape and the Space bar
---    window mode work as in every macOS capture; -x keeps it silent.
--- 2. The clipboard write is read back: success is never claimed for a text
---    the pasteboard does not hold.
--- ==============================================================================

local M = {}

local hs = hs
local ShellRunner = require("core.process.adapters.shell_runner")

local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"

--- Lets the user select a region and writes it to a PNG file.
--- @param path string The file to write.
--- @param on_done function (exit_code, stderr)
--- @return boolean started
function M.select_region(path, on_done)
	local task = ShellRunner.spawn(SCREENCAPTURE_BIN, { "-i", "-x", "-t", "png", path }, function(exit_code, _, stderr)
		on_done(exit_code, stderr)
	end, nil, nil, true)
	return type(task) == "table" and task.start() == true
end

--- Puts plain text on the clipboard and reads it back.
--- @param text string
--- @return boolean written
function M.set_clipboard(text)
	local ok, written = pcall(hs.pasteboard.setContents, text)
	if not ok or written ~= true then return false end
	local read_ok, current = pcall(hs.pasteboard.getContents)
	return read_ok and current == text
end

return M

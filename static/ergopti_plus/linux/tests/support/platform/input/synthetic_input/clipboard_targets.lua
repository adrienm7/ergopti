--- tests/support/platform/input/synthetic_input/clipboard_targets.lua

--- ==============================================================================
--- MODULE: Clipboard Target Listing Fixture
--- DESCRIPTION:
--- Answers the clipboard adapter's format listing (xclip TARGETS, wl-paste
--- --list-types) for recording shells that model one text clipboard. Those
--- fixtures answer every read with the clipboard text, which the snapshot
--- preflight would read as a format it cannot restore.
--- ==============================================================================

local M = {}

-- What a text-only owner advertises: its text targets and ICCCM bookkeeping.
M.TEXT_ONLY = "TARGETS\nTIMESTAMP\nUTF8_STRING\nSTRING\ntext/plain;charset=utf-8\n"

--- Whether a shell command is the adapter's clipboard format listing.
--- @param command any
--- @return boolean
function M.is_listing(command)
	return type(command) == "string"
		and (command:find("-t TARGETS -o", 1, true) ~= nil or command:find("--list-types", 1, true) ~= nil)
end

return M

--- adapters/clipboard.lua

--- ==============================================================================
--- MODULE: Clipboard Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Clipboard port contract defined in
--- static/ergopti_plus/shared/ports/Clipboard.spec.js. Wraps hs.pasteboard behind
--- four canonical methods (read, write, save, restore) so domain modules can
--- interact with the system clipboard without coupling to hs APIs.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe returns: read() and save() return nil instead of crashing when
---    the clipboard is empty or contains non-text data; write() and restore()
---    return false on any error so callers can branch on the result.
--- 2. Defensive pcall: hs.pasteboard calls can raise on permission denial or
---    when the pasteboard daemon is temporarily unavailable; every call is
---    wrapped in pcall to prevent propagation.
--- 3. Nil-restore support: restore(nil) clears the clipboard rather than writing
---    a literal "nil" string, preserving the original pre-save state cleanly.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.clipboard"




-- ==================================
-- ==================================
-- ======= 1/ Adapter Methods =======
-- ==================================
-- ==================================

--- Reads the current clipboard contents.
--- @return string|nil The clipboard text, or nil if empty or non-text.
function M.read()
	local ok, result = pcall(function()
		return hs.pasteboard.getContents()
	end)

	if not ok then
		Logger.error(LOG, "read(): pasteboard error — %s", tostring(result))
		return nil
	end

	if type(result) ~= "string" or result == "" then
		return nil
	end

	return result
end

--- Writes text to the clipboard.
--- @param text string The text to place on the clipboard.
--- @return boolean True on success, false on error.
function M.write(text)
	local ok, err = pcall(function()
		hs.pasteboard.setContents(text)
	end)

	if not ok then
		Logger.error(LOG, "write(): pasteboard error — %s", tostring(err))
		return false
	end

	Logger.debug(LOG, "write(): %d char(s) written to clipboard", #tostring(text))
	return true
end

--- Saves the current clipboard contents and returns them.
--- @return string|nil The saved clipboard text, or nil if empty or non-text.
function M.save()
	local ok, result = pcall(function()
		return hs.pasteboard.getContents()
	end)

	if not ok then
		Logger.error(LOG, "save(): pasteboard error — %s", tostring(result))
		return nil
	end

	if type(result) ~= "string" or result == "" then
		return nil
	end

	Logger.debug(LOG, "save(): %d char(s) saved from clipboard", #result)
	return result
end

--- Restores the clipboard to a previously saved value.
--- Clears the clipboard when saved is nil.
--- @param saved string|nil The text to restore, or nil to clear.
--- @return boolean True on success, false on error.
function M.restore(saved)
	local ok, err = pcall(function()
		if saved == nil then
			hs.pasteboard.clearContents()
		else
			hs.pasteboard.setContents(saved)
		end
	end)

	if not ok then
		Logger.error(LOG, "restore(): pasteboard error — %s", tostring(err))
		return false
	end

	Logger.debug(LOG, "restore(): clipboard %s", saved == nil and "cleared" or "restored")
	return true
end

return M

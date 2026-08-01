--- adapters/clipboard.lua

--- ==============================================================================
--- MODULE: Clipboard Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Clipboard port contract defined in
--- static/ergopti_plus/_shared/core/ports/Clipboard.spec.js. Wraps hs.pasteboard behind
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

--- Saves ALL current clipboard data (all pasteboard types: text, images, files, etc.).
--- Uses readAllData() so non-text content (images, RTF, file URLs) is preserved.
--- Returns nil when the clipboard is empty; a truthy table otherwise.
--- @return table|nil Pasteboard data table, or nil if empty.
function M.save()
	local ok, result = pcall(function()
		return hs.pasteboard.readAllData()
	end)

	if not ok then
		Logger.error(LOG, "save(): pasteboard error — %s", tostring(result))
		return nil
	end

	-- readAllData() returns an empty table when clipboard is empty
	if type(result) ~= "table" or next(result) == nil then
		return nil
	end

	-- readAllData() is a UTI-string-keyed HASH table, not an array, so `#result`
	-- always reports 0. Count with pairs() so the diagnostic is truthful (F-I3).
	local n = 0
	for _ in pairs(result) do n = n + 1 end
	Logger.debug(LOG, "save(): clipboard snapshot taken (%d type(s)).", n)
	return result
end

--- Restores the clipboard to a previously saved value.
--- Clears the clipboard when saved is nil.
--- Uses writeAllData() to restore all pasteboard types, not just text.
--- @param saved table|nil The pasteboard data to restore, or nil to clear.
--- @return boolean True on success, false on error.
function M.restore(saved)
	local ok, err = pcall(function()
		if saved == nil then
			hs.pasteboard.clearContents()
		else
			hs.pasteboard.writeAllData(saved)
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

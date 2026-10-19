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
local Logger = require("infra.logger")

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

--- Reads native ownership metadata without logging or adopting a failed read.
--- This macOS-private extension does not change the four-method Clipboard port.
--- @return integer|nil count Zero is a valid native generation.
--- @return string|nil error
function M._change_count()
	local ok, count = pcall(function() return hs.pasteboard.changeCount() end)
	if not ok or math.type(count) ~= "integer" or count < 0 then
		return nil, "native clipboard change count is unavailable"
	end
	return count
end

--- Captures metadata before any diagnostic can reenter another clipboard owner.
local function capture_ownership(receipt)
	if receipt == nil then return end
	local count, detail = M._change_count()
	receipt.count, receipt.count_ok, receipt.detail = count, count ~= nil, detail
end

--- Refuses a private conditional mutation before touching a foreign pasteboard.
local function admit_ownership(receipt)
	if receipt == nil then return true end
	receipt.attempted = false
	capture_ownership(receipt)
	if receipt.count_ok ~= true then return false end
	if receipt.expected_count ~= nil and receipt.count ~= receipt.expected_count then
		receipt.detail = "native clipboard ownership changed"
		return false
	end
	receipt.attempted = true
	return true
end

--- Writes text to the clipboard.
--- @param text string The text to place on the clipboard.
--- @param receipt table|nil Private macOS conditional ownership receipt.
--- @return boolean True on success, false on error.
function M.write(text, receipt)
	if not admit_ownership(receipt) then
		Logger.error(LOG, "write(): ownership check refused — %s", tostring(receipt.detail))
		return false, receipt
	end
	local ok, result = pcall(function()
		return hs.pasteboard.setContents(text)
	end)
	capture_ownership(receipt)

	if not ok or result ~= true then
		Logger.error(LOG, "write(): pasteboard error — %s", tostring(result))
		return false, receipt
	end

	Logger.debug(LOG, "write(): %d char(s) written to clipboard", #tostring(text))
	return true, receipt
end

--- Saves ALL current clipboard data (all pasteboard types: text, images, files, etc.).
--- Uses readAllData() so non-text content (images, RTF, file URLs) is preserved.
--- Returns nil when the clipboard is empty; a truthy table otherwise.
--- @return table|nil Pasteboard data table, or nil if empty/error.
--- @return boolean read_ok True when nil means an empty clipboard, false on error.
function M.save()
	local ok, result = pcall(function()
		return hs.pasteboard.readAllData()
	end)

	if not ok then
		Logger.error(LOG, "save(): pasteboard error — %s", tostring(result))
		return nil, false
	end

	if type(result) ~= "table" then
		Logger.error(LOG, "save(): pasteboard returned %s instead of a data table", type(result))
		return nil, false
	end
	-- readAllData() returns an empty table when clipboard is empty.
	if next(result) == nil then
		return nil, true
	end

	-- readAllData() is a UTI-string-keyed HASH table, not an array, so `#result`
	-- always reports 0. Count with pairs() so the diagnostic is truthful (F-I3).
	local n = 0
	for _ in pairs(result) do n = n + 1 end
	Logger.debug(LOG, "save(): clipboard snapshot taken (%d type(s)).", n)
	return result, true
end

--- Restores the clipboard to a previously saved value.
--- Clears the clipboard when saved is nil.
--- Uses writeAllData() to restore all pasteboard types, not just text.
--- @param saved table|nil The pasteboard data to restore, or nil to clear.
--- @param receipt table|nil Private macOS conditional ownership receipt.
--- @return boolean True on success, false on error.
function M.restore(saved, receipt)
	if not admit_ownership(receipt) then
		Logger.error(LOG, "restore(): ownership check refused — %s", tostring(receipt.detail))
		return false, receipt
	end
	local ok, result = pcall(function()
		if saved == nil then
			hs.pasteboard.clearContents()
			return true
		else
			return hs.pasteboard.writeAllData(saved)
		end
	end)
	capture_ownership(receipt)

	if not ok or result ~= true then
		Logger.error(LOG, "restore(): pasteboard error — %s", tostring(result))
		return false, receipt
	end

	Logger.debug(LOG, "restore(): clipboard %s", saved == nil and "cleared" or "restored")
	return true, receipt
end

return M

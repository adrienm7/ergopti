--- linux/adapters/clipboard.lua

--- ==============================================================================
--- MODULE: Clipboard Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Clipboard port contract defined in
--- static/ergopti_plus/shared/ports/Clipboard.spec.js. Wraps xclip/xsel/wl-paste
--- to provide read/write/save/restore operations without coupling domain
--- modules to platform-specific clipboard APIs.
---
--- FEATURES & RATIONALE:
--- 1. Wayland/X11 detection: tries wl-paste (Wayland) first, falls back to
---    xclip (X11) so the same adapter works in both environments.
--- 2. Fail-safe returns: read() and save() return nil when the clipboard is
---    empty; write() and restore() return false on any error.
--- 3. Defensive pcall: all shell invocations are wrapped in pcall.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "adapters.clipboard"


-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Detect which clipboard tool is available.
--- Returns a backend string: "wayland", "xclip", "xsel", or nil.
local function _detect_backend()
	if os.execute("which wl-paste >/dev/null 2>&1") == 0 then
		-- Verify WAYLAND_DISPLAY is set
		if os.getenv("WAYLAND_DISPLAY") then return "wayland" end
	end
	if os.execute("which xclip >/dev/null 2>&1") == 0 then return "xclip" end
	if os.execute("which xsel  >/dev/null 2>&1") == 0 then return "xsel"  end
	return nil
end

local _backend = _detect_backend()

--- Reads the clipboard via the detected backend.
--- @return string|nil
local function _read_raw()
	if not _backend then return nil end
	local cmd
	if _backend == "wayland" then
		cmd = "wl-paste --no-newline 2>/dev/null"
	elseif _backend == "xclip" then
		cmd = "xclip -selection clipboard -o 2>/dev/null"
	else
		cmd = "xsel --clipboard --output 2>/dev/null"
	end
	local fh = io.popen(cmd, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	if type(content) ~= "string" or content == "" then return nil end
	return content
end

--- Writes text to the clipboard via the detected backend.
--- @param text string
--- @return boolean
local function _write_raw(text)
	if not _backend then return false end
	local cmd
	if _backend == "wayland" then
		cmd = string.format("printf '%%s' %q | wl-copy 2>/dev/null", text)
	elseif _backend == "xclip" then
		cmd = string.format("printf '%%s' %q | xclip -selection clipboard 2>/dev/null", text)
	else
		cmd = string.format("printf '%%s' %q | xsel --clipboard --input 2>/dev/null", text)
	end
	local code = os.execute(cmd)
	return code == true or code == 0
end




-- ==================================
-- ==================================
-- ======= 2/ Adapter Methods =======
-- ==================================
-- ==================================

--- Reads the current clipboard contents.
--- @return string|nil The clipboard text, or nil if empty or unavailable.
function M.read()
	local ok, result = pcall(_read_raw)
	if not ok then
		Logger.error(LOG, "read(): error — %s", tostring(result))
		return nil
	end
	return result
end

--- Writes text to the clipboard.
--- @param text string The text to place on the clipboard.
--- @return boolean True on success, false on error.
function M.write(text)
	if type(text) ~= "string" then return false end
	local ok, result = pcall(_write_raw, text)
	if not ok then
		Logger.error(LOG, "write(): error — %s", tostring(result))
		return false
	end
	if result then
		Logger.debug(LOG, "write(): %d char(s) written to clipboard.", #text)
	end
	return result == true
end

--- Saves the current clipboard contents and returns them.
--- @return string|nil The saved text, or nil if empty or unavailable.
function M.save()
	local ok, result = pcall(_read_raw)
	if not ok then
		Logger.error(LOG, "save(): error — %s", tostring(result))
		return nil
	end
	if type(result) == "string" then
		Logger.debug(LOG, "save(): %d char(s) saved from clipboard.", #result)
	end
	return result
end

--- Restores the clipboard to a previously saved value.
--- Clears the clipboard when saved is nil.
--- @param saved string|nil The text to restore, or nil to clear.
--- @return boolean True on success, false on error.
function M.restore(saved)
	if saved == nil then
		-- Clear by writing an empty string
		local ok, err = pcall(_write_raw, "")
		if not ok then
			Logger.error(LOG, "restore(): clear error — %s", tostring(err))
			return false
		end
		Logger.debug(LOG, "restore(): clipboard cleared.")
		return true
	end
	local ok, result = pcall(_write_raw, saved)
	if not ok then
		Logger.error(LOG, "restore(): error — %s", tostring(result))
		return false
	end
	Logger.debug(LOG, "restore(): clipboard restored.")
	return result == true
end

return M

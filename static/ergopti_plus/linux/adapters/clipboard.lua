--- adapters/clipboard.lua

--- ==============================================================================
--- MODULE: Clipboard Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Clipboard port contract defined in
--- static/ergopti_plus/_shared/core/ports/Clipboard.spec.js. Wraps xclip/xsel/wl-paste
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
local Shell  = require("adapters.shell_runner")

local LOG = "adapters.clipboard"


-- =========================================
-- =========================================
-- ======= 1/ Internal Helpers =============
-- =========================================
-- =========================================

--- Detect which clipboard tool is available.
--- Probing goes through Shell.has_command because the previous form compared
--- os.execute()'s result against 0 only. That is the Lua 5.1/LuaJIT spelling;
--- from Lua 5.2 on the same success is reported as `true`, so every probe read
--- as "absent" and the whole adapter silently no-opped on any modern
--- interpreter — invisible in CI, which runs LuaJIT.
--- Returns a backend string: "wayland", "xclip", "xsel", or nil.
local function _detect_backend()
	-- WAYLAND_DISPLAY decides first: wl-copy exists on X11 sessions too, but
	-- writing through it there silently reaches no clipboard.
	if os.getenv("WAYLAND_DISPLAY") and Shell.has_command("wl-paste") then return "wayland" end
	if Shell.has_command("xclip") then return "xclip" end
	if Shell.has_command("xsel")  then return "xsel"  end
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
--- Clipboard content is whatever the user last copied, so it is quoted through
--- the shell_runner. The previous string.format("%q") form emitted a
--- double-quoted word: copying a snippet containing $(…) or a backtick ran it.
--- @param text string
--- @return boolean
local function _write_raw(text)
	if not _backend then return false end
	local quoted = Shell.quote(text)
	local cmd
	if _backend == "wayland" then
		cmd = string.format("printf '%%s' %s | wl-copy 2>/dev/null", quoted)
	elseif _backend == "xclip" then
		cmd = string.format("printf '%%s' %s | xclip -selection clipboard 2>/dev/null", quoted)
	else
		cmd = string.format("printf '%%s' %s | xsel --clipboard --input 2>/dev/null", quoted)
	end
	return Shell.run(cmd)
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

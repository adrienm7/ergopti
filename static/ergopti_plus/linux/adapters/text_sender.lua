--- static/ergopti_plus/linux/adapters/text_sender.lua

--- ==============================================================================
--- MODULE: TextSender Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the TextSender port contract defined in
--- static/ergopti_plus/shared/ports/TextSender.spec.js. Bridges domain-level text
--- insertion requests to uinput (via ydotool) and the X11 clipboard (via
--- xdotool / xclip) without coupling domain modules to any OS API.
---
--- FEATURES & RATIONALE:
--- 1. Auto mode: when opts.mode == "auto" (default), payloads longer than
---    CLIPBOARD_THRESHOLD characters use the clipboard path (xdotool type
---    --clearmodifiers or xdotool key ctrl+v after xclip) to avoid the
---    per-character overhead of uinput event injection.
--- 2. Direct mode: ydotool type --delay=0 drives character-by-character
---    injection via uinput — required for Wayland or when the clipboard is
---    inaccessible (e.g., password fields).
--- 3. X11 clipboard path: xclip -selection clipboard sets the clipboard;
---    xdotool key ctrl+v pastes it into the focused window.
--- 4. Callback semantics: the callback is invoked synchronously after the
---    shell command returns, matching the contract's "called inline" note.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.text_sender"


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Payload length above which "auto" mode switches to clipboard injection.
-- Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
local CLIPBOARD_THRESHOLD = 1000


-- =========================================
-- =========================================
-- ======= 2/ Internal Helpers =============
-- =========================================
-- =========================================

--- Runs a shell command and returns true on exit 0, false otherwise.
--- @param cmd string Shell command to execute.
--- @return boolean true if the command exited successfully.
local function shell_run(cmd)
	local ok, result = pcall(function()
		return os.execute(cmd .. " 2>/dev/null")
	end)
	-- os.execute returns true on success in Lua 5.2+ / LuaJIT.
	return ok and (result == true or result == 0)
end


-- =========================================
-- =========================================
-- ======= 3/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Inserts text at the current insertion point.
--- @param text     string       The Unicode text to insert.
--- @param opts     table|nil    { mode?: "direct"|"clipboard"|"auto" }
--- @param callback function|nil Called with no arguments on completion.
function M.send(text, opts, callback)
	-- TODO(linux): wire up ydotool (uinput) for direct mode and xclip+xdotool for clipboard mode
	local options = type(opts) == "table" and opts or {}
	local mode    = type(options.mode) == "string" and options.mode or "auto"

	-- Resolve "auto" to a concrete strategy based on payload length.
	if mode == "auto" then
		mode = #text > CLIPBOARD_THRESHOLD and "clipboard" or "direct"
	end

	local ok, err
	if mode == "clipboard" then
		-- X11 clipboard path: pipe text to xclip then simulate Ctrl+V.
		ok, err = pcall(function()
			local pipe = io.popen("xclip -selection clipboard 2>/dev/null", "w")
			if pipe then
				pipe:write(text)
				pipe:close()
			end
			shell_run("xdotool key ctrl+v")
		end)
	else
		-- Direct uinput path via ydotool.
		local safe = text:gsub("'", "'\\''")
		ok, err = pcall(function()
			shell_run(string.format("ydotool type --delay=0 -- '%s'", safe))
		end)
	end

	if not ok then
		Logger.error(LOG, "send(): injection failed (mode=%s) — %s", mode, tostring(err))
	end

	if type(callback) == "function" then
		pcall(callback)
	end
end

--- Emits count Backspace keystrokes via uinput.
--- @param count integer Number of Backspace keystrokes to emit.
function M.eraseChars(count)
	-- TODO(linux): implement via ydotool key --repeat or xdotool key BackSpace
	if type(count) ~= "number" or count < 1 then return end
	local ok, err = pcall(function()
		shell_run(string.format("ydotool key --repeat=%d 14:1 14:0", count))
	end)
	if not ok then
		Logger.error(LOG, "eraseChars(%d): failed — %s", count, tostring(err))
	end
end

--- Emits a single keystroke with optional modifiers.
--- @param key       string   Key name (e.g. "Return", "Escape", "F1").
--- @param modifiers table    Array of modifier names: "ctrl"|"shift"|"alt"|"super".
function M.pressKey(key, modifiers)
	-- TODO(linux): translate key names to xdotool key names and emit via xdotool/ydotool
	local mods = type(modifiers) == "table" and modifiers or {}
	local combo = table.concat(mods, "+")
	if combo ~= "" then combo = combo .. "+" end
	local ok, err = pcall(function()
		shell_run(string.format("xdotool key %s%s", combo, key))
	end)
	if not ok then
		Logger.error(LOG, "pressKey('%s'): failed — %s", tostring(key), tostring(err))
	end
end

return M

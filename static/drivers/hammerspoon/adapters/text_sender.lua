--- adapters/text_sender.lua

--- ==============================================================================
--- MODULE: TextSender Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TextSender port contract defined in
--- static/drivers/_shared/ports/TextSender.spec.js. Bridges domain-level text
--- insertion requests to hs.eventtap.keyStroke, hs.pasteboard, and
--- hs.eventtap.keyStrokes without coupling domain modules to any hs API.
---
--- FEATURES & RATIONALE:
--- 1. Auto mode: when opts.mode == "auto" (default), payloads longer than
---    CLIPBOARD_THRESHOLD characters use the clipboard path (paste) to avoid
---    the overhead of simulating keystrokes for large insertions.
--- 2. Direct mode: hs.eventtap.keyStrokes drives character-by-character
---    injection — required when clipboard is inaccessible (e.g., password fields).
--- 3. Callback semantics: the callback is always invoked synchronously (HS is
---    event-driven but text injection is blocking at the macOS layer), matching
---    the contract's "called inline" note for sync adapters.
--- ==============================================================================

local M = {}

local hs     = hs
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

-- Paste keystroke on macOS.
local PASTE_KEY      = "v"
local PASTE_MODIFIER = { "cmd" }


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Inserts text at the current insertion point.
--- @param text     string       The Unicode text to insert.
--- @param opts     table|nil    { mode?: "direct"|"clipboard"|"auto" }
--- @param callback function|nil Called with no arguments on completion.
function M.send(text, opts, callback)
	local options = type(opts) == "table" and opts or {}
	local mode    = type(options.mode) == "string" and options.mode or "auto"

	-- Resolve "auto" to a concrete strategy based on payload length.
	if mode == "auto" then
		mode = #text > CLIPBOARD_THRESHOLD and "clipboard" or "direct"
	end

	local ok, err
	if mode == "clipboard" then
		ok, err = pcall(function()
			local prev = hs.pasteboard.getContents()
			hs.pasteboard.setContents(text)
			hs.eventtap.keyStroke(PASTE_MODIFIER, PASTE_KEY)
			-- Restore previous clipboard after a short delay so the paste
			-- completes before the clipboard is overwritten.
			hs.timer.doAfter(0.15, function()
				if prev then hs.pasteboard.setContents(prev) end
			end)
		end)
	else
		ok, err = pcall(hs.eventtap.keyStrokes, text)
	end

	if not ok then
		Logger.error(LOG, "send(): injection failed (mode=%s) — %s", mode, tostring(err))
	end

	if type(callback) == "function" then
		pcall(callback)
	end
end

--- Emits count Backspace keystrokes synchronously.
--- @param count integer Number of Backspace keystrokes to emit.
function M.eraseChars(count)
	if type(count) ~= "number" or count < 1 then return end
	local ok, err = pcall(function()
		for _ = 1, count do
			hs.eventtap.keyStroke({}, "delete")
		end
	end)
	if not ok then
		Logger.error(LOG, "eraseChars(%d): failed — %s", count, tostring(err))
	end
end

--- Emits a single keystroke with optional modifiers.
--- @param key       string   Key name (e.g. "return", "escape", "f1").
--- @param modifiers table    Array of modifier names: "ctrl"|"shift"|"alt"|"cmd".
function M.pressKey(key, modifiers)
	local mods = type(modifiers) == "table" and modifiers or {}
	local ok, err = pcall(hs.eventtap.keyStroke, mods, key)
	if not ok then
		Logger.error(LOG, "pressKey('%s'): failed — %s", tostring(key), tostring(err))
	end
end

return M

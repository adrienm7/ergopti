--- adapters/text_sender.lua

--- ==============================================================================
--- MODULE: TextSender Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TextSender port contract defined in
--- static/ergopti_plus/shared/ports/TextSender.spec.js. Bridges domain-level text
--- insertion requests to hs.eventtap.keyStroke, the Clipboard port adapter, and
--- hs.eventtap.keyStrokes without coupling domain modules to any hs API.
---
--- FEATURES & RATIONALE:
--- 1. Auto mode: when opts.mode == "auto" (default), payloads longer than
---    CLIPBOARD_THRESHOLD characters use the clipboard path (paste) to avoid
---    the overhead of simulating keystrokes for large insertions.
--- 2. Direct mode: hs.eventtap.keyStrokes drives character-by-character
---    injection — required when clipboard is inaccessible (e.g., password fields).
--- 3. Clipboard port: the clipboard path delegates to the Clipboard adapter
---    (adapters/clipboard.lua) via save/write/restore instead of touching
---    hs.pasteboard directly — keeps the interaction testable and centralises
---    all clipboard I/O in a single adapter.
--- 4. Callback semantics: the callback is always invoked synchronously (HS is
---    event-driven but text injection is blocking at the macOS layer), matching
---    the contract's "called inline" note for sync adapters.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local Clipboard = require("adapters.clipboard")

local LOG = "adapters.text_sender"


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Payload length above which "auto" mode switches to clipboard injection.
-- Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
local CLIPBOARD_THRESHOLD = 1000

-- Delay in seconds before the clipboard is restored after a paste injection.
-- Long enough for the receiving application to process Cmd+V before we overwrite.
local CLIPBOARD_RESTORE_DELAY_S = 0.15

-- Paste keystroke on macOS.
local PASTE_KEY      = "v"
local PASTE_MODIFIER = { "cmd" }


-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Inserts text at the current insertion point.
--- Uses the Clipboard port (Clipboard.save / Clipboard.write / Clipboard.restore)
--- for the clipboard path so the interaction is mockable and the driver has one
--- canonical clipboard code path.
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
			-- Save via the Clipboard port so the user's clipboard is restored
			-- cleanly after the paste completes.
			local saved = Clipboard.save()
			Clipboard.write(text)
			hs.eventtap.keyStroke(PASTE_MODIFIER, PASTE_KEY)
			-- Restore after a short delay so the paste completes before we overwrite.
			hs.timer.doAfter(CLIPBOARD_RESTORE_DELAY_S, function()
				Clipboard.restore(saved)
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

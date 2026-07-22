--- adapters/text_sender.lua

--- ==============================================================================
--- MODULE: TextSender Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the TextSender port contract defined in
--- static/ergopti_plus/_shared/core/ports/TextSender.spec.js. Bridges domain-level text
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
local Timings  = require("lib.timings")
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
-- Shared cross-driver value ([debounce] clipboard_restore_ms).
local CLIPBOARD_RESTORE_DELAY_S = Timings.sec("debounce", "clipboard_restore_ms")

-- Paste keystroke on macOS.
local PASTE_KEY      = "v"
local PASTE_MODIFIER = { "cmd" }

-- Explicit inter-key delay for the paste keystroke, matching the 0 default that
-- M.eraseChars/M.pressKey already apply. Omitting the argument makes
-- hs.eventtap.keyStroke() fall back to 200 000 us implemented as a BLOCKING usleep,
-- stalling the run loop that services the typing event tap mid-injection.
local PASTE_KEY_DELAY_US = 0

-- Serialised clipboard save/restore state. Two clipboard sends within
-- CLIPBOARD_RESTORE_DELAY_S of each other must NOT each save() — the second would
-- capture the first's still-injected payload as "the user's clipboard" and both
-- restores would then clobber the real original. On an overlapping send we cancel
-- the pending restore but KEEP the first-captured original (mirrors the
-- keymap/utils.lua paste discipline). Declared ABOVE M.send so the restore closures
-- capture them correctly (F-L8).
local _paste_saved_original = nil
local _paste_pending_timer  = nil


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
	if type(text) ~= "string" then
		Logger.error(LOG, "M.send() requires a string, got %s — ignoring call.", type(text))
		return
	end
	local options = type(opts) == "table" and opts or {}
	local mode    = type(options.mode) == "string" and options.mode or "auto"

	-- Resolve "auto" to a concrete strategy based on payload length.
	if mode == "auto" then
		mode = #text > CLIPBOARD_THRESHOLD and "clipboard" or "direct"
	end

	local ok, err
	if mode == "clipboard" then
		ok, err = pcall(function()
			-- If a restore is still pending from a previous clipboard send, cancel it
			-- but KEEP the first-captured original; only capture the user's clipboard
			-- when no send is in flight (otherwise we'd save our own injected payload).
			if _paste_pending_timer then
				pcall(function() _paste_pending_timer:stop() end)
				_paste_pending_timer = nil
			else
				_paste_saved_original = Clipboard.save()
			end
			local saved = _paste_saved_original  -- bind the correct value into the closure
			Clipboard.write(text)
			hs.eventtap.keyStroke(PASTE_MODIFIER, PASTE_KEY, PASTE_KEY_DELAY_US)
			-- Restore after a short delay so the paste completes before we overwrite.
			_paste_pending_timer = hs.timer.doAfter(CLIPBOARD_RESTORE_DELAY_S, function()
				_paste_pending_timer  = nil
				Clipboard.restore(saved)
				_paste_saved_original = nil
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
--- @param delay number|nil Hammerspoon inter-key delay in seconds (defaults to 0).
function M.eraseChars(count, ...)
	if type(count) ~= "number" or count < 1 then return end
	local delay = select(1, ...)
	local key_delay = tonumber(delay) or 0
	local ok, err = pcall(function()
		for _ = 1, count do
			hs.eventtap.keyStroke({}, "delete", key_delay)
		end
	end)
	if not ok then
		Logger.error(LOG, "eraseChars(%d): failed — %s", count, tostring(err))
	end
end

--- Emits a single keystroke with optional modifiers.
--- @param key       string   Key name (e.g. "return", "escape", "f1").
--- @param modifiers table    Array of modifier names: "ctrl"|"shift"|"alt"|"cmd".
--- @param delay     number|nil Hammerspoon inter-key delay in seconds (defaults to 0).
function M.pressKey(key, modifiers, ...)
	local mods = type(modifiers) == "table" and modifiers or {}
	local delay = select(1, ...)
	local key_delay = tonumber(delay) or 0
	local ok, err = pcall(hs.eventtap.keyStroke, mods, key, key_delay)
	if not ok then
		Logger.error(LOG, "pressKey('%s'): failed — %s", tostring(key), tostring(err))
	end
end

return M

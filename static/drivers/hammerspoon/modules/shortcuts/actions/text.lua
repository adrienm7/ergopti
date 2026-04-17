--- modules/shortcuts/actions/text.lua

--- ==============================================================================
--- MODULE: Shortcuts — Text Actions
--- DESCRIPTION:
--- Implements all text-manipulation shortcuts: word and line selection, case
--- transformation (title case, uppercase toggle), plain-text paste, and line
--- wrapping.
---
--- FEATURES & RATIONALE:
--- 1. Async Clipboard Engine: copy → transform → paste → re-select → restore
---    clipboard never leaves the pasteboard permanently modified.
--- 2. Toggle Logic: case transforms alternate between two states on repeated
---    invocations so the user never needs to undo manually.
--- ==============================================================================

local M = {}

local hs         = hs
local timer      = hs.timer
local eventtap   = hs.eventtap
local pasteboard = hs.pasteboard
local Logger     = require("lib.logger")

local LOG = "shortcuts.actions.text"




-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local COPY_SETTLE_SEC    = 0.2    -- Wait after Cmd+C for clipboard to fill
local PASTE_SETTLE_SEC   = 0.08   -- Wait before pasting the transformed text
local RESELECT_DELAY_SEC = 0.08   -- Wait after paste before re-selecting
local RESTORE_DELAY_SEC  = 0.15   -- Wait after re-select before restoring clipboard
local MAX_RESELECT_CHARS = 5000   -- Safety cap: avoid freezing on huge pastes




-- ==========================================
-- ==========================================
-- ======= 2/ Internal String Helpers =======
-- ==========================================
-- ==========================================

--- Trims leading and trailing whitespace from a string.
--- @param s string The input string.
--- @return string The trimmed string.
local function trim(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Converts a string to Title Case.
--- @param s string The input string.
--- @return string The Title Case string.
local function titlecase(s)
	if type(s) ~= "string" then return "" end
	return (s:lower():gsub("(%S+)", function(w)
		return w:sub(1, 1):upper() .. w:sub(2)
	end))
end

--- Asynchronous text-transform engine.
--- Copies the current selection, applies the callback, pastes the result, then
--- re-selects the pasted text so repeated transforms work without re-selecting,
--- and finally restores the original clipboard content.
--- @param transform_func function Receives the selected text; returns the transformed string.
local function do_transform(transform_func)
	Logger.trace(LOG, "Text transformation started…")
	local prior = pasteboard.getContents()
	pasteboard.clearContents()
	eventtap.keyStroke({"cmd"}, "c")

	timer.doAfter(COPY_SETTLE_SEC, function()
		local sel = pasteboard.getContents()

		if not sel or sel == "" then
			if prior then pcall(pasteboard.setContents, prior) end
			Logger.warn(LOG, "Text transform aborted — no text was selected.")
			return
		end

		local ok, transformed = pcall(transform_func, sel)
		if not ok or not transformed then
			if prior then pcall(pasteboard.setContents, prior) end
			Logger.error(LOG, "Text transform callback failed.")
			return
		end

		pcall(pasteboard.setContents, transformed)

		timer.doAfter(PASTE_SETTLE_SEC, function()
			eventtap.keyStroke({"cmd"}, "v", 0.02)

			timer.doAfter(RESELECT_DELAY_SEC, function()
				-- Use utf8.len for accuracy; fall back to byte length
				local len_ok, ulen = pcall(utf8.len, transformed)
				local n = (len_ok and ulen and ulen > 0) and ulen or #transformed
				if n > MAX_RESELECT_CHARS then n = MAX_RESELECT_CHARS end

				if n > 0 then
					-- Move the caret to the start of the pasted block, then re-select
					for _ = 1, n do eventtap.keyStroke({},        "left",  0.001) end
					for _ = 1, n do eventtap.keyStroke({"shift"}, "right", 0.001) end
				end

				timer.doAfter(RESTORE_DELAY_SEC, function()
					pcall(function()
						if prior and prior ~= "" then
							pasteboard.setContents(prior)
						else
							pasteboard.clearContents()
						end
					end)
					Logger.done(LOG, "Text transformation completed.")
				end)
			end)
		end)
	end)
end




-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Pastes the current clipboard content stripped of any rich-text formatting.
function M.paste_as_plain_text()
	local prior = pasteboard.getContents()
	local plain = prior or ""

	pcall(function()
		pasteboard.clearContents()
		pasteboard.setContents(plain)
	end)

	timer.doAfter(PASTE_SETTLE_SEC, function()
		eventtap.keyStroke({"cmd"}, "v", 0.02)
		timer.doAfter(0.25, function()
			pcall(function()
				if prior and prior ~= "" then
					pasteboard.setContents(prior)
				else
					pasteboard.clearContents()
				end
			end)
		end)
	end)
end

--- Selects the entire current line (Cmd+Left, then Cmd+Shift+Right).
function M.select_line()
	eventtap.keyStroke({"cmd"}, "left")
	eventtap.keyStroke({"cmd", "shift"}, "right")
end

--- Wraps the current line in parentheses.
function M.surround_with_parens()
	eventtap.keyStroke({"cmd"}, "left")
	hs.eventtap.keyStrokes("(")
	timer.doAfter(0.04, function()
		eventtap.keyStroke({"cmd"}, "right")
		hs.eventtap.keyStrokes(")")
	end)
end

--- Toggles the current selection between Title Case and lowercase.
function M.toggle_titlecase()
	do_transform(function(sel)
		local t = titlecase(sel)
		-- If already title-cased, drop to lowercase; otherwise apply title case
		return (sel == t) and sel:lower() or t
	end)
end

--- Toggles the current selection between UPPERCASE and lowercase.
function M.toggle_uppercase()
	do_transform(function(sel)
		-- Promote if any lowercase exists; demote otherwise
		return sel:match("%l") and sel:upper() or sel:lower()
	end)
end

--- Selects the current word under the cursor (Alt+Right, then Alt+Shift+Left).
function M.select_word()
	eventtap.keyStroke({"alt"}, "right")
	eventtap.keyStroke({"alt", "shift"}, "left")
end

return M

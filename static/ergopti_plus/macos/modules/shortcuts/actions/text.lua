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
--- ====================================
-- ======= 1/ Constants & State =======
--- ====================================
-- ====================================

local COPY_SETTLE_SEC    = 0.2    -- Wait after Cmd+C for clipboard to fill
local PASTE_SETTLE_SEC   = 0.08   -- Wait before pasting the transformed text
local RESELECT_DELAY_SEC = 0.08   -- Wait after paste before re-selecting
local RESTORE_DELAY_SEC  = 0.15   -- Wait after re-select before restoring clipboard
local MAX_RESELECT_CHARS = 5000   -- Safety cap: avoid freezing on huge pastes

-- Symbols that should wrap the selection rather than replace it.
-- The canonical catalogue AND its grouping live in the SHARED single source of
-- truth: ``static/ergopti_plus/shared/wrap_symbols.json`` (the same file the AHK
-- driver reads). It is loaded once below — NEVER hardcode the list or its order
-- here. WRAP_GROUPS preserves the ordered groups (the menu draws a separator
-- between them); WRAP_PAIRS is the flattened {[char]={left,right}} lookup with
-- both the opening and closing char of each pair registered as keys.

-- Emergency-only fallback used when the shared JSON cannot be read/parsed. Kept
-- intentionally minimal (ASCII brackets + straight quotes) so a transient I/O
-- failure still leaves basic wrapping usable; the real catalogue is the JSON.
local FALLBACK_GROUPS = {
	{ { left = "(", right = ")" }, { left = "[", right = "]" },
	  { left = "{", right = "}" }, { left = "<", right = ">" } },
	{ { left = '"', right = '"' }, { left = "'", right = "'" } },
}

--- Resolves the shared/wrap_symbols.json path from this module's own on-disk
--- location, independent of any config-dir override, so the catalogue loads
--- identically in the packaged app and in headless unit tests.
--- @return string|nil Absolute path, or nil if the source path is unresolvable.
local function shared_wrap_symbols_path()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	-- src = .../ergopti_plus/macos/modules/shortcuts/actions/text.lua
	local actions_dir = src:match("^(.*)[/\\][^/\\]+%.lua$")
	if not actions_dir then return nil end
	-- actions → shortcuts → modules → macos → ergopti_plus, then shared/
	return actions_dir .. "/../../../../shared/wrap_symbols.json"
end

--- Reads the shared catalogue and returns its ordered groups, or nil on failure.
--- @return table|nil Array of groups (each an array of {left,right}).
local function load_shared_groups()
	local path = shared_wrap_symbols_path()
	if not path then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	if type(content) ~= "string" or content == "" then return nil end
	local ok, data = pcall(hs.json.decode, content)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then return nil end
	return data.groups
end

-- Build WRAP_GROUPS (ordered) and WRAP_PAIRS (flattened lookup) from the shared
-- catalogue, falling back to the minimal emergency set on any failure.
local WRAP_GROUPS = load_shared_groups()
if type(WRAP_GROUPS) ~= "table" or #WRAP_GROUPS == 0 then
	Logger.warn(LOG, "Shared wrap-symbols catalogue unreadable — using emergency fallback.")
	WRAP_GROUPS = FALLBACK_GROUPS
end

local WRAP_PAIRS = {}
for _, group in ipairs(WRAP_GROUPS) do
	for _, pair in ipairs(group) do
		if type(pair) == "table" and type(pair.left) == "string" and pair.left ~= ""
				and type(pair.right) == "string" and pair.right ~= "" then
			WRAP_PAIRS[pair.left] = { left = pair.left, right = pair.right }
			if pair.right ~= pair.left then
				WRAP_PAIRS[pair.right] = { left = pair.left, right = pair.right }
			end
		end
	end
end




-- ==========================================
--- ==========================================
-- ======= 2/ Internal String Helpers =======
--- ==========================================
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
--- =============================
-- ======= 3/ Public API =======
--- =============================
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

--- Returns the AXSelectedText of the focused UI element, or nil if unavailable.
--- Uses the Accessibility API so no clipboard manipulation is needed.
--- @return string|nil The selected text, or nil when nothing is selected.
local function ax_selected_text()
	local ok_ax, ax = pcall(require, "hs.axuielement")
	if not ok_ax or not ax then return nil end

	local ok_el, el = pcall(function() return ax.systemWideElement():attributeValue("AXFocusedUIElement") end)
	if not ok_el or not el then return nil end

	local ok_sel, sel = pcall(function() return el:attributeValue("AXSelectedText") end)
	if not ok_sel then return nil end
	return (type(sel) == "string" and sel ~= "") and sel or nil
end

--- The full built-in WRAP_PAIRS catalogue exposed for external inspection.
--- Callers that need a filtered or user-extended table should use build_active_wrap_pairs().
M.WRAP_PAIRS = WRAP_PAIRS

--- The ordered built-in groups from the shared catalogue. Each entry is an array
--- of {left, right} pairs; the menu draws a separator between consecutive groups.
--- Exposed so the menu mirrors the shared grouping without duplicating the order.
M.WRAP_GROUPS = WRAP_GROUPS

--- Builds the active wrapping-pairs table from the built-in catalogue and user state.
--- @param symbol_states table Map of symbol key → boolean (true = enabled).
---   The key is the opening character, e.g. "(" or the asymmetric "« ".
--- @param custom_symbols table Array of {key, left, right} for user-added pairs.
--- @return table {[char]={left,right}} ready for the eventtap filter.
function M.build_active_wrap_pairs(symbol_states, custom_symbols)
	local result = {}
	for char, pair in pairs(WRAP_PAIRS) do
		-- Use the opening symbol as the canonical key for state lookup
		local state_key = pair.left
		local enabled = (type(symbol_states) ~= "table") or (symbol_states[state_key] ~= false)
		if enabled then
			result[char] = pair
		end
	end
	if type(custom_symbols) == "table" then
		for _, cs in ipairs(custom_symbols) do
			if type(cs) == "table" and type(cs.left) == "string" and cs.left ~= "" then
				local right = (type(cs.right) == "string" and cs.right ~= "") and cs.right or cs.left
				-- Register under both opening and closing chars (mirrors WRAP_PAIRS pattern)
				result[cs.left]  = { left = cs.left, right = right }
				if right ~= cs.left then
					result[right] = { left = cs.left, right = right }
				end
			end
		end
	end
	return result
end

--- Wraps the current selection with left/right symbols, or types the symbol if nothing is selected.
--- Uses AXSelectedText to avoid touching the clipboard.
--- @param symbol string The raw character typed by the user.
--- @param left string Opening symbol to prepend.
--- @param right string Closing symbol to append.
function M.surround_selection_if_selected(symbol, left, right)
	local sel = ax_selected_text()

	if sel then
		Logger.debug(LOG, "Wrapping %d-char selection with '%s'…'%s'.", #sel, left, right)
		local prior = pasteboard.getContents()
		pcall(pasteboard.setContents, left .. sel .. right)
		timer.doAfter(0, function()
			eventtap.keyStroke({"cmd"}, "v", 0.02)
			timer.doAfter(0.25, function()
				pcall(function()
					if prior and prior ~= "" then pasteboard.setContents(prior)
					else pasteboard.clearContents() end
				end)
				Logger.done(LOG, "Selection wrapped.")
			end)
		end)
	else
		-- No selection — type the raw symbol so the key behaves normally
		hs.eventtap.keyStrokes(symbol)
	end
end

return M

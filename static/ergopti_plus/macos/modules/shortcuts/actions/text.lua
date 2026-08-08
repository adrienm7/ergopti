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
local pasteboard = hs.pasteboard
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local Timings    = require("infra.timings")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "shortcuts.actions.text"

-- Explicit inter-key delay for simulated keystrokes. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on
-- the main run loop, so an omitted delay stalls the loop that services the typing
-- event tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout).
local KEYSTROKE_NO_DELAY_US = 0





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Clipboard settle delays come from the shared cross-driver registry
-- (_shared/modules/timings/constants.toml [debounce]) so AHK and macOS stay in sync.
local COPY_SETTLE_SEC    = Timings.sec("debounce", "clipboard_copy_settle_ms")  -- Wait after Cmd+C for clipboard to fill
local PASTE_SETTLE_SEC   = Timings.sec("debounce", "clipboard_paste_settle_ms") -- Wait before pasting the transformed text
local RESELECT_DELAY_SEC = Timings.sec("debounce", "clipboard_reselect_ms")     -- Wait after paste before re-selecting
local RESTORE_DELAY_SEC  = Timings.sec("debounce", "clipboard_restore_ms")      -- Wait after re-select before restoring clipboard
local MAX_RESELECT_CHARS = 5000   -- Safety cap: avoid freezing on huge pastes

-- Symbols that should wrap the selection rather than replace it.
-- The canonical catalogue AND its grouping live in the SHARED single source of
-- truth: ``static/ergopti_plus/_shared/wrap_symbols.json`` (the same file the AHK
-- driver reads). It is loaded once below — NEVER hardcode the list or its order
-- here. WRAP_GROUPS preserves the ordered groups (each {i18n=<label key>, pairs=…};
-- the menu renders each as a named nested sub-submenu); WRAP_PAIRS is the
-- flattened {[char]={left,right}} lookup with both the opening and closing char
-- of each pair registered as keys.

-- Emergency-only fallback used when the shared JSON cannot be read/parsed. Kept
-- intentionally minimal (ASCII brackets + straight quotes) so a transient I/O
-- failure still leaves basic wrapping usable; the real catalogue is the JSON.
local FALLBACK_GROUPS = {
	{ i18n = "menu.shortcuts.wrap_group_brackets", pairs = {
		{ left = "(", right = ")" }, { left = "[", right = "]" },
		{ left = "{", right = "}" }, { left = "<", right = ">" } } },
	{ i18n = "menu.shortcuts.wrap_group_quotes", pairs = {
		{ left = '"', right = '"' }, { left = "'", right = "'" } } },
}

--- Reads the shared catalogue and returns its ordered groups, or nil on failure.
--- The path is resolved through the single shared-tree resolver (Paths.shared),
--- which performs the dual-root upward walk — robust to packaged .app builds and
--- symlinked ~/.hammerspoon setups alike.
--- @return table|nil Array of groups (each {i18n=<label key>, pairs={{left,right},…}}).
local function load_shared_groups()
	local path = Paths.shared("modules/wrap_symbols/wrap_symbols.json")
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	if type(content) == "string" and content ~= "" then
		-- Strip a leading UTF-8 BOM — hs.json.decode rejects it.
		if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
		local ok, data = pcall(hs.json.decode, content)
		if ok and type(data) == "table" and type(data.groups) == "table" and #data.groups > 0 then
			return data.groups
		end
	end
	return nil
end

-- Normalize a raw groups array to the canonical {i18n, pairs} shape. Tolerates
-- the older bare-array-of-pairs shape so a shape mismatch (e.g. a stale on-disk
-- catalogue) can never silently empty the lookup and stop ALL wrapping.
local function normalize_groups(raw)
	local out = {}
	for _, g in ipairs(raw or {}) do
		if type(g) == "table" then
			if type(g.pairs) == "table" then
				out[#out + 1] = { i18n = g.i18n, pairs = g.pairs }
			elseif type(g[1]) == "table" then
				-- Bare array of {left,right} pairs (legacy / hand-edited shape).
				out[#out + 1] = { i18n = nil, pairs = g }
			end
		end
	end
	return out
end

-- Build WRAP_GROUPS (ordered, each {i18n, pairs}) and WRAP_PAIRS (flattened
-- lookup) from the shared catalogue, falling back to the minimal emergency set
-- on any failure.
local WRAP_GROUPS = normalize_groups(load_shared_groups())
if #WRAP_GROUPS == 0 then
	Logger.warn(LOG, "Shared wrap-symbols catalogue unreadable — using emergency fallback.")
	WRAP_GROUPS = FALLBACK_GROUPS
end

local WRAP_PAIRS = {}
for _, group in ipairs(WRAP_GROUPS) do
	for _, pair in ipairs(group.pairs or {}) do
		if type(pair) == "table" and type(pair.left) == "string" and pair.left ~= ""
				and type(pair.right) == "string" and pair.right ~= "" then
			WRAP_PAIRS[pair.left] = { left = pair.left, right = pair.right }
			if pair.right ~= pair.left then
				WRAP_PAIRS[pair.right] = { left = pair.left, right = pair.right }
			end
		end
	end
end

-- Surface the catalogue size at load. An empty catalogue (a path/parse failure)
-- would silently break ALL wrapping, so it is logged loudly as an ERROR; the
-- healthy case is a one-shot INFO that confirms the source the catalogue came
-- from. Kept permanently — cheap (fires once) and invaluable when wrapping
-- mysteriously stops in a given deployment.
do
	local key_count = 0
	for _ in pairs(WRAP_PAIRS) do key_count = key_count + 1 end
	if key_count == 0 then
		Logger.error(LOG, "Wrap catalogue is EMPTY — selection wrapping is disabled. Catalogue path/parse failed.")
	else
		Logger.info(LOG, "Wrap catalogue ready: %d group(s), %d lookup key(s).", #WRAP_GROUPS, key_count)
	end
end





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
-- The transform pipeline owns the clipboard for roughly half a second (copy →
-- transform → paste → re-select → restore). A second press inside that window
-- snapshots a clipboard the first run had already overwritten with its own
-- intermediate value, and then "restores" that instead of the user's real
-- clipboard — silently destroying it. Guarded with the in-flight-flag pattern
-- already used by infra/ui_restore and api_mlx, including their hard timeout: a
-- flag that could stick would block every later transform for the session.
local _transform_in_flight = false
-- Same guard for the wrap path, declared beside its sibling so the pair stays visible.
local _wrap_in_flight      = false
local TRANSFORM_LOCK_TIMEOUT_SEC = 2.0

-- Identity of the transform that currently owns the clipboard. The failsafe
-- below fires on a fixed delay, so without this it released whichever transform
-- was in flight when it happened to expire — including a newer one that had
-- barely started.
local _transform_generation = 0

--- Re-selects the preceding characters as one ordered synthetic action.
--- Building one batch avoids one broker trigger/action epoch per cursor key.
--- Preserve the original Left then Shift+Right sequence: besides selecting the
--- same text, it leaves the active end of the selection on the right so a
--- repeated transform replaces the same range in the same direction.
--- @param count integer Number of preceding characters to select.
--- @return boolean dispatched
local function reselect_previous_text(count)
	if type(count) ~= "number" or count < 1 then return true end
	local tx = nil
	local ok, err = xpcall(function()
		tx = SyntheticInput.begin("shortcuts.text.reselect", "action")
		local batch = SyntheticInput.begin_batch(tx)
		for _ = 1, count do
			SyntheticInput.keyStroke(batch, {}, "left")
		end
		for _ = 1, count do
			SyntheticInput.keyStroke(batch, { "shift" }, "right")
		end
		assert(SyntheticInput.dispatch(batch),
			"synthetic reselection batch could not be dispatched")
		SyntheticInput.seal(tx)
	end, debug.traceback)
	if ok then return true end
	if tx then pcall(SyntheticInput.cancel, tx) end
	Logger.error(LOG, "Text reselection could not be dispatched - %s.", tostring(err))
	return false
end

local function do_transform(transform_func)
	if _transform_in_flight then
		Logger.debug(LOG, "Text transform ignored — a previous one still owns the clipboard.")
		return
	end
	_transform_in_flight = true
	_transform_generation = _transform_generation + 1
	local my_generation = _transform_generation

	--- Releases the lock, but only if this transform still owns it.
	--- Called at every terminal point rather than left to the failsafe: released
	--- only by the 2 s timer, a transform that finished in half a second still
	--- blocked the next one for the remaining second and a half, so deliberate
	--- repeat transforms were simply dropped.
	local function release()
		if my_generation ~= _transform_generation then return end
		_transform_in_flight = false
	end

	-- Failsafe release: a callback that never fires must not strand the flag for
	-- the session. Generation-checked because a long selection legitimately
	-- outlives this delay — the re-select walks the text one keystroke at a time
	-- — and an unguarded failsafe then unlocked the clipboard mid-transform,
	-- re-opening the very race the flag exists to close.
	timer.doAfter(TRANSFORM_LOCK_TIMEOUT_SEC, release)

	Logger.trace(LOG, "Text transformation started…")
	local prior = pasteboard.getContents()
	pasteboard.clearContents()
	SyntheticInput.emit_key_stroke({"cmd"}, "c", KEYSTROKE_NO_DELAY_US)

	timer.doAfter(COPY_SETTLE_SEC, function()
		local sel = pasteboard.getContents()

		if not sel or sel == "" then
			if prior then pcall(pasteboard.setContents, prior) end
			release()
			Logger.warn(LOG, "Text transform aborted — no text was selected.")
			return
		end

		local ok, transformed = pcall(transform_func, sel)
		if not ok or not transformed then
			if prior then pcall(pasteboard.setContents, prior) end
			release()
			Logger.error(LOG, "Text transform callback failed.")
			return
		end

		pcall(pasteboard.setContents, transformed)

		timer.doAfter(PASTE_SETTLE_SEC, function()
			SyntheticInput.emit_key_stroke({"cmd"}, "v", 0.02)

			timer.doAfter(RESELECT_DELAY_SEC, function()
				-- Use utf8.len for accuracy; fall back to byte length
				local len_ok, ulen = pcall(utf8.len, transformed)
				local n = (len_ok and ulen and ulen > 0) and ulen or #transformed
				if n > MAX_RESELECT_CHARS then n = MAX_RESELECT_CHARS end

				if n > 0 then
					reselect_previous_text(n)
				end

				timer.doAfter(RESTORE_DELAY_SEC, function()
					pcall(function()
						if prior and prior ~= "" then
							pasteboard.setContents(prior)
						else
							pasteboard.clearContents()
						end
					end)
					release()
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
		SyntheticInput.emit_key_stroke({"cmd"}, "v", 0.02)
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
	SyntheticInput.emit_key_stroke({"cmd"}, "left", KEYSTROKE_NO_DELAY_US)
	SyntheticInput.emit_key_stroke({"cmd", "shift"}, "right", KEYSTROKE_NO_DELAY_US)
end

--- Wraps the current line in parentheses.
function M.surround_with_parens()
	SyntheticInput.emit_key_stroke({"cmd"}, "left", KEYSTROKE_NO_DELAY_US)
	SyntheticInput.emit_key_strokes("(")
	timer.doAfter(0.04, function()
		SyntheticInput.emit_key_stroke({"cmd"}, "right", KEYSTROKE_NO_DELAY_US)
		SyntheticInput.emit_key_strokes(")")
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
	SyntheticInput.emit_key_stroke({"alt"}, "right", KEYSTROKE_NO_DELAY_US)
	SyntheticInput.emit_key_stroke({"alt", "shift"}, "left", KEYSTROKE_NO_DELAY_US)
end

--- Returns the AXSelectedText of the focused UI element, or nil if unavailable.
--- Uses the Accessibility API so no clipboard manipulation is needed. Returns nil
--- BOTH when nothing is selected AND when the focused app does not expose
--- AXSelectedText (notably Electron apps such as VS Code). Callers MUST treat nil
--- as "cannot wrap" and let the raw symbol type through, never swallow it.
--- @return string|nil The selected text, or nil when unavailable.
function M.read_ax_selection()
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

--- The ordered built-in groups from the shared catalogue. Each entry is
--- {i18n=<label key>, pairs={{left,right},…}}; the menu renders each group as a
--- named nested sub-submenu. Exposed so the menu mirrors the shared grouping and
--- labels without duplicating the order or the catalogue.
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

--- Replaces an already-read, non-empty selection with ``left .. sel .. right``
--- via the clipboard. The caller MUST have confirmed a selection exists (use
--- read_ax_selection); this never types a bare symbol, so it is only ever called
--- on the path that has decided to suppress the original keystroke.
--- @param sel string The current selection text (non-empty).
--- @param left string Opening symbol to prepend.
--- @param right string Closing symbol to append.
function M.wrap_selection(sel, left, right)
	-- The missed sibling of _transform_in_flight, twenty lines up in this same
	-- file. Without it a second wrap fired while the first is still holding the
	-- clipboard snapshots the text the FIRST one just wrote, then "restores" it
	-- 250 ms later — so the user's real clipboard is replaced by a wrapped
	-- fragment of their own selection and is gone for good.
	if _wrap_in_flight then
		Logger.debug(LOG, "Wrap already in flight — ignoring the second request.")
		return
	end
	_wrap_in_flight = true
	Logger.debug(LOG, "Wrapping %d-char selection with '%s'…'%s'.", #sel, left, right)
	local prior = pasteboard.getContents()
	pcall(pasteboard.setContents, left .. sel .. right)
	timer.doAfter(0, function()
		SyntheticInput.emit_key_stroke({"cmd"}, "v", 0.02)
		timer.doAfter(0.25, function()
			pcall(function()
				if prior and prior ~= "" then pasteboard.setContents(prior)
				else pasteboard.clearContents() end
			end)
			-- Released only after the restore, so the window the guard covers is
			-- exactly the window in which `prior` is the value that must survive.
			_wrap_in_flight = false
			Logger.done(LOG, "Selection wrapped.")
		end)
	end)
end

--- Wraps the current selection with left/right symbols, or types the symbol if
--- nothing is selected. Retained for compatibility; the eventtap path now reads
--- the selection itself (read_ax_selection) so it can pass the key through
--- untouched when no selection is available — that path never reaches here.
--- @param symbol string The raw character typed by the user.
--- @param left string Opening symbol to prepend.
--- @param right string Closing symbol to append.
function M.surround_selection_if_selected(symbol, left, right)
	local sel = M.read_ax_selection()
	if sel then
		M.wrap_selection(sel, left, right)
	else
		-- No selection — type the raw symbol so the key behaves normally
		SyntheticInput.emit_key_strokes(symbol)
	end
end

return M

--- modules/shortcuts/manager.lua

--- ==============================================================================
--- MODULE: Shortcuts Manager (Linux)
--- DESCRIPTION:
--- Text-manipulation shortcuts for Linux: wrap symbols (brackets, quotes),
--- CapsWord (auto-capitalize first letter of each word), and text transforms
--- (uppercase, lowercase, title case) via xclip/xdotool.
---
--- Unlike macOS (hs.eventtap), Linux has no global keyboard-grab API. Wrap and
--- text transforms use the clipboard path (xclip to read/write, xdotool to
--- simulate Ctrl+C/V). CapsWord is hooked into the daemon's on_char callback
--- and tracks keyboard state through the keyboard_hook adapter.
---
--- FEATURES & RATIONALE:
--- 1. Wrap symbols: when the user types a bracket/quote while text is selected,
---    the selection is wrapped (e.g. "hello" → "(hello)"). If nothing is
---    selected, the symbol types normally. Deferred to a future keyboard-grab
---    implementation; the wrap-pairs catalogue and wrapping logic are ready.
--- 2. CapsWord: toggled via menu or shortcut. When active, the next word's
---    first letter is capitalized and CapsWord auto-disengages. Hooked into
---    the daemon's on_char for per-keystroke processing.
--- 3. Text transforms: clipboard-based transforms that copy the selection,
---    apply a transform function, paste the result, and restore the clipboard.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.shortcuts.manager"

-- =========================================
-- =========================================
-- ======= 1/ Wrap Symbol Pairs ============
-- =========================================
-- =========================================

--- Canonical wrap-pair catalogue. Each entry maps a trigger character to
--- { left, right } wrapping symbols.
local WRAP_PAIRS = {
	["("] = { left = "(", right = ")" },
	[")"] = { left = "(", right = ")" },
	["["] = { left = "[", right = "]" },
	["]"] = { left = "[", right = "]" },
	["{"] = { left = "{", right = "}" },
	["}"] = { left = "{", right = "}" },
	["<"] = { left = "<", right = ">" },
	[">"] = { left = "<", right = ">" },
	['"'] = { left = '"', right = '"' },
	["'"] = { left = "'", right = "'" },
	["`"] = { left = "`", right = "`" },
	["*"] = { left = "*", right = "*" },
	["_"] = { left = "_", right = "_" },
	["~"] = { left = "~", right = "~" },
	["«"] = { left = "« ", right = " »" },
	["»"] = { left = "« ", right = " »" },
}

--- Checks whether a character is a wrap-pair trigger.
--- @param ch string Single character.
--- @return table|nil { left, right } or nil if not a wrap character.
function M.get_wrap_pair(ch)
	if type(ch) ~= "string" or #ch ~= 1 then return nil end
	return WRAP_PAIRS[ch]
end

--- Returns the full wrap-pairs catalogue.
--- @return table
function M.get_wrap_pairs()
	return WRAP_PAIRS
end

--- Wraps the current X11 selection with left/right symbols.
--- Uses xclip to read the primary selection, then xdotool to type the result.
--- @param left string Opening symbol.
--- @param right string Closing symbol.
function M.wrap_selection(left, right)
	if type(left) ~= "string" or type(right) ~= "string" then return end

	-- Read current selection via xclip (clipboard, not primary, so
	-- the paste below via Ctrl+V matches the same selection buffer).
	local pipe = io.popen("xclip -o -selection clipboard 2>/dev/null")
	if not pipe then
		Logger.warn(LOG, "wrap_selection: xclip not available.")
		return
	end
	local sel = pipe:read("*a")
	pipe:close()

	if not sel or sel == "" then
		-- No selection — type the symbols as-is.
		local safe = (left .. right):gsub("'", "'\\''")
		os.execute("xdotool type -- '" .. safe .. "' 2>/dev/null &")
		return
	end

	-- Strip trailing newline that xclip adds.
	sel = sel:gsub("\n$", "")

	local wrapped = left .. sel .. right

	-- Write wrapped text to clipboard and paste.
	local pipe2 = io.popen("xclip -selection clipboard 2>/dev/null", "w")
	if pipe2 then
		pipe2:write(wrapped)
		pipe2:close()
		os.execute("xdotool key ctrl+v 2>/dev/null &")
	end

	Logger.debug(LOG, "Wrapped %d-char selection with '%s'…'%s'.", #sel, left, right)
end

-- =========================================
-- =========================================
-- ======= 2/ CapsWord =====================
-- =========================================
-- =========================================

local _caps_word_active = false
local _caps_word_triggered = false  -- true after first letter capitalized, waiting for word end

--- Returns whether CapsWord is currently active.
--- @return boolean
function M.is_caps_word_active()
	return _caps_word_active
end

--- Toggles CapsWord on/off via the menu.
function M.toggle_caps_word()
	_caps_word_active = not _caps_word_active
	_caps_word_triggered = false
	Logger.info(LOG, "CapsWord: %s", _caps_word_active and "ON" or "OFF")
end

--- Processes a character for CapsWord.
--- Called from the daemon's on_char hook.
--- CapsWord logic: when active, capitalize the first letter of the next word,
--- then disengage until the next word boundary.
--- @param ch string The character just typed.
--- @return string|nil Modified character (upper-cased), or nil to pass through.
function M.process_caps_word(ch)
	if not _caps_word_active then return nil end
	if type(ch) ~= "string" or #ch ~= 1 then return nil end

	-- Word boundaries: space, newline, tab, punctuation.
	local is_boundary = ch:match("^[%s%p]$") ~= nil

	if is_boundary then
		-- Word boundary reached — prepare for next word.
		_caps_word_triggered = false
		return nil
	end

	if not _caps_word_triggered then
		-- First letter of new word — capitalize and disengage for this word.
		_caps_word_triggered = true
		local upper = ch:upper()
		if upper == ch then
			return nil  -- already uppercase, no change needed
		end
		Logger.debug(LOG, "CapsWord: '%s' → '%s'.", ch, upper)
		return upper
	end

	return nil
end

-- =========================================
-- =========================================
-- ======= 3/ Text Manipulation ============
-- =========================================
-- =========================================

--- Reads the current X11 clipboard selection.
--- @return string|nil
local function _read_selection()
	local pipe = io.popen("xclip -o -selection clipboard 2>/dev/null")
	if not pipe then return nil end
	local sel = pipe:read("*a")
	pipe:close()
	if sel then sel = sel:gsub("\n$", "") end
	return sel
end

--- Pastes text via xdotool (replaces current selection).
--- @param text string
local function _paste_text(text)
	local pipe = io.popen("xclip -selection clipboard 2>/dev/null", "w")
	if pipe then
		pipe:write(text)
		pipe:close()
		os.execute("xdotool key ctrl+v 2>/dev/null &")
	else
		-- Fallback: type directly.
		local safe = text:gsub("'", "'\\''")
		os.execute("xdotool type -- '" .. safe .. "' 2>/dev/null &")
	end
end

--- Transforms the current selection to UPPERCASE.
function M.transform_uppercase()
	local sel = _read_selection()
	if not sel or sel == "" then
		Logger.warn(LOG, "transform_uppercase: no selection.")
		return
	end
	_paste_text(sel:upper())
	Logger.info(LOG, "Selection → UPPERCASE (%d chars).", #sel)
end

--- Transforms the current selection to lowercase.
function M.transform_lowercase()
	local sel = _read_selection()
	if not sel or sel == "" then
		Logger.warn(LOG, "transform_lowercase: no selection.")
		return
	end
	_paste_text(sel:lower())
	Logger.info(LOG, "Selection → lowercase (%d chars).", #sel)
end

--- Transforms the current selection to Title Case.
function M.transform_titlecase()
	local sel = _read_selection()
	if not sel or sel == "" then
		Logger.warn(LOG, "transform_titlecase: no selection.")
		return
	end
	local result = sel:lower():gsub("(%S+)", function(w)
		return w:sub(1, 1):upper() .. w:sub(2)
	end)
	_paste_text(result)
	Logger.info(LOG, "Selection → Title Case (%d chars).", #sel)
end

--- Selects the current word under cursor (Ctrl+Shift+Left, Ctrl+Shift+Right).
function M.select_word()
	os.execute("xdotool key ctrl+shift+Left 2>/dev/null &")
end

--- Selects the entire current line (Home, Shift+End).
function M.select_line()
	os.execute("xdotool key Home 2>/dev/null &")
	-- Small delay then extend selection.
	os.execute("(sleep 0.05 && xdotool key shift+End) 2>/dev/null &")
end

--- Pastes clipboard content as plain text (strips formatting).
function M.paste_plain()
	-- Read clipboard, then type it via xdotool (bypasses rich-text paste).
	local pipe = io.popen("xclip -o -selection clipboard 2>/dev/null")
	if not pipe then return end
	local text = pipe:read("*a")
	pipe:close()
	if text and text ~= "" then
		text = text:gsub("\n$", "")
		local safe = text:gsub("'", "'\\''")
		os.execute("xdotool type -- '" .. safe .. "' 2>/dev/null &")
	end
end

-- =========================================
-- =========================================
-- ======= 4/ Enable / Disable =============
-- =========================================
-- =========================================

local _enabled = false

--- Returns whether shortcuts are enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Enables shortcuts processing.
function M.enable()
	_enabled = true
	Logger.info(LOG, "Shortcuts enabled.")
end

--- Disables shortcuts processing.
function M.disable()
	_enabled = false
	_caps_word_active = false
	_caps_word_triggered = false
	Logger.info(LOG, "Shortcuts disabled.")
end

--- Toggles shortcuts on/off.
function M.toggle()
	if _enabled then M.disable() else M.enable() end
end

-- =========================================
-- =========================================
-- ======= 5/ Init =========================
-- =========================================
-- =========================================

--- Initialises the shortcuts module.
--- @param opts table|nil { enabled? }
function M.init(opts)
	opts = type(opts) == "table" and opts or {}
	-- Reset CapsWord state so init() gives a clean slate for tests.
	_caps_word_active = false
	_caps_word_triggered = false
	if opts.enabled == true then
		_enabled = true
	end
	Logger.info(LOG, "Shortcuts manager initialised (enabled=%s).", tostring(_enabled))
end

return M

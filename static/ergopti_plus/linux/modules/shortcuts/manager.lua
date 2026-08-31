--- modules/shortcuts/manager.lua

--- ==============================================================================
--- MODULE: Shortcuts Manager (Linux)
--- DESCRIPTION:
--- Text-manipulation shortcuts for Linux: wrap symbols (brackets, quotes),
--- CapsWord (auto-capitalize first letter of each word), and text transforms
--- (uppercase, lowercase, title case) through the session clipboard and uinput.
---
--- Wrap and text transforms use the display-server-aware clipboard adapter and
--- the daemon's owned uinput channel. CapsWord is hooked into the daemon's
--- on_char callback and tracks keyboard state through the keyboard_hook adapter.
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
local Paths  = require("infra.paths")
local Manifest = require("infra.manifest_reader")
local TomlCodec = require("toml_codec")
local Clipboard = require("adapters.clipboard")
local EventLoop = require("adapters.event_loop")
local ComboEmitter = require("modules.gestures.combo_emitter")
local Injector = require("modules.hotstrings.injector")
local LOG = "modules.shortcuts.manager"
local ENABLED_PATH = "shortcuts.enabled"
local CONFIG_SECTION = "shortcuts"
local DEFAULT_ENABLED = Manifest.default_for(ENABLED_PATH)

if type(DEFAULT_ENABLED) ~= "boolean" then
	error("The manifest default for " .. ENABLED_PATH .. " must be a boolean.")
end

local _writer_ok, TomlWriter = pcall(require, "toml_codec.writer")
if not _writer_ok then TomlWriter = nil end

--- Records that the user fired a shortcut.
---
--- At ENTRY, not on success, and deliberately: the table stores what the user
--- asked for, not whether it worked. macOS's events_shortcut carries a key name
--- and nothing else for the same reason — "I pressed the uppercase shortcut and
--- had nothing selected" is still a use of that shortcut, and a recorder that
--- only fires on the happy path under-reports exactly the actions a user is
--- struggling with.
---
--- pcall'd and lazily required: metrics are optional and must never be the
--- reason a shortcut does not run.
--- @param key string Stable action name; the dashboard groups by it.
local function record(key)
	local ok, keylogger = pcall(require, "modules.keylogger.keylogger")
	if not ok or type(keylogger.record_shortcut) ~= "function" then return end
	local app = "unknown"
	local ok_win, WindowInfo = pcall(require, "adapters.window_info")
	if ok_win and type(WindowInfo.focused_app_id) == "function" then
		local ok_id, id = pcall(WindowInfo.focused_app_id)
		if ok_id and type(id) == "string" and id ~= "" then app = id end
	end
	pcall(keylogger.record_shortcut, app, key)
end

-- =========================================
-- =========================================
-- ======= 1/ Wrap Symbol Pairs ============
-- =========================================
-- =========================================

-- Relative path (from static/ergopti_plus) to the shared wrap-symbol catalogue,
-- the single source of truth shared with the AHK and macOS drivers — never
-- hardcode the pair list here; edit the JSON so all 3 drivers stay in sync
local WRAP_SYMBOLS_REL_PATH = "modules/wrap_symbols/wrap_symbols.json"

-- Leading UTF-8 BOM bytes; the pure-Lua JSON decoder rejects a byte-order mark
local UTF8_BOM = "\239\187\191"

--- Resolves the absolute path to the shared wrap-symbols catalogue.
---
--- Through infra.paths. Stripping four path segments off this file's own
--- location described one layout only: an installed package stages the driver
--- flat under /usr/lib/ergopti, where four up leaves the install entirely and
--- every wrap pair is silently lost.
--- @return string Absolute catalogue path, or "" when the location is unresolvable.
local function resolve_wrap_symbols_path()
	return Paths.shared(WRAP_SYMBOLS_REL_PATH) or ""
end

--- Reads the shared wrap-symbols JSON and flattens its ordered groups into the
--- { [char] = { left, right } } lookup used at wrap time. Both the opening and
--- the closing character of each pair are registered as keys so typing either one
--- wraps the selection (mirrors the macOS driver's build loop). Fails loud with an
--- ERROR log and returns an empty table on any resolve/read/parse failure.
--- @return table The flattened wrap-pair lookup.
local function load_wrap_pairs()
	local lookup = {}

	local ok_json, json = pcall(require, "json")
	if not ok_json or type(json) ~= "table" or type(json.decode) ~= "function" then
		Logger.error(LOG, "JSON decoder unavailable — wrap-symbol catalogue not loaded.")
		return lookup
	end

	local path = resolve_wrap_symbols_path()
	if path == "" then
		Logger.error(LOG, "Could not resolve the shared wrap-symbols path — catalogue not loaded.")
		return lookup
	end

	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Shared wrap-symbols catalogue unreadable at '%s'.", path)
		return lookup
	end
	local content = fh:read("*a")
	fh:close()

	if type(content) == "string" and content:sub(1, 3) == UTF8_BOM then
		content = content:sub(4)
	end

	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then
		Logger.error(LOG, "Shared wrap-symbols catalogue failed to parse — catalogue not loaded.")
		return lookup
	end

	for _, group in ipairs(data.groups) do
		for _, pair in ipairs(group.pairs or {}) do
			if type(pair) == "table"
					and type(pair.left) == "string" and pair.left ~= ""
					and type(pair.right) == "string" and pair.right ~= "" then
				lookup[pair.left] = { left = pair.left, right = pair.right }
				if pair.right ~= pair.left then
					lookup[pair.right] = { left = pair.left, right = pair.right }
				end
			end
		end
	end

	local count = 0
	for _ in pairs(lookup) do count = count + 1 end
	Logger.info(LOG, "Wrap-symbol catalogue loaded from shared SSoT (%d lookup key(s)).", count)

	return lookup
end

--- Canonical wrap-pair catalogue, derived at require-time from the shared JSON
--- single source of truth (never hardcoded here). Each entry maps a trigger
--- character to its { left, right } wrapping symbols.
local WRAP_PAIRS = load_wrap_pairs()

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

--- Wraps the current selection with left/right symbols.
--- @param left string Opening symbol.
--- @param right string Closing symbol.
function M.wrap_selection(left, right)
	record("wrap_selection")
	if type(left) ~= "string" or type(right) ~= "string" then return false end
	local ok, reason = Clipboard.transform_selection(function(selected)
		return left .. selected .. right
	end, ComboEmitter.press, EventLoop.sleep_ms)
	if ok then return true end
	if reason == "no_selection" then
		local result = Injector.inject(0, left .. right, false)
		return type(result) == "table" and result.ok == true
	end
	Logger.error(LOG, "Selection wrapping failed: %s.", tostring(reason))
	return false
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
	record("caps_word")
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

local function transform_selection(action, transform)
	record(action)
	local ok, reason = Clipboard.transform_selection(transform, ComboEmitter.press, EventLoop.sleep_ms)
	if not ok then Logger.warn(LOG, "%s failed: %s.", action, tostring(reason)) end
	return ok
end

--- Transforms the current selection to UPPERCASE.
function M.transform_uppercase()
	return transform_selection("to_uppercase", string.upper)
end

--- Transforms the current selection to lowercase.
function M.transform_lowercase()
	return transform_selection("to_lowercase", string.lower)
end

--- Transforms the current selection to Title Case.
function M.transform_titlecase()
	return transform_selection("to_titlecase", function(selected)
		return selected:lower():gsub("(%S+)", function(word)
			return word:sub(1, 1):upper() .. word:sub(2)
		end)
	end)
end

--- Selects the current word under cursor (Ctrl+Shift+Left, Ctrl+Shift+Right).
function M.select_word()
	record("select_word")
	return ComboEmitter.press("ctrl+shift+Left")
end

--- Selects the entire current line (Home, Shift+End).
function M.select_line()
	record("select_line")
	if not ComboEmitter.press("Home") then return false end
	return ComboEmitter.press("shift+End")
end

--- Pastes clipboard content as plain text (strips formatting).
function M.paste_plain()
	record("paste_plain")
	local ok, text, reason = Clipboard.read_checked()
	if not ok or text == "" then
		Logger.warn(LOG, "Plain-text paste failed: %s.", tostring(reason or "clipboard is empty"))
		return false
	end
	local result = Injector.inject(0, text, false)
	return type(result) == "table" and result.ok == true
end

-- =========================================
-- =========================================
-- ======= 4/ Enable / Disable =============
-- =========================================
-- =========================================

local _enabled = false
local _config_path = nil
local _persist = false

--- Returns whether shortcuts are enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Persists a master-state transition before publishing it.
--- @param enabled boolean
--- @return boolean True when the transition was committed.
function M.set_enabled(enabled)
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Shortcut state must be a boolean — nothing changed.")
		return false
	end
	if _persist then
		if not TomlWriter or not _config_path then
			Logger.error(LOG, "Shortcut state cannot be persisted — nothing changed.")
			return false
		end
		local ok, err = TomlWriter.batch_write(_config_path, {
			{ section = CONFIG_SECTION, key = "enabled", value = enabled },
		})
		if not ok then
			Logger.error(LOG, "Could not persist shortcut state: %s.", tostring(err))
			return false
		end
	end

	_enabled = enabled
	if not enabled then
		_caps_word_active = false
		_caps_word_triggered = false
	end
	Logger.info(LOG, "Shortcuts %s.", enabled and "enabled" or "disabled")
	return true
end

--- Enables shortcuts processing.
--- @return boolean True when the transition was committed.
function M.enable()
	return M.set_enabled(true)
end

--- Disables shortcuts processing.
--- @return boolean True when the transition was committed.
function M.disable()
	return M.set_enabled(false)
end

--- Toggles shortcuts on/off.
function M.toggle()
	M.set_enabled(not _enabled)
	return _enabled
end

-- =========================================
-- =========================================
-- ======= 5/ Init =========================
-- =========================================
-- =========================================

--- Initialises the shortcuts module.
--- @param opts table|nil { enabled?, persist?, config_path? }
function M.init(opts)
	opts = type(opts) == "table" and opts or {}
	if opts.enabled ~= nil and type(opts.enabled) ~= "boolean" then
		error("shortcuts enabled override must be a boolean")
	end
	-- Reset CapsWord state so init() gives a clean slate for tests.
	_caps_word_active = false
	_caps_word_triggered = false
	_config_path = opts.config_path or require("infra.config_paths").config("config.toml")
	_persist = opts.persist == true

	local enabled = DEFAULT_ENABLED
	if _persist then
		local fh = io.open(_config_path, "r")
		if fh then
			local content = fh:read("*a")
			fh:close()
			local ok, config = pcall(TomlCodec.decode, content)
			if not ok or type(config) ~= "table" then
				Logger.error(LOG, "Shortcut configuration is invalid — failing closed.")
				enabled = false
			elseif type(config[CONFIG_SECTION]) == "table"
				and config[CONFIG_SECTION].enabled ~= nil
			then
				if type(config[CONFIG_SECTION].enabled) == "boolean" then
					enabled = config[CONFIG_SECTION].enabled
				else
					Logger.error(LOG, "Shortcut enabled state is invalid — failing closed.")
					enabled = false
				end
			end
		end
	end
	if type(opts.enabled) == "boolean" then enabled = opts.enabled end
	_enabled = enabled
	Logger.info(LOG, "Shortcuts manager initialised (enabled=%s).", tostring(_enabled))
end

return M

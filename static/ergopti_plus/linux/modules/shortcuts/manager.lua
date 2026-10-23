--- modules/shortcuts/manager.lua

--- ==============================================================================
--- MODULE: Shortcuts Manager (Linux)
--- DESCRIPTION:
--- Text-manipulation shortcuts for Linux: wrap symbols (brackets, quotes),
--- CapsWord (the next word typed in capitals), and text transforms
--- (uppercase, lowercase, title case) through the session clipboard and uinput.
---
--- Wrap and text transforms use the display-server-aware clipboard adapter and
--- the daemon's owned uinput channel. CapsWord is hooked into the daemon's
--- on_char callback and tracks keyboard state through the keyboard_hook adapter.
---
--- FEATURES & RATIONALE:
--- 1. Wrap symbols: when the user types a bracket/quote while text is selected,
---    the selection is wrapped (e.g. "hello" → "(hello)"). If nothing is
---    selected, the symbol types normally. The decision lives in
---    modules/shortcuts/wrap_on_type.lua, run from the keyboard hook's
---    consumption callback; this module owns its switch
---    (shortcuts.wrap_text_if_selected) and the wrap-pair catalogue.
--- 2. CapsWord: toggled via menu, shortcut or tap action. While it is on,
---    CapsLock is locked on the desktop (adapters/keyboard_hook,
---    lock_caps_for_word), as Windows and macOS light theirs, so every letter
---    reaches the application as a capital and the digits and punctuation
---    stay what the layout's CapsLock level types. It switches itself off on
---    what [shortcuts.caps_word] names (a delay without a keystroke, a checked
---    delimiter, a checked pointer kind), through the shared policy and
---    modules/shortcuts/caps_word_auto_off, and on a CapsLock press. Hooked
---    into the daemon's on_char, control-key and pointer callbacks.
--- 3. Text transforms: clipboard-based transforms that copy the selection,
---    apply a transform function, paste the result, and restore the clipboard.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")

local Logger = require("logger.shim")
local Paths  = require("infra.paths")
local Manifest = require("infra.manifest_reader")
local TextCase = require("unicode_case")
local WrapPair = require("wrap_pair")
local SendInput = require("send_input")
local TomlCodec = require("toml_codec")
local Clipboard = require("adapters.clipboard")
local EventLoop = require("adapters.event_loop")
local ComboEmitter = require("modules.gestures.combo_emitter")
local Injector = require("modules.hotstrings.injector")
local EvdevCodes = require("infra.evdev_codes")
local Monotonic = require("infra.monotonic")
local CapsWordPolicy = require("caps_word.auto_off")
local CapsWordAutoOff = require("modules.shortcuts.caps_word_auto_off")
local LOG = "modules.shortcuts.manager"
local _configuration_owner = nil
local _capture_text_owner = nil
local ENABLED_PATH = "shortcuts.enabled"

-- The send_text / send_key / send_shortcut vocabulary, read on first use.
local SEND_KEYS_REL_PATH = "modules/actions/send_keys.json"
local _send_vocabulary = nil

-- The keys that select the level keyboard_layout reports a character on, for a
-- shortcut whose key is a character: Shift for level 2, AltGr for level 3.
local LEVEL_MODIFIER_CODES = {
	shift = EvdevCodes.KEY_LEFTSHIFT,
	altgr = EvdevCodes.KEY_RIGHTALT,
}
local CONFIG_SECTION = "shortcuts"
local DEFAULT_ENABLED = Manifest.default_for(ENABLED_PATH)

if type(DEFAULT_ENABLED) ~= "boolean" then
	error("The manifest default for " .. ENABLED_PATH .. " must be a boolean.")
end

local _writer_ok, TomlWriter = pcall(require, "toml_codec.writer")
if not _writer_ok then TomlWriter = nil end
local collision_read = TomlWriter and TomlWriter.read_classified
local collision_decode, collision_shared = TomlCodec.decode, Paths.shared
local collision_single_character = TextCase.is_single_character
local collision_generation, collision_initialized = 0, false

--- Retains the original native field before metrics or clipboard I/O can yield.
--- @return table|nil publication
local function capture_text_destination()
	if type(_capture_text_owner) ~= "function" or _configuration_owner ~= nil then return nil end
	local generation = collision_generation
	local ok, destination = pcall(_capture_text_owner)
	if not ok or type(destination) ~= "table" or getmetatable(destination) ~= nil
		or type(destination.current) ~= "function" or type(destination.cached) ~= "function" then return nil end
	local function check(cached)
		if generation ~= collision_generation or _configuration_owner ~= nil then return false end
		local checked, allowed = pcall(cached and destination.cached or destination.current)
		return checked and allowed == true and generation == collision_generation and _configuration_owner == nil
	end
	if not check(false) then return nil end
	return { current = function() return check(false) end, cached = function() return check(true) end }
end
local wrap_source
local collision_json, collision_json_decode
local collision_factory

local function copy_wrap_pairs(pairs_by_symbol)
	local copy = {}
	for symbol, pair in pairs(pairs_by_symbol) do
		copy[symbol] = { left = pair.left, right = pair.right }
	end
	return copy
end

local function wrap_pairs_equal(actual, expected)
	if type(actual) ~= "table" or getmetatable(actual) ~= nil then return false end
	for symbol, pair in pairs(actual) do
		local saved = expected[symbol]
		if type(pair) ~= "table" or getmetatable(pair) ~= nil or not saved
			or pair.left ~= saved.left or pair.right ~= saved.right then return false end
		for field in pairs(pair) do if field ~= "left" and field ~= "right" then return false end end
	end
	for symbol in pairs(expected) do if rawget(actual, symbol) == nil then return false end end
	return true
end

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
	local ok, keystats = pcall(require, "modules.keystats.keystats")
	if not ok or type(keystats.record_shortcut) ~= "function" then return end
	local app = "unknown"
	local ok_win, WindowInfo = pcall(require, "adapters.window_info")
	if ok_win and type(WindowInfo.focused_app_id) == "function" then
		local ok_id, id = pcall(WindowInfo.focused_app_id)
		if ok_id and type(id) == "string" and id ~= "" then app = id end
	end
	pcall(keystats.record_shortcut, app, key)
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
	return collision_shared(WRAP_SYMBOLS_REL_PATH) or ""
end

--- Reads the shared wrap-symbols JSON and flattens its ordered groups into the
--- { [char] = { left, right } } lookup used at wrap time, and the ordered pair
--- list the wrap_selection parameter resolves against. Both the opening and
--- the closing character of each pair are registered as lookup keys so typing
--- either one wraps the selection (mirrors the macOS driver's build loop). Fails
--- loud with an ERROR log and returns empty tables on any resolve/read/parse
--- failure.
--- @return table The flattened wrap-pair lookup.
--- @return table The pairs in catalogue order, each { left, right }.
local function load_wrap_pairs()
	local lookup = {}
	local ordered = {}

	local ok_json, json = pcall(require, "json")
	if not ok_json or type(json) ~= "table" or type(json.decode) ~= "function" then
		Logger.error(LOG, "JSON decoder unavailable — wrap-symbol catalogue not loaded.")
		return lookup, ordered
	end

	local path = resolve_wrap_symbols_path()
	if path == "" then
		Logger.error(LOG, "Could not resolve the shared wrap-symbols path — catalogue not loaded.")
		return lookup, ordered
	end

	if type(collision_read) ~= "function" then
		Logger.error(LOG, "Shared wrap-symbols reader unavailable — catalogue not loaded.")
		return lookup, ordered
	end
	collision_json, collision_json_decode = json, json.decode
	local content, status = collision_read(path)
	if status ~= "ok" or type(content) ~= "string" then
		Logger.error(LOG, "Shared wrap-symbols catalogue unreadable at '%s'.", path)
		return lookup, ordered
	end
	local original_content = content

	if type(content) == "string" and content:sub(1, 3) == UTF8_BOM then
		content = content:sub(4)
	end

	local ok, data = pcall(collision_json_decode, content)
	if not ok or type(data) ~= "table" or type(data.groups) ~= "table" then
		Logger.error(LOG, "Shared wrap-symbols catalogue failed to parse — catalogue not loaded.")
		return lookup, ordered
	end

	for _, group in ipairs(data.groups) do
		for _, pair in ipairs(group.pairs or {}) do
			if type(pair) == "table"
					and type(pair.left) == "string" and pair.left ~= ""
					and type(pair.right) == "string" and pair.right ~= "" then
				ordered[#ordered + 1] = { left = pair.left, right = pair.right }
				lookup[pair.left] = { left = pair.left, right = pair.right }
				if pair.right ~= pair.left then
					lookup[pair.right] = { left = pair.left, right = pair.right }
				end
			end
		end
	end

	Logger.info(LOG, "Wrap-symbol catalogue loaded from shared SSoT (%d lookup key(s)).", TableUtil.count(lookup))

	wrap_source = { path = path, content = original_content, pairs = copy_wrap_pairs(lookup) }
	return lookup, ordered
end

--- Canonical wrap-pair catalogue, derived at require-time from the shared JSON
--- single source of truth (never hardcoded here). Each entry maps a trigger
--- character to its { left, right } wrapping symbols; WRAP_PAIR_LIST keeps the
--- catalogue order.
local WRAP_PAIRS, WRAP_PAIR_LIST = load_wrap_pairs()

--- Checks whether a character is a wrap-pair trigger.
--- @param ch string Single character.
--- @return table|nil { left, right } or nil if not a wrap character.
function M.get_wrap_pair(ch)
	-- One CHARACTER, not one byte: « », “ ” and the CJK brackets are pairs of
	-- the catalogue too, and a byte test made every one of them unmatched.
	if not TextCase.is_single_character(ch) then return nil end
	return WRAP_PAIRS[ch]
end

--- Returns the full wrap-pairs catalogue.
--- @return table
function M.get_wrap_pairs()
	return WRAP_PAIRS
end

--- The built-in pairs in catalogue order, as a copy.
--- @return table Array of { left, right }.
function M.get_wrap_pair_list()
	local list = {}
	for index, pair in ipairs(WRAP_PAIR_LIST) do
		list[index] = { left = pair.left, right = pair.right }
	end
	return list
end

--- The left and right symbols a wrap_selection parameter names: a catalogue
--- symbol or a custom left|right pair (_shared/lua/wrap_pair).
--- @param value any The stored parameter.
--- @return string|nil left
--- @return string|nil right Both nil when the value names no pair.
function M.resolve_wrap_pair(value)
	return WrapPair.parse(value, WRAP_PAIR_LIST)
end

--- The vocabulary of the send_text, send_key and send_shortcut parameters,
--- read once from _shared/modules/actions/send_keys.json. A missing or
--- malformed file raises: every send_* binding would otherwise refuse its value
--- with no explanation.
--- @return table The decoded vocabulary.
function M.send_vocabulary()
	if _send_vocabulary then return _send_vocabulary end
	local path = Paths.shared(SEND_KEYS_REL_PATH)
	local handle = path and io.open(path, "r")
	if not handle then error("shortcuts: cannot read " .. tostring(path)) end
	local body = handle:read("*a")
	handle:close()
	local ok, parsed = pcall(require("json").decode, body)
	if not ok or type(parsed) ~= "table" or type(parsed.keys) ~= "table"
		or type(parsed.modifiers) ~= "table" or type(parsed.text_max_code_points) ~= "number" then
		error("shortcuts: " .. tostring(path) .. " is not a send-input vocabulary")
	end
	_send_vocabulary = parsed
	return parsed
end

--- Parses a send_* parameter (_shared/lua/send_input over the vocabulary).
--- @param kind string "text", "key" or "shortcut".
--- @param value any The stored parameter.
--- @return table|nil The parse, or nil when the value is invalid.
function M.parse_send_input(kind, value)
	return SendInput.parse(kind, value, M.send_vocabulary())
end

--- Presses a parsed key or shortcut on the daemon's uinput device.
---
--- A named key is its evdev code. A character in a shortcut is the key the
--- loaded keymap types it with, plus that key's level modifier: on AZERTY,
--- Ctrl+A is Ctrl with the key the kernel calls KEY_Q. A character alone
--- (send_key "é") is typed through the injector instead, which knows every
--- level and falls back to the clipboard.
--- @param kind string "key" or "shortcut".
--- @param parsed table A parse from parse_send_input.
--- @return boolean True when the input was sent.
local function send_keystroke(kind, parsed)
	local vocabulary = M.send_vocabulary()
	local mod_codes, held = {}, {}
	local function hold(code)
		if not held[code] then
			held[code] = true
			mod_codes[#mod_codes + 1] = code
		end
	end
	for _, id in ipairs(parsed.mods or {}) do
		hold(SendInput.entry(vocabulary, "modifiers", id).linux)
	end
	if parsed.named then
		return ComboEmitter.press_codes(mod_codes,
			{ SendInput.entry(vocabulary, "keys", parsed.named).linux }, parsed.canonical)
	end
	if kind == "key" then
		local result = Injector.inject(0, parsed.char, false)
		return type(result) == "table" and result.ok == true
	end
	local ok_layout, Layout = pcall(require, "adapters.keyboard_layout")
	local hit = ok_layout and type(Layout.resolve) == "function" and Layout.resolve(parsed.char) or nil
	if type(hit) ~= "table" then
		Logger.error(LOG, "send_shortcut: the loaded keymap has no key for '%s' — nothing pressed.",
			parsed.char)
		return false
	end
	for _, level_modifier in ipairs(hit.mods or {}) do
		local code = LEVEL_MODIFIER_CODES[level_modifier]
		if not code then
			Logger.error(LOG, "send_shortcut: '%s' needs the modifier '%s', which cannot be pressed.",
				parsed.char, tostring(level_modifier))
			return false
		end
		hold(code)
	end
	return ComboEmitter.press_codes(mod_codes, { hit.keycode }, parsed.canonical)
end

--- Wraps the current selection with left/right symbols.
--- @param left string Opening symbol.
--- @param right string Closing symbol.
function M.wrap_selection(left, right)
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "Selection wrapping refused: no retained text destination."); return false end
	record("wrap_selection")
	if type(left) ~= "string" or type(right) ~= "string" then return false end
	local ok, reason = Clipboard.transform_selection(function(selected)
		return left .. selected .. right
	end, ComboEmitter.press, EventLoop.sleep_ms, publication)
	if ok then return true end
	if reason == "no_selection" then
		local result = Injector.inject(0, left .. right, false, nil, publication)
		return type(result) == "table" and result.ok == true
	end
	if reason == "destination_changed" then
		Logger.warn(LOG, "Selection wrapping stopped: its original text destination was retired.")
		return false
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
-- What ends this CapsWord session on its own (modules/shortcuts/caps_word_auto_off),
-- compiled when it was switched on; nil while CapsWord is off.
local _caps_word_policy = nil
-- Monotonic time of the last keystroke of the session, for the idle delay.
local _caps_word_last_ms = nil
-- Bumped by every session start and stop, so a queued idle check of an earlier
-- session never ends a later one.
local _caps_word_session = 0

--- Returns whether CapsWord is currently active.
--- @return boolean
function M.is_caps_word_active()
	return _caps_word_active
end

-- Both idle checks take the clock resolution off the measured gap: without
-- luv the clock counts whole seconds, and two keys typed together would read a
-- second apart (project-linux-coarse-clock-overstates-a-gap).

--- Presses and releases CapsLock on the daemon's device: the key a CapsWord
--- session locks and unlocks the desktop's Caps Lock with.
--- @return boolean True when the press and the release were written.
--- @return table Typed outcome; only a pre-output refusal permits another tap.
local function press_caps_lock()
	return ComboEmitter.press_codes({}, { EvdevCodes.KEY_CAPSLOCK }, "CapsWord CapsLock")
end

--- Clears the session state, naming why once.
--- @param reason string What ended it, for the log.
local function clear_caps_word(reason)
	_caps_word_active = false
	_caps_word_policy, _caps_word_last_ms = nil, nil
	_caps_word_session = _caps_word_session + 1
	Logger.info(LOG, "CapsWord: OFF (%s).", reason)
end

--- Ends the current CapsWord session and unlocks the CapsLock it locked.
--- @param reason string What ended it, for the log.
local function end_caps_word(reason)
	if not _caps_word_active then return end
	clear_caps_word(reason)
	-- The hook logs an unlock it could not emit; the session is over either way.
	require("adapters.keyboard_hook").release_caps_word_lock()
end

--- Queues the idle check of one session on the daemon loop: it ends the
--- session once the delay has passed since its last keystroke, or queues
--- itself again for the time still left.
--- @param session integer Session the check belongs to.
--- @param delay_ms number Milliseconds until the earliest possible expiry.
local function schedule_idle_check(session, delay_ms)
	local queued = EventLoop.defer(function()
		if session ~= _caps_word_session or not _caps_word_active or not _caps_word_policy then return end
		local now = Monotonic.now_ms()
		if CapsWordPolicy.idle_expired(_caps_word_policy, _caps_word_last_ms, now - Monotonic.resolution_ms()) then
			end_caps_word("no keystroke for the configured delay")
			return
		end
		schedule_idle_check(session,
			CapsWordPolicy.idle_delay_ms(_caps_word_policy) + Monotonic.resolution_ms() - (now - _caps_word_last_ms))
	end, math.max(0, delay_ms))
	if not queued then Logger.error(LOG, "CapsWord idle check could not be queued; the delay will not apply.") end
end

--- Starts a CapsWord session with the settings in force now.
--- @return boolean started
local function start_caps_word()
	-- Read now, not cached from boot: a scope restore or a hand edit applies to
	-- the next CapsWord without any disk access on the input path.
	CapsWordAutoOff.refresh()
	local called, policy = pcall(CapsWordAutoOff.policy)
	if not called or type(policy) ~= "table" then
		Logger.error(LOG, "CapsWord refused: its auto-off settings do not compile: %s.", tostring(policy))
		return false
	end
	-- The capitals come from CapsLock, locked on the desktop as Windows and
	-- macOS light it: the application receives what the layout's CapsLock
	-- level types. The hook ends the hold itself when the user presses
	-- CapsLock, when it stops and before a dialog takes the keyboard.
	local session = _caps_word_session + 1
	local locked, refusal = require("adapters.keyboard_hook").lock_caps_for_word(press_caps_lock, function(reason)
		if session == _caps_word_session and _caps_word_active then clear_caps_word(reason) end
	end)
	if not locked then
		Logger.error(LOG, "CapsWord refused: CapsLock could not be locked: %s.", tostring(refusal))
		return false
	end
	_caps_word_session = session
	_caps_word_active = true
	_caps_word_policy, _caps_word_last_ms = policy, Monotonic.now_ms()
	local delay = CapsWordPolicy.idle_delay_ms(policy)
	if delay then schedule_idle_check(_caps_word_session, delay) end
	Logger.info(LOG, "CapsWord: ON (idle delay %s).", delay and (delay .. " ms") or "never")
	return true
end

--- Toggles CapsWord on/off via the menu.
--- @return boolean True only after runtime state publication.
function M.toggle_caps_word()
	if _configuration_owner ~= nil then return false end
	record("caps_word")
	-- Metric delivery is protected external code and can reserve configuration.
	if _configuration_owner ~= nil then return false end
	if _caps_word_active then
		end_caps_word("switched off")
		return true
	end
	return start_caps_word()
end

--- Stamps a keystroke of the session and ends it when the delay before it was
--- longer than the configured one.
--- @return boolean active Whether CapsWord is still on.
local function observe_caps_word_keystroke()
	if not _caps_word_active or not _caps_word_policy then return false end
	local now = Monotonic.now_ms()
	if CapsWordPolicy.idle_expired(_caps_word_policy, _caps_word_last_ms, now - Monotonic.resolution_ms()) then
		end_caps_word("no keystroke for the configured delay")
		return false
	end
	_caps_word_last_ms = now
	return true
end

--- Ends CapsWord on a typed checked delimiter, before the character is processed.
--- @param ch string Characters of one typed event.
--- @return boolean ended
function M.caps_word_observe_text(ch)
	if not observe_caps_word_keystroke() then return false end
	if CapsWordPolicy.ends_on_text(_caps_word_policy, ch) then
		end_caps_word("delimiter typed")
		return true
	end
	return false
end

--- Ends CapsWord on a control key that is a checked delimiter (a modified Tab
--- or Enter reaches the control callback, not the text one).
--- @param key_name string The hook's control-key name.
--- @return boolean ended
function M.caps_word_observe_control(key_name)
	if not observe_caps_word_keystroke() then return false end
	if CapsWordPolicy.is_terminator_key(key_name) and CapsWordPolicy.ends_on_key(_caps_word_policy, key_name) then
		end_caps_word("delimiter key " .. key_name)
		return true
	end
	return false
end

--- Ends CapsWord on a pointer event of a checked kind.
--- @param kind string|nil Declared pointer kind; nil for an event of no kind.
--- @return boolean ended
function M.caps_word_observe_pointer(kind)
	if not _caps_word_active or not _caps_word_policy or kind == nil then return false end
	if CapsWordPolicy.ends_on_pointer(_caps_word_policy, kind) then
		end_caps_word("pointer " .. kind)
		return true
	end
	return false
end

--- Ends CapsWord on a native pointer event of a checked kind, named here so
--- the daemon's main() captures no pointer-kind table of its own (it sits at
--- LuaJIT's 60-upvalue limit).
--- @param kind_of_event string "press" (a button) or "motion" (an EV_REL report).
--- @param code integer The button's evdev code for a press.
--- @return boolean ended
function M.caps_word_observe_pointer_event(kind_of_event, code)
	if not _caps_word_active then return false end
	local kind
	if kind_of_event == "press" then kind = CapsWordAutoOff.pointer_kind_of_button(code)
	else kind = CapsWordAutoOff.pointer_kind_of_motion() end
	return M.caps_word_observe_pointer(kind)
end

--- Ends a running CapsWord session from outside its own rules (a script
--- pause), unlocking the CapsLock it locked.
--- @param reason string What ended it, for the log.
function M.cancel_caps_word(reason)
	end_caps_word(reason)
end

-- =========================================
-- =========================================
-- ======= 3/ Text Manipulation ============
-- =========================================
-- =========================================

local function transform_selection(action, transform)
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "%s refused: no retained text destination.", action); return false end
	record(action)
	-- Metric delivery can reserve configuration before clipboard ownership begins.
	if _configuration_owner ~= nil then return false end
	local ok, reason = Clipboard.transform_selection(transform, ComboEmitter.press, EventLoop.sleep_ms, publication)
	if not ok then Logger.warn(LOG, "%s failed: %s.", action, tostring(reason)) end
	return ok
end

--- Toggles the current selection between Unicode uppercase and lowercase.
function M.transform_uppercase()
	return transform_selection("to_uppercase", TextCase.toggle_upper)
end

--- Transforms the current selection to lowercase.
function M.transform_lowercase()
	return transform_selection("to_lowercase", TextCase.lower)
end

--- Toggles the current selection between Unicode title case and lowercase.
function M.transform_titlecase()
	return transform_selection("to_titlecase", TextCase.toggle_title)
end

--- Transforms the current selection to uppercase, whatever its current case.
function M.transform_to_uppercase()
	return transform_selection("selection_uppercase", TextCase.upper)
end

--- Transforms the current selection to title case, whatever its current case.
function M.transform_to_titlecase()
	return transform_selection("selection_titlecase", TextCase.title)
end

--- Selects the word under the cursor: Ctrl+Right moves to its end, then
--- Ctrl+Shift+Left selects back to its start, as macOS does with Option. Only
--- the second half used to be sent, which selected from the caret to the start
--- of the word instead of the word.
function M.select_word()
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "Word selection refused: no retained text destination."); return false end
	record("select_word")
	if not ComboEmitter.press("ctrl+Right", publication) then return false end
	return ComboEmitter.press("ctrl+shift+Left", publication)
end

--- Selects the entire current line (Home, Shift+End).
function M.select_line()
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "Line selection refused: no retained text destination."); return false end
	record("select_line")
	if not ComboEmitter.press("Home", publication) then return false end
	return ComboEmitter.press("shift+End", publication)
end

--- Wraps the current line in parentheses: Home, "(", End, ")", Home, the
--- sequence the Windows driver emits for the same action.
--- @return boolean True when every step was emitted.
function M.surround_line_with_parens()
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "Line wrapping refused: no retained text destination."); return false end
	record("surround_parens")
	local function typed(text)
		local result = Injector.inject(0, text, false, nil, publication)
		return type(result) == "table" and result.ok == true
	end
	return ComboEmitter.press("Home", publication) and typed("(")
		and ComboEmitter.press("End", publication) and typed(")")
		and ComboEmitter.press("Home", publication)
end

--- Pastes clipboard content as plain text (strips formatting).
function M.paste_plain()
	if _configuration_owner ~= nil then return false end
	local publication = capture_text_destination()
	if not publication then Logger.warn(LOG, "Plain-text paste refused: no retained text destination."); return false end
	record("paste_plain")
	local ok, text, reason = Clipboard.read_checked()
	if not ok or text == "" then
		Logger.warn(LOG, "Plain-text paste failed: %s.", tostring(reason or "clipboard is empty"))
		return false
	end
	local result = Injector.inject(0, text, false, nil, publication)
	return type(result) == "table" and result.ok == true
end

--- The catalogue actions this module performs, by action id, for the gesture
--- executor. The daemon injects them through modules/shortcuts/action_handlers,
--- so a gesture or a keyboard slot runs the same code as the tray row instead
--- of a second copy in the gesture layer.
--- @return table { [action_id] = function(binding, parameter): boolean }
function M.action_handlers()
	return {
		-- A key, a key combination, a tap-hold or a gesture bound to CapsWord
		-- toggles the session the tray row shows, as Windows' ToggleCapsWord.
		["caps_word"] = function() return M.toggle_caps_word() end,
		["select_line"] = function() return M.select_line() end,
		["select_word"] = function() return M.select_word() end,
		["paste_plain"] = function() return M.paste_plain() end,
		["surround_parens"] = function() return M.surround_line_with_parens() end,
		["uppercase_selection"] = function() return M.transform_uppercase() end,
		["titlecase_selection"] = function() return M.transform_titlecase() end,
		["selection_uppercase"] = function() return M.transform_to_uppercase() end,
		["selection_lowercase"] = function() return M.transform_lowercase() end,
		["selection_titlecase"] = function() return M.transform_to_titlecase() end,
		-- The value is the binding's own parameter, validated by the executor.
		["send_text"] = function(_, parameter)
			record("send_text")
			local parsed = M.parse_send_input("text", parameter)
			if not parsed then return false end
			local result = Injector.inject(0, parsed.text, false)
			return type(result) == "table" and result.ok == true
		end,
		["send_key"] = function(_, parameter)
			record("send_key")
			local parsed = M.parse_send_input("key", parameter)
			return parsed ~= nil and send_keystroke("key", parsed)
		end,
		["send_shortcut"] = function(_, parameter)
			record("send_shortcut")
			local parsed = M.parse_send_input("shortcut", parameter)
			return parsed ~= nil and send_keystroke("shortcut", parsed)
		end,
		-- The pair is the binding's own parameter, validated by the executor.
		-- Nothing selected: nothing is typed, as on macOS and Windows.
		["wrap_selection"] = function(_, parameter)
			local left, right = M.resolve_wrap_pair(parameter)
			if not left then
				Logger.warn(LOG, "wrap_selection ignored: no valid pair ('%s').", tostring(parameter))
				return false
			end
			return transform_selection("wrap_selection", function(selected)
				return left .. selected .. right
			end)
		end,
	}
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
	if _configuration_owner ~= nil then return false end
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Shortcut state must be a boolean — nothing changed.")
		return false
	end
	if _persist then
		if not TomlWriter or not _config_path then
			Logger.error(LOG, "Shortcut state cannot be persisted — nothing changed.")
			return false
		end
		local called, committed, err = pcall(TomlWriter.batch_write, _config_path, {
			{ section = CONFIG_SECTION, key = "enabled", value = enabled },
		})
		if not called or committed ~= true then
			Logger.error(LOG, "Could not persist shortcut state: %s.", tostring(called and err or committed))
			return false
		end
	end

	_enabled = enabled
	collision_generation = collision_generation + 1
	if not enabled then end_caps_word("shortcuts disabled") end
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

-- The wrap-on-type switch (shortcuts.wrap_text_if_selected).
local WRAP_ON_TYPE_KEY = "wrap_text_if_selected"
local DEFAULT_WRAP_ON_TYPE = Manifest.default_for(CONFIG_SECTION .. "." .. WRAP_ON_TYPE_KEY)
if type(DEFAULT_WRAP_ON_TYPE) ~= "boolean" then
	error("The manifest default for shortcuts." .. WRAP_ON_TYPE_KEY .. " must be a boolean.")
end
local _wrap_on_type = DEFAULT_WRAP_ON_TYPE

--- Whether typing a wrap symbol over a selection wraps it.
--- @return boolean
function M.is_wrap_on_type_enabled()
	return _wrap_on_type
end

--- Returns the runtime revision owned by an in-progress selection window.
--- This getter performs no file, clipboard or native input queries.
--- @return integer epoch Committed state and configuration ownership revision.
function M.wrap_selection_epoch()
	return collision_generation
end

--- Persists and applies the wrap-on-type switch.
--- @param enabled boolean
--- @return boolean True when the state was committed.
function M.set_wrap_on_type_enabled(enabled)
	if _configuration_owner ~= nil then return false end
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Wrap-on-type state must be a boolean — nothing changed.")
		return false
	end
	if _persist then
		if not TomlWriter or not _config_path then
			Logger.error(LOG, "Wrap-on-type state cannot be persisted — nothing changed.")
			return false
		end
		local ok, err = TomlWriter.batch_write(_config_path, {
			{ section = CONFIG_SECTION, key = WRAP_ON_TYPE_KEY, value = enabled },
		})
		if not ok then
			Logger.error(LOG, "Could not persist the wrap-on-type state: %s.", tostring(err))
			return false
		end
	end
	_wrap_on_type = enabled
	collision_generation = collision_generation + 1
	Logger.info(LOG, "Wrap selection on typed symbol %s.", enabled and "enabled" or "disabled")
	return true
end

-- =========================================
-- =========================================
-- ======= 5/ Init =========================
-- =========================================
-- =========================================

--- The master state init() reads from a decoded config.toml: any value, even
--- a malformed one, because a malformed one fails closed.
--- @param config table Decoded config.toml.
--- @return any value `[shortcuts].enabled`, nil when absent.
local function configured_enabled(config)
	if type(config[CONFIG_SECTION]) ~= "table" then return nil end
	return config[CONFIG_SECTION].enabled
end

--- Marks every config.toml path init() reads.
--- @param config table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(config, mark)
	if configured_enabled(config) ~= nil then mark(CONFIG_SECTION, "enabled") end
	if type(config[CONFIG_SECTION]) == "table" and config[CONFIG_SECTION][WRAP_ON_TYPE_KEY] ~= nil then
		mark(CONFIG_SECTION, WRAP_ON_TYPE_KEY)
	end
end

--- Initialises the shortcuts module.
--- @param opts table|nil { enabled?, persist?, config_path?, capture_text_owner? }
function M.init(opts)
	if _configuration_owner ~= nil then return false end
	opts = type(opts) == "table" and opts or {}
	if opts.enabled ~= nil and type(opts.enabled) ~= "boolean" then
		error("shortcuts enabled override must be a boolean")
	end
	if opts.capture_text_owner ~= nil and type(opts.capture_text_owner) ~= "function" then
		error("shortcuts text destination capture must be a function")
	end
	_capture_text_owner = opts.capture_text_owner
	-- A clean slate: a session still running unlocks its CapsLock first.
	end_caps_word("shortcuts re-initialised")
	_caps_word_policy, _caps_word_last_ms = nil, nil
	_caps_word_session = _caps_word_session + 1
	_config_path = opts.config_path or require("infra.config_paths").config("config.toml")
	_persist = opts.persist == true

	local enabled = DEFAULT_ENABLED
	local wrap_on_type = DEFAULT_WRAP_ON_TYPE
	collision_initialized = false
	if _persist then
		local content, status
		if type(collision_read) == "function" then content, status = collision_read(_config_path) end
		if status ~= "ok" and status ~= "absent" then
			Logger.error(LOG, "Shortcut configuration read was not acknowledged — failing closed.")
			enabled, wrap_on_type = false, false
		elseif status == "absent" then
			collision_initialized = true
		else
			collision_initialized = true
			local ok, config = pcall(collision_decode, content)
			if not ok or type(config) ~= "table" then
				Logger.error(LOG, "Shortcut configuration is invalid — failing closed.")
				enabled = false
				wrap_on_type = false
			else
				local configured = configured_enabled(config)
				if type(configured) == "boolean" then
					enabled = configured
				elseif configured ~= nil then
					Logger.error(LOG, "Shortcut enabled state is invalid — failing closed.")
					enabled = false
				end
				local section = type(config[CONFIG_SECTION]) == "table" and config[CONFIG_SECTION] or {}
				local wrap = section[WRAP_ON_TYPE_KEY]
				if type(wrap) == "boolean" then
					wrap_on_type = wrap
				elseif wrap ~= nil then
					Logger.error(LOG, "Wrap-on-type state is invalid — failing closed.")
					wrap_on_type = false
				end
			end
		end
	end
	if type(opts.enabled) == "boolean" then enabled = opts.enabled end
	_enabled = enabled
	_wrap_on_type = wrap_on_type
	collision_generation = collision_generation + 1
	Logger.info(LOG, "Shortcuts manager initialised (enabled=%s, wrap_on_type=%s).",
		tostring(_enabled), tostring(_wrap_on_type))
end


--- Acquires the initialized shortcut runtime before a scoped publication.
--- @param owner table Exact transaction token.
--- @return boolean acquired
function M.acquire_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= nil or not _persist or not _config_path then return false end
	_configuration_owner = owner
	collision_generation = collision_generation + 1
	return true
end

--- Releases the same configuration owner after success or compensation.
--- @param owner table Exact transaction token.
--- @return boolean released
function M.release_configuration(owner)
	if type(owner) ~= "table" or _configuration_owner ~= owner then return false end
	_configuration_owner = nil
	return true
end

--- Keeps desired menu state separate from input admission during a transaction.
--- @return boolean admitted
function M.configuration_admitted()
	return _configuration_owner == nil
end

--- Resolves the manager's actual two preferences from a detached source.
--- @param document table Decoded configuration.
--- @return table state
function M.configuration_candidate(document)
	assert(document.shortcuts == nil or type(document.shortcuts) == "table", "shortcut section is malformed")
	local section = document.shortcuts or {}
	local enabled, wrap = section.enabled, section[WRAP_ON_TYPE_KEY]
	if enabled == nil then enabled = Manifest.default_for(ENABLED_PATH) end
	if wrap == nil then wrap = Manifest.default_for(CONFIG_SECTION .. "." .. WRAP_ON_TYPE_KEY) end
	assert(type(enabled) == "boolean" and type(wrap) == "boolean", "shortcut switches must be boolean")
	return { enabled = enabled, wrap = wrap, caps_word_active = false }
end

--- Captures the exact manager state without touching clipboard or input devices.
--- @param owner table Exact transaction token.
--- @return table|nil state
function M.configuration_snapshot(owner)
	if _configuration_owner ~= owner then return nil end
	return { enabled = _enabled, wrap = _wrap_on_type, caps_word_active = _caps_word_active }
end

--- Applies a validated runtime state without invoking independent setters.
--- A state with CapsWord off ends a running session and unlocks its CapsLock.
--- One with CapsWord on never starts a session: a lock is the desktop's state,
--- not a value to restore, so a transaction that stopped CapsWord leaves it off.
--- @param owner table Exact transaction token.
--- @param state table Candidate or saved state.
--- @return boolean acknowledged
function M.apply_configuration(owner, state)
	if _configuration_owner ~= owner or type(state) ~= "table" then return false end
	for _, key in ipairs({ "enabled", "wrap", "caps_word_active" }) do
		if type(state[key]) ~= "boolean" then return false end
	end
	collision_generation = collision_generation + 1
	_enabled, _wrap_on_type = state.enabled, state.wrap
	if not state.caps_word_active then end_caps_word("shortcut configuration applied") end
	return true
end

local collision_candidate, collision_init = M.configuration_candidate, M.init
local collision_get_pair, collision_enabled, collision_wrap_enabled = M.get_wrap_pair, M.is_enabled, M.is_wrap_on_type_enabled
local collision_admitted = M.configuration_admitted

--- Captures configured wrap-symbol eligibility, without observing a selection.
--- These reservations describe a possible earlier consumer, never active output.
--- @return table|nil frame Original source/runtime guards and detached claims.
function M.capture_collision_inventory()
	if not collision_initialized or not _persist or _configuration_owner ~= nil or not wrap_source then return nil end
	local Routes = require("infra.config_paths")
	local route = Routes.config
	local path, epoch, enabled, wrap = _config_path, collision_generation, _enabled, _wrap_on_type
	local source = wrap_source
	local function runtime()
		return rawequal(package.loaded["modules.shortcuts.manager"], M) and getmetatable(M) == nil
			and _configuration_owner == nil and collision_initialized and _persist and _config_path == path
			and collision_generation == epoch and _enabled == enabled and _wrap_on_type == wrap
			and rawequal(wrap_source, source) and wrap_pairs_equal(WRAP_PAIRS, source.pairs)
			and rawequal(package.loaded["infra.config_paths"], Routes) and Routes.config == route
			and rawequal(package.loaded["infra.paths"], Paths) and Paths.shared == collision_shared
			and rawequal(package.loaded["toml_codec.writer"], TomlWriter) and TomlWriter.read_classified == collision_read
			and rawequal(package.loaded["toml_codec"], TomlCodec) and TomlCodec.decode == collision_decode
			and rawequal(package.loaded["json"], collision_json) and collision_json.decode == collision_json_decode
			and M.configuration_candidate == collision_candidate and M.init == collision_init
			and M.get_wrap_pair == collision_get_pair and M.is_enabled == collision_enabled
			and M.is_wrap_on_type_enabled == collision_wrap_enabled and M.configuration_admitted == collision_admitted
			and TextCase.is_single_character == collision_single_character
			and rawequal(package.loaded["unicode_case"], TextCase)
			and M.capture_collision_inventory == collision_factory
	end
	if not runtime() or route("config.toml") ~= path then return nil end
	local bytes, status = collision_read(path)
	if status ~= "ok" and status ~= "absent" then return nil end
	local decoded, document = pcall(collision_decode, bytes or "")
	if not decoded or type(document) ~= "table" then return nil end
	local resolved, expected = pcall(collision_candidate, document)
	if not resolved or type(expected) ~= "table" or expected.enabled ~= enabled or expected.wrap ~= wrap then return nil end
	local function current()
		if not runtime() or route("config.toml") ~= path
			or collision_shared(WRAP_SYMBOLS_REL_PATH) ~= source.path then return false end
		local content, classification = collision_read(path)
		local catalogue, catalogue_status = collision_read(source.path)
		return content == bytes and classification == status and catalogue_status == "ok"
			and catalogue == source.content and route("config.toml") == path
			and collision_shared(WRAP_SYMBOLS_REL_PATH) == source.path and runtime()
	end
	if not current() then return nil end
	local claims = {}
	if enabled and wrap then
		for symbol in pairs(source.pairs) do
			if collision_single_character(symbol) then
				for _, shift in ipairs({ false, true }) do
					claims[#claims + 1] = { kind = "logical", binding = "wrap_on_type__" .. symbol,
						key = symbol:lower(), mods = { shift = shift } }
				end
			end
		end
	end
	if not current() then return nil end
	return { path = path, content = bytes, status = status, claims = claims, current = current, sealed = runtime }
end

collision_factory = M.capture_collision_inventory

return M

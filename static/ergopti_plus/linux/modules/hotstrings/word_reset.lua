--- modules/hotstrings/word_reset.lua

--- ==============================================================================
--- MODULE: Word Reset Settings
--- DESCRIPTION:
--- Owns the config.toml leaves that decide when the hotstring buffer is
--- forgotten and the next key starts a new word: `hotstrings.idle_reset_seconds`
--- (a pause without typing, 0 = never), `hotstrings.click_resets_word` (a
--- pointer click), `hotstrings.arrow_resets_word` (Left, Right, Up, Down),
--- `hotstrings.shortcut_resets_word` (a key struck under Ctrl, Alt or Super)
--- and `hotstrings.tap_hold_resets_word` (a tap-hold key's own command, and a
--- shortcut struck under a tap-hold or navigation-layer hold).
---
--- FEATURES & RATIONALE:
--- 1. Before them the buffer kept the last word for as long as the user stayed
---    away, and a click did not touch it at all: the first key typed after a
---    pause or a click was read as the continuation of text elsewhere, so every
---    word-start hotstring stayed silent until a delimiter.
--- 2. An arrow or a shortcut used to empty the buffer at an UNKNOWN position,
---    so a word-start hotstring could not fire on the next word either. With
---    its option on the event starts a word (known boundary); off, the word and
---    its start are kept exactly as they were.
--- 3. A tap-hold command (copy, paste, a window switch) never reached the
---    hotstring engine at all. Its option owns it, and every shortcut whose
---    Ctrl, Alt or Super came from a tap-hold, so turning it off keeps the word
---    across "c", tap-hold Ctrl+V, "t★" even while shortcuts reset words.
--- 4. The values are cached: the input path reads them on every keystroke and
---    never touches the disk. The pause rule itself is the shared engine's
---    `idle_resets_word`, which the other two drivers apply too.
--- 5. Setters publish a sparse canonical write before changing runtime state,
---    and the Hotstrings scope adopts and restores every leaf with the others.
--- 6. Ctrl+Backspace deletes the previous word: the caret then sits where that
---    word began, so the next key starts a word whatever the settings say.
---    Alt+Backspace (undo in many editors) and Super+Backspace keep their
---    reset to an unknown start.
--- 7. A field left empty: a bare Enter in a terminal submits the line, and
---    Ctrl+A (outside a terminal) or Ctrl+L in a browser selects the whole
---    text. A Backspace that finds the buffer empty there deleted nothing, so
---    the engine keeps the word start (its line-start reset). Windows and
---    macOS apply the same rules.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Paths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Preferences = require("infra.hotstring_preferences")
local ConfigOutdated = require("config_outdated")
local Engine = require("modules.hotstrings.engine")
local Monotonic = require("infra.monotonic")

local LOG = "hotstrings.word_reset"

local IDLE_PATH = "hotstrings.idle_reset_seconds"

-- The boolean leaves of [hotstrings] this module owns, each a runtime field of
-- the same name; the feature path is "hotstrings." .. key.
local SWITCHES = { "click_resets_word", "arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word" }

-- The caret keys arrow_resets_word governs, by the hook's control-key name.
-- Home, End, Page Up/Down and Insert keep their unconditional reset.
local ARROWS = { up = true, down = true, left = true, right = true }

-- Control keys that keep their own handling even under Ctrl, Alt or Super:
-- Backspace and Delete then remove text by an unknown amount, Home, End, Page
-- Up/Down and Insert move the caret by an unknown amount, and Tab is the
-- daemon's focus boundary. None of them is governed by an option.
local UNGOVERNED_CHORDS = { backspace = true, delete = true, home = true, ["end"] = true,
	pageup = true, pagedown = true, insert = true, tab = true }

-- Terminal emulators, by the last dot-separated part of their lowercase
-- application id or WM_CLASS ("org.gnome.Terminal" -> "terminal"). Their line
-- editor submits on Enter and ignores a Backspace at the start of the prompt.
local TERMINAL_APPS = {
	terminal = true, ["gnome-terminal"] = true, ["gnome-terminal-server"] = true,
	console = true, kgx = true, ptyxis = true, konsole = true, yakuake = true,
	kitty = true, alacritty = true, foot = true, footclient = true, wezterm = true,
	["wezterm-gui"] = true, ghostty = true, tilix = true, terminator = true,
	["xfce4-terminal"] = true, ["mate-terminal"] = true, lxterminal = true,
	qterminal = true, xterm = true, uxterm = true, urxvt = true, rxvt = true,
	st = true, ["st-256color"] = true, sakura = true, terminology = true,
	guake = true, tilda = true, blackbox = true, contour = true, tabby = true,
	hyper = true, warp = true, ["deepin-terminal"] = true, ["cool-retro-term"] = true,
}

-- Browsers, whose Ctrl+L selects the whole address of the address bar.
local BROWSER_APPS = {
	firefox = true, ["firefox-esr"] = true, librewolf = true, waterfox = true,
	chromium = true, ["chromium-browser"] = true, ["google-chrome"] = true,
	chrome = true, brave = true, ["brave-browser"] = true, vivaldi = true,
	["vivaldi-stable"] = true, opera = true, ["microsoft-edge"] = true,
	epiphany = true, falkon = true, floorp = true, zen = true,
}

-- Populated once; no preference IO on each keystroke.
local _settings = nil
-- Monotonic time of the last physical keystroke, nil before the first.
local _last_key_ms = nil




-- =========================================
-- =========================================
-- ======= 1/ The settings =================
-- =========================================
-- =========================================

--- Copies the runtime values, so a caller never aliases the cache.
--- @param settings table Validated settings.
--- @return table copy
local function copy_settings(settings)
	local copy = { idle_seconds = settings.idle_seconds }
	for _, key in ipairs(SWITCHES) do copy[key] = settings[key] end
	return copy
end

--- The manifest defaults of every leaf.
--- @return table settings
local function default_settings()
	local defaults = { idle_seconds = Manifest.default_for(IDLE_PATH) }
	for _, key in ipairs(SWITCHES) do defaults[key] = Manifest.default_for("hotstrings." .. key) end
	return defaults
end

--- Resolves exactly the leaves consumed here. A value of another shape is
--- an outdated entry: warned once, read as the manifest default and left
--- unmarked for the cleanup.
--- @param document table Decoded canonical configuration.
--- @param mark function|nil Cleanup ownership visitor.
--- @return table settings `{ idle_seconds, click_resets_word, arrow_resets_word,
---   shortcut_resets_word, tap_hold_resets_word }`.
local function resolve_settings(document, mark)
	local section = ConfigOutdated.settings_table(document.hotstrings, { "hotstrings" }, Logger)
	local idle = section and section.idle_reset_seconds
	if idle ~= nil and not Engine.valid_idle_reset_seconds(idle) then
		ConfigOutdated.report(IDLE_PATH, "the value is not a non-negative number of seconds", Logger)
		idle = nil
	end
	if idle == nil then idle = Manifest.default_for(IDLE_PATH)
	elseif mark then mark("hotstrings", "idle_reset_seconds") end
	assert(Engine.valid_idle_reset_seconds(idle), "the manifest default of idle_reset_seconds must be valid")

	local settings = { idle_seconds = idle }
	for _, key in ipairs(SWITCHES) do
		local path = "hotstrings." .. key
		local value = section and section[key]
		if value ~= nil and type(value) ~= "boolean" then
			ConfigOutdated.report(path, "the value is not a boolean", Logger)
			value = nil
		end
		if value == nil then value = Manifest.default_for(path)
		elseif mark then mark("hotstrings", key) end
		assert(type(value) == "boolean", "the manifest default of " .. key .. " must be a boolean")
		settings[key] = value
	end
	return settings
end

--- Captures one validated source for a conditional sparse write.
--- @return table settings
--- @return table source
local function read_settings()
	local content, status, detail = Writer.read_classified(Paths.config("config.toml"))
	assert(status == "ok" or status == "absent", "word-reset configuration is unreadable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "word-reset configuration is malformed")
	return resolve_settings(decoded), { status = status, content = content }
end

--- Marks the same canonical values used by initialization and setters.
--- @param document table Decoded configuration.
--- @param mark function Exact ownership visitor.
function M.mark_config_reads(document, mark)
	resolve_settings(document, mark)
end

--- Reloads the runtime values only after their canonical source is validated.
--- @return boolean acknowledged
function M.refresh()
	local called, value = pcall(read_settings)
	if not called then
		Logger.error(LOG, "Word-reset configuration refresh refused: %s.", tostring(value))
		return false
	end
	_settings = value
	return true
end

--- Makes a scope's validated candidate effective before its file is published.
--- @param document table Decoded configuration candidate.
--- @return boolean adopted
function M.adopt_configuration(document)
	local called, value = pcall(resolve_settings, document)
	if not called then
		Logger.error(LOG, "Candidate word-reset configuration refused: %s.", tostring(value))
		return false
	end
	_settings = value
	return true
end

--- The runtime values, for a scope to restore after a refused publication.
--- @return table snapshot
function M.snapshot()
	return copy_settings(M.current())
end

--- Restores the exact runtime values a scope captured.
--- @param snapshot table Value returned by snapshot().
--- @return boolean restored
function M.restore_configuration(snapshot)
	if type(snapshot) ~= "table" or not Engine.valid_idle_reset_seconds(snapshot.idle_seconds) then return false end
	for _, key in ipairs(SWITCHES) do
		if type(snapshot[key]) ~= "boolean" then return false end
	end
	_settings = copy_settings(snapshot)
	return true
end

--- The cached values, read once. A configuration that cannot be read leaves
--- every leaf on its manifest default until an explicit refresh succeeds, and
--- the fallback is cached so the input path never retries the disk per keystroke.
--- @return table settings
function M.current()
	if _settings == nil and not M.refresh() then
		Logger.error(LOG, "Word-reset configuration is unreadable; the defaults apply until a refresh succeeds.")
		_settings = default_settings()
	end
	return _settings
end

--- @return number seconds Pause after which a key starts a new word; 0 = never.
function M.idle_seconds()
	return M.current().idle_seconds
end

--- @return boolean Whether a click starts a new word.
function M.click_resets_word()
	return M.current().click_resets_word
end

--- @return boolean Whether Left, Right, Up or Down starts a new word.
function M.arrow_resets_word()
	return M.current().arrow_resets_word
end

--- @return boolean Whether a key struck under Ctrl, Alt or Super starts a new word.
function M.shortcut_resets_word()
	return M.current().shortcut_resets_word
end

--- @return boolean Whether a tap-hold command, or a shortcut under a tap-hold
---   hold, starts a new word.
function M.tap_hold_resets_word()
	return M.current().tap_hold_resets_word
end

--- Publishes one sparse leaf, then the runtime value.
--- @param path string Feature path.
--- @param key string Runtime field.
--- @param value any Validated value.
--- @return boolean committed
local function persist(path, key, value)
	-- The hotstrings scope owns these leaves while it holds the preferences.
	if Preferences.is_acquired() then
		Logger.error(LOG, "Word-reset change refused: a hotstring configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_settings()
		return Writer.batch_write(Paths.config("config.toml"),
			{ Manifest.sparse_operation(path, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Word-reset change was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	local updated = M.snapshot()
	updated[key] = value
	_settings = updated
	Logger.info(LOG, "%s set to %s.", path, tostring(value))
	return true
end

--- Sets one boolean leaf.
--- @param key string One of SWITCHES.
--- @param enabled boolean
--- @return boolean committed
local function set_switch(key, enabled)
	if type(enabled) ~= "boolean" then
		Logger.warn(LOG, "Invalid value '%s' for hotstrings.%s refused.", tostring(enabled), key)
		return false
	end
	return persist("hotstrings." .. key, key, enabled)
end

--- Sets the pause after which a key starts a new word.
--- @param seconds number Non-negative seconds; 0 disables the reset.
--- @return boolean committed
function M.set_idle_seconds(seconds)
	if not Engine.valid_idle_reset_seconds(seconds) then
		Logger.warn(LOG, "Invalid idle delay '%s' refused.", tostring(seconds))
		return false
	end
	return persist(IDLE_PATH, "idle_seconds", seconds)
end

--- Sets whether a click starts a new word.
--- @param enabled boolean
--- @return boolean committed
function M.set_click_resets_word(enabled)
	return set_switch("click_resets_word", enabled)
end

--- Flips the click setting.
--- @return boolean committed
function M.toggle_click_resets_word()
	return M.set_click_resets_word(not M.click_resets_word())
end

--- Sets whether an arrow starts a new word.
--- @param enabled boolean
--- @return boolean committed
function M.set_arrow_resets_word(enabled)
	return set_switch("arrow_resets_word", enabled)
end

--- Flips the arrow setting.
--- @return boolean committed
function M.toggle_arrow_resets_word()
	return M.set_arrow_resets_word(not M.arrow_resets_word())
end

--- Sets whether a shortcut starts a new word.
--- @param enabled boolean
--- @return boolean committed
function M.set_shortcut_resets_word(enabled)
	return set_switch("shortcut_resets_word", enabled)
end

--- Flips the shortcut setting.
--- @return boolean committed
function M.toggle_shortcut_resets_word()
	return M.set_shortcut_resets_word(not M.shortcut_resets_word())
end

--- Sets whether a tap-hold command or a shortcut under a tap-hold hold starts
--- a new word.
--- @param enabled boolean
--- @return boolean committed
function M.set_tap_hold_resets_word(enabled)
	return set_switch("tap_hold_resets_word", enabled)
end

--- Flips the tap-hold setting.
--- @return boolean committed
function M.toggle_tap_hold_resets_word()
	return M.set_tap_hold_resets_word(not M.tap_hold_resets_word())
end

--- Parses a free entry typed in the menu prompt: a decimal point or comma,
--- surrounding blanks ignored.
--- @param text string|nil Raw prompt answer.
--- @return number|nil seconds Valid value, or nil when the text is not one.
function M.parse_seconds(text)
	if type(text) ~= "string" then return nil end
	local trimmed = text:match("^%s*(.-)%s*$"):gsub(",", ".", 1)
	if not trimmed:match("^%d+%.?%d*$") and not trimmed:match("^%.%d+$") then return nil end
	local value = tonumber(trimmed)
	if not Engine.valid_idle_reset_seconds(value) then return nil end
	return value
end




-- =========================================
-- =========================================
-- ======= 2/ The input path ===============
-- =========================================
-- =========================================

--- Stamps one physical keystroke and tells whether the pause before it starts
--- a new word. Called for every key the hotstring path observes, so a pause is
--- measured from the last key of any kind.
--- @param now_ms number Monotonic time of this keystroke.
--- @return boolean idle Whether the caller must reset its buffer at a word start.
function M.observe_key(now_ms)
	local previous = _last_key_ms
	_last_key_ms = now_ms
	return Engine.idle_resets_word(previous, now_ms, M.idle_seconds(), Monotonic.resolution_ms())
end

--- Forgets the last keystroke time (tests and a restarted input session).
function M.forget_last_key()
	_last_key_ms = nil
end

--- The last dot-separated part of an application id, lowercase.
--- @param app_id string|nil Focused application id or WM_CLASS.
--- @return string|nil
local function app_key(app_id)
	if type(app_id) ~= "string" or app_id == "" then return nil end
	return app_id:lower():match("([^%.]+)$")
end

--- Whether the focused application is a terminal emulator.
--- @param app_id string|nil Focused application id or WM_CLASS.
--- @return boolean
function M.is_terminal_app(app_id)
	return TERMINAL_APPS[app_key(app_id)] == true
end

--- Whether a Backspace event is the delete-previous-word chord: Ctrl held,
--- Shift allowed, no Alt, AltGr or Super.
--- @param detail table|nil `{ mods }` as the hook reports it.
--- @return boolean
function M.deletes_previous_word(detail)
	local mods = type(detail) == "table" and type(detail.mods) == "table" and detail.mods or {}
	return mods.ctrl == true and mods.alt ~= true and mods.altgr ~= true and mods.meta ~= true
end

--- Whether a shortcut selects the whole text of the focused field: Ctrl+A
--- outside a terminal, Ctrl+L in a browser (its address bar).
--- @param detail table|nil `{ key, mods }` as the hook reports it.
--- @param app_id string|nil Focused application id.
--- @return boolean
local function selects_whole_field(detail, app_id)
	if type(detail) ~= "table" or type(detail.key) ~= "string" or not M.deletes_previous_word(detail) then
		return false
	end
	local key = detail.key:lower()
	if key == "a" then return not M.is_terminal_app(app_id) end
	return key == "l" and BROWSER_APPS[app_key(app_id)] == true
end

--- Applies a typed character that may leave an empty line: a bare Enter in a
--- terminal submits the line and the prompt after it is empty, so the engine
--- restarts at a word start and at the start of that line.
--- @param engine table Hotstring engine (`reset(at_word_start, at_line_start)`).
--- @param ch string The character just typed.
--- @param app_id string|nil Focused application id.
--- @return boolean applied
function M.apply_typed_newline(engine, ch, app_id)
	if ch ~= "\n" or not M.is_terminal_app(app_id) then return false end
	engine:reset(true, true)
	return true
end

--- Names the option that governs a control-key event, if any.
---
--- An arrow is an arrow whatever is held with it and wherever it came from (a
--- navigation-layer arrow included). A shortcut is any other key struck under
--- Ctrl, Alt or Super, Shift added or not: the hook's "shortcut" event, or a
--- control key such as Enter, Escape or F5 reported with those modifiers. AltGr
--- and Shift alone are typing and never reach here as a shortcut. The hook flags
--- `tap_hold` when the chord's Ctrl, Alt or Super, or the key itself, came from
--- the tap-hold engine: that option then owns it, not the shortcut one.
--- @param key_name string The hook's control-key name, or "shortcut".
--- @param detail table|nil `{ mods, tap_hold }` as the hook reports it.
--- @return string|nil owner "arrow", "shortcut", "tap_hold", or nil when no
---   option governs the event and its own handling stands.
function M.control_owner(key_name, detail)
	if ARROWS[key_name] then return "arrow" end
	local mods = type(detail) == "table" and type(detail.mods) == "table" and detail.mods or {}
	local chord = key_name == "shortcut"
		or (not UNGOVERNED_CHORDS[key_name] and (mods.ctrl == true or mods.alt == true or mods.meta == true))
	if not chord then return nil end
	if type(detail) == "table" and detail.tap_hold == true then return "tap_hold" end
	return "shortcut"
end

--- Applies a control key that does not edit the buffer by one character (a
--- bare Backspace is the caller's) to the hotstring engine.
---
--- A governed event resets at a word start when its option is on and leaves
--- the buffer and its start exactly as they were when it is off. Every other
--- control key keeps its unconditional reset: Escape leaves the caret where it
--- was (word start), the others move it by an unknown amount.
--- Ctrl+Backspace is no option's: it always starts a word. A shortcut that
--- selects the whole field also tells the engine the line is empty.
--- @param engine table Hotstring engine (`reset(at_word_start, at_line_start)`).
--- @param key_name string The hook's control-key name, or "shortcut".
--- @param detail table|nil As for control_owner().
--- @param app_id string|nil Focused application id.
--- @return string effect "word_start", "unknown" or "kept".
function M.apply_control(engine, key_name, detail, app_id)
	if key_name == "backspace" and M.deletes_previous_word(detail) then
		engine:reset(true)
		return "word_start"
	end
	local owner = M.control_owner(key_name, detail)
	if owner ~= nil and not M.current()[owner .. "_resets_word"] then return "kept" end
	local at_word_start = owner ~= nil or key_name == "escape"
	engine:reset(at_word_start, owner ~= nil and key_name == "shortcut" and selects_whole_field(detail, app_id))
	return at_word_start and "word_start" or "unknown"
end

--- Applies a tap-hold key's own command (copy, paste, a window switch: any
--- catalogue action the engine could not express as a typed key) to the
--- hotstring engine. Its keys go straight to the virtual keyboard and never
--- reach the hook, so this is the only place the engine hears of it.
--- @param engine table Hotstring engine (`reset(at_word_start)`).
--- @param binding string|nil The binding the tap-hold manager ran the action
---   for: "tap_hold__<key>", or "tap_hold" for one without its key identity.
--- @return string effect "word_start", "kept", or "not_tap_hold" for an action
---   another owner ran (a key combination).
function M.apply_tap_action(engine, binding)
	if binding ~= "tap_hold" and not (type(binding) == "string" and binding:match("^tap_hold__")) then
		return "not_tap_hold"
	end
	if not M.tap_hold_resets_word() then return "kept" end
	engine:reset(true)
	return "word_start"
end

return M

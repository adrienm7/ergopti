--- _shared/layouts/engine/emulation/game_keys.lua

--- ==============================================================================
--- MODULE: Game Keys (Shared)
--- DESCRIPTION:
--- « Touches de jeu » (maintainer decision of 2026-11-26): which key identity a
--- game reads while Ergopti types, the character staying Ergopti's. A key
--- event carries an identity (the scan code, evdev code or macOS key code that
--- controls and bind menus read) and a character (what a chat field reads):
--- "physical" keeps the physical key's identity, "letters" gives the key the
--- identity of the system layout's key that types the Ergopti character.
--- macOS and Linux run this module; Windows runs its twin in
--- modules/keymap/keylayout/game_keys.ahk, and both replay
--- _shared/tests/corpus/layouts/game_keys_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. One source for the settings: layout.game_keys (the global choice,
---    "physical" by default) and layout.game_keys_apps (application identity
---    to choice). An application listed there is a game: its held keys skip
---    the tap-hold delays (M.is_game).
--- 2. One route table: per OS, Ergopti mode (emulated, installed system
---    layout, or neither) and choice, which strategy a driver applies, and the
---    locale key of the reason when the choice cannot be honoured there, with
---    the route the driver takes instead (M.route).
--- 3. One rule for the held key: an emulated character goes out as a real key
---    held for as long as the physical key is held only when the system layout
---    types it with exactly the modifiers the hand holds; any other character
---    keeps the text route, still typed, simply not bindable (M.held_admissible).
--- ==============================================================================

local ManifestData = require("settings.engine.features.manifest_data")
local ConfigKeys = require("settings.engine.keys")
local ConfigOutdated = require("settings.engine.migration.outdated")
local TextUtils = require("core.text.engine.utils_core")
local Logger = require("core.logger.engine.shim")
local Names = require("layouts.engine.emulation.game_keys_data")

local M = {}

local LOG = "layouts.game_keys"

--- One name of the generated table; a missing one is a stale generation.
--- @param group string The table's group.
--- @param name string The name.
--- @return string
local function name_of(group, name)
	local value = Names[group] and Names[group][name]
	if type(value) ~= "string" then error("game_keys_data has no " .. group .. "." .. name .. ": run npm run codegen:game-keys") end
	return value
end

M.PHYSICAL = name_of("choices", "PHYSICAL")
M.LETTERS = name_of("choices", "LETTERS")

-- The three Ergopti modes a route is asked for.
M.MODE_EMULATION = name_of("modes", "EMULATION")
M.MODE_INSTALLED = name_of("modes", "INSTALLED")
M.MODE_SYSTEM = name_of("modes", "SYSTEM")

-- The strategies a driver applies (_shared/layouts/data/game_keys.json says what each does).
M.NATIVE = name_of("strategies", "NATIVE")
M.HELD_BASE_KEY = name_of("strategies", "HELD_BASE_KEY")
M.SPLIT_EVENT = name_of("strategies", "SPLIT_EVENT")
M.SWITCH_TO_INSTALLED = name_of("strategies", "SWITCH_TO_INSTALLED")
M.REWRITE_KEYCODE = name_of("strategies", "REWRITE_KEYCODE")

local KEY = ConfigKeys.KEY

-- The choices, in the manifest's order: the enum is the one source.
local CHOICES = nil
for _, entry in ipairs(ManifestData.features) do
	if entry.path == KEY.LAYOUT_GAME_KEYS then CHOICES = entry.enum_values end
end
if type(CHOICES) ~= "table" or #CHOICES == 0 then error("The manifest declares no layout.game_keys choices.") end
M.CHOICES = CHOICES

local PLATFORMS = { windows = true, macos = true, linux = true }

-- The reason keys (platform_reason.*), each shown on the row it greys.
M.REASON = {
	physical_needs_installed_layout = name_of("reasons", "physical_needs_installed_layout"),
	letters_needs_base_layout = name_of("reasons", "letters_needs_base_layout"),
	vk_games_follow_letters = name_of("reasons", "vk_games_follow_letters"),
	hid_games_are_physical = name_of("reasons", "hid_games_are_physical"),
}

--- Whether a value is one of the choices.
--- @param value any
--- @return boolean
function M.valid_choice(value)
	for _, choice in ipairs(CHOICES) do
		if value == choice then return true end
	end
	return false
end

--- Whether a value is a map of application identities to choices.
--- @param value any
--- @return boolean valid
--- @return string|nil detail Why it is refused.
function M.valid_apps(value)
	if type(value) ~= "table" then return false, "the value is not a table" end
	for app, choice in pairs(value) do
		if type(app) ~= "string" or app == "" then return false, "the table holds something other than an application" end
		if not M.valid_choice(choice) then return false, "the table holds something other than physical or letters" end
	end
	return true
end

--- The key an application identity is stored under on its OS: the Windows
--- executable and the Linux WM class or app_id ignore case, as the other
--- per-application lists compare them; a macOS bundle identifier is exact.
--- @param platform string "windows", "macos" or "linux".
--- @param app any The identity the driver read.
--- @return string|nil key nil for no identity.
function M.app_key(platform, app)
	if not PLATFORMS[platform] then error("Unknown platform for the game keys: " .. tostring(platform)) end
	if type(app) ~= "string" then return nil end
	local trimmed = TextUtils.trim(app)
	if trimmed == "" then return nil end
	if platform == "macos" then return trimmed end
	return trimmed:lower()
end

--- Resolves the game-key settings of one parsed configuration, without effects.
--- @param config table Parsed config.toml.
--- @param default_for function (path) -> the manifest default.
--- @param report function|nil (segments, detail) Called for an outdated leaf.
--- @return table settings { choice, apps = key -> choice }
function M.resolve(config, default_for, report)
	if type(config) ~= "table" then error("The game keys need a parsed configuration.") end
	if type(default_for) ~= "function" then error("The game keys need the manifest defaults.") end
	local layout = type(config.layout) == "table" and config.layout or {}
	local choice = ConfigOutdated.canonical_enum_value({ type = "enum", enum_values = CHOICES }, layout[ConfigKeys.LEAF.GAME_KEYS])
	if choice ~= nil and not M.valid_choice(choice) then
		if report then report({ "layout", ConfigKeys.LEAF.GAME_KEYS }, "the value is not physical or letters") end
		choice = nil
	end
	if choice == nil then choice = default_for(KEY.LAYOUT_GAME_KEYS) end
	if not M.valid_choice(choice) then error("The manifest default of layout.game_keys is invalid.") end
	local apps = layout[ConfigKeys.LEAF.GAME_KEYS_APPS]
	if apps ~= nil then
		local valid, detail = M.valid_apps(apps)
		if not valid then
			if report then report({ "layout", ConfigKeys.LEAF.GAME_KEYS_APPS }, detail) end
			apps = nil
		end
	end
	local copy = {}
	for app, value in pairs(apps or default_for(KEY.LAYOUT_GAME_KEYS_APPS)) do copy[app] = value end
	return { choice = choice, apps = copy }
end

--- The stored entry of an application, whatever case it was written in on an
--- OS whose identities ignore case.
local function stored_entry(settings, platform, key)
	if settings.apps[key] ~= nil then return key, settings.apps[key] end
	if platform == "macos" then return nil, nil end
	for app, choice in pairs(settings.apps) do
		if app:lower() == key then return app, choice end
	end
	return nil, nil
end

--- The choice in force for an application.
--- @param settings table M.resolve's result.
--- @param platform string
--- @param app string|nil The application's identity.
--- @return string choice
--- @return boolean overridden True when the application has its own choice.
function M.choice_for(settings, platform, app)
	local key = M.app_key(platform, app)
	if key ~= nil then
		local _, choice = stored_entry(settings, platform, key)
		if choice ~= nil then return choice, true end
	end
	return settings.choice, false
end

--- Whether an application is a game: it has its own choice.
--- @param settings table M.resolve's result.
--- @param platform string
--- @param app string|nil
--- @return boolean
function M.is_game(settings, platform, app)
	return select(2, M.choice_for(settings, platform, app)) == true
end

--- The application table after an application's choice changes.
--- @param settings table M.resolve's result.
--- @param platform string
--- @param app string The application's identity.
--- @param choice string|nil Its own choice; nil to follow the global choice again.
--- @return table apps A new table.
function M.apps_with(settings, platform, app, choice)
	local key = M.app_key(platform, app)
	if key == nil then error("An application identity is required to set its game keys.") end
	if choice ~= nil and not M.valid_choice(choice) then error("Not a game-key choice: " .. tostring(choice)) end
	local stored = stored_entry(settings, platform, key)
	local apps = {}
	for name, value in pairs(settings.apps) do
		if name ~= stored then apps[name] = value end
	end
	if choice ~= nil then apps[key] = choice end
	return apps
end

--- The leaves a menu choice writes: the global choice when app is nil, else
--- the application table with that application's own choice (nil choice: it
--- follows the global one again).
--- @param settings table M.resolve's result.
--- @param platform string
--- @param app string|nil
--- @param choice string|nil
--- @return table|nil values path -> value; nil for a refused choice (logged).
function M.write_values(settings, platform, app, choice)
	if app == nil then
		if M.valid_choice(choice) then return { [KEY.LAYOUT_GAME_KEYS] = choice } end
		Logger.error(LOG, "Refused game-key choice %s.", tostring(choice))
		return nil
	end
	local ok, apps = pcall(M.apps_with, settings, platform, app, choice)
	if ok then return { [KEY.LAYOUT_GAME_KEYS_APPS] = apps } end
	Logger.error(LOG, "Refused game-key choice %s for %s: %s.", tostring(choice), tostring(app), tostring(apps))
	return nil
end

--- How a driver honours a choice.
--- @param platform string "windows", "macos" or "linux".
--- @param mode string M.MODE_EMULATION, M.MODE_INSTALLED or M.MODE_SYSTEM.
--- @param choice string M.PHYSICAL or M.LETTERS.
--- @param caps table { installed_layout = boolean (an installed and listed system
---   layout types what the emulation types: the Ergopti one under an Ergopti
---   emulation), game = boolean (the application has its own choice: only a game
---   switches the system layout) }
--- @return table route { available, identity, strategy, reason_key, note_key }:
---   available false means the choice cannot be honoured, reason_key says why and
---   identity and strategy are what the driver does instead; note_key names a
---   limit of the choice that greys nothing (some games read the other identity).
function M.route(platform, mode, choice, caps)
	if not PLATFORMS[platform] then error("Unknown platform for the game keys: " .. tostring(platform)) end
	if not M.valid_choice(choice) then error("Not a game-key choice: " .. tostring(choice)) end
	caps = type(caps) == "table" and caps or {}
	local function route(available, identity, strategy, reason_key, note_key)
		return { available = available, identity = identity, strategy = strategy,
			reason_key = reason_key, note_key = note_key }
	end
	if mode == M.MODE_SYSTEM then return route(true, M.PHYSICAL, M.NATIVE, nil, nil) end
	if mode ~= M.MODE_EMULATION and mode ~= M.MODE_INSTALLED then error("Unknown Ergopti mode: " .. tostring(mode)) end
	if platform == "macos" then
		-- macOS carries the key code and the string apart: both choices exist in
		-- both modes; a game reading the hardware (GameController) sees neither.
		if choice == M.LETTERS then
			return route(true, M.LETTERS, M.REWRITE_KEYCODE, nil, M.REASON.hid_games_are_physical)
		end
		return route(true, M.PHYSICAL, M.NATIVE, nil, nil)
	end
	if mode == M.MODE_INSTALLED then
		if choice == M.PHYSICAL then
			return route(true, M.PHYSICAL, M.NATIVE, nil,
				platform == "windows" and M.REASON.vk_games_follow_letters or nil)
		end
		-- One key code carries both the identity and the character: the letters
		-- need the emulation over a QWERTY or AZERTY layout.
		return route(false, M.PHYSICAL, M.NATIVE, M.REASON.letters_needs_base_layout, nil)
	end
	if choice == M.LETTERS then return route(true, M.LETTERS, M.HELD_BASE_KEY, nil, nil) end
	-- A game switches its window to the installed layout, which types the same
	-- text with the keys at their place and nothing injected.
	if caps.installed_layout == true and caps.game == true then
		return route(true, M.PHYSICAL, M.SWITCH_TO_INSTALLED, nil,
			platform == "windows" and M.REASON.vk_games_follow_letters or nil)
	end
	if platform == "windows" then
		-- Unproven until the Windows field check (TODO.md): one injected event
		-- whose scan code is the physical key and whose VK types the letter.
		return route(true, M.PHYSICAL, M.SPLIT_EVENT, nil, M.REASON.vk_games_follow_letters)
	end
	-- Linux: the compositor derives the character from the one key code, so
	-- outside a game switched to the installed layout the keys follow the letters.
	if caps.installed_layout == true then return route(true, M.LETTERS, M.HELD_BASE_KEY, nil, nil) end
	return route(false, M.LETTERS, M.HELD_BASE_KEY, M.REASON.physical_needs_installed_layout, nil)
end

--- Whether an emulated text goes out as a held key: one character the system
--- layout types with exactly the level modifiers the hand holds, Caps Lock off
--- and no modifier a tap-hold holds on the hand's behalf.
--- @param text string The emulated text of the press.
--- @param step table|nil The system layout's keystroke for it: { mods = { "shift"?, "altgr"? } },
---   nil when the layout cannot type it.
--- @param held table { shift, altgr, caps_lock, virtual } as booleans: what the hand holds,
---   whether Caps Lock is on, and whether a tap-hold holds a modifier for it.
--- @return boolean held
function M.held_admissible(text, step, held)
	if type(text) ~= "string" or text == "" or type(step) ~= "table" or type(step.mods) ~= "table" then return false end
	-- One UTF-8 character, never a dead key's leftover plus a character.
	if not text:match("^[%z\1-\127\194-\244][\128-\191]*$") then return false end
	held = type(held) == "table" and held or {}
	if held.caps_lock == true or held.virtual == true then return false end
	local wants = { shift = false, altgr = false }
	for _, mod in ipairs(step.mods) do
		if wants[mod] == nil then return false end
		wants[mod] = true
	end
	return wants.shift == (held.shift == true) and wants.altgr == (held.altgr == true)
end

return M

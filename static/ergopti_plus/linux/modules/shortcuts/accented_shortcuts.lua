--- modules/shortcuts/accented_shortcuts.lua

--- ==============================================================================
--- MODULE: Accented-Letter Shortcuts (Linux)
--- DESCRIPTION:
--- Ctrl, Alt or Super (Shift may ride along) on a key that types an accented
--- letter directly (è, ê, é, à) acts as the same chord on the letter the user
--- chose: Ctrl+é becomes Ctrl+C on AZERTY, BÉPO or an installed Ergopti
--- layout, whose accented keys would otherwise reach the application as a
--- chord nothing binds. Windows defines the contract
--- (windows/modules/keymap/layout/accented_shortcuts.ahk); this follows it.
---
--- FEATURES & RATIONALE:
--- 1. Layout-driven: the key's plain press is read from the loaded keymap
---    (keyboard_layout.base_symbol), so switching to QWERTY gives Ctrl+2 back.
---    A letter behind Shift or AltGr there gets no shortcut, as on Windows.
--- 2. AltGr is left alone: it is the level-3 key of the keymap, and AltGr+é
---    keeps typing what the layout puts there.
--- 3. Digits first: while the number row types its digits first, a digit-row
---    key is a digit and Ctrl on it stays Ctrl+digit, as on Windows.
--- 4. Read at the press: config.toml is read only when Ctrl, Alt or Super is
---    held on one of the four letters, so a restore or clear of the Shortcuts
---    scope applies at the next press with no live state to keep in step.
--- 5. Decided in the keyboard hook's consumption callback, the one place the
---    daemon can keep a key from the application; the chord is pressed on the
---    next loop tick with the modifiers the hand held.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Manifest = require("infra.manifest_reader")
local EvdevCodes = require("platform.input.evdev_codes")
local Writer = require("core.text.engine.toml_codec.writer")
local Codec = require("core.text.engine.toml_codec")
local ConfigOutdated = require("settings.engine.migration.outdated")

local LOG = "modules.shortcuts.accented_shortcuts"

--- The feature ids in menu order, and the letter each one is.
M.IDS = { "e_grave", "e_circ", "e_acute", "a_grave" }
M.LETTERS = { e_grave = "è", e_circ = "ê", e_acute = "é", a_grave = "à" }

local ID_OF_LETTER = {}
for id, letter in pairs(M.LETTERS) do ID_OF_LETTER[letter] = id end

-- The chord's modifiers in the order the combo names them.
local MODIFIERS = { { held = "ctrl", name = "ctrl" }, { held = "shift", name = "shift" },
	{ held = "alt", name = "alt" }, { held = "meta", name = "super" } }





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- The configuration path of one leaf.
--- @param id string Feature id.
--- @param leaf string "enabled" or "letter".
--- @return string
local function path_of(id, leaf) return "shortcuts." .. id .. "." .. leaf end

--- Whether a value is a target letter: one ASCII letter, lower case.
--- @param value any
--- @return boolean
function M.valid_letter(value)
	return type(value) == "string" and value:match("^[a-z]$") ~= nil
end

--- Resolves every letter's setting from a decoded configuration; a value of
--- another shape is read as the manifest default.
--- @param document table Decoded config.toml.
--- @param mark function|nil Segment-based cleanup ownership visitor.
--- @return table settings id -> { enabled = boolean, letter = string }
function M.resolve(document, mark)
	local shortcuts = type(document) == "table" and type(document.shortcuts) == "table" and document.shortcuts or {}
	local settings = {}
	for _, id in ipairs(M.IDS) do
		local section = type(shortcuts[id]) == "table" and shortcuts[id] or {}
		local enabled, letter = section.enabled, section.letter
		if type(enabled) == "boolean" then
			if mark then mark("shortcuts", id, "enabled") end
		else
			if enabled ~= nil then ConfigOutdated.report({ "shortcuts", id, "enabled" }, "the value is not a boolean", Logger) end
			enabled = Manifest.default_for(path_of(id, "enabled"))
		end
		if M.valid_letter(letter) then
			if mark then mark("shortcuts", id, "letter") end
		else
			if letter ~= nil then ConfigOutdated.report({ "shortcuts", id, "letter" }, "the value is not a letter from a to z", Logger) end
			letter = Manifest.default_for(path_of(id, "letter"))
		end
		assert(type(enabled) == "boolean" and M.valid_letter(letter), "the manifest defaults of shortcuts." .. id .. " must be valid")
		settings[id] = { enabled = enabled, letter = letter }
	end
	return settings
end

--- Marks the leaves this module reads, for the unused-keys cleanup.
--- @param document table Decoded configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(document, mark)
	M.resolve(document, mark)
end

--- Reads config.toml and resolves the settings.
--- @return table|nil settings Nil when the file cannot be read or decoded.
--- @return table|nil source { status, content } for a conditional write.
local function read_settings()
	local path = require("settings.engine.paths").config("config.toml")
	local content, status = Writer.read_classified(path)
	if status ~= "ok" and status ~= "absent" then return nil end
	local decoded = Codec.decode(content or "")
	if type(decoded) ~= "table" then return nil end
	return M.resolve(decoded), { status = status, content = content }
end

--- The current settings, read from config.toml.
--- @return table|nil settings
function M.settings()
	return (read_settings())
end

--- Persists one letter's setting: `letter` nil turns the shortcut off and
--- keeps the letter, as the Windows menu's « Désactivé » row does.
--- @param id string Feature id.
--- @param letter string|nil Target letter, or nil to turn it off.
--- @return boolean committed
function M.set(id, letter)
	if not M.LETTERS[id] then error("accented_shortcuts.set: unknown id " .. tostring(id), 2) end
	if letter ~= nil and not M.valid_letter(letter) then
		Logger.warn(LOG, "Invalid letter '%s' for %s refused.", tostring(letter), id)
		return false
	end
	if require("settings.engine.scope.registry").pending() then
		Logger.error(LOG, "Accented shortcut change refused: a configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_settings()
		assert(source, "config.toml is unreadable or malformed")
		local operations = { Manifest.sparse_operation(path_of(id, "enabled"), letter ~= nil) }
		if letter ~= nil then operations[2] = Manifest.sparse_operation(path_of(id, "letter"), letter) end
		return Writer.batch_write(require("settings.engine.paths").config("config.toml"), operations, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Accented shortcut %s was not persisted: %s.", id, tostring(called and detail or committed))
		return false
	end
	Logger.info(LOG, "Accented shortcut %s set to %s.", id, letter or "off")
	return true
end





-- ===========================================
-- ===========================================
-- ======= 2/ The consumption decision =======
-- ===========================================
-- ===========================================

--- The combo a press becomes, or nil when it is not an accented shortcut.
--- @param detail table { code, value, mods } as the keyboard hook reports it.
--- @param ports table { base_symbol = fn(code), number_row_mode = fn(), settings = fn() }.
--- @return string|nil combo e.g. "ctrl+shift+c".
--- @return string|nil id The feature id.
function M.combo_for(detail, ports)
	if type(detail) ~= "table" or type(detail.code) ~= "number" then return nil end
	if detail.value ~= nil and detail.value ~= 1 then return nil end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	if mods.altgr or not (mods.ctrl or mods.alt or mods.meta) then return nil end
	local base = ports.base_symbol(detail.code)
	if type(base) ~= "table" or base.dead or type(base.text) ~= "string" then return nil end
	local id = ID_OF_LETTER[base.text]
	if not id then return nil end
	if EvdevCodes.DIGIT_ROW_SLOT[detail.code] and ports.number_row_mode() == "digits" then return nil end
	local settings = ports.settings()
	if type(settings) ~= "table" then
		Logger.error(LOG, "The accented shortcuts cannot be read: the key goes to the application.")
		return nil
	end
	local entry = settings[id]
	if not entry or entry.enabled ~= true then return nil end
	local parts = {}
	for _, modifier in ipairs(MODIFIERS) do
		if mods[modifier.held] then parts[#parts + 1] = modifier.name end
	end
	parts[#parts + 1] = entry.letter
	return table.concat(parts, "+"), id
end

--- Decides one key press from the keyboard hook's consumption callback.
--- @param detail table { code, value, mods }.
--- @param options table { active = fn() -> boolean, emulating = fn() -> boolean,
---   defer = fn(fn) -> boolean, press = fn(combo) -> boolean, base_symbol?,
---   number_row_mode?, settings? }.
--- @return boolean consumed True when the press became the letter's chord.
--- @return function|nil repeat_callback Owner of the held press's auto-repeats.
function M.on_key(detail, options)
	if type(options) ~= "table" or type(options.emulating) ~= "function" then
		error("accented shortcuts need to know whether the layout emulation runs", 2)
	end
	if type(options.active) ~= "function" or not options.active() then return false end
	-- As Windows, which registers these chords only without the Ergopti
	-- emulation: an emulated layout decides a chord on its own keys (SCL-002).
	if options.emulating() == true then return false end
	local ports = {
		base_symbol = options.base_symbol or require("adapters.keyboard_layout").base_symbol,
		number_row_mode = options.number_row_mode or require("platform.input.keyboard_hook").number_row_mode,
		settings = options.settings or M.settings,
	}
	local press = options.press

	--- Queues the chord one key event decides; false lets that event through.
	local function queue(event)
		local combo, id = M.combo_for(event, ports)
		if not combo then return false end
		local queued = options.defer(function()
			if not options.active() then return end
			if press(combo) ~= true then Logger.error(LOG, "Accented shortcut %s could not press %s.", id, combo) end
		end)
		if queued ~= true then
			Logger.error(LOG, "Accented shortcut %s could not be queued: the key goes to the application.", id)
			return false
		end
		Logger.debug(LOG, "Accented shortcut %s → %s.", id, combo)
		return true
	end

	if not queue(detail) then return false end
	-- Each auto-repeat presses the chord again, as AHK's ^SCxxx hotkeys fire on
	-- every repeat (holding Ctrl+è undoes repeatedly), with the modifiers held
	-- at that repeat (SCL-001).
	return true, function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.code ~= detail.code or not options.active() then
			return false
		end
		return queue({ code = repeat_detail.code, value = 1, mods = repeat_detail.mods })
	end
end

return M

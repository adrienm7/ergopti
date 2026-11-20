--- modules/shortcuts/ctrl_magic_save.lua

--- ==============================================================================
--- MODULE: Modifiers + Magic Key Saves (Linux)
--- DESCRIPTION:
--- With [layout] ctrl_magic_save on, a shortcut chord on the layout's own magic
--- key sends the same modifiers with S: Ctrl+★ gives Ctrl+S, Ctrl+Shift+★
--- Ctrl+Shift+S, Alt+★ Alt+S, Super+★ Super+S. ★ alone stays the magic key.
--- The rule is the three drivers' shared one
--- (_shared/shortcuts/engine/magic_key_save_core.lua); this applies it to the
--- keyboard hook's presses.
---
--- FEATURES & RATIONALE:
--- 1. The layout's own magic key: the key whose plain press types the magic key,
---    read from the running emulation when a layout is emulated, else from the
---    session's XKB keymap. A physical magic key the user chose
---    (hotstrings.magic_key_source) keeps every chord the layout gives it, as on
---    Windows, where only its plain press becomes the magic key.
--- 2. Shift alone and AltGr, whatever else is held, keep the layout's level:
---    AltGr+★ types the layout's AltGr character, never AltGr+S.
--- 3. Only while the magic key is replaced (the magickey replace section) and
---    the driver is not paused, the condition under which Windows registers it.
--- 4. A keyboard shortcut assigned to the chord keeps it: the daemon decides the
---    keyboard slots, the magic editor's Super+★ included, before this module,
---    and its shortcut_owns port reports what they left.
--- 5. Read at the press: config.toml is read only when a shortcut chord is held
---    on that key, so a restore or clear of the configuration applies at the
---    next press.
--- 6. Decided in the keyboard hook's consumption callback, the one place the
---    daemon can keep a key from the application; the chord is pressed on the
---    next loop tick, where the live layout types « s ».
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Manifest = require("menu.engine.manifest_reader")
local Writer = require("core.text.engine.toml_codec.writer")
local Codec = require("core.text.engine.toml_codec")
local ConfigOutdated = require("settings.engine.migration.outdated")
local ConfigKeys = require("settings.engine.keys")
local Policy = require("shortcuts.engine.magic_key_save_core")

local LOG = "modules.shortcuts.ctrl_magic_save"

-- The configuration path of the switch.
M.PATH = ConfigKeys.KEY.LAYOUT_CTRL_MAGIC_SAVE

-- The modifiers the keyboard hook reports, and their combo_emitter spelling.
local HELD = { "ctrl", "alt", "shift", "meta", "altgr" }
local COMBO_NAME = { ctrl = "ctrl", alt = "alt", shift = "shift", meta = "super" }





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- Resolves the switch from a decoded configuration; a value of another shape
--- is reported and read as the manifest default.
--- @param document table Decoded config.toml.
--- @param mark function|nil Segment-based cleanup ownership visitor.
--- @return boolean enabled
function M.resolve(document, mark)
	local layout = type(document) == "table" and type(document.layout) == "table" and document.layout or {}
	local value = layout[ConfigKeys.LEAF.CTRL_MAGIC_SAVE]
	if type(value) == "boolean" then
		if mark then mark("layout", ConfigKeys.LEAF.CTRL_MAGIC_SAVE) end
		return value
	end
	if value ~= nil then
		ConfigOutdated.report({ "layout", ConfigKeys.LEAF.CTRL_MAGIC_SAVE }, "the value is not a boolean", Logger)
	end
	local default = Manifest.default_for(M.PATH)
	assert(type(default) == "boolean", "the manifest default of " .. M.PATH .. " must be a boolean")
	return default
end

--- Marks the leaf this module reads, for the unused-keys cleanup.
--- @param document table Decoded configuration.
--- @param mark function Segment-based ownership collector.
function M.mark_config_reads(document, mark)
	M.resolve(document, mark)
end

--- Reads config.toml.
--- @return table|nil document Nil when the file cannot be read or decoded.
--- @return table|nil source { status, content } for a conditional write.
local function read_document()
	local content, status = Writer.read_classified(require("settings.engine.paths").config("config.toml"))
	if status ~= "ok" and status ~= "absent" then return nil end
	local decoded = Codec.decode(content or "")
	if type(decoded) ~= "table" then return nil end
	return decoded, { status = status, content = content }
end

--- Whether the switch is on, read from config.toml.
--- @return boolean|nil enabled Nil when the file cannot be read.
function M.enabled()
	local document = read_document()
	if document == nil then return nil end
	return M.resolve(document)
end

--- Persists the switch, sparse against the manifest default.
--- @param value boolean
--- @return boolean committed
function M.set(value)
	if type(value) ~= "boolean" then error("ctrl_magic_save.set needs a boolean", 2) end
	if require("settings.engine.scope.registry").pending() then
		Logger.error(LOG, "Modifiers + magic key change refused: a configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_document()
		assert(source, "config.toml is unreadable or malformed")
		return Writer.batch_write(require("settings.engine.paths").config("config.toml"),
			{ Manifest.sparse_operation(M.PATH, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Modifiers + magic key was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	Logger.info(LOG, "Modifiers + magic key set to %s.", value and "save" or "the layout's chords")
	return true
end





-- ===========================================
-- ===========================================
-- ======= 2/ The consumption decision =======
-- ===========================================
-- ===========================================

--- The combo_emitter chord of a press's modifiers with S.
--- @param sends table Modifier names, as the shared rule orders them.
--- @return string combo "ctrl+shift+s".
local function combo_of(sends)
	local parts = {}
	for _, name in ipairs(sends) do parts[#parts + 1] = COMBO_NAME[name] end
	parts[#parts + 1] = Policy.SAVE_KEY
	return table.concat(parts, "+")
end

--- The held modifiers of a key press, nil when the rule leaves the press to the
--- layout whatever key it is (a release, a plain press, Shift, AltGr). Reads
--- nothing but the event.
--- @param detail table { code, value, mods } as the keyboard hook reports it.
--- @return table|nil held Modifier names.
local function shortcut_chord(detail)
	if type(detail) ~= "table" or type(detail.code) ~= "number" then return nil end
	if detail.value ~= nil and detail.value ~= 1 then return nil end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	local held = {}
	for _, name in ipairs(HELD) do
		if mods[name] == true then held[#held + 1] = name end
	end
	if Policy.decide("linux", held) == nil then return nil end
	return held
end

--- The chord a press sends instead of its own, with the hook active and the
--- switch on. The press itself is decided first: a press the rule leaves to the
--- layout, and any chord of another key, return before the driver state or
--- config.toml is read (CI run 44733461420: a Ctrl+U that read the driver state
--- raised there and never reached the consumers behind this one).
--- @param detail table { code, value, mods } as the keyboard hook reports it.
--- @param ports table { magic_key = fn() -> string, chosen_source = fn() -> boolean,
---   plain_text = fn(evdev) -> string|nil, active = fn() -> boolean,
---   enabled = fn() -> boolean|nil, shortcut_owns = fn(detail) -> boolean }.
--- @return string|nil combo "ctrl+shift+s", nil when the press stays the layout's.
function M.match(detail, ports)
	local held = shortcut_chord(detail)
	if held == nil then return nil end
	local magic = ports.magic_key()
	if type(magic) ~= "string" or magic == "" or ports.plain_text(detail.code) ~= magic then return nil end
	if ports.chosen_source() == true then return nil end
	-- active() reads the pause and the replace section.
	if not ports.active() then return nil end
	local decision = Policy.resolve({ os = "linux", held = held, paused = false, replace_on = true,
		chosen_source = false, is_magic_key = true, shortcut_owns = false })
	if decision.action ~= "save" then return nil end
	if ports.shortcut_owns(detail) == true then return nil end
	local enabled = ports.enabled()
	if enabled == nil then
		Logger.error(LOG, "The modifiers + magic key switch cannot be read: the chord goes to the application.")
		return nil
	end
	return enabled and combo_of(decision.sends) or nil
end

--- Decides one key press from the keyboard hook's consumption callback.
--- @param detail table { code, value, mods }.
--- @param options table { active = fn() -> boolean, defer = fn(fn) -> boolean,
---   press = fn(combo) -> boolean, magic_key, chosen_source, plain_text,
---   shortcut_owns, enabled? }.
--- @return boolean consumed True when the press became its modifiers + S.
--- @return function|nil repeat_callback Owner of the held press's auto-repeats.
function M.on_key(detail, options)
	if type(options) ~= "table" or type(options.active) ~= "function" or type(options.defer) ~= "function"
		or type(options.press) ~= "function" or type(options.magic_key) ~= "function"
		or type(options.chosen_source) ~= "function" or type(options.plain_text) ~= "function"
		or type(options.shortcut_owns) ~= "function" then
		error("ctrl_magic_save.on_key needs active, defer, press, magic_key, chosen_source, plain_text"
			.. " and shortcut_owns", 2)
	end
	local ports = { magic_key = options.magic_key, chosen_source = options.chosen_source,
		plain_text = options.plain_text, active = options.active, shortcut_owns = options.shortcut_owns,
		enabled = options.enabled or M.enabled }

	--- Queues the chord for one key event; false lets that event through.
	local function queue(event)
		local combo = M.match(event, ports)
		if combo == nil then return false end
		local queued = options.defer(function()
			if not options.active() then return end
			if options.press(combo) ~= true then Logger.error(LOG, "Modifiers + magic key could not press %s.", combo) end
		end)
		if queued ~= true then
			Logger.error(LOG, "Modifiers + magic key could not be queued: the chord goes to the application.")
			return false
		end
		Logger.debug(LOG, "Modifiers + magic key → %s.", combo)
		return true
	end

	if not queue(detail) then return false end
	-- Each auto-repeat saves again, as the Windows hotkeys fire on every repeat,
	-- with the modifiers held at that repeat.
	return true, function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.code ~= detail.code or not options.active() then
			return false
		end
		return queue({ code = repeat_detail.code, value = 1, mods = repeat_detail.mods })
	end
end

return M

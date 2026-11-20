--- modules/keymap/ctrl_magic_save.lua

--- ==============================================================================
--- MODULE: Ctrl + Magic Key Saves (Linux)
--- DESCRIPTION:
--- With [layout] ctrl_magic_save on, Ctrl alone on the layout's own magic key
--- sends a bare Ctrl+S instead of a Ctrl+★ chord no application binds. Windows
--- defines the contract (windows/modules/keymap/keylayout/layout_registry.ahk,
--- LayoutRegistry_MagicKeyHotkeys); this follows it.
---
--- FEATURES & RATIONALE:
--- 1. The layout's own magic key: the key whose plain press types the magic key,
---    read from the running emulation when a layout is emulated, else from the
---    session's XKB keymap. A physical magic key the user chose
---    (hotstrings.magic_key_source) keeps every chord the layout gives it, as on
---    Windows, where only its plain press becomes the magic key.
--- 2. Ctrl alone, as the Windows ^SCxxx hotkey: Shift, Alt, AltGr or Super held
---    with it leave the chord to the application.
--- 3. Only while the magic key is replaced (the magickey replace section) and
---    the driver is not paused, the condition under which Windows registers it.
--- 4. Read at the press: config.toml is read only when Ctrl is held on that key,
---    so a restore or clear of the configuration applies at the next press.
--- 5. Decided in the keyboard hook's consumption callback, the one place the
---    daemon can keep a key from the application; Ctrl+S is pressed on the next
---    loop tick, where the live layout types « s ».
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Manifest = require("menu.engine.manifest_reader")
local Writer = require("core.text.engine.toml_codec.writer")
local Codec = require("core.text.engine.toml_codec")
local ConfigOutdated = require("settings.engine.migration.outdated")
local ConfigKeys = require("settings.engine.keys")

local LOG = "modules.keymap.ctrl_magic_save"

-- The configuration path of the switch, and the chord it sends.
M.PATH = ConfigKeys.KEY.LAYOUT_CTRL_MAGIC_SAVE
M.COMBO = "ctrl+s"

-- The modifiers that make the press another chord than Ctrl alone.
local OTHER_MODIFIERS = { "shift", "alt", "altgr", "meta" }





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
		Logger.error(LOG, "Ctrl + magic key change refused: a configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_document()
		assert(source, "config.toml is unreadable or malformed")
		return Writer.batch_write(require("settings.engine.paths").config("config.toml"),
			{ Manifest.sparse_operation(M.PATH, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Ctrl + magic key was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	Logger.info(LOG, "Ctrl + magic key set to %s.", value and "save" or "the layout's chord")
	return true
end





-- ===========================================
-- ===========================================
-- ======= 2/ The consumption decision =======
-- ===========================================
-- ===========================================

--- Whether a press is Ctrl alone on the layout's own magic key with the switch on.
--- @param detail table { code, value, mods } as the keyboard hook reports it.
--- @param ports table { magic_key = fn() -> string, chosen_source = fn() -> boolean,
---   plain_text = fn(evdev) -> string|nil, enabled = fn() -> boolean|nil }.
--- @return boolean
function M.matches(detail, ports)
	if type(detail) ~= "table" or type(detail.code) ~= "number" then return false end
	if detail.value ~= nil and detail.value ~= 1 then return false end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	if mods.ctrl ~= true then return false end
	for _, name in ipairs(OTHER_MODIFIERS) do
		if mods[name] then return false end
	end
	if ports.chosen_source() == true then return false end
	local magic = ports.magic_key()
	if type(magic) ~= "string" or magic == "" or ports.plain_text(detail.code) ~= magic then return false end
	local enabled = ports.enabled()
	if enabled == nil then
		Logger.error(LOG, "The Ctrl + magic key switch cannot be read: the chord goes to the application.")
		return false
	end
	return enabled
end

--- Decides one key press from the keyboard hook's consumption callback.
--- @param detail table { code, value, mods }.
--- @param options table { active = fn() -> boolean, defer = fn(fn) -> boolean,
---   press = fn(combo) -> boolean, magic_key, chosen_source, plain_text, enabled? }.
--- @return boolean consumed True when the press became Ctrl+S.
--- @return function|nil repeat_callback Owner of the held press's auto-repeats.
function M.on_key(detail, options)
	if type(options) ~= "table" or type(options.active) ~= "function" or type(options.defer) ~= "function"
		or type(options.press) ~= "function" or type(options.magic_key) ~= "function"
		or type(options.chosen_source) ~= "function" or type(options.plain_text) ~= "function" then
		error("ctrl_magic_save.on_key needs active, defer, press, magic_key, chosen_source and plain_text", 2)
	end
	if not options.active() then return false end
	local ports = { magic_key = options.magic_key, chosen_source = options.chosen_source,
		plain_text = options.plain_text, enabled = options.enabled or M.enabled }

	--- Queues Ctrl+S for one key event; false lets that event through.
	local function queue(event)
		if not M.matches(event, ports) then return false end
		local queued = options.defer(function()
			if not options.active() then return end
			if options.press(M.COMBO) ~= true then Logger.error(LOG, "Ctrl + magic key could not press %s.", M.COMBO) end
		end)
		if queued ~= true then
			Logger.error(LOG, "Ctrl + magic key could not be queued: the chord goes to the application.")
			return false
		end
		Logger.debug(LOG, "Ctrl + magic key → %s.", M.COMBO)
		return true
	end

	if not queue(detail) then return false end
	-- Each auto-repeat saves again, as the Windows ^SCxxx hotkey fires on every
	-- repeat, with the modifiers held at that repeat.
	return true, function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.code ~= detail.code or not options.active() then
			return false
		end
		return queue({ code = repeat_detail.code, value = 1, mods = repeat_detail.mods })
	end
end

return M

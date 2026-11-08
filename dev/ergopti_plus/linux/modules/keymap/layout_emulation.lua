--- modules/keymap/layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (Linux)
--- DESCRIPTION:
--- Types the layout chosen in [layout] (emulated_layout, or the built-in
--- Ergopti variant) over whatever XKB layout the session has, as the Windows
--- driver does: the user keeps AZERTY, QWERTY or any other system layout, and
--- each grabbed key press is replaced by what the emulated .keylayout types
--- there. The decisions are the shared engine's
--- (_shared/lua/layouts/keylayout_emulation.lua), so the three drivers type the
--- same text for the same physical keys.
---
--- FEATURES & RATIONALE:
--- 1. Decided in the keyboard hook's consumption callback, after the physical
---    magic key: the grabbed press never reaches the application, its text is
---    typed in its place and then handed to the character path, so the buffer,
---    the metrics and the hotstrings see exactly what the application shows,
---    as for the magic key (modules/hotstrings/magic_key_source.lua).
--- 2. Key presses first: a text the session's XKB layout types with keys goes
---    out as key presses; a character it cannot type goes through the
---    injector's clipboard route, the one the expansions use for such
---    characters, and says so in the log.
--- 3. A shortcut chord keeps the modifiers the user holds and presses, instead
---    of the physical key, the key the session layout types the emulated
---    layout's Command-level character with (Ctrl+Z where Ergopti has z).
--- 4. Off the key path: the settings, the .keylayout parse and the number-row
---    analysis run at start and on every [layout] change (M.reload). A layout
---    that cannot be read or compiled turns the emulation off with an ERROR,
---    never a partial layout.
--- 5. Every collaborator is injected (M.init), so tests drive the decisions
---    without a keyboard.
--- ==============================================================================

local Emulation = require("layouts.keylayout_emulation")
local Settings = require("layouts.emulation_settings")
local Logger = require("logger.shim")

local M = {}

local LOG = "keymap.layout_emulation"

-- Collaborators (M.init), the running session and the last reload's outcome.
local _deps = nil
local _session = nil
local _evdev_to_code = nil
local _status = { active = false, id = nil, error = nil }

local REQUIRED_DEPS = { "read_config", "default_for", "source", "keycodes", "registry", "type_text",
	"dispatch_char", "emit_shortcut", "caps_locked", "magic_evdev", "is_active" }





-- ================================
-- ================================
-- ======= 1/ Lifecycle ===========
-- ================================
-- ================================

--- Takes the collaborators. Called once, before the hook starts.
--- @param deps table { read_config, default_for, report_outdated?, source, keycodes, registry,
---   type_text, dispatch_char, emit_shortcut, caps_locked, magic_evdev, is_active }
function M.init(deps)
	if _deps ~= nil then error("layout_emulation: already initialized", 2) end
	if type(deps) ~= "table" then error("layout_emulation.init needs its collaborators", 2) end
	for _, name in ipairs(REQUIRED_DEPS) do
		if type(deps[name]) ~= "function" then error("layout_emulation.init needs " .. name, 2) end
	end
	local registry = deps.registry()
	if type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("layout_emulation.init needs the physical-key registry", 2)
	end
	local map = {}
	for code, key in pairs(registry.keys) do
		if type(key) == "table" and type(key.evdev) == "number" and key.kind == "key" then map[key.evdev] = code end
	end
	_deps, _evdev_to_code = deps, map
	Logger.info(LOG, "Layout emulation initialized.")
end

--- Reads the [layout] settings and (re)loads the emulated layout. Called at start
--- and after every change of a setting it reads.
--- @return boolean ok False when the chosen layout cannot be emulated (logged).
function M.reload()
	if _deps == nil then error("layout_emulation.reload needs M.init first", 2) end
	local settings = Settings.resolve(_deps.read_config(), _deps.default_for, _deps.report_outdated)
	if not Settings.active(settings) then
		_session = nil
		_status = { active = false, id = settings.id, error = nil }
		Logger.info(LOG, "Layout emulation off: the system layout types every key.")
		return true
	end
	local source, source_err = _deps.source(settings.id)
	if source == nil then
		_session = nil
		_status = { active = false, id = settings.id, error = tostring(source_err) }
		Logger.error(LOG, "Layout '%s' cannot be emulated: %s — the system layout types every key.",
			settings.id, tostring(source_err))
		return false
	end
	local ok, built = pcall(function()
		local model = Emulation.load(source.text, _deps.keycodes(), source.convention, { composer = source.composer })
		local session = Emulation.new_session(model, Emulation.row_map(_deps.registry()))
		Emulation.configure(session, { base = settings.base, alt_gr = settings.alt_gr, layout = settings.layout,
			number_row = settings.number_row, edges = settings.edges })
		return session
	end)
	if not ok then
		_session = nil
		_status = { active = false, id = settings.id, error = tostring(built) }
		Logger.error(LOG, "Layout '%s' cannot be emulated: %s — the system layout types every key.",
			settings.id, tostring(built))
		return false
	end
	_session = built
	_status = { active = true, id = settings.id, error = nil }
	Logger.info(LOG, "Layout emulation of '%s' on (base %s, AltGr %s).", settings.id,
		tostring(settings.base), tostring(settings.alt_gr))
	return true
end

--- Reloads after a settings change made outside the emulation (a menu row, a
--- scope restore): a no-op answering nil while the owner is not started (a
--- dry run, a menu test).
--- @return boolean|nil ok M.reload's answer, nil when not started.
function M.reload_if_started()
	if _deps == nil then return nil end
	return M.reload()
end

--- What the emulation does now, for the menu.
--- @return table status { active, id, error }
function M.status()
	return { active = _status.active, id = _status.id, error = _status.error }
end

--- Drops the running layout (stop, pause: a pending dead key does not survive).
function M.reset()
	if _session ~= nil then Emulation.reset(_session) end
end

--- Forgets the collaborators and the session (test seam).
function M._reset_for_test()
	_deps, _session, _evdev_to_code = nil, nil, nil
	_status = { active = false, id = nil, error = nil }
end





-- ================================
-- ================================
-- ======= 2/ Key path ============
-- ================================
-- ================================

--- Types an emulated text in place of the consumed press and hands each
--- character to the character path.
--- @return boolean typed
local function type_in_place(text, code)
	if text == "" then return true end
	if _deps.type_text(text) ~= true then
		Logger.error(LOG, "The emulated text could not be typed — the key types its own character.")
		return false
	end
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do _deps.dispatch_char(char, code) end
	return true
end

--- Decides one grabbed key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods, char } as the hook reports a key-down.
--- @return boolean consumed True when the emulation typed in the key's place.
--- @return function|nil repeat_callback Owner of the held press's repeats.
function M.on_key(detail)
	local session = _session
	if session == nil or type(detail) ~= "table" then return false end
	local code = _evdev_to_code[detail.code]
	if code == nil or _deps.is_active() ~= true then return false end
	local mods = type(detail.mods) == "table" and detail.mods or {}
	local magic = _deps.magic_evdev()
	session.config.magic_code = magic and _evdev_to_code[magic] or nil
	local decision, text = Emulation.decide(session, code, mods.shift == true, _deps.caps_locked() == true,
		mods.altgr == true, mods.ctrl == true, mods.alt == true, mods.meta == true, detail.char)
	if decision == Emulation.PASS then return false end
	if decision == Emulation.SHORTCUT then
		if _deps.emit_shortcut(text, detail.code) == true then return true end
		Logger.error(LOG, "The emulated shortcut key could not be pressed — the chord keeps its own key.")
		return false
	end
	if not type_in_place(text, detail.code) then
		Emulation.reset(session)
		return false
	end
	if decision == Emulation.TYPE_PASS then return false end
	local held = detail.code
	return true, function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.code ~= held or _session ~= session then return false end
		return M.on_key(repeat_detail) == true
	end
end





-- ================================
-- ================================
-- ======= 3/ Production wiring ===
-- ================================
-- ================================

--- Reads and decodes one shared JSON file once.
local _json_cache = {}
local function shared_json(rel, lossless)
	if _json_cache[rel] == nil then
		local Json = require("json")
		local text = require("adapters.file_system").read(require("infra.paths").shared(rel))
		if type(text) ~= "string" then error("layout_emulation: " .. rel .. " is unreadable") end
		local decoded = lossless and Json.decode_lossless(text) or Json.decode(text)
		if type(decoded) ~= "table" then error("layout_emulation: " .. rel .. " is not valid JSON") end
		_json_cache[rel] = decoded
	end
	return _json_cache[rel]
end

--- Initializes the module with the daemon's collaborators and loads the layout.
--- @param ports table { injector, is_paused, dispatch_char, magic_evdev, dry_run }
--- @return boolean ok M.reload's answer.
function M.start(ports)
	local Registry = require("modules.keymap.layout_registry")
	local Injector = ports.injector
	M.init({
		read_config = function()
			local bytes, status, detail = require("toml_codec.writer").read_classified(
				require("infra.config_paths").config("config.toml"))
			if status ~= "ok" and status ~= "absent" then error("config.toml is unreadable: " .. tostring(detail)) end
			return require("toml_codec").decode(bytes or "")
		end,
		default_for = require("infra.manifest_reader").default_for,
		report_outdated = function(segments, detail) require("config_outdated").report(segments, detail, Logger) end,
		source = function(id)
			local composer = Registry.composer_settings()
			return Settings.source(id, { installed = Registry.snapshot().installed,
				read_installed = function(layout_id) return Registry.read_local_copy(layout_id) end,
				shipped = function(layout_id) return Registry.shipped_layout(layout_id) end,
				composer_id = composer and composer.id or nil })
		end,
		keycodes = function() return shared_json("modules/layouts/mac_keycodes.json", false) end,
		registry = function() return shared_json("data/keycodes/physical_keys.json", true) end,
		type_text = function(text)
			if ports.dry_run then return false end
			local direct = Injector.type_directly(text)
			if type(direct) == "table" and direct.ok == true then return true end
			if type(direct) ~= "table" or direct.error ~= "untypable" then return false end
			-- The session layout has no key for it: the expansions' clipboard route.
			Logger.debug(LOG, "An emulated character has no key in the session layout: typed through the clipboard.")
			local pasted = Injector.inject(0, text, false, nil, nil, nil, true)
			return type(pasted) == "table" and pasted.ok == true
		end,
		dispatch_char = ports.dispatch_char,
		emit_shortcut = function(char, code)
			if ports.dry_run then return false end
			local keycode, level_mods = require("adapters.keyboard_layout").shortcut_keycode(char, code)
			for _, mod in ipairs(level_mods) do if not Injector.emit_key(mod, 1) then return false end end
			local pressed = Injector.emit_key(keycode, 1)
			local released = pressed and Injector.emit_key(keycode, 0)
			for index = #level_mods, 1, -1 do Injector.emit_key(level_mods[index], 0) end
			return pressed == true and released == true
		end,
		caps_locked = function() return require("adapters.xkb_capture").caps_locked() == true end,
		magic_evdev = ports.magic_evdev,
		is_active = function() return not ports.is_paused() end,
	})
	return M.reload()
end

return M

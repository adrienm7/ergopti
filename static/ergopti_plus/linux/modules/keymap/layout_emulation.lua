--- modules/keymap/layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (Linux)
--- DESCRIPTION:
--- Types the layout chosen in [layout] (emulated_layout, or the built-in
--- Ergopti variant) over whatever XKB layout the session has, as the Windows
--- driver does: the user keeps AZERTY, QWERTY or any other system layout, and
--- each grabbed key press is replaced by what the emulated .keylayout types
--- there. The decisions are the shared engine's
--- (_shared/layouts/engine/composer/keylayout_emulation.lua), so the three drivers type the
--- same text for the same physical keys.
---
--- FEATURES & RATIONALE:
--- 1. Decided in the keyboard hook's consumption callback, after the physical
---    magic key: the grabbed press never reaches the application, its text is
---    typed in its place and then handed to the character path, so the buffer,
---    the metrics and the hotstrings see exactly what the application shows,
---    as for the magic key (hotstrings/engine/magic_key_source.lua).
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
--- 6. A layout source's records no .keylayout holds (custom modifiers, tap-holds,
---    shortcuts sending another key, key chords, system-key remaps) come first,
---    from the composed layout's emulation table (layouts/engine/composer/source_emulation.lua).
---    Its held keys own their release through the hook's release callback; a
---    press of a key the engine still holds means that release was lost, so it
---    is settled before the new press. A built-in modifier a tap-hold holds
---    applies to the keys pressed under it (typed shifted, or pressed with it),
---    not to a mouse click.
--- ==============================================================================

local Emulation = require("layouts.engine.composer.keylayout_emulation")
local SourceEmulation = require("layouts.engine.composer.source_emulation")
local Settings = require("layouts.engine.emulation.settings")
local Logger = require("core.logger.engine.shim")
local EvdevCodes = require("platform.input.evdev_codes")

local M = {}

local LOG = "keymap.layout_emulation"

-- Collaborators (M.init), the running session and the last reload's outcome.
local _deps = nil
local _session = nil
local _extras = nil   -- the layout source emulation session, nil without a table
local _virtual = {}   -- built-in modifiers a tap-hold holds for the user (engine ids)
local _evdev_to_code = nil
local _status = { active = false, id = nil, error = nil }

-- The key each built-in modifier of the source emulation presses.
local EMIT_MODIFIERS = {
	shift = EvdevCodes.KEY_LEFTSHIFT, control = EvdevCodes.KEY_LEFTCTRL, alt = EvdevCodes.KEY_LEFTALT,
	alt_right = EvdevCodes.KEY_RIGHTALT, meta = EvdevCodes.KEY_LEFTMETA,
}

-- The modifiers a shortcut chord keeps from the hand, as the hook names them.
local CHORD_MODIFIERS = {
	{ name = "ctrl", code = EvdevCodes.KEY_LEFTCTRL }, { name = "shift", code = EvdevCodes.KEY_LEFTSHIFT },
	{ name = "alt", code = EvdevCodes.KEY_LEFTALT }, { name = "meta", code = EvdevCodes.KEY_LEFTMETA },
}

-- The engine's built-in modifier ids as the hook names them in detail.mods.
local HOOK_MODIFIERS = { shift = "shift", control = "ctrl", alt = "alt", alt_right = "altgr", meta = "meta" }

local REQUIRED_DEPS = { "read_config", "default_for", "source", "keycodes", "registry", "type_text",
	"dispatch_char", "emit_shortcut", "emit_key", "now_ms", "caps_locked", "magic_evdev", "is_active" }





-- ================================
-- ================================
-- ======= 1/ Lifecycle ===========
-- ================================
-- ================================

--- Takes the collaborators. Called once, before the hook starts.
--- @param deps table { read_config, default_for, report_outdated?, source, keycodes, registry,
---   type_text, dispatch_char, emit_shortcut(char, code, mods), emit_key(code, modifiers) where
---   code is a KeyboardEvent.code and modifiers engine ids, now_ms, caps_locked, magic_evdev, is_active }
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
	if _extras ~= nil then M.reset() end
	_extras = nil
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
	local extras = nil
	local ok, built = pcall(function()
		local model = Emulation.load(source.text, _deps.keycodes(), source.convention, { composer = source.composer })
		local session = Emulation.new_session(model, Emulation.row_map(_deps.registry(), require("core.text.engine.json").is_null))
		Emulation.configure(session, { base = settings.base, alt_gr = settings.alt_gr, layout = settings.layout,
			number_row = settings.number_row, edges = settings.edges })
		if source.emulation ~= nil then extras = SourceEmulation.new_session(SourceEmulation.compile(source.emulation)) end
		return session
	end)
	if not ok then
		_session = nil
		_status = { active = false, id = settings.id, error = tostring(built) }
		Logger.error(LOG, "Layout '%s' cannot be emulated: %s — the system layout types every key.",
			settings.id, tostring(built))
		return false
	end
	_session, _extras = built, extras
	_status = { active = true, id = settings.id, error = nil }
	Logger.info(LOG, "Layout emulation of '%s' on (base %s, AltGr %s, source records %s).", settings.id,
		tostring(settings.base), tostring(settings.alt_gr), tostring(extras ~= nil))
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

--- What the running emulation types unshifted on a key, for the layer
--- editor's legends (layouts/engine/composer/keylayout_emulation.lua M.legend).
--- @param code string The key's KeyboardEvent.code.
--- @return string|nil text nil when the emulation is off or leaves the key to
---   the system layout.
function M.legend(code)
	if not _status.active or _session == nil then return nil end
	local text = Emulation.legend(_session, code)
	return text ~= "" and text or nil
end

--- What the emulation does now, for the menu.
--- @return table status { active, id, error }
function M.status()
	return { active = _status.active, id = _status.id, error = _status.error }
end

--- Drops the running layout (stop, pause: a pending dead key does not survive,
--- nor a held or locked custom modifier or a tap-hold's held modifier).
function M.reset()
	if _session ~= nil then Emulation.reset(_session) end
	if _extras ~= nil then SourceEmulation.reset(_extras) end
	_virtual = {}
end

--- Forgets the collaborators and the session (test seam).
function M._reset_for_test()
	_deps, _session, _extras, _evdev_to_code = nil, nil, nil, nil
	_virtual = {}
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

--- The hook's modifiers with the ones a tap-hold holds for the user.
local function merged_mods(mods)
	if next(_virtual) == nil then return mods end
	local merged = {}
	for name, held in pairs(mods) do merged[name] = held end
	for id in pairs(_virtual) do merged[HOOK_MODIFIERS[id]] = true end
	return merged
end

--- The engine's held built-in modifiers of a press.
local function engine_held(mods)
	local held = {}
	for id, name in pairs(HOOK_MODIFIERS) do
		if mods[name] == true then held[id] = true end
	end
	if _deps.caps_locked() == true then held.caps_lock = true end
	return held
end

--- Performs the source emulation's actions in order.
--- @return boolean performed False when an output failed (logged).
local function perform(actions, evdev_code)
	for _, action in ipairs(actions) do
		if action.type == "modifier" then
			_virtual[action.id] = action.down == true or nil
		elseif action.type == "text" then
			local text = Emulation.flush(_session) .. action.text
			if not type_in_place(text, evdev_code) then return false end
		elseif action.type == "key" then
			if _session ~= nil then Emulation.reset(_session) end
			if _deps.emit_key(action.key, action.modifiers) ~= true then
				Logger.error(LOG, "The emulated key %s could not be pressed.", tostring(action.key))
				return false
			end
		end
	end
	return true
end

--- Decides a press with the layout source emulation first.
--- @return boolean|nil consumed nil when the press goes on to the keylayout emulation.
--- @return function|nil repeat_callback
--- @return function|nil release_callback
local function source_press(detail, code, mods)
	local extras = _extras
	local now = _deps.now_ms()
	-- A real press of a key the engine holds: its release never arrived.
	if extras.held_keys[code] ~= nil then perform(select(2, SourceEmulation.release(extras, code, now)), detail.code) end
	local consumed, actions = SourceEmulation.press(extras, code, engine_held(mods), now)
	local performed = perform(actions, detail.code)
	if not consumed then return nil end
	local function release(release_detail)
		if _extras ~= extras then return true end
		local _, released = SourceEmulation.release(extras, code, _deps.now_ms())
		perform(released, type(release_detail) == "table" and release_detail.code or detail.code)
		return true
	end
	if not performed then return false end
	-- A held key (custom modifier, tap-hold) ignores its repeats; another repeats its output.
	if extras.held_keys[code] ~= nil then return true, function() return true end, release end
	local held = detail.code
	return true, function(repeat_detail)
		if type(repeat_detail) ~= "table" or repeat_detail.code ~= held or _extras ~= extras then return false end
		local _, repeated = SourceEmulation.press(extras, code, engine_held(merged_mods(
			type(repeat_detail.mods) == "table" and repeat_detail.mods or {})), _deps.now_ms())
		return perform(repeated, held)
	end, release
end

--- Decides one grabbed key press from the keyboard hook's consumption callback.
--- @param detail table { code, mods, char } as the hook reports a key-down.
--- @return boolean consumed True when the emulation typed in the key's place.
--- @return function|nil repeat_callback Owner of the held press's repeats.
--- @return function|nil release_callback Owner of the press's release (a source emulation key).
function M.on_key(detail)
	local session = _session
	if session == nil or type(detail) ~= "table" then return false end
	local code = _evdev_to_code[detail.code]
	if code == nil or _deps.is_active() ~= true then return false end
	local hand = type(detail.mods) == "table" and detail.mods or {}
	if _extras ~= nil then
		local consumed, repeat_callback, release_callback = source_press(detail, code, merged_mods(hand))
		if consumed ~= nil then return consumed, repeat_callback, release_callback end
	end
	-- After the source emulation: this very press may have started a held modifier.
	local mods = merged_mods(hand)
	local magic = _deps.magic_evdev()
	session.config.magic_code = magic and _evdev_to_code[magic] or nil
	local decision, text = Emulation.decide(session, code, mods.shift == true, _deps.caps_locked() == true,
		mods.altgr == true, mods.ctrl == true, mods.alt == true, mods.meta == true, detail.char)
	if decision == Emulation.PASS then
		-- A modifier a tap-hold holds is the user's: the key goes out with it.
		if next(_virtual) == nil then return false end
		local held = {}
		for id in pairs(engine_held(mods)) do if id ~= "caps_lock" then held[#held + 1] = id end end
		table.sort(held)
		if _deps.emit_key(code, held) ~= true then return false end
		-- Each auto-repeat presses the key again under the held modifier, as the
		-- OS repeats a key held with a real one (ILL-004, ILX-002).
		local pressed = detail.code
		return true, function(repeat_detail)
			if type(repeat_detail) ~= "table" or repeat_detail.code ~= pressed or _session ~= session then return false end
			return M.on_key(repeat_detail) == true
		end
	end
	if decision == Emulation.SHORTCUT then
		if _deps.emit_shortcut(text, detail.code, mods) == true then
			-- Each auto-repeat presses the chord again, as AHK's ^SCxxx hotkeys
			-- fire on every repeat (holding Ctrl+z undoes repeatedly).
			local held = detail.code
			return true, function(repeat_detail)
				if type(repeat_detail) ~= "table" or repeat_detail.code ~= held or _session ~= session then return false end
				return M.on_key(repeat_detail) == true
			end
		end
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


--- The character a Ctrl, Alt or Super chord on this key sends while the
--- emulation runs, without typing anything: the keyboard shortcut slots match
--- it, as Windows registers a slot on the key that types its letter (ILX-001).
--- @param detail table Keyboard hook press detail.
--- @return string|nil char nil when the chord keeps the system layout's key.
function M.chord_key(detail)
	local session = _session
	if session == nil or type(detail) ~= "table" or _deps.is_active() ~= true then return nil end
	local code = _evdev_to_code[detail.code]
	if code == nil then return nil end
	local mods = merged_mods(type(detail.mods) == "table" and detail.mods or {})
	return (Emulation.chord_char(session, code, mods.ctrl == true, mods.alt == true, mods.meta == true))
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
		local Json = require("core.text.engine.json")
		local text = require("core.fs.adapters.file_system").read(require("core.fs.engine.paths").shared(rel))
		if type(text) ~= "string" then error("layout_emulation: " .. rel .. " is unreadable") end
		local decoded = lossless and Json.decode_lossless(text) or Json.decode(text)
		if type(decoded) ~= "table" then error("layout_emulation: " .. rel .. " is not valid JSON") end
		_json_cache[rel] = decoded
	end
	return _json_cache[rel]
end

--- The daemon's collaborators for M.init, built from its ports.
--- @param ports table { injector, is_paused, dispatch_char, magic_evdev, dry_run }
--- @return table deps
function M.production_deps(ports)
	local Registry = require("modules.keymap.layout_registry")
	local Injector = ports.injector
	return {
		read_config = function()
			local bytes, status, detail = require("core.text.engine.toml_codec.writer").read_classified(
				require("settings.engine.paths").config("config.toml"))
			if status ~= "ok" and status ~= "absent" then error("config.toml is unreadable: " .. tostring(detail)) end
			return require("core.text.engine.toml_codec").decode(bytes or "")
		end,
		default_for = require("menu.engine.manifest_reader").default_for,
		report_outdated = function(segments, detail) require("settings.engine.migration.outdated").report(segments, detail, Logger) end,
		source = function(id)
			local composer = Registry.composer_settings()
			return Settings.source(id, { installed = Registry.snapshot().installed,
				read_installed = function(layout_id) return Registry.read_local_copy(layout_id) end,
				shipped = function(layout_id) return Registry.shipped_layout(layout_id) end,
				composer_id = composer and composer.id or nil,
				read_emulation = function() return Registry.composer_emulation() end,
				read_composed = function() return Registry.composer_copy() end })
		end,
		keycodes = function() return shared_json("layouts/data/mac_keycodes.json", false) end,
		registry = function() return shared_json("layouts/data/keycodes/physical_keys.json", true) end,
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
		emit_shortcut = function(char, code, mods)
			if ports.dry_run then return false end
			-- A layout with no key for the character (Cyrillic) gets the
			-- character's US key, as GTK and Qt resolve a shortcut there; the
			-- physical key would be another shortcut (Ctrl+X for Ergopti's c).
			-- A character with no US key keeps the physical one.
			local Combo = require("gestures.engine.combo_emitter")
			local us_name = char:match("^%w$") and char:lower() or ({ ["."] = "period", [","] = "comma" })[char]
			local us_code = us_name and Combo.KEYSYM_TO_CODE[us_name] or code
			local keycode, level_mods = require("adapters.keyboard_layout").shortcut_keycode(char, us_code)
			-- Through the broker, which owns every write on the virtual keyboard:
			-- a bare write beside it moves the writer's epoch under the broker,
			-- which then refuses all later output, the grab's pass-through
			-- included. The modifiers the hand holds are named so the chord keeps
			-- them instead of suspending them as foreign.
			local chord = {}
			for _, held in ipairs(CHORD_MODIFIERS) do
				if type(mods) == "table" and mods[held.name] == true then chord[#chord + 1] = held.code end
			end
			for _, mod in ipairs(level_mods) do chord[#chord + 1] = mod end
			local pressed = require("gestures.engine.combo_emitter").press_codes(chord, { keycode }, "emulated shortcut")
			return pressed == true
		end,
		emit_key = function(code, modifiers)
			if ports.dry_run then return false end
			local key = shared_json("layouts/data/keycodes/physical_keys.json", true).keys[code]
			if type(key) ~= "table" or type(key.evdev) ~= "number" then return false end
			-- Through the broker, as the shortcut above: the chord holds exactly these
			-- modifiers, and any other the hand holds is suspended for it.
			local chord = {}
			for _, id in ipairs(modifiers) do
				local evdev = EMIT_MODIFIERS[id]
				if evdev == nil then return false end
				chord[#chord + 1] = evdev
			end
			return require("gestures.engine.combo_emitter").press_codes(chord, { key.evdev },
				"emulated layout source key") == true
		end,
		now_ms = function() return require("core.logger.engine.monotonic").now_ms() end,
		caps_locked = function() return require("adapters.xkb_capture").caps_locked() == true end,
		magic_evdev = ports.magic_evdev,
		is_active = function() return not ports.is_paused() end,
	}
end

--- Initializes the module with the daemon's collaborators and loads the layout.
--- @param ports table { injector, is_paused, dispatch_char, magic_evdev, dry_run }
--- @return boolean ok M.reload's answer.
function M.start(ports)
	M.init(M.production_deps(ports))
	return M.reload()
end

return M

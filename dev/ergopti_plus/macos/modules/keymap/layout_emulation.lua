--- modules/keymap/layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (macOS)
--- DESCRIPTION:
--- Types the layout chosen in [layout] (emulated_layout, or the built-in
--- Ergopti variant) over whatever input source macOS has selected, as the
--- Windows driver does: the user keeps ABC, French or any other system layout,
--- and each physical key-down the keymap tap sees is rewritten to what the
--- emulated .keylayout types there. The decisions are the shared engine's
--- (_shared/lua/layouts/keylayout_emulation.lua), so the three drivers type
--- the same text for the same physical keys.
---
--- FEATURES & RATIONALE:
--- 1. The event itself carries the emulated text (setUnicodeString), the way
---    the physical magic key already does: the buffer, the metrics, the
---    hotstrings and the application all read the same characters, and no
---    synthetic event is posted on the typing path.
--- 2. A dead key's press is consumed and types nothing until the next key
---    composes; a key the emulation leaves to the system layout completes it
---    with the system layout's character.
--- 3. A shortcut chord (Cmd or Ctrl held) keeps its modifiers and takes the key
---    code the system layout types the emulated layout's Command-level
---    character with (hs.keycodes.map), so Cmd+Z is where Ergopti has z.
---    Option is the emulated AltGr level, as on a .keylayout; the Option flag
---    is cleared from a rewritten event so no application reads it as a chord.
--- 4. Off the key path: the settings, the .keylayout parse and the number-row
---    analysis run at start and on every [layout] change (M.reload). A layout
---    that cannot be read or compiled turns the emulation off with an ERROR.
--- 5. macOS limit: while a password field holds Secure Event Input no event tap
---    sees the keys, so the system layout types there.
--- ==============================================================================

local Emulation = require("layouts.keylayout_emulation")
local Settings = require("layouts.emulation_settings")
local Logger = require("infra.logger")

local M = {}

local LOG = "keymap.layout_emulation"

-- Collaborators (M.init), the running session and the last reload's outcome.
local _deps = nil
local _session = nil
local _native_to_code = nil  -- unambiguous macOS key code -> KeyboardEvent.code
local _ambiguous = nil       -- key code -> { registry entries sharing it across ISO/ANSI }
local _status = { active = false, id = nil, error = nil }

local REQUIRED_DEPS = { "read_config", "default_for", "source", "keycodes", "registry", "keyboard_type",
	"physical_code", "keycode_for_char", "magic_code", "is_active" }





-- ================================
-- ================================
-- ======= 1/ Lifecycle ===========
-- ================================
-- ================================

--- Takes the collaborators. Called once, before the keymap tap starts.
--- @param deps table { read_config, default_for, report_outdated?, source, keycodes, registry,
---   keyboard_type(event), physical_code(entry, keyboard_type), keycode_for_char(char), magic_code,
---   is_active }
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
	local native, ambiguous = {}, {}
	for code, key in pairs(registry.keys) do
		if type(key) == "table" and key.kind == "key" and type(key.hs) == "number" then
			local iso = type(key.macos_iso) == "table" and key.macos_iso.hs or key.hs
			if iso == key.hs then
				native[key.hs] = code
			else
				-- The ISO pair: which key a code names depends on the keyboard.
				for _, value in ipairs({ key.hs, iso }) do
					ambiguous[value] = ambiguous[value] or {}
					ambiguous[value][#ambiguous[value] + 1] = { code = code, entry = key }
				end
			end
		end
	end
	_deps, _native_to_code, _ambiguous = deps, native, ambiguous
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

--- Drops a pending dead key (pause, focus change).
function M.reset()
	if _session ~= nil then Emulation.reset(_session) end
end

--- Forgets the collaborators and the session (test seam).
function M._reset_for_test()
	_deps, _session, _native_to_code, _ambiguous = nil, nil, nil, nil
	_status = { active = false, id = nil, error = nil }
end





-- ================================
-- ================================
-- ======= 2/ Key path ============
-- ================================
-- ================================

--- The KeyboardEvent.code of a key-down, nil for a key the registry does not name.
local function physical(e, key_code)
	local code = _native_to_code[key_code]
	if code ~= nil then return code end
	local candidates = _ambiguous[key_code]
	if candidates == nil then return nil end
	local keyboard_type = _deps.keyboard_type(e)
	for _, candidate in ipairs(candidates) do
		if _deps.physical_code(candidate.entry, keyboard_type) == key_code then return candidate.code end
	end
	return nil
end

--- Rewrites one physical key-down of the keymap tap.
--- @param e table|userdata The key-down event.
--- @param key_code integer Its key code (already read by the tap).
--- @return boolean consume True when the event must be deleted (a pending dead key).
function M.key_down(e, key_code)
	local session = _session
	if session == nil then return false end
	local code = physical(e, key_code)
	if code == nil or _deps.is_active() ~= true then return false end
	local flags = e:getFlags()
	session.config.magic_code = _deps.magic_code()
	local native = nil
	if Emulation.pending(session) then native = e:getCharacters(false) end
	local decision, text = Emulation.decide(session, code, flags.shift == true, flags.capslock == true,
		flags.alt == true, flags.ctrl == true, false, flags.cmd == true, native)
	if decision == Emulation.PASS then return false end
	if decision == Emulation.SHORTCUT then
		local target = _deps.keycode_for_char(text)
		if type(target) == "number" then e:setKeyCode(target) end
		return false
	end
	if decision == Emulation.TYPE and text == "" then return true end
	if flags.alt then
		local cleared = {}
		for name, held in pairs(flags) do if name ~= "alt" then cleared[name] = held end end
		e:setFlags(cleared)
	end
	e:setUnicodeString(text)
	return false
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

--- Initializes the module with the driver's collaborators and loads the layout.
--- @param ports table { is_paused, magic_code }
--- @return boolean ok M.reload's answer.
function M.start(ports)
	local Registry = require("modules.keymap.layout_registry")
	local Geometry = require("adapters.keyboard_geometry")
	M.init({
		read_config = function()
			local content, status, detail = require("toml_codec.writer").read_classified(
				require("infra.config_paths").get("ConfigTomlPath"), require("adapters.file_system"))
			if status ~= "ok" and status ~= "absent" then error("config.toml is unreadable: " .. tostring(detail)) end
			return require("toml_codec").decode(content or "")
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
		keyboard_type = Geometry.event_type,
		physical_code = Geometry.physical_code,
		-- The key the selected input source types a character with.
		keycode_for_char = function(char) return hs.keycodes.map[char] end,
		magic_code = ports.magic_code,
		is_active = function() return not ports.is_paused() end,
	})
	return M.reload()
end

return M

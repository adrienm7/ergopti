--- modules/keymap/layout_emulation.lua

--- ==============================================================================
--- MODULE: Layout Emulation (macOS)
--- DESCRIPTION:
--- Types the layout chosen in [layout] (emulated_layout, or the built-in
--- Ergopti variant) over whatever input source macOS has selected, as the
--- Windows driver does: the user keeps ABC, French or any other system layout,
--- and each physical key-down the keymap tap sees is rewritten to what the
--- emulated .keylayout types there. The decisions are the shared engine's
--- (_shared/layouts/engine/composer/keylayout_emulation.lua), so the three drivers type
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
--- 6. A layout source's records no .keylayout holds (custom modifiers, tap-holds,
---    shortcuts sending another key, key chords, system-key remaps) come first,
---    from the composed layout's emulation table (layouts/engine/composer/source_emulation.lua).
---    One output rides the event itself (its text, or its key code and flags,
---    the key-up rewritten alike); several are posted after the callback in
---    physical order (defer_consumed_input_action). A built-in modifier a
---    tap-hold holds is added to the flags of the keys pressed under it, not to
---    a mouse click.
--- ==============================================================================

local Emulation = require("layouts.engine.composer.keylayout_emulation")
local SourceEmulation = require("layouts.engine.composer.source_emulation")
local Settings = require("layouts.engine.emulation.settings")
local Logger = require("infra.logger")

local M = {}

local LOG = "keymap.layout_emulation"

-- Collaborators (M.init), the running session and the last reload's outcome.
local _deps = nil
local _session = nil
local _native_to_code = nil  -- unambiguous macOS key code -> KeyboardEvent.code
local _ambiguous = nil       -- key code -> { registry entries sharing it across ISO/ANSI }
local _status = { active = false, id = nil, error = nil }
local _extras = nil     -- the layout source emulation session, nil without a table
local _virtual = {}     -- built-in modifiers a tap-hold holds for the user (engine ids)
local _rewritten = {}   -- physical key code -> the key code its key-down was rewritten to

-- The engine's built-in modifier ids and the event flags they are.
local FLAG_OF = { shift = "shift", control = "ctrl", alt = "alt", alt_right = "alt", meta = "cmd" }
-- The inverse: an event flag names the unsided id (alt, not alt_right).
local ID_OF_FLAG = {}
for id, flag in pairs(FLAG_OF) do
	if id ~= "alt_right" then ID_OF_FLAG[flag] = id end
end

local REQUIRED_DEPS = { "read_config", "default_for", "source", "keycodes", "registry", "keyboard_type",
	"physical_code", "keycode_for_char", "magic_code", "is_active", "autorepeat", "now_ms", "post" }





-- ================================
-- ================================
-- ======= 1/ Lifecycle ===========
-- ================================
-- ================================

--- Takes the collaborators. Called once, before the keymap tap starts.
--- @param deps table { read_config, default_for, report_outdated?, source, keycodes, registry,
---   keyboard_type(event), physical_code(entry, keyboard_type), keycode_for_char(char), magic_code,
---   is_active, autorepeat(event), now_ms, post(outputs) posting { type = "text", text } and
---   { type = "key", key_code, flags } after the callback, in order }
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

--- Drops a pending dead key (pause, focus change), and a held or locked custom
--- modifier or a tap-hold's held modifier.
function M.reset()
	if _session ~= nil then Emulation.reset(_session) end
	if _extras ~= nil then SourceEmulation.reset(_extras) end
	_virtual = {}
end

--- Forgets the collaborators and the session (test seam).
function M._reset_for_test()
	_deps, _session, _native_to_code, _ambiguous = nil, nil, nil, nil
	_extras, _virtual, _rewritten = nil, {}, {}
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

--- The event flags with the modifiers a tap-hold holds for the user.
local function merged_flags(flags)
	if next(_virtual) == nil then return flags end
	local merged = {}
	for name, held in pairs(flags) do merged[name] = held end
	for id in pairs(_virtual) do merged[FLAG_OF[id]] = true end
	return merged
end

--- The engine's held built-in modifiers of a press.
local function engine_held(flags)
	local held = {}
	for flag, id in pairs(ID_OF_FLAG) do
		if flags[flag] == true then held[id] = true end
	end
	if flags.capslock == true then held.caps_lock = true end
	return held
end

--- The key code and flags a key action presses on this keyboard.
local function key_target(e, action)
	local entry = _deps.registry().keys[action.key]
	if type(entry) ~= "table" or type(entry.hs) ~= "number" then return nil end
	local flags = {}
	for _, id in ipairs(action.modifiers) do flags[FLAG_OF[id]] = true end
	return _deps.physical_code(entry, _deps.keyboard_type(e)), flags
end

--- Splits the engine's actions: modifiers update the held set now, outputs stay in order.
local function outputs_of(e, actions)
	local outputs = {}
	for _, action in ipairs(actions) do
		if action.type == "modifier" then
			_virtual[action.id] = action.down == true or nil
		elseif action.type == "text" then
			outputs[#outputs + 1] = { type = "text", text = Emulation.flush(_session) .. action.text }
		else
			local target, flags = key_target(e, action)
			if target == nil then
				Logger.error(LOG, "The emulated key %s has no key code.", tostring(action.key))
			else
				if _session ~= nil then Emulation.reset(_session) end
				outputs[#outputs + 1] = { type = "key", key_code = target, flags = flags }
			end
		end
	end
	return outputs
end

--- Performs outputs on the event when one can ride it, else after the callback.
--- @return boolean consume
local function deliver(e, key_code, outputs)
	if #outputs == 0 then return true end
	if #outputs == 1 and outputs[1].type == "text" then
		local cleared = {}
		for name, held in pairs(e:getFlags()) do if name ~= "alt" then cleared[name] = held end end
		e:setFlags(cleared)
		e:setUnicodeString(outputs[1].text)
		return false
	end
	if #outputs == 1 then
		e:setKeyCode(outputs[1].key_code)
		e:setFlags(outputs[1].flags)
		_rewritten[key_code] = outputs[1].key_code
		return false
	end
	_deps.post(outputs)
	return true
end

--- Decides a key-down with the layout source emulation first.
--- @return boolean|nil consume nil when the press goes on to the keylayout emulation.
--- @return table prefix Outputs to type before the press's own (a tap settled by it).
local function source_down(e, key_code, code)
	local extras = _extras
	local now = _deps.now_ms()
	if extras.held_keys[code] ~= nil then
		if _deps.autorepeat(e) then return true, {} end
		-- A real press of a key the engine holds: its release never arrived.
		local _, lost = SourceEmulation.release(extras, code, now)
		local late = outputs_of(e, lost)
		if #late > 0 then _deps.post(late) end
	end
	local consumed, actions = SourceEmulation.press(extras, code, engine_held(merged_flags(e:getFlags())), now)
	local outputs = outputs_of(e, actions)
	if consumed then return deliver(e, key_code, outputs), {} end
	return nil, outputs
end

--- Rewrites one physical key-up: the release of a key the source emulation
--- holds, or of a key-down rewritten to another key code.
--- @param e table|userdata The key-up event.
--- @param key_code integer Its key code.
--- @return boolean consume True when the event must be deleted.
function M.key_up(e, key_code)
	local target = _rewritten[key_code]
	if target ~= nil then
		_rewritten[key_code] = nil
		e:setKeyCode(target)
		return false
	end
	if _extras == nil or _session == nil then return false end
	local code = physical(e, key_code)
	if code == nil then return false end
	local consumed, actions = SourceEmulation.release(_extras, code, _deps.now_ms())
	local outputs = outputs_of(e, actions)
	if #outputs > 0 then _deps.post(outputs) end
	return consumed
end

--- Rewrites one physical key-down of the keymap tap.
--- @param e table|userdata The key-down event.
--- @param key_code integer Its key code (already read by the tap).
--- @return boolean consume True when the event must be deleted (a pending dead key).
function M.key_down(e, key_code)
	local session = _session
	if session == nil then return false end
	local code = physical(e, key_code)
	if code == nil then return false end
	-- A key pressed during a pause ends a pending dead key and the held source
	-- state, as the pause listener's reset does: the composition never spans it.
	if _deps.is_active() ~= true then
		M.reset()
		return false
	end
	local prefix = {}
	if _extras ~= nil then
		local consumed
		consumed, prefix = source_down(e, key_code, code)
		if consumed ~= nil then return consumed end
	end
	-- After the source emulation: this very press may have started a held modifier.
	local flags = merged_flags(e:getFlags())
	session.config.magic_code = _deps.magic_code()
	local native = nil
	if Emulation.pending(session) then native = e:getCharacters(false) end
	local decision, text = Emulation.decide(session, code, flags.shift == true, flags.capslock == true,
		flags.alt == true, flags.ctrl == true, false, flags.cmd == true, native)
	-- Ctrl+AltGr (Ctrl+Option, Option being the AltGr level here) sends Ctrl and
	-- the key's logical character with the level key suspended, as Linux does
	-- (ILD-2, decided by the maintainer on 2026-11-11). Cmd+Option keeps Option:
	-- it is macOS's own chord family, not a level (decided by the coordinator on
	-- 2026-11-11, to review by the maintainer).
	if decision == Emulation.SHORTCUT and flags.ctrl == true and flags.alt == true and flags.cmd ~= true then
		local suspended = {}
		for name, held in pairs(flags) do if name ~= "alt" then suspended[name] = held end end
		flags = suspended
	end
	if #prefix > 0 then
		-- A tap settled by this press types first: the press's own output follows it.
		if decision == Emulation.TYPE or decision == Emulation.TYPE_PASS then
			prefix[#prefix + 1] = { type = "text", text = text }
		end
		if decision ~= Emulation.TYPE then
			local target = decision == Emulation.SHORTCUT and _deps.keycode_for_char(text) or key_code
			prefix[#prefix + 1] = { type = "key", key_code = type(target) == "number" and target or key_code,
				flags = flags }
		end
		_deps.post(prefix)
		return true
	end
	if decision == Emulation.PASS then
		-- A modifier a tap-hold holds is the user's: the key goes out with it.
		if next(_virtual) ~= nil then e:setFlags(flags) end
		return false
	end
	if decision == Emulation.SHORTCUT then
		local target = _deps.keycode_for_char(text)
		-- The release goes out on the key code the press went out on (key_up).
		if type(target) == "number" then
			e:setKeyCode(target)
			if target ~= key_code then _rewritten[key_code] = target end
		end
		if next(_virtual) ~= nil or flags.alt ~= merged_flags(e:getFlags()).alt then e:setFlags(flags) end
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
		local Json = require("core.text.engine.json")
		local text = require("adapters.file_system").read(require("infra.paths").shared(rel))
		if type(text) ~= "string" then error("layout_emulation: " .. rel .. " is unreadable") end
		local decoded = lossless and Json.decode_lossless(text) or Json.decode(text)
		if type(decoded) ~= "table" then error("layout_emulation: " .. rel .. " is not valid JSON") end
		_json_cache[rel] = decoded
	end
	return _json_cache[rel]
end

-- The US positions of the shortcut characters, by their mac_keycodes.json name.
local US_KEY_NAMES = { ["."] = "Period", [","] = "Comma", ["/"] = "Slash", [";"] = "Semicolon" }

--- The key code a character has on the US layout, where macOS resolves a
--- Command shortcut when the input source has no key for it (a non-Latin
--- source): letters, digits and the usual marks; nil for any other.
--- @param char string One character.
--- @param keycodes table mac_keycodes.json.
--- @return integer|nil key_code
function M.us_keycode(char, keycodes)
	local name = US_KEY_NAMES[char]
	if not name and char:match("^%a$") then name = "Key" .. char:upper() end
	if not name and char:match("^%d$") then name = "Digit" .. char end
	if not name then return nil end
	for _, key in ipairs(keycodes.keys) do
		if key.code == name and type(key.mac) == "number" then return key.mac end
	end
	return nil
end

--- Initializes the module with the driver's collaborators and loads the layout.
--- @param ports table { is_paused, magic_code }
--- @return boolean ok M.reload's answer.
function M.start(ports)
	local Registry = require("modules.keymap.layout_registry")
	local Geometry = require("adapters.keyboard_geometry")
	M.init({
		read_config = function()
			local content, status, detail = require("core.text.engine.toml_codec.writer").read_classified(
				require("infra.config_paths").get("ConfigTomlPath"), require("adapters.file_system"))
			if status ~= "ok" and status ~= "absent" then error("config.toml is unreadable: " .. tostring(detail)) end
			return require("core.text.engine.toml_codec").decode(content or "")
		end,
		default_for = require("infra.manifest_reader").default_for,
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
		keyboard_type = Geometry.event_type,
		physical_code = Geometry.physical_code,
		-- The key the selected input source types a character with.
		-- On the US position when the source has none (a non-Latin source).
		keycode_for_char = function(char)
			return hs.keycodes.map[char] or M.us_keycode(char, shared_json("layouts/data/mac_keycodes.json", false))
		end,
		magic_code = ports.magic_code,
		is_active = function() return not ports.is_paused() end,
		autorepeat = function(e)
			local value = e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
			return value ~= nil and value ~= 0
		end,
		now_ms = function() return math.floor(hs.timer.absoluteTime() / 1000000) end,
		-- After the callback and before any later physical key, in order.
		post = function(outputs)
			local SyntheticInput = require("adapters.synthetic_input")
			return SyntheticInput.defer_consumed_input_action("layout source emulation", function()
				for _, output in ipairs(outputs) do
					if output.type == "text" then
						assert(SyntheticInput.emit_key_strokes(output.text), "emulated text could not be posted")
					else
						local names = {}
						for name, held in pairs(output.flags) do
							if held == true and name ~= "capslock" and name ~= "fn" then names[#names + 1] = name end
						end
						table.sort(names)
						assert(SyntheticInput.emit_key_stroke(names, output.key_code), "emulated key could not be posted")
					end
				end
			end)
		end,
	})
	return M.reload()
end

return M

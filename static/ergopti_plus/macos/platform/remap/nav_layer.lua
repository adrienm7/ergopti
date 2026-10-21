--- platform/remap/nav_layer.lua

--- ==============================================================================
--- MODULE: Navigation Layer Rule (Karabiner)
--- DESCRIPTION:
--- Turns the navigation layer's bindings — the user's layers.toml, resolved for
--- macOS by the shared loader (_shared/lua/keymap/layers.lua) — into the
--- Karabiner rule the generator deploys, in place of the hand-written
--- data/layer_keys.json it used to append verbatim. That file survives as
--- data/legacy_layer_keys.json, the anchor that proves and removes the blocks
--- older releases wrote before rules carried a lease.
---
--- FEATURES & RATIONALE:
--- 1. The layer_active contract is unchanged: every manipulator fires only while
---    the layer variable is 1, whatever modifier is held, and the generator
---    scopes the variable to the lease like every other rule.
--- 2. Inputs and outputs both use the registry's ISO projection
---    (KEYBOARD_FORM): the deployed ANSI virtual keyboard passes the ISO pair
---    through unswapped (modules/keymap/layout.lua VIRTUAL_KEYBOARD_PRODUCT), so
---    an output reaches the keycode the physical key itself produces (#99).
--- 3. F1-F12 reach the function keys in either top-row mode: sent plain while
---    macOS uses them as standard keys, with Fn added while it treats the row as
---    media keys (Karabiner's system.use_fkeys_as_standard_function_keys).
--- 4. Driver-native handlers ([call_handlers].macos in layer_actions.toml) and
---    the `none` action have Karabiner forms of their own; a repeat count has
---    none on macOS and raises.
--- 5. No binding, no rule: Karabiner refuses a rule without manipulators, and
---    an absent layers.toml means the keys behave natively.
--- 6. The wheel stays out of the Karabiner rule, which cannot take wheel input:
---    load() turns the wheel bindings into the strokes Hammerspoon posts while
---    the layer is held (wheel_slots, run by modules/shortcuts/actions/system.lua
---    bind_layer_wheel between the F20 and F19 sentinels).
--- 7. The layer comes with its key: importing the recommended key whose hold
---    enters the layer (the first-run wizard, the Tap-Holds « Restore
---    recommended values ») also creates layers.toml from Ergopti's recommended
---    layer when the folder has none (keymap.layer_preset); an existing file is
---    the user's and is never replaced.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local NativePath = require("native_path")
local Layout = require("modules.keymap.layout")

local LOG = "karabiner.nav_layer"

-- Configured input observations originate in the same acknowledged load. They
-- reserve mapping inputs only; no Karabiner installation or lease is admitted.
local Json = require("json")
local TomlCodec = require("toml_codec")
local Layers = require("keymap.layers")
local Writer = require("toml_codec.writer")
local original_read, original_json, original_toml = Writer.read_classified, Json.decode, TomlCodec.decode
local source_records = setmetatable({}, { __mode = "k" })
local layer_ports = {}
for _, name in ipairs({ "load_context", "load_user_file", "user_file_path", "new_context", "load", "format_resolution" }) do
	layer_ports[name] = Layers[name]
end
local original_load, original_build, original_wheel, original_capture

local function source_ports_current()
	if package.loaded["platform.remap.nav_layer"] ~= M or getmetatable(M) ~= nil
		or M.load ~= original_load or M.build_rule ~= original_build or M.wheel_slots ~= original_wheel
		or M.capture_configured_inputs ~= original_capture
		or package.loaded["json"] ~= Json or getmetatable(Json) ~= nil or Json.decode ~= original_json
		or package.loaded["toml_codec"] ~= TomlCodec or getmetatable(TomlCodec) ~= nil or TomlCodec.decode ~= original_toml
		or package.loaded["toml_codec.writer"] ~= Writer or getmetatable(Writer) ~= nil or Writer.read_classified ~= original_read
		or package.loaded["keymap.layers"] ~= Layers or getmetatable(Layers) ~= nil then return false end
	for name, port in pairs(layer_ports) do if type(port) ~= "function" or Layers[name] ~= port then return false end end
	return true
end

-- The layer a tap-hold key's hold_layer "nav" enters
-- (_shared/tap_hold/defaults.toml [tap_hold.hold_picker].layers).
M.NAV_LAYER_ID = "nav"

-- The tap-hold hold action (data/actions.json) that sets layer_active, the
-- one way a macOS key enters the layer.
M.HOLD_ACTION_ID = "layer"

local OS = "macos"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The registry form the key codes are read for (physical_keys.json "forms").
-- The layer editor host reads the keys' legends in the same form.
local KEYBOARD_FORM = "iso"
M.KEYBOARD_FORM = KEYBOARD_FORM

-- The Karabiner variable the hold actions set while the layer is held.
local LAYER_ACTIVE_VAR_NAME = "layer_active"
local LAYER_ACTIVE_ON_VALUE = 1

-- Karabiner's mirror of "Use F1, F2, etc. keys as standard function keys".
local FKEYS_STANDARD_VAR_NAME = "system.use_fkeys_as_standard_function_keys"

-- Karabiner's modifier names for the layer vocabulary's modifiers.
local KARABINER_MODIFIERS = {
	ctrl = "control", alt = "option", shift = "shift", meta = "command", fn = "fn",
}

-- Karabiner's no-op key: the `none` action swallows the key it is bound to.
local NO_OP_KEY_CODE = "vk_none"

-- The fields of a Karabiner event object that name the key it is.
local EVENT_FIELDS = { "key_code", "consumer_key_code", "pointing_button" }

local RULE_DESCRIPTION = "Navigation layer — generated from layers.toml, active while layer_active == 1"

-- The registry kind of a wheel direction, and the keys a wheel stroke sends as
-- system-defined media events (hs.eventtap.event.newSystemKeyEvent), which a
-- plain key event cannot drive.
local WHEEL_KIND = "wheel"
local SYSTEM_KEYS = {
	AudioVolumeUp = "SOUND_UP", AudioVolumeDown = "SOUND_DOWN", AudioVolumeMute = "MUTE",
}

-- Hammerspoon's modifier names for the layer vocabulary's modifiers.
local HS_MODIFIERS = { ctrl = "ctrl", alt = "alt", shift = "shift", meta = "cmd", fn = "fn" }





-- ===================================
-- ===================================
-- ======= 2/ Karabiner events =======
-- ===================================
-- ===================================

--- The Karabiner event of one physical key on Ergopti's board, as a fresh table.
--- @param code string A registry key code.
--- @param registry table Decoded physical_keys.json.
--- @return table event { key_code | consumer_key_code | pointing_button = name }
local function karabiner_event(code, registry)
	local entry = registry.keys[code]
	if type(entry) ~= "table" then error("nav_layer: " .. tostring(code) .. " is not in the physical-key registry", 3) end
	local source = entry.karabiner
	local override = type(entry["macos_" .. KEYBOARD_FORM]) == "table"
		and entry["macos_" .. KEYBOARD_FORM].karabiner
	if type(override) == "table" then source = override end
	-- json.lua decodes a JSON null to a sentinel table, so check for a real field.
	if type(source) == "table" then
		for _, field in ipairs(EVENT_FIELDS) do
			if type(source[field]) == "string" then return { [field] = source[field] } end
		end
	end
	error("nav_layer: Karabiner cannot take or send " .. tostring(code), 3)
end

--- Whether a key is one of the function keys F1-F12.
local function is_function_key(code, registry)
	local entry = registry.keys[code]
	return type(entry) == "table" and entry.group == "function" and code:match("^F%d+$") ~= nil
end

--- The `to` events of a keystroke, with Fn added to every function key when asked.
--- @param chords table Resolved chords { mods, key }.
--- @param add_fn boolean Whether F1-F12 are sent with Fn.
--- @return table events
local function keystroke_events(chords, registry, add_fn)
	local events = {}
	for _, chord in ipairs(chords) do
		local event = karabiner_event(chord.key, registry)
		local mods, has_fn = {}, false
		for _, mod in ipairs(chord.mods) do
			local name = KARABINER_MODIFIERS[mod]
			if not name then error("nav_layer: Karabiner cannot send the " .. tostring(mod) .. " modifier", 3) end
			if mod == "fn" then has_fn = true end
			mods[#mods + 1] = name
		end
		if add_fn and not has_fn and is_function_key(chord.key, registry) then mods[#mods + 1] = KARABINER_MODIFIERS.fn end
		if #mods > 0 then event.modifiers = mods end
		events[#events + 1] = event
	end
	return events
end

--- Whether a keystroke sends a function key, and so needs a variant per top-row mode.
local function sends_function_key(chords, registry)
	for _, chord in ipairs(chords) do
		if is_function_key(chord.key, registry) then return true end
	end
	return false
end





-- =========================================
-- =========================================
-- ======= 3/ Driver-native handlers =======
-- =========================================
-- =========================================

-- [call_handlers].macos in _shared/keymap/layer_actions.toml; each fills the
-- manipulator's outputs.
local Brightness = require("brightness_actions").load()
local CALL_HANDLERS = {
	brightness_up = function(manipulator)
		manipulator.to = { { consumer_key_code = Brightness.actions.brightness_up.karabiner_consumer } }
	end,
	brightness_down = function(manipulator)
		manipulator.to = { { consumer_key_code = Brightness.actions.brightness_down.karabiner_consumer } }
	end,
	-- Escape on a tap; Option+Shift while held, the Ergopti keylayout's symbol level.
	tap_escape_hold_option_shift = function(manipulator, registry)
		local shift = karabiner_event("ShiftLeft", registry)
		shift.modifiers = { karabiner_event("AltLeft", registry).key_code }
		manipulator.to_if_alone = { karabiner_event("Escape", registry) }
		manipulator.to = { shift }
	end,
}
M.CALL_HANDLERS = CALL_HANDLERS





-- =================================
-- =================================
-- ======= 4/ The layer rule =======
-- =================================
-- =================================

--- A manipulator firing on one key while the layer is held.
local function base_manipulator(code, registry, description, extra_condition)
	local from = karabiner_event(code, registry)
	from.modifiers = { optional = { "any" } }
	local conditions = { { type = "variable_if", name = LAYER_ACTIVE_VAR_NAME, value = LAYER_ACTIVE_ON_VALUE } }
	if extra_condition then conditions[#conditions + 1] = extra_condition end
	return { type = "basic", description = description, conditions = conditions, from = from }
end

--- What a resolution is called in a manipulator's description.
local function resolution_label(resolution)
	if resolution.action then return resolution.action end
	local parts = {}
	for _, chord in ipairs(resolution.chords or {}) do
		local tokens = {}
		for _, mod in ipairs(chord.mods) do tokens[#tokens + 1] = mod end
		tokens[#tokens + 1] = chord.key
		parts[#parts + 1] = table.concat(tokens, "+")
	end
	return table.concat(parts, ", ")
end

--- The manipulators of one bound key.
--- @return table manipulators
local function manipulators_for(code, resolution, registry)
	local label = "Navigation layer: " .. code .. " — " .. resolution_label(resolution)
	if resolution.kind == "keystroke" then
		if not sends_function_key(resolution.chords, registry) then
			local manipulator = base_manipulator(code, registry, label)
			manipulator.to = keystroke_events(resolution.chords, registry, false)
			return { manipulator }
		end
		local media = base_manipulator(code, registry, label .. " (Fn added: the top row is media keys)",
			{ type = "variable_unless", name = FKEYS_STANDARD_VAR_NAME, value = true })
		media.to = keystroke_events(resolution.chords, registry, true)
		local standard = base_manipulator(code, registry, label .. " (the top row is standard function keys)",
			{ type = "variable_if", name = FKEYS_STANDARD_VAR_NAME, value = true })
		standard.to = keystroke_events(resolution.chords, registry, false)
		return { media, standard }
	end
	if resolution.kind == "none" then
		local manipulator = base_manipulator(code, registry, label)
		manipulator.to = { { key_code = NO_OP_KEY_CODE } }
		return { manipulator }
	end
	if resolution.kind == "call" then
		local handler = CALL_HANDLERS[resolution.handler]
		if not handler then error("nav_layer: no macOS handler implements call:" .. tostring(resolution.handler), 3) end
		local manipulator = base_manipulator(code, registry, label)
		handler(manipulator, registry)
		return { manipulator }
	end
	error("nav_layer: Karabiner has no " .. tostring(resolution.kind) .. " resolution", 3)
end

--- Builds the Karabiner rule of the navigation layer.
--- @param bindings table Key code -> resolution, resolved for macOS.
--- @param registry table Decoded physical_keys.json.
--- @return table|nil rule { description, manipulators }, nil when nothing is bound.
function M.build_rule(bindings, registry)
	if type(bindings) ~= "table" or type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("nav_layer.build_rule needs the bindings and the physical-key registry", 2)
	end
	local codes = {}
	for code in pairs(bindings) do
		-- A wheel direction is Hammerspoon's to run (M.wheel_slots).
		local entry = registry.keys[code]
		if not (type(entry) == "table" and entry.kind == WHEEL_KIND) then codes[#codes + 1] = code end
	end
	if #codes == 0 then return nil end
	-- Sorted: Lua tables have no order, and a stable rule keeps the deployed
	-- karabiner.json identical from one regeneration to the next.
	table.sort(codes)
	local manipulators = {}
	for _, code in ipairs(codes) do
		for _, manipulator in ipairs(manipulators_for(code, bindings[code], registry)) do
			manipulators[#manipulators + 1] = manipulator
		end
	end
	return { description = RULE_DESCRIPTION, manipulators = manipulators }
end





-- ===================================
-- ===================================
-- ======= 5/ The wheel slots ========
-- ===================================
-- ===================================

--- The strokes of one wheel binding: what Hammerspoon posts for a turn of the
--- wheel while the layer is held.
--- @param code string A registry wheel code.
--- @param resolution table Its macOS resolution.
--- @param registry table Decoded physical_keys.json.
--- @return table|nil strokes Array of { system = "SOUND_UP" } or
---   { mods = { "cmd", … }, keycode = n }; empty for `none`.
--- @return string|nil problem Why the binding cannot run on the wheel.
local function wheel_strokes(code, resolution, registry, form)
	if resolution.kind == "none" then return {} end
	if resolution.kind == "call" and Brightness.actions[resolution.handler] then
		return { { system = Brightness.actions[resolution.handler].macos_system } }
	end
	if resolution.kind ~= "keystroke" then
		return nil, "a " .. tostring(resolution.kind) .. " resolution is no stroke a wheel turn can send"
	end
	local strokes = {}
	for _, chord in ipairs(resolution.chords) do
		local system = SYSTEM_KEYS[chord.key]
		if system and #chord.mods == 0 then
			strokes[#strokes + 1] = { system = system }
		else
			local entry = registry.keys[chord.key]
			local override = type(entry) == "table" and entry["macos_" .. form]
			local keycode = type(override) == "table" and override.hs or (type(entry) == "table" and entry.hs)
			if type(keycode) ~= "number" then
				return nil, tostring(chord.key) .. " has no macOS keycode to send for " .. code
			end
			local mods = {}
			for _, mod in ipairs(chord.mods) do mods[#mods + 1] = HS_MODIFIERS[mod] end
			strokes[#strokes + 1] = { mods = mods, keycode = keycode }
		end
	end
	return strokes
end

--- The wheel bindings of a layer, by axis and direction.
--- @param bindings table Key code -> resolution, resolved for macOS.
--- @param registry table Decoded physical_keys.json.
--- @param form string|nil Captured active layout convention for Quartz output.
--- @return table slots { vertical = { [1] = slot, [-1] = slot }, horizontal = … },
---   a slot being { code, strokes }; a direction the layer leaves unbound, or
---   binds to what a wheel turn cannot send (logged), has none.
function M.wheel_slots(bindings, registry, form)
	if form ~= nil then
		assert(form == "ansi" or form == "iso", "wheel output requires the declared virtual keyboard convention")
	end
	local slots = { vertical = {}, horizontal = {} }
	for code, resolution in pairs(bindings) do
		local entry = registry.keys[code]
		if type(entry) == "table" and entry.kind == WHEEL_KIND then
			form = form or Layout.keyboard_form()
			local strokes, problem = wheel_strokes(code, resolution, registry, form)
			if strokes and slots[entry.axis] then
				slots[entry.axis][entry.direction] = { code = code, strokes = strokes }
			else
				Logger.warn(LOG, "The wheel binding %s is left out: %s.", code, tostring(problem))
			end
		end
	end
	return slots
end





-- ===============================
-- ===============================
-- ======= 6/ Loading ============
-- ===============================
-- ===============================

--- Reads the user's layer file: only genuine absence is nil; failed read or
--- close acknowledgement must not lend its bytes to the navigation loader.
local function read_user_file(path, remember, reader)
	local content, status, detail = (reader or require("toml_codec.writer").read_classified)(path)
	if remember then remember(path, content, status) end
	if status == "ok" and type(content) == "string" then return content end
	if status == "absent" and content == nil then return nil end
	error("nav_layer: cannot read " .. path .. ": " .. tostring(detail or "source read was not acknowledged"), 0)
end

--- Shipped context has no optional-file contract: even genuine absence is fatal.
local function read_shipped(path, remember, reader)
	local content = read_user_file(path, remember, reader)
	if content == nil then error("nav_layer: cannot read " .. path .. ": source is absent", 0) end
	return content
end

--- Says where a loader error sits: layer.section.key, or the file as a whole.
local function error_where(err)
	local parts = {}
	for _, field in ipairs({ "layer", "section", "key" }) do
		if err[field] ~= nil then parts[#parts + 1] = tostring(err[field]) end
	end
	return #parts > 0 and table.concat(parts, ".") or "the whole file"
end

local function project_configured_inputs(layer)
	if type(layer) ~= "table" or getmetatable(layer) ~= nil or type(layer.bindings) ~= "table"
		or getmetatable(layer.bindings) ~= nil or type(layer.registry) ~= "table"
		or getmetatable(layer.registry) ~= nil or type(layer.registry.keys) ~= "table"
		or getmetatable(layer.registry.keys) ~= nil then return nil end
	local inputs, codes, seen = {}, {}, {}
	local function compiled_input(rule)
		local result
		if type(rule) ~= "table" or type(rule.manipulators) ~= "table" or #rule.manipulators == 0 then return nil end
		for _, manipulator in ipairs(rule.manipulators) do
			local from, event = manipulator.from, nil
			if type(from) ~= "table" then return nil end
			for _, field in ipairs(EVENT_FIELDS) do
				if from[field] ~= nil then
					if event ~= nil or type(from[field]) ~= "string" then return nil end
					event = field .. "=" .. from[field]
				end
			end
			local modifiers = from.modifiers
			if event == nil or type(modifiers) ~= "table" or modifiers.mandatory ~= nil
				or type(modifiers.optional) ~= "table" or #modifiers.optional ~= 1
				or modifiers.optional[1] ~= "any" then return nil end
			if result ~= nil and result ~= event then return nil end
			result = event
		end
		return result
	end
	for code, resolution in pairs(layer.bindings) do
		local entry = layer.registry.keys[code]
		if type(code) ~= "string" or type(resolution) ~= "table" or getmetatable(resolution) ~= nil
			or type(entry) ~= "table" or getmetatable(entry) ~= nil then return nil end
		local kind = rawget(resolution, "kind")
		if kind == "keystroke" then
			local chords = rawget(resolution, "chords")
			if type(chords) ~= "table" or getmetatable(chords) ~= nil then return nil end
			local count = 0
			for index, chord in pairs(chords) do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1
					or type(chord) ~= "table" or getmetatable(chord) ~= nil or type(rawget(chord, "key")) ~= "string"
					or type(rawget(chord, "mods")) ~= "table" or getmetatable(chord.mods) ~= nil then return nil end
				local modifiers = 0
				for item, mod in pairs(chord.mods) do
					if type(item) ~= "number" or item % 1 ~= 0 or item < 1 or type(mod) ~= "string" or HS_MODIFIERS[mod] == nil then return nil end
					modifiers = modifiers + 1
				end
				for item = 1, modifiers do if rawget(chord.mods, item) == nil then return nil end end
				count = count + 1
			end
			if count == 0 then return nil end
			for index = 1, count do if rawget(chords, index) == nil then return nil end end
		elseif kind ~= "none" and kind ~= "call" then return nil end
		if kind == "call" and type(rawget(resolution, "handler")) ~= "string" then return nil end
		local native, compiled
		if entry.kind == "key" then
			local override = rawget(entry, "macos_" .. KEYBOARD_FORM)
			if override ~= nil and (type(override) ~= "table" or getmetatable(override) ~= nil) then return nil end
			native = type(override) == "table" and rawget(override, "hs") or rawget(entry, "hs")
			if type(native) ~= "number" or native ~= native or native % 1 ~= 0 or native < 0 then return nil end
			-- The real rule compiler validates this exact input and its resolution.
			compiled = compiled_input(original_build({ [code] = resolution }, layer.registry))
			if compiled == nil then return nil end
			if not seen[native] then codes[#codes + 1] = native; seen[native] = true end
		end
		inputs[code] = { native = native, compiled = compiled, resolution = layer_ports.format_resolution(resolution) }
	end
	table.sort(codes)
	return inputs, codes
end

--- Loads the navigation layer's bindings from the user's layers.toml.
--- @param opts table|nil { shared_root, config_dir }; each defaults to the driver's own.
--- @return table layer { bindings = key code -> resolution for macOS, registry =
---   physical_keys.json, wheel = M.wheel_slots of the bindings }
function M.load(opts)
	local eligible, sources = source_ports_current(), {}
	local observing = eligible
	local reader = observing and original_read or Writer.read_classified
	local json_decode = observing and original_json or Json.decode
	local toml_decode = observing and original_toml or TomlCodec.decode
	local load_context = observing and layer_ports.load_context or Layers.load_context
	local load_user_file = observing and layer_ports.load_user_file or Layers.load_user_file
	local function rejoin() if not source_ports_current() then eligible = false end end
	local function invoke(port, ...)
		rejoin()
		local result = port(...)
		rejoin()
		return result
	end
	local function remember(path, content, status)
		rejoin()
		sources[#sources + 1] = { path = path, content = content, status = status }
	end
	opts = opts or {}
	local shared_root = opts.shared_root or require("infra.paths").shared_root()
	local config_dir = opts.config_dir or require("infra.config_paths").get_config_dir()
	if type(shared_root) ~= "string" then error("nav_layer: the _shared tree is unreachable", 2) end
	if type(config_dir) ~= "string" then error("nav_layer: the configuration folder is unknown", 2) end
	-- The shipped registry and vocabulary first: a broken copy raises before this
	-- load has started, and the regeneration logs that failure.
	local ctx = invoke(load_context, {
		shared_root = shared_root,
		json_decode = function(text) return invoke(json_decode, text) end,
		toml_decode = function(text) return invoke(toml_decode, text) end,
		read_file = function(path) return read_shipped(path, remember, reader) end,
	})
	Logger.start(LOG, "Loading the navigation layer from '%s'…", config_dir)
	local result = invoke(load_user_file, {
		config_dir  = config_dir,
		os          = OS,
		ctx         = ctx,
		toml_decode = function(text) return invoke(toml_decode, text) end,
		read_file = function(path) return read_user_file(path, remember, reader) end,
	})
	for _, err in ipairs(result.errors) do
		Logger.warn(LOG, "%s: %s (%s) — %s.", result.path, tostring(err.code), error_where(err), tostring(err.detail))
	end
	-- A file rejected as a whole is this load's failure: the error closes the
	-- START, and no SUCCESS may follow it for a layer that binds nothing.
	if not result.ok and next(result.layers) == nil then
		Logger.error(LOG, "'%s' could not be used as a whole: the navigation layer binds no key.", result.path)
		return { bindings = {}, registry = ctx.registry, wheel = M.wheel_slots({}, ctx.registry) }
	end
	for layer_id in pairs(result.layers) do
		if layer_id ~= M.NAV_LAYER_ID then
			Logger.warn(LOG, "Layer '%s' in '%s' has no hold key to activate it on macOS; only '%s' does.",
				layer_id, result.path, M.NAV_LAYER_ID)
		end
	end
	local bindings = result.layers[M.NAV_LAYER_ID] or {}
	local count = 0
	for _ in pairs(bindings) do count = count + 1 end
	local wheel = M.wheel_slots(bindings, ctx.registry)
	Logger.success(LOG, "Navigation layer loaded: %d key(s) bound.", count)
	local layer = { bindings = bindings, registry = ctx.registry, wheel = wheel }
	local observation
	if eligible and source_ports_current() and #sources == 3
		and sources[1].path == NativePath.without_trailing_separators(shared_root) .. "/data/keycodes/physical_keys.json"
		and sources[2].path == NativePath.without_trailing_separators(shared_root) .. "/keymap/layer_actions.toml"
		and sources[3].path == result.path then
		local complete = sources[1].status == "ok" and sources[2].status == "ok"
		for _, source in ipairs(sources) do
			if type(source.path) ~= "string" or not (source.status == "ok" and type(source.content) == "string"
				or source.status == "absent" and source.content == nil) then complete = false end
		end
		local projected, inputs, codes = pcall(project_configured_inputs, layer)
		if complete and projected and inputs ~= nil and eligible and source_ports_current() then
			observation = {}
			source_records[observation] = { layer = layer, sources = sources, inputs = inputs, codes = codes }
		end
	end
	return layer, observation
end

--- Captures the genuine load's configured physical inputs without native authority.
--- The exact bound code, resolution and ISO input projection remain joined to
--- those original registry/vocabulary/user bytes, including explicit None.
--- @param layer table Original first return of load.
--- @param observation table Opaque second return from that same load.
--- @return table|nil inventory Detached codes with current and sealed joins.
function M.capture_configured_inputs(layer, observation)
	local record = source_records[observation]
	if not record or record.layer ~= layer or not source_ports_current() then return nil end
	local inputs, codes = record.inputs, {}
	for index, code in ipairs(record.codes) do codes[index] = code end
	local function sealed()
		if not source_ports_current() or getmetatable(observation) ~= nil or next(observation) ~= nil
			or source_records[observation] ~= record then return false end
		local ok, actual = pcall(project_configured_inputs, layer)
		if not ok or actual == nil or not source_ports_current() then return false end
		for code, item in pairs(inputs) do
			local other = actual[code]
			if not other or other.native ~= item.native or other.compiled ~= item.compiled or other.resolution ~= item.resolution then return false end
		end
		for code in pairs(actual) do if inputs[code] == nil then return false end end
		return true
	end
	local function current()
		if not sealed() then return false end
		for _, source in ipairs(record.sources) do
			local content, status = original_read(source.path)
			if content ~= source.content or status ~= source.status or not sealed() then return false end
		end
		return sealed()
	end
	if not current() then return nil end
	return { codes = codes, current = current, sealed = sealed }
end
original_load, original_build, original_wheel, original_capture = M.load, M.build_rule, M.wheel_slots, M.capture_configured_inputs





-- ===========================================
-- ===========================================
-- ======= 7/ Recommended layer import =======
-- ===========================================
-- ===========================================

--- Whether the shipped recommendation of one of the keys holds the layer.
--- @param key_ids table Key ids of tap_hold_keys.json.
--- @param presets table Key id -> { tap, hold } (platform.remap.defaults tap_hold).
--- @return boolean enters
function M.recommendation_enters_layer(key_ids, presets)
	if type(key_ids) ~= "table" or type(presets) ~= "table" then
		error("nav_layer.recommendation_enters_layer needs the key ids and the presets", 2)
	end
	for _, key_id in ipairs(key_ids) do
		local preset = presets[key_id]
		if type(preset) == "table" and preset[2] == M.HOLD_ACTION_ID then return true end
	end
	return false
end

--- Creates the user's layers.toml from Ergopti's recommended layer when the
--- configuration folder has none; an existing file is kept as it is.
--- @param opts table|nil { shared_root, config_dir, file_adapter }; each defaults to the driver's own.
--- @return table|nil import What keymap.layer_preset.import_if_absent() returned.
--- @return string|nil err Why the absent file could not be created.
--- @return table|nil failed Private refused-import cleanup record.
function M.import_recommended(opts)
	opts = opts or {}
	local shared_root = opts.shared_root or require("infra.paths").shared_root()
	local config_dir = opts.config_dir or require("infra.config_paths").get_config_dir()
	local LayerPreset = require("keymap.layer_preset")
	Logger.start(LOG, "Importing the recommended navigation layer into '%s' when it has none…", tostring(config_dir))
	local ok, import, err, failed = pcall(LayerPreset.import_if_absent, {
		shared_root  = shared_root,
		config_dir   = config_dir,
		toml_decode  = require("toml_codec").decode,
		file_adapter = opts.file_adapter or require("adapters.file_system"),
	})
	if not ok then import, err = nil, tostring(import) end
	if not import then
		Logger.error(LOG, "The recommended navigation layer was not imported: %s.", tostring(err))
		return nil, err, failed
	end
	if import.status == LayerPreset.IMPORTED then
		Logger.success(LOG, "Recommended navigation layer imported into '%s'.", import.path)
	else
		Logger.success(LOG, "'%s' is kept as the user's own layer%s.", import.path,
			import.detail and (" (" .. import.detail .. ")") or "")
	end
	return import
end

--- Removes a layers.toml import_recommended() created, while it holds the preset's bytes.
--- @param import table|nil What import_recommended() returned.
--- @param file_adapter table|nil The adapter it wrote through; the driver's own by default.
--- @return boolean undone
function M.undo_import(import, file_adapter)
	local undone, err = require("keymap.layer_preset").undo(import, file_adapter or require("adapters.file_system"))
	if undone ~= true then
		Logger.error(LOG, "The navigation layer '%s' could not be removed again: %s.",
			tostring(import and import.path), tostring(err))
	end
	return undone == true
end

--- Tells the owner of the layer's wheel bindings, which Hammerspoon runs
--- rather than Karabiner, to read a layers.toml that was just created.
--- @param label string For the logs.
function M.reconcile_wheel(label)
	local reconciled, committed = pcall(function()
		return require("modules.shortcuts.bindings").reconcile_layer_wheel()
	end)
	if not reconciled or committed ~= true then
		Logger.warn(LOG, "%s: the layer's wheel bindings apply with the next Shortcuts start (%s).",
			tostring(label), tostring(reconciled and "a start is in progress" or committed))
	end
end

--- Runs a hold setter with the layer its action enters. A hold on the
--- navigation layer creates the folder's layers.toml from Ergopti's
--- recommended layer when there is none, before the setter saves: a key set
--- to hold the layer in a folder without that file entered a layer that binds
--- no key. An existing file is the user's and stays; a setter that does not
--- save takes the created file back.
--- @param label string For the logs.
--- @param action_id string The hold action being set.
--- @param commit function Saves the hold; returns true once it is committed.
--- @return boolean committed
function M.commit_hold(label, action_id, commit)
	local layer = nil
	if action_id == M.HOLD_ACTION_ID then
		local import, layer_err = M.import_recommended()
		if not import then
			Logger.error(LOG, "%s refused: the recommended navigation layer cannot be imported (%s).",
				tostring(label), tostring(layer_err))
			return false
		end
		layer = import
	end
	local committed = commit()
	if committed ~= true then
		M.undo_import(layer)
		return committed
	end
	if layer and layer.status == require("keymap.layer_preset").IMPORTED then
		M.reconcile_wheel(label)
	end
	return committed
end

return M

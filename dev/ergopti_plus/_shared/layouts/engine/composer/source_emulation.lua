--- _shared/layouts/engine/composer/source_emulation.lua

--- ==============================================================================
--- MODULE: Layout Source Emulation (Shared)
--- DESCRIPTION:
--- Performs the records of an Ergopti layout source that no .keylayout holds:
--- custom modifiers (held or locked, Caps Lock and AltGr included) and the
--- layers they select, key-chord mappings, shortcuts sending another key,
--- tap-holds, remaps of system keys and the dead keys of an emulated layer.
--- It reads the emulation table the one source compiler writes
--- (_shared/ui/layout_composer/source_compiler.js, compileEmulation) and runs
--- on top of the keylayout emulation (layouts/engine/composer/keylayout_emulation.lua): a press
--- it leaves alone goes on to that engine or to the OS. macOS and Linux run it;
--- the web emulation (_shared/ui/layout_composer/source_emulation.js) is its
--- twin, and all of them replay the same vectors
--- (_shared/tests/corpus/layouts/source/emulation_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no driver import, no io, no clock. The caller passes the press
---    time in milliseconds and performs the returned actions in order.
--- 2. TN2056 selection: the first layer whose selector the held modifiers
---    match wins, a required modifier must be held and every held one must be
---    allowed; an unsided id (alt) matches either side, two sides never match.
---    An emulated layer types nothing on a key it does not map, as a keyMap
---    without that key does.
--- 3. Tap-holds follow the shared tap-hold catalogue's typing rule (macOS): a
---    press under a pending key before its threshold types the tap first, a
---    press after it, or the threshold passing (tick), starts the hold. No
---    keystroke is held back or reordered.
--- 4. Fail fast: a table of another format or version, or one naming an
---    undeclared layer or modifier, raises at compile time, never on a key.
--- 5. A dead key of an emulated layer composes with the next key, native layers
---    included (the table's compose_keys), as TN2056 does: a rule's text or
---    next dead key, else the terminator before the key. Its auto-repeat and
---    release type nothing. While AltGr holds a custom modifier, the AltGr the
---    driver reports (alt_right) is that key's, never a level of its own.
--- ==============================================================================

local TableUtil = require("core.text.engine.table_util")
local M = {}

M.FORMAT = "ergopti-layout-emulation"
M.VERSION = 1

-- The built-in modifiers a driver reports, in the order key actions name them.
M.REPORTED = { "shift", "control", "alt", "alt_right", "meta", "caps_lock" }
local REPORTED = {}
for _, id in ipairs(M.REPORTED) do REPORTED[id] = true end

-- The key whose AltGr the driver reports as alt_right.
local ALTGR_KEY = "AltRight"





-- ===============================
-- ===============================
-- ======= 1/ Matching ===========
-- ===============================
-- ===============================

-- The built-in modifiers that have a left and a right key.
local SIDED = { shift = true, control = true, alt = true, meta = true }

--- The modifier family of an id: shift for shift_left and shift_right. A custom
--- id is its own family, whatever its spelling.
local function family(id)
	local base = id:match("^(.-)_left$") or id:match("^(.-)_right$")
	if base ~= nil and SIDED[base] then return base end
	return id
end

--- Whether a selector modifier id stands for a held one.
local function covers(spec, held)
	if spec == held then return true end
	if family(spec) ~= family(held) then return false end
	return family(spec) == spec or family(held) == held
end

--- Whether some id of a list covers a held one.
local function any_covers(list, held)
	for _, spec in ipairs(list) do
		if covers(spec, held) then return true end
	end
	return false
end

--- Whether a selector matches the held modifier ids exactly (TN2056).
--- @param selector table { required = {...}, optional = {...} }
--- @param pressed table Array of held modifier ids.
--- @return boolean
function M.selector_matches(selector, pressed)
	for _, required in ipairs(selector.required) do
		local held = false
		for _, id in ipairs(pressed) do
			if covers(required, id) then held = true; break end
		end
		if not held then return false end
	end
	for _, id in ipairs(pressed) do
		if not any_covers(selector.required, id) and not any_covers(selector.optional, id) then return false end
	end
	return true
end





-- ===============================
-- ===============================
-- ======= 2/ Compilation ========
-- ===============================
-- ===============================

--- Checks one mapping of the table and copies it. A dead key must be one of the
--- table's; a text's compose identity, when it differs from the text, is kept.
--- A repeat key reaches one or two characters back; a magic key names one of
--- the table's magic tables (none given: no magic key is admitted).
local function mapping_of(value, where, dead_keys, magic)
	if type(value) ~= "table" then error("The emulation table holds a malformed mapping at " .. where .. ".") end
	if value["repeat"] == 1 or value["repeat"] == 2 then return { ["repeat"] = value["repeat"] } end
	if type(value.magic) == "string" and magic ~= nil and magic[value.magic] ~= nil then
		return { magic = value.magic }
	end
	if type(value.text) == "string" then
		if value.compose == nil then return { text = value.text } end
		if type(value.compose) ~= "string" then
			error("The emulation table holds a malformed mapping at " .. where .. ".")
		end
		return { text = value.text, compose = value.compose }
	end
	if type(value.key) == "string" then
		local modifiers = {}
		for _, id in ipairs(type(value.modifiers) == "table" and value.modifiers or {}) do
			modifiers[#modifiers + 1] = id
		end
		return { key = value.key, modifiers = modifiers }
	end
	if value.disabled == true then return { disabled = true } end
	if type(value.dead_key) == "string" and dead_keys[value.dead_key] ~= nil then
		return { dead_key = value.dead_key }
	end
	error("The emulation table holds a malformed mapping at " .. where .. ".")
end

--- What a native layer's key answers a pending dead key with: a text, or a
--- dead key of the .keylayout, named whether the table emulates it or not.
local function compose_key_of(value, where, dead_keys)
	if type(value) == "table" and type(value.dead_key) == "string" then return { dead_key = value.dead_key } end
	local mapping = mapping_of(value, where, dead_keys)
	if mapping.text == nil then error("The emulation table holds a malformed mapping at " .. where .. ".") end
	return mapping
end

--- Checks the table's magic keys' tables: each rule types one text after its
--- context; the fallback when no rule's context ends the text typed.
local function magic_of(source)
	if source == nil then return {} end
	if type(source) ~= "table" then error("The emulation table holds malformed magic keys.") end
	local out = {}
	for id, entry in pairs(source) do
		if type(entry) ~= "table" or type(entry.rules) ~= "table" or type(entry.fallback) ~= "string" then
			error("The emulation table holds a malformed magic key at magic." .. tostring(id) .. ".")
		end
		local rules = {}
		for index, rule in ipairs(entry.rules) do
			if type(rule) ~= "table" or type(rule.after) ~= "string" or rule.after == "" or type(rule.types) ~= "string" then
				error("The emulation table holds a malformed rule at magic." .. tostring(id) .. ".rules[" .. index .. "].")
			end
			rules[#rules + 1] = { after = rule.after, types = rule.types }
		end
		out[id] = { rules = rules, fallback = entry.fallback }
	end
	return out
end

-- One UTF-8 code point (the text the drivers pass is valid UTF-8).
local CODE_POINT = "[%z\1-\127\194-\244][\128-\191]*"

--- What a repeat or magic key types after a text: the character `repeat`
--- places back, or the rule whose context is the longest end of the text,
--- else the table's fallback; "" when it types nothing. The definition of
--- _shared/tests/corpus/layouts/magic_vectors.json, as the web engine and the
--- Studio's analysis.
--- @param magic table Magic table id -> { rules = { { after, types } }, fallback }.
--- @param mapping table { repeat = 1|2 } or { magic = id }.
--- @param before string The text typed so far (UTF-8).
--- @return string
function M.context_text(magic, mapping, before)
	if mapping["repeat"] ~= nil then
		local points = {}
		for point in before:sub(-4 * mapping["repeat"]):gmatch(CODE_POINT) do points[#points + 1] = point end
		return points[#points - mapping["repeat"] + 1] or ""
	end
	local table_ = magic[mapping.magic]
	local best = nil
	for _, rule in ipairs(table_.rules) do
		if before:sub(-#rule.after) == rule.after and (best == nil or #rule.after > #best.after) then best = rule end
	end
	if best ~= nil then return best.types end
	return table_.fallback
end

--- Checks the table's dead keys: each rule types a text, leads to a dead key, or both.
local function dead_keys_of(source)
	if source == nil then return {} end
	if type(source) ~= "table" then error("The emulation table holds malformed dead keys.") end
	local function outcomes(rules, where)
		if type(rules) ~= "table" then error("The emulation table holds a malformed dead key at " .. where .. ".") end
		local out = {}
		for input, rule in pairs(rules) do
			local valid = type(rule) == "table" and (rule.text == nil or type(rule.text) == "string")
				and (rule.next == nil or (type(rule.next) == "string" and type(source[rule.next]) == "table"))
				and (rule.text ~= nil or rule.next ~= nil)
			if not valid then
				error("The emulation table holds a malformed dead key at " .. where .. "." .. tostring(input) .. ".")
			end
			out[input] = { text = rule.text, next = rule.next }
		end
		return out
	end
	local dead_keys = {}
	for id, dead in pairs(source) do
		local where = "dead_keys." .. tostring(id)
		if type(id) ~= "string" or type(dead) ~= "table" or type(dead.terminator) ~= "string" then
			error("The emulation table holds a malformed dead key at " .. where .. ".")
		end
		dead_keys[id] = { terminator = dead.terminator, inputs = outcomes(dead.inputs, where .. ".inputs"),
			dead_inputs = outcomes(dead.dead_inputs, where .. ".dead_inputs") }
	end
	return dead_keys
end

--- Copies an array of modifier ids, refusing an undeclared one.
local function ids_of(list, known, where)
	if type(list) ~= "table" then error("The emulation table holds no modifier list at " .. where .. ".") end
	local out = {}
	for _, id in ipairs(list) do
		if type(id) ~= "string" or not known(id) then
			error("The emulation table names the unknown modifier '" .. tostring(id) .. "' at " .. where .. ".")
		end
		out[#out + 1] = id
	end
	return out
end

--- Compiles a decoded emulation table into the lookups the key path walks.
--- @param table_ table The decoded JSON of compileEmulation.
--- @return table model
function M.compile(table_)
	if type(table_) ~= "table" or table_.format ~= M.FORMAT or table_.version ~= M.VERSION then
		error("The layout emulation table is not an " .. M.FORMAT .. " version " .. M.VERSION .. " table.")
	end
	local model = { layout = table_.layout, modifier_keys = {}, custom = {}, layers = {}, layer_by_id = {},
		shortcuts = {}, tap_holds = {}, remaps = {}, dead_keys = dead_keys_of(table_.dead_keys),
		magic = magic_of(table_.magic) }
	for _, modifier in ipairs(table_.modifiers or {}) do
		if type(modifier.id) ~= "string" or (modifier.mode ~= "held" and modifier.mode ~= "locked") then
			error("The emulation table holds a malformed custom modifier.")
		end
		model.custom[modifier.id] = modifier.mode
		for _, key in ipairs(modifier.keys or {}) do
			if model.modifier_keys[key] ~= nil then error("Two custom modifiers share the key " .. key .. ".") end
			model.modifier_keys[key] = { id = modifier.id, mode = modifier.mode }
		end
	end
	-- Kana is a built-in no driver reports: the targets compile its layers to
	-- their native Option/AltGr level, so a selector naming it never matches here.
	local function known(id)
		return REPORTED[id] == true or id == "kana" or model.custom[id] ~= nil or SIDED[family(id)] == true
	end
	for index, layer in ipairs(table_.layers or {}) do
		if type(layer.id) ~= "string" or type(layer.selectors) ~= "table" or type(layer.keys) ~= "table" then
			error("The emulation table holds a malformed layer.")
		end
		local selectors = {}
		for position, selector in ipairs(layer.selectors) do
			local where = "layers[" .. index .. "].selectors[" .. position .. "]"
			selectors[#selectors + 1] = { required = ids_of(selector.required, known, where),
				optional = ids_of(selector.optional, known, where) }
		end
		local keys = {}
		for code, value in pairs(layer.keys) do
			keys[code] = mapping_of(value, "layers." .. layer.id .. "." .. code, model.dead_keys, model.magic)
		end
		if layer.compose_keys ~= nil and type(layer.compose_keys) ~= "table" then
			error("The emulation table holds malformed compose keys at layers." .. layer.id .. ".")
		end
		local compose_keys = {}
		for code, value in pairs(layer.compose_keys or {}) do
			compose_keys[code] = compose_key_of(value, "layers." .. layer.id .. ".compose_keys." .. code, model.dead_keys)
		end
		local compiled = { id = layer.id, native = layer.native == true, selectable = layer.selectable ~= false,
			selectors = selectors, keys = keys, compose_keys = compose_keys }
		model.layers[#model.layers + 1] = compiled
		model.layer_by_id[layer.id] = compiled
	end
	for index, shortcut in ipairs(table_.shortcuts or {}) do
		local where = "shortcuts[" .. index .. "]"
		if type(shortcut.key) ~= "string" or type(shortcut.send_key) ~= "string" then
			error("The emulation table holds a malformed shortcut at " .. where .. ".")
		end
		model.shortcuts[#model.shortcuts + 1] = { key = shortcut.key,
			modifiers = ids_of(shortcut.modifiers, known, where), send_key = shortcut.send_key,
			send_modifiers = ids_of(shortcut.send_modifiers, known, where) }
	end
	for index, entry in ipairs(table_.tap_holds or {}) do
		local where = "tap_holds[" .. index .. "]"
		local threshold = entry.threshold_ms
		-- The delay's declaration in the shared value schema (whole milliseconds
		-- up to the shared tap-hold maximum) guards the emulation's timers.
		local ValueCheck = require("settings.engine.value_check")
		local checked = ValueCheck.check_value(
			ValueCheck.declaration(ValueCheck.KEY.LAYOUT_SOURCE_TAP_HOLDS_THRESHOLD_MS), threshold)
		if type(entry.key) ~= "string" or not checked.ok then
			error("The emulation table holds a malformed tap-hold at " .. where .. " ("
				.. tostring(checked.reason or "no key") .. ").")
		end
		if (entry.hold_layer == nil) == (entry.hold_modifier == nil) then
			error("A tap-hold of the emulation table needs one hold at " .. where .. ".")
		end
		if entry.hold_layer ~= nil and model.layer_by_id[entry.hold_layer] == nil then
			error("A tap-hold holds the unknown layer '" .. tostring(entry.hold_layer) .. "'.")
		end
		if entry.hold_modifier ~= nil and not known(entry.hold_modifier) then
			error("A tap-hold holds the unknown modifier '" .. tostring(entry.hold_modifier) .. "'.")
		end
		if model.tap_holds[entry.key] ~= nil or model.modifier_keys[entry.key] ~= nil then
			error("The key " .. entry.key .. " has two roles in the emulation table.")
		end
		-- A tap's text is chosen at its release, with no text typed before it to read.
		local tap = mapping_of(entry.tap, where .. ".tap", model.dead_keys)
		if tap["repeat"] ~= nil then error("The emulation table holds a malformed mapping at " .. where .. ".tap.") end
		model.tap_holds[entry.key] = { key = entry.key, tap = tap,
			hold_layer = entry.hold_layer, hold_modifier = entry.hold_modifier, threshold_ms = threshold }
	end
	for _, remap in ipairs(table_.remaps or {}) do
		if type(remap.key) ~= "string" or type(remap.to) ~= "string" then
			error("The emulation table holds a malformed remap.")
		end
		model.remaps[remap.key] = remap.to
	end
	return model
end

--- Whether a compiled table does anything a .keylayout does not.
--- @param model table
--- @return boolean
function M.has_records(model)
	if next(model.modifier_keys) ~= nil or next(model.tap_holds) ~= nil or next(model.remaps) ~= nil
		or #model.shortcuts > 0 then return true end
	for _, layer in ipairs(model.layers) do
		if next(layer.keys) ~= nil then return true end
	end
	return false
end

--- Whether the table holds a custom modifier on a key, so the driver's hook
--- takes that key (Caps Lock, AltGr) as a plain key instead of its own role.
--- @param model table
--- @param code string KeyboardEvent.code.
--- @return boolean
function M.holds_modifier_key(model, code)
	return model.modifier_keys[code] ~= nil
end





-- ===============================
-- ===============================
-- ======= 3/ Session ============
-- ===============================
-- ===============================

--- Starts performing a compiled table.
--- @param model table M.compile's model.
--- @return table session
function M.new_session(model)
	if type(model) ~= "table" or type(model.layers) ~= "table" then error("A session needs a compiled table.") end
	return { model = model, active = {}, held_keys = {}, pending = nil, hold = nil, dead = nil }
end

--- Whether the driver reports a built-in modifier held, the AltGr a custom
--- modifier holds left out.
local function reports(session, held, id)
	if type(held) ~= "table" or held[id] ~= true then return false end
	return id ~= "alt_right" or session.held_keys[ALTGR_KEY] ~= "modifier"
end

--- The modifier ids held now: the driver's built-ins, then the active customs.
local function pressed_ids(session, held)
	local pressed = {}
	for _, id in ipairs(M.REPORTED) do
		if reports(session, held, id) then pressed[#pressed + 1] = id end
	end
	for _, id in ipairs(TableUtil.sorted_keys(session.active)) do pressed[#pressed + 1] = id end
	return pressed
end

--- The built-in modifiers a key action keeps from the hand (Caps Lock is a lock).
local function held_modifiers(session, held)
	local out = {}
	for _, id in ipairs(M.REPORTED) do
		if id ~= "caps_lock" and reports(session, held, id) then out[#out + 1] = id end
	end
	return out
end

--- The rule of the pending dead key a mapping answers, nil when none.
local function dead_rule(session, mapping)
	local dead = session.model.dead_keys[session.dead]
	if mapping.dead_key ~= nil then return dead.dead_inputs[mapping.dead_key] end
	if mapping.text == nil then return nil end
	local identity = mapping.compose or mapping.text
	if identity == "" then return nil end
	return dead.inputs[identity]
end

--- Follows a dead-key rule: its text, then the dead key it leads to.
local function follow(session, rule, actions)
	session.dead = rule.next
	if rule.text ~= nil then actions[#actions + 1] = { type = "text", text = rule.text } end
end

--- Ends a pending dead key with its terminator.
local function terminate(session, actions)
	if session.dead == nil then return end
	local terminator = session.model.dead_keys[session.dead].terminator
	session.dead = nil
	if terminator ~= "" then actions[#actions + 1] = { type = "text", text = terminator } end
end

--- The actions of one mapping, composing with a pending dead key.
local function perform(session, mapping, actions)
	if session.dead ~= nil then
		local rule = dead_rule(session, mapping)
		if rule ~= nil then
			follow(session, rule, actions)
			return
		end
		terminate(session, actions)
	end
	if mapping.dead_key ~= nil then
		session.dead = mapping.dead_key
	elseif mapping.text ~= nil then
		actions[#actions + 1] = { type = "text", text = mapping.text }
	elseif mapping.key ~= nil then
		local modifiers = {}
		for _, id in ipairs(mapping.modifiers) do modifiers[#modifiers + 1] = id end
		actions[#actions + 1] = { type = "key", key = mapping.key, modifiers = modifiers }
	end
end

--- Starts the hold of the pending tap-hold.
local function start_hold(session, actions)
	local entry = session.pending.entry
	session.hold = { entry = entry, code = session.pending.code }
	session.pending = nil
	if entry.hold_modifier ~= nil then
		if session.model.custom[entry.hold_modifier] ~= nil then
			session.active[entry.hold_modifier] = true
		else
			actions[#actions + 1] = { type = "modifier", id = entry.hold_modifier, down = true }
		end
	end
end

--- Ends a running hold.
local function end_hold(session, actions)
	local entry = session.hold.entry
	session.hold = nil
	if entry.hold_modifier ~= nil then
		if session.model.custom[entry.hold_modifier] ~= nil then
			session.active[entry.hold_modifier] = nil
		else
			actions[#actions + 1] = { type = "modifier", id = entry.hold_modifier, down = false }
		end
	end
end

--- Settles a pending tap-hold before another key: the tap before its threshold,
--- the hold from it on.
local function settle(session, now, actions)
	local pending = session.pending
	if pending == nil then return end
	if now - pending.at < pending.entry.threshold_ms then
		session.pending = nil
		perform(session, pending.entry.tap, actions)
	else
		start_hold(session, actions)
	end
end

--- The layer a press types on: a running layer hold, else the first match.
local function selected_layer(session, pressed)
	if session.hold ~= nil and session.hold.entry.hold_layer ~= nil then
		return session.model.layer_by_id[session.hold.entry.hold_layer]
	end
	for _, layer in ipairs(session.model.layers) do
		if layer.selectable then
			for _, selector in ipairs(layer.selectors) do
				if M.selector_matches(selector, pressed) then return layer end
			end
		end
	end
	return nil
end

--- Whether a press of `code` matches a shortcut, Caps Lock ignored unless named.
local function shortcut_for(session, code, pressed)
	for _, shortcut in ipairs(session.model.shortcuts) do
		if shortcut.key == code then
			local names_caps = false
			for _, id in ipairs(shortcut.modifiers) do names_caps = names_caps or id == "caps_lock" end
			local chord = {}
			for _, id in ipairs(pressed) do
				if id ~= "caps_lock" or names_caps then chord[#chord + 1] = id end
			end
			if M.selector_matches({ required = shortcut.modifiers, optional = {} }, chord) then return shortcut end
		end
	end
	return nil
end

--- Decides one physical key press (a repeat of a held one included).
--- @param session table
--- @param code string KeyboardEvent.code of the key.
--- @param held table Set of the built-in modifier ids the driver reports held
---   (shift, control, alt, alt_right, meta) and caps_lock when it is on.
--- @param now number Milliseconds of the press, on any monotonic clock.
--- @param before string|nil The text typed so far (the driver's last typed
---   text), which a repeat or magic key reads; required for such a key.
--- @return boolean consumed True when the key itself must not reach the OS or
---   the keylayout emulation.
--- @return table actions Ordered { type = "text", text } | { type = "key", key,
---   modifiers } | { type = "modifier", id, down }.
function M.press(session, code, held, now, before)
	local model = session.model
	local actions = {}
	if session.held_keys[code] ~= nil then return true, actions end
	local modifier = model.modifier_keys[code]
	local tap_hold = model.tap_holds[code]
	if modifier == nil and tap_hold == nil then settle(session, now, actions) end
	if modifier ~= nil then
		session.held_keys[code] = "modifier"
		if modifier.mode == "locked" then
			session.active[modifier.id] = (session.active[modifier.id] == nil) and true or nil
		else
			session.active[modifier.id] = true
		end
		return true, actions
	end
	if tap_hold ~= nil then
		-- A second tap-hold key settles the first, as any other key does.
		settle(session, now, actions)
		session.held_keys[code] = "tap_hold"
		session.pending = { entry = tap_hold, code = code, at = now }
		return true, actions
	end
	local pressed = pressed_ids(session, held)
	local shortcut = shortcut_for(session, code, pressed)
	if shortcut ~= nil then
		terminate(session, actions)
		local modifiers = {}
		for _, id in ipairs(shortcut.send_modifiers) do modifiers[#modifiers + 1] = id end
		actions[#actions + 1] = { type = "key", key = shortcut.send_key, modifiers = modifiers }
		return true, actions
	end
	local remap = model.remaps[code]
	if remap ~= nil then
		terminate(session, actions)
		if remap ~= "" then
			actions[#actions + 1] = { type = "key", key = remap, modifiers = held_modifiers(session, held) }
		end
		return true, actions
	end
	local layer = selected_layer(session, pressed)
	if layer == nil then
		terminate(session, actions)
		return false, actions
	end
	local mapping = layer.keys[code]
	if mapping ~= nil and (mapping["repeat"] ~= nil or mapping.magic ~= nil) then
		if type(before) ~= "string" then error("A repeat or magic key needs the text typed before it.") end
		-- Its text types as a text key would; typing nothing leaves a dead key pending.
		local text = M.context_text(model.magic, mapping, before)
		if text ~= "" then perform(session, { text = text }, actions) end
		return true, actions
	end
	if mapping ~= nil then
		perform(session, mapping, actions)
		-- A dead key's auto-repeat and release are its own: they type nothing.
		if mapping.dead_key ~= nil then session.held_keys[code] = "dead" end
		return true, actions
	end
	-- A pending dead key composes with a native layer's key, else ends with its
	-- terminator and lets the key type as the .keylayout does.
	if session.dead ~= nil then
		local native = layer.compose_keys[code]
		local rule = native ~= nil and dead_rule(session, native) or nil
		if rule ~= nil then
			follow(session, rule, actions)
			if native.dead_key ~= nil then session.held_keys[code] = "dead" end
			return true, actions
		end
		terminate(session, actions)
	end
	-- An emulated layer has no keyMap for the OS to fall back on.
	if not layer.native then return true, actions end
	-- A hold reaching a native layer: no modifier selects it on the OS, so the
	-- key goes out with the modifiers of the layer's first selector.
	if session.hold ~= nil and session.hold.entry.hold_layer == layer.id then
		local sent, modifiers = {}, {}
		for _, id in ipairs(held_modifiers(session, held)) do sent[id] = true end
		for _, id in ipairs(layer.selectors[1].required) do sent[id] = true end
		for _, id in ipairs(M.REPORTED) do
			if sent[id] then modifiers[#modifiers + 1] = id; sent[id] = nil end
		end
		for _, id in ipairs(layer.selectors[1].required) do
			if sent[id] then modifiers[#modifiers + 1] = id; sent[id] = nil end
		end
		actions[#actions + 1] = { type = "key", key = code, modifiers = modifiers }
		return true, actions
	end
	return false, actions
end

--- Decides one physical key release.
--- @param session table
--- @param code string KeyboardEvent.code.
--- @param now number Milliseconds of the release.
--- @return boolean consumed True when the press was the engine's (swallow the release).
--- @return table actions As M.press.
function M.release(session, code, now)
	local actions = {}
	local role = session.held_keys[code]
	if role == nil then return false, actions end
	session.held_keys[code] = nil
	if role == "modifier" then
		local modifier = session.model.modifier_keys[code]
		if modifier.mode == "held" then session.active[modifier.id] = nil end
		return true, actions
	end
	if session.pending ~= nil and session.pending.code == code then
		local pending = session.pending
		session.pending = nil
		if now - pending.at < pending.entry.threshold_ms then perform(session, pending.entry.tap, actions) end
		return true, actions
	end
	if session.hold ~= nil and session.hold.code == code then end_hold(session, actions) end
	return true, actions
end

--- Starts the hold of a pending tap-hold whose threshold has passed, so a held
--- modifier is down before any key (a click) comes under it.
--- @param session table
--- @param now number Milliseconds now.
--- @return table actions As M.press.
function M.tick(session, now)
	local actions = {}
	local pending = session.pending
	if pending ~= nil and now - pending.at >= pending.entry.threshold_ms then start_hold(session, actions) end
	return actions
end

--- Drops every pending and held state (stop, pause, reload), releasing a held
--- built-in modifier the engine pressed.
--- @param session table
--- @return table actions As M.press.
function M.reset(session)
	local actions = {}
	if session.hold ~= nil then end_hold(session, actions) end
	session.pending, session.hold, session.held_keys, session.active, session.dead = nil, nil, {}, {}, nil
	return actions
end

--- Whether a custom modifier is active, for a menu or a test.
--- @param session table
--- @param id string
--- @return boolean
function M.active(session, id)
	return session.active[id] == true
end

return M

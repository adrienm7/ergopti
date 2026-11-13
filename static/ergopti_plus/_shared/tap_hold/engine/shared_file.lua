--- _shared/tap_hold/engine/shared_file.lua

--- ==============================================================================
--- MODULE: Shared Tap-Hold File (shared)
--- DESCRIPTION:
--- The one tap_hold.toml every driver keeps its tap-hold keys in
--- (_shared/tap_hold/data/SCHEMA.md): the keys, the global delay and, on macOS, the
--- Karabiner integration; and the config.toml rows beside it that hold the
--- manifest's tap-hold rows (`[tap_holds]` enabled, sticky_timeout_ms,
--- lone_modifier_tap_max_ms and the whole `[mod_combos]`, the maintainer
--- decision of 2026-11-11). This module translates both to and from the
--- Karabiner model macos/keyboard/engine/runtime/config.lua merges (the shape
--- config_karabiner.toml had: `[tap_holds]`, `[tap_holds.config.<macOS key>]`,
--- `[mod_combos.config.<macOS combination>]`), and converts an old
--- config_karabiner.toml once.
---
--- FEATURES & RATIONALE:
--- 1. One vocabulary on disk. Keys are catalogue ids ([tap_hold.catalog]), a
---    combination is `<first>_then_<second>` over them, a hold is a modifier
---    set, a layer or (macOS only) another action, a delay is in seconds: the
---    spelling Linux and Windows already read. macOS spellings never reach the
---    file.
--- 2. A driver writes only what it changed. M.apply_karabiner() compares the
---    model a save started from with the one it ends with and writes the
---    leaves that differ, so a key, a field or a spelling macOS does not know
---    (a Linux-only key, `inherit_defaults`, "Ctrl + Shift") survives a macOS
---    save untouched.
--- 3. Pure: no I/O. Arrays and scalars found where a table belongs are handed
---    to the model by reference, so the model's own shape receipt still
---    recognises them and keeps reporting them as outdated.
--- 4. Fail fast on shipped data: a catalogue key or combination the context
---    cannot place raises, never a guess.
--- 5. One home per row. A config-owned leaf left in tap_hold.toml (by a build
---    before schema v22, or a crash between the v22 migration's two writes) is
---    reported as outdated and left where it is, never read; only the one-time
---    config_karabiner.toml import writes them there, so the boot's v22
---    migration (_shared/settings/data/config_schema/migrations.toml) moves them.
--- ==============================================================================

local M = {}

local ConfigKeys = require("settings.engine.keys")
local KeyCombinations = require("tap_hold.engine.key_combinations")

local LEAF = ConfigKeys.LEAF

--- The file's name in a driver's configuration folder (shared_file.toml [layout]).
M.FILE_NAME = "tap_hold.toml"
--- The sections the file holds (shared_file.toml [layout]).
M.TAP_HOLD = "tap_hold"
M.COMBOS = LEAF.MOD_COMBOS
M.KARABINER = "karabiner"
M.META = "_meta"

-- The model's own section names (macos/keyboard/engine/runtime/config.lua).
local MODEL_TAP_HOLDS = LEAF.TAP_HOLDS
local MODEL_COMBOS = LEAF.MOD_COMBOS
local MODEL_KARABINER = "karabiner"

-- The section leaves whose name and value are the same in the file and in the model.
local SAME_TAP_HOLD_LEAVES = { "enabled", LEAF.STICKY_TIMEOUT_MS, LEAF.LONE_MODIFIER_TAP_MAX_MS }
local SAME_COMBO_LEAVES = { "enabled", LEAF.SIMULTANEOUS_THRESHOLD_MS, "symmetric" }
local COMBO_SLOTS = { "combo", "tap", "hold" }
local HOLD_FIELDS = { "hold_modifier", "hold_layer", "hold_action" }
local NONE = "none"

-- Every field of a shared key entry this translation owns.
local KEY_FIELDS = { tap_action = true, hold_modifier = true, hold_layer = true, hold_action = true,
	time_activation_seconds = true, enabled = true }
-- The model's own fields of a key binding, which only the translation sets.
local MODEL_KEY_FIELDS = { tap = true, hold = true, timeout_ms = true }
-- The slots of a key combination, the same in the file and in the model.
local SLOT_FIELDS = { combo = true, tap = true, hold = true }
-- The owned fields of the sections, in the file and in the model.
local TAP_HOLD_FIELDS = { enabled = true, inherit_defaults = true, time_activation_seconds = true,
	sticky_timeout_ms = true, lone_modifier_tap_max_ms = true, keys = true }
local MODEL_TAP_HOLD_FIELDS = { enabled = true, timeout_ms = true, sticky_timeout_ms = true,
	lone_modifier_tap_max_ms = true, config = true }
local COMBO_FIELDS = { enabled = true, simultaneous_threshold_ms = true, symmetric = true, config = true }

-- Why a config-owned leaf found in tap_hold.toml is not read.
local MOVED_TO_CONFIG = "kept in config.toml since schema v22; this copy is not read"

-- An opaque leaf: a scalar or array found where the model expects a table.
local OPAQUE = {}




-- =================================
-- =================================
-- ======= 1/ Specification ========
-- =================================
-- =================================

--- Validates the decoded _shared/tap_hold/data/shared_file.toml.
--- @param decoded table
--- @return table spec `{ order = { names }, rank = { name = index }, hs_names, hs_hold_actions }`.
function M.parse_spec(decoded)
	local layout = type(decoded) == "table" and decoded.layout
	if type(layout) ~= "table" or layout.file_name ~= M.FILE_NAME
		or layout.tap_hold_section ~= M.TAP_HOLD or layout.combos_section ~= M.COMBOS
		or layout.karabiner_section ~= M.KARABINER or layout.meta_section ~= M.META then
		error("shared tap-hold file spec: [layout] does not name the sections this reader writes", 0)
	end
	local modifiers = decoded.modifiers
	if type(modifiers) ~= "table" or type(modifiers.order) ~= "table" or #modifiers.order == 0 then
		error("shared tap-hold file spec: [modifiers] needs an order", 0)
	end
	local rank = {}
	for index, name in ipairs(modifiers.order) do
		if type(name) ~= "string" or name == "" or rank[name] then
			error("shared tap-hold file spec: [modifiers] order needs distinct names", 0)
		end
		rank[name] = index
	end
	for _, field in ipairs({ "hs_names", "hs_hold_actions" }) do
		if type(modifiers[field]) ~= "table" then error("shared tap-hold file spec: [modifiers] needs " .. field, 0) end
		for from, to in pairs(modifiers[field]) do
			if type(from) ~= "string" or not rank[to] then
				error(string.format("shared tap-hold file spec: [modifiers] %s.%s names no modifier", field, tostring(from)), 0)
			end
		end
	end
	local positions = decoded.thumb_positions
	if type(positions) ~= "table" then error("shared tap-hold file spec: [thumb_positions] is missing", 0) end
	local placed = {}
	for from, to in pairs(positions) do
		if type(from) ~= "string" or type(to) ~= "string" or from == to or placed[to] then
			error("shared tap-hold file spec: [thumb_positions] maps distinct key ids to distinct key ids", 0)
		end
		placed[to] = true
	end
	return { order = modifiers.order, rank = rank, hs_names = modifiers.hs_names,
		hs_hold_actions = modifiers.hs_hold_actions, thumb_positions = positions }
end

--- The positional key a Mac thumb key id names (spec [thumb_positions]), or
--- the id itself: what every driver reads a file's key entry as.
--- @param spec table See M.parse_spec.
--- @param key_id string A catalogue id.
--- @return string key_id
function M.positional_key(spec, key_id)
	return spec.thumb_positions[key_id] or key_id
end

--- The canonical spelling of a hold modifier: its modifiers, lower case,
--- without blanks, joined with "+" in the spec order.
--- @param spec table See M.parse_spec.
--- @param value string What the file holds ("Ctrl + Shift", "shift+ctrl").
--- @param aliases table|nil Spelling -> modifier name ([tap_hold.hold_picker] aliases).
--- @return string|nil canonical Nil when a part names no modifier.
function M.canonical_modifier(spec, value, aliases)
	local parts, seen = {}, {}
	for raw in (value .. "+"):gmatch("([^+]*)%+") do
		local part = raw:lower():gsub("%s", "")
		part = (aliases and aliases[part]) or part
		if not spec.rank[part] then return nil end
		if not seen[part] then seen[part], parts[#parts + 1] = true, part end
	end
	if #parts == 0 then return nil end
	table.sort(parts, function(left, right) return spec.rank[left] < spec.rank[right] end)
	return table.concat(parts, "+")
end




-- =================================
-- =================================
-- ======= 2/ macOS context ========
-- =================================
-- =================================

--- Builds the macOS translation context from shipped data.
--- @param spec table See M.parse_spec.
--- @param data table `{ catalogue = KeyCatalog.for_platform(defaults, "hs"),
---   catalogue_ids = { every [tap_hold.catalog] id },
---   tap_hold_keys = data/tap_hold_keys.json, mod_combos = data/mod_combos.json,
---   actions = data/actions.json, aliases = table|nil,
---   spellings = table|nil }`; `spellings` maps a macOS action id to the PC id
---   the file holds for it (the action catalogue's `tap_hold_spellings`).
--- @return table context
function M.hs_context(spec, data)
	assert(type(data) == "table", "the macOS tap-hold file context needs its data")
	assert(type(data.catalogue_ids) == "table", "the macOS tap-hold file context needs every catalogue id")
	local catalogue_ids = {}
	for _, id in ipairs(data.catalogue_ids) do catalogue_ids[id] = true end
	local key_of_hs, hs_of_key = {}, {}
	-- A Mac thumb key is written under the PC key at its place; its own id is
	-- still read, below the positional one (M.positional_key).
	for _, entry in ipairs(data.catalogue) do
		local positional = M.positional_key(spec, entry.key)
		if positional ~= entry.key and not catalogue_ids[positional] then
			error("[thumb_positions] places '" .. entry.key .. "' on '" .. positional .. "', which is no catalogue key", 0)
		end
		key_of_hs[entry.id], hs_of_key[positional] = positional, entry.id
		if positional ~= entry.key then hs_of_key[entry.key] = entry.id end
	end
	-- The spellings of the actions macOS names under another id than the PC.
	local shared_of_action, hs_of_action = {}, {}
	for hs, shared in pairs(data.spellings or {}) do
		if hs_of_action[shared] ~= nil then error("two macOS actions are spelled '" .. shared .. "' in the file", 0) end
		shared_of_action[hs], hs_of_action[shared] = shared, hs
	end
	-- A combination names its keys by key code; a tap-hold key binds one.
	local hs_of_code = {}
	for _, def in ipairs(data.tap_hold_keys) do
		local code = type(def.from) == "table" and def.from.key_code
		if type(code) ~= "string" then error("macOS tap-hold key '" .. tostring(def.id) .. "' binds no key code", 0) end
		hs_of_code[code] = def.id
	end
	local pair_of_combo, combo_of_pair = {}, {}
	for _, def in ipairs(data.mod_combos) do
		local keys = type(def.from) == "table" and def.from.simultaneous
		if type(keys) ~= "table" or #keys ~= 2 then
			error("macOS key combination '" .. tostring(def.id) .. "' is not two simultaneous keys", 0)
		end
		local ids = {}
		for index, key in ipairs(keys) do
			local hs = hs_of_code[key.key_code]
			ids[index] = hs and key_of_hs[hs]
			if not ids[index] then
				error(string.format("macOS key combination '%s' names key '%s', which no catalogue key binds",
					tostring(def.id), tostring(key.key_code)), 0)
			end
		end
		local pair = KeyCombinations.pair(ids[1], ids[2])
		pair_of_combo[def.id], combo_of_pair[pair] = pair, def.id
	end
	-- What each holdable action holds, and the action that holds each thing.
	local hold_of_action, action_of_modifier, action_of_layer = {}, {}, {}
	for _, action in ipairs(data.actions) do
		local id = action.id
		if type(action.hold_layer) == "string" then
			hold_of_action[id] = { field = "hold_layer", value = action.hold_layer }
			action_of_layer[action.hold_layer] = action_of_layer[action.hold_layer] or id
		elseif type(action.modifiers) == "table" or spec.hs_hold_actions[id] then
			local names = {}
			for _, name in ipairs(type(action.modifiers) == "table" and action.modifiers or {}) do
				local shared = spec.hs_names[name]
				if not shared then error("macOS action '" .. id .. "' holds modifier '" .. tostring(name) .. "', which the spec does not name", 0) end
				names[#names + 1] = shared
			end
			if spec.hs_hold_actions[id] then names[#names + 1] = spec.hs_hold_actions[id] end
			local modifier = M.canonical_modifier(spec, table.concat(names, "+"))
			hold_of_action[id] = { field = "hold_modifier", value = modifier }
			action_of_modifier[modifier] = action_of_modifier[modifier] or id
		end
	end
	return { spec = spec, catalogue_ids = catalogue_ids, key_of_hs = key_of_hs, hs_of_key = hs_of_key, pair_of_combo = pair_of_combo,
		combo_of_pair = combo_of_pair, hold_of_action = hold_of_action, action_of_modifier = action_of_modifier,
		action_of_layer = action_of_layer, aliases = data.aliases, shared_of_action = shared_of_action,
		hs_of_action = hs_of_action }
end

--- The macOS action id an action the file holds names.
--- @param ctx table See M.hs_context.
--- @param value any
--- @return any
local function action_to_model(ctx, value)
	return type(value) == "string" and ctx.hs_of_action[value] or value
end

--- The id the file holds for a macOS action id.
--- @param ctx table See M.hs_context.
--- @param value any
--- @return any
local function action_to_file(ctx, value)
	return type(value) == "string" and ctx.shared_of_action[value] or value
end




-- =================================
-- =================================
-- ======= 3/ File -> model ========
-- =================================
-- =================================

--- Milliseconds of a delay in seconds; a non-number is handed on as it is so
--- the model reports it.
local function to_ms(seconds)
	if type(seconds) ~= "number" then return seconds end
	local ms = seconds * 1000
	local whole = math.floor(ms + 0.5)
	if math.abs(ms - whole) < 1e-6 then return whole end
	return ms
end

--- The model binding of one shared key entry.
--- @return table entry, table notes
local function key_to_model(entry, ctx, where, notes)
	local model = {}
	-- A field no driver owns rides along, so the model keeps it as it did.
	for field, value in pairs(entry) do
		if not KEY_FIELDS[field] and not MODEL_KEY_FIELDS[field] then model[field] = value end
	end
	-- A key switched off on another driver binds nothing here either.
	if entry.enabled == false then return model end
	local tap = entry.tap_action
	if type(tap) == "string" then
		if tap ~= "" then model.tap = action_to_model(ctx, tap) end
	elseif tap ~= nil then
		notes[#notes + 1] = { path = where .. ".tap_action", detail = "a tap is an action id" }
	end
	if entry.hold_action ~= nil then
		if type(entry.hold_action) == "string" and entry.hold_action ~= "" then
			model.hold = action_to_model(ctx, entry.hold_action)
		else
			notes[#notes + 1] = { path = where .. ".hold_action", detail = "a hold action is an action id" }
		end
	elseif type(entry.hold_layer) == "string" and entry.hold_layer ~= "" then
		model.hold = ctx.action_of_layer[entry.hold_layer]
		if not model.hold then
			notes[#notes + 1] = { path = where .. ".hold_layer", detail = "macOS has no hold for layer '" .. entry.hold_layer .. "'" }
		end
	elseif type(entry.hold_modifier) == "string" and entry.hold_modifier ~= "" then
		local canonical = M.canonical_modifier(ctx.spec, entry.hold_modifier, ctx.aliases)
		model.hold = canonical and ctx.action_of_modifier[canonical]
		if not model.hold then
			notes[#notes + 1] = { path = where .. ".hold_modifier",
				detail = "macOS has no hold for '" .. entry.hold_modifier .. "'; the key holds nothing" }
		end
	end
	if entry.time_activation_seconds ~= nil then model.timeout_ms = to_ms(entry.time_activation_seconds) end
	return model
end

--- The Karabiner model of a decoded shared file. Sections the model does not
--- own are handed on by reference, so a save keeps them.
--- @param document table Decoded tap_hold.toml.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean Whether a value is a table, not an array.
--- @return table model The config_karabiner.toml shape.
--- @return table notes `{ path, detail }` for each leaf macOS cannot run.
function M.to_karabiner(document, ctx, is_table)
	local model, notes = {}, {}
	-- Other sections ride along by reference; a stray model-named one
	-- (`[tap_holds]` pasted from an old file) stays in the file, unread.
	for key, value in pairs(document) do
		if key ~= M.TAP_HOLD and key ~= M.COMBOS and key ~= M.KARABINER and key ~= MODEL_TAP_HOLDS then
			model[key] = value
		end
	end
	model[MODEL_KARABINER] = document[M.KARABINER]
	local section = document[M.TAP_HOLD]
	if section ~= nil and not is_table(section) then
		model[MODEL_TAP_HOLDS] = section
	elseif section ~= nil then
		local tap_holds = {}
		for field, value in pairs(section) do
			if not TAP_HOLD_FIELDS[field] and not MODEL_TAP_HOLD_FIELDS[field] then tap_holds[field] = value end
		end
		for _, leaf in ipairs(SAME_TAP_HOLD_LEAVES) do
			if section[leaf] ~= nil then notes[#notes + 1] = { path = M.TAP_HOLD .. "." .. leaf, detail = MOVED_TO_CONFIG } end
		end
		if section.time_activation_seconds ~= nil then tap_holds.timeout_ms = to_ms(section.time_activation_seconds) end
		local keys = section.keys
		if keys ~= nil and not is_table(keys) then
			tap_holds.config = keys
		elseif keys ~= nil then
			local config = {}
			for key_id, entry in pairs(keys) do
				local hs = ctx.hs_of_key[key_id]
				local positional = type(key_id) == "string" and M.positional_key(ctx.spec, key_id) or key_id
				-- A key another driver has is theirs; one no driver has is named.
				if not ctx.catalogue_ids[key_id] then
					notes[#notes + 1] = { path = M.TAP_HOLD .. ".keys." .. tostring(key_id), detail = "no driver has this tap-hold key" }
				elseif positional ~= key_id and keys[positional] ~= nil then
					notes[#notes + 1] = { path = M.TAP_HOLD .. ".keys." .. key_id,
						detail = "the key at its place, '" .. positional .. "', is read instead" }
				elseif hs then
					config[hs] = is_table(entry) and key_to_model(entry, ctx, M.TAP_HOLD .. ".keys." .. key_id, notes) or entry
				end
			end
			tap_holds.config = config
		end
		model[MODEL_TAP_HOLDS] = tap_holds
	end
	if document[M.COMBOS] ~= nil then notes[#notes + 1] = { path = M.COMBOS, detail = MOVED_TO_CONFIG } end
	return model, notes
end




-- =================================
-- =================================
-- ======= 4/ Model -> file ========
-- =================================
-- =================================

--- Flattens a model into shared leaf paths. A hold is one group: changing it
--- rewrites all three hold fields. A scalar or array where a table belongs is
--- one opaque leaf at that path.
--- @param model table
--- @param ctx table
--- @param is_table function
--- @param with_config boolean Whether the config-owned leaves go into the
---   file too (the one-time config_karabiner.toml import only).
--- @return table leaves `path -> value`, `holds` `key path -> { field, value }|false`
local function flatten(model, ctx, is_table, with_config)
	local leaves, holds = {}, {}
	local function opaque(path, value)
		leaves[path] = { [OPAQUE] = value }
	end
	-- A field no driver owns rides along as it is.
	local function carry(base, entry, model_fields, file_fields)
		for field, value in pairs(entry) do
			if not model_fields[field] and not file_fields[field] then opaque(base .. "." .. field, value) end
		end
	end
	local tap_holds = model[MODEL_TAP_HOLDS]
	if tap_holds ~= nil and not is_table(tap_holds) then
		opaque(M.TAP_HOLD, tap_holds)
	elseif tap_holds ~= nil then
		carry(M.TAP_HOLD, tap_holds, MODEL_TAP_HOLD_FIELDS, TAP_HOLD_FIELDS)
		if with_config then
			for _, leaf in ipairs(SAME_TAP_HOLD_LEAVES) do leaves[M.TAP_HOLD .. "." .. leaf] = tap_holds[leaf] end
		end
		if tap_holds.timeout_ms ~= nil then
			leaves[M.TAP_HOLD .. ".time_activation_seconds"] = type(tap_holds.timeout_ms) == "number"
				and tap_holds.timeout_ms / 1000 or tap_holds.timeout_ms
		end
		local config = tap_holds.config
		if config ~= nil and not is_table(config) then
			opaque(M.TAP_HOLD .. ".keys", config)
		elseif config ~= nil then
			for hs, entry in pairs(config) do
				local key_id = ctx.key_of_hs[hs]
				if not key_id then error("macOS tap-hold key '" .. tostring(hs) .. "' has no catalogue id", 0) end
				local base = M.TAP_HOLD .. ".keys." .. key_id
				if not is_table(entry) then
					opaque(base, entry)
				else
					carry(base, entry, MODEL_KEY_FIELDS, KEY_FIELDS)
					leaves[base .. ".tap_action"] = entry.tap ~= NONE and action_to_file(ctx, entry.tap) or nil
					if entry.timeout_ms ~= nil then
						leaves[base .. ".time_activation_seconds"] = type(entry.timeout_ms) == "number"
							and entry.timeout_ms / 1000 or entry.timeout_ms
					end
					local hold = entry.hold
					if hold == nil or hold == NONE then
						holds[base] = false
					else
						holds[base] = ctx.hold_of_action[hold] or { field = "hold_action", value = action_to_file(ctx, hold) }
					end
				end
			end
		end
	end
	local combos = with_config and model[MODEL_COMBOS] or nil
	if combos ~= nil and not is_table(combos) then
		opaque(M.COMBOS, combos)
	elseif combos ~= nil then
		carry(M.COMBOS, combos, COMBO_FIELDS, COMBO_FIELDS)
		for _, leaf in ipairs(SAME_COMBO_LEAVES) do leaves[M.COMBOS .. "." .. leaf] = combos[leaf] end
		local config = combos.config
		if config ~= nil and not is_table(config) then
			opaque(M.COMBOS .. ".config", config)
		elseif config ~= nil then
			for combo, entry in pairs(config) do
				local pair = ctx.pair_of_combo[combo]
				if not pair then error("macOS key combination '" .. tostring(combo) .. "' has no pair id", 0) end
				local base = M.COMBOS .. ".config." .. pair
				if not is_table(entry) then
					opaque(base, entry)
				else
					carry(base, entry, SLOT_FIELDS, SLOT_FIELDS)
					for _, slot in ipairs(COMBO_SLOTS) do
						leaves[base .. "." .. slot] = entry[slot] ~= NONE and action_to_file(ctx, entry[slot]) or nil
					end
				end
			end
		end
	end
	return leaves, holds
end

--- Splits a dotted path into its segments.
local function segments_of(path)
	local out = {}
	for segment in path:gmatch("[^%.]+") do out[#out + 1] = segment end
	return out
end

--- Sets or deletes one leaf of the shared document, creating tables on the
--- way and pruning the ones a deletion leaves empty.
local function set_leaf(document, path, value, is_table)
	local segments = segments_of(path)
	local node, chain = document, {}
	for index = 1, #segments - 1 do
		local segment = segments[index]
		if value == nil and not is_table(node[segment]) then return end
		if node[segment] == nil or not is_table(node[segment]) then node[segment] = {} end
		chain[#chain + 1] = { parent = node, key = segment }
		node = node[segment]
	end
	node[segments[#segments]] = value
	if value ~= nil then return end
	for index = #chain, 1, -1 do
		local link = chain[index]
		if next(link.parent[link.key]) == nil then link.parent[link.key] = nil else return end
	end
end

--- Whether two flattened values are the same leaf value. Numbers compare by
--- kind and sign too: a user who turns 0.0 into 0, or -0.0 into 0.0, changed it.
local function same(left, right)
	if type(left) == "table" and type(right) == "table" and left[OPAQUE] ~= nil and right[OPAQUE] ~= nil then
		return left[OPAQUE] == right[OPAQUE]
	end
	if type(left) == "number" and type(right) == "number" then
		local kind = math.type or function() return nil end
		return left == right and kind(left) == kind(right) and (left ~= 0 or 1 / left == 1 / right)
	end
	return left == right
end

--- Writes into a decoded shared file the leaves a save of the model changed.
--- @param document table Decoded tap_hold.toml, edited in place.
--- @param before table The model M.to_karabiner() returned for it (not edited since).
--- @param after table The model the save produced.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean For the document and both models.
--- @param with_config boolean|nil True only for the one-time config_karabiner.toml
---   import: the config-owned leaves (see M.config_rows) are written too.
function M.apply_karabiner(document, before, after, ctx, is_table, with_config)
	if before[MODEL_KARABINER] ~= after[MODEL_KARABINER] then document[M.KARABINER] = after[MODEL_KARABINER] end
	local old_leaves, old_holds = flatten(before, ctx, is_table, with_config == true)
	local new_leaves, new_holds = flatten(after, ctx, is_table, with_config == true)
	local changes = {}
	local function compare(path, left, right)
		if not same(left, right) then changes[#changes + 1] = { path = path, value = right } end
	end
	for path, value in pairs(new_leaves) do compare(path, old_leaves[path], value) end
	for path, value in pairs(old_leaves) do if new_leaves[path] == nil then compare(path, value, nil) end end
	-- A file laid over the shipped keys reads an absent tap or hold as the
	-- shipped one on Windows and Linux, so a tap or hold macOS clears is
	-- written as nothing: tap "none", hold "" (SCHEMA.md).
	local section = document[M.TAP_HOLD]
	local inherit = is_table(section) and section.inherit_defaults == true
	if inherit then
		for _, change in ipairs(changes) do
			if change.value == nil and change.path:match("^" .. M.TAP_HOLD .. "%.keys%.[^%.]+%.tap_action$") then
				change.value = NONE
			end
		end
	end
	local function hold_of(holds, path)
		local hold = holds[path]
		if hold == nil or hold == false then return nil end
		return hold.field .. "=" .. tostring(hold.value)
	end
	local hold_paths = {}
	for path in pairs(new_holds) do hold_paths[path] = true end
	for path in pairs(old_holds) do hold_paths[path] = true end
	for path in pairs(hold_paths) do
		if hold_of(old_holds, path) ~= hold_of(new_holds, path) then
			for _, field in ipairs(HOLD_FIELDS) do changes[#changes + 1] = { path = path .. "." .. field } end
			local hold = new_holds[path]
			if hold then
				changes[#changes + 1] = { path = path .. "." .. hold.field, value = hold.value, last = true }
			elseif inherit then
				changes[#changes + 1] = { path = path .. ".hold_modifier", value = "", last = true }
			end
		end
	end
	-- A key macOS rebinds is switched back on: the user just chose what it does.
	local rebound = {}
	for _, change in ipairs(changes) do
		local base = change.path:match("^(" .. M.TAP_HOLD .. "%.keys%.[^%.]+)%.")
		if base and not rebound[base] then
			rebound[base] = true
			changes[#changes + 1] = { path = base .. ".enabled" }
		end
	end
	-- Shorter paths first, so an opaque leaf a repair replaces goes before its
	-- new fields arrive; a hold's new field after its group was cleared.
	table.sort(changes, function(left, right)
		if (left.last == true) ~= (right.last == true) then return not left.last end
		local depth_left, depth_right = #segments_of(left.path), #segments_of(right.path)
		if depth_left ~= depth_right then return depth_left < depth_right end
		return left.path < right.path
	end)
	for _, change in ipairs(changes) do
		local value = change.value
		if type(value) == "table" and value[OPAQUE] ~= nil then value = value[OPAQUE] end
		set_leaf(document, change.path, value, is_table)
	end
end

--- Removes from a shared file everything a macOS reset replaces: the
--- Karabiner section, macOS's section leaves, every key and combination macOS
--- has and every one no driver has. Other drivers' keys, combinations, fields
--- and sections stay.
--- @param document table Decoded shared file, edited in place.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean
function M.drop_karabiner_owned(document, ctx, is_table)
	document[M.KARABINER] = nil
	local section = document[M.TAP_HOLD]
	if section ~= nil and not is_table(section) then
		document[M.TAP_HOLD] = nil
	elseif section ~= nil then
		for _, leaf in ipairs(SAME_TAP_HOLD_LEAVES) do section[leaf] = nil end
		section.time_activation_seconds = nil
		if section.keys ~= nil and not is_table(section.keys) then section.keys = nil end
		for key_id in pairs(section.keys or {}) do
			if ctx.hs_of_key[key_id] or not ctx.catalogue_ids[key_id] then section.keys[key_id] = nil end
		end
		if section.keys and next(section.keys) == nil then section.keys = nil end
		if next(section) == nil then document[M.TAP_HOLD] = nil end
	end
	local combos = document[M.COMBOS]
	if combos ~= nil and not is_table(combos) then
		document[M.COMBOS] = nil
	elseif combos ~= nil then
		for _, leaf in ipairs(SAME_COMBO_LEAVES) do combos[leaf] = nil end
		if combos.config ~= nil and not is_table(combos.config) then combos.config = nil end
		for pair in pairs(combos.config or {}) do
			local first, second = tostring(pair):match("^(.-)" .. KeyCombinations.PAIR_SEPARATOR .. "(.+)$")
			local foreign = first and ctx.catalogue_ids[first] and ctx.catalogue_ids[second]
			if ctx.combo_of_pair[pair] or not foreign then combos.config[pair] = nil end
		end
		if combos.config and next(combos.config) == nil then combos.config = nil end
		if next(combos) == nil then document[M.COMBOS] = nil end
	end
end

--- The file path of a model path, for a warning that names the leaf where the
--- user finds it: `tap_holds.config.left_control.hold` is
--- `tap_hold.keys.left_ctrl.hold_modifier`.
--- @param segments table Model path segments.
--- @param ctx table See M.hs_context.
--- @return table segments File path segments.
function M.file_segments(segments, ctx)
	local out = {}
	for index, segment in ipairs(segments) do out[index] = segment end
	local section = out[1]
	if section == MODEL_TAP_HOLDS then
		out[1] = M.TAP_HOLD
		if out[2] == "config" then
			out[2] = "keys"
			if out[3] ~= nil then out[3] = ctx.key_of_hs[out[3]] or out[3] end
			local field = { tap = "tap_action", hold = "hold_modifier", timeout_ms = LEAF.TIME_ACTIVATION_SECONDS }
			if out[4] ~= nil then out[4] = field[out[4]] or out[4] end
		elseif out[2] == "timeout_ms" then
			out[2] = LEAF.TIME_ACTIVATION_SECONDS
		end
	elseif section == MODEL_COMBOS and out[2] == "config" and out[3] ~= nil then
		out[3] = ctx.pair_of_combo[out[3]] or out[3]
	end
	return out
end

--- The shared document a model becomes over no file.
local function new_document(model, ctx, is_table, with_config)
	local document = {}
	for key, value in pairs(model) do
		if key ~= MODEL_TAP_HOLDS and key ~= MODEL_COMBOS and key ~= MODEL_KARABINER then document[key] = value end
	end
	M.apply_karabiner(document, {}, model, ctx, is_table, with_config)
	return document
end

--- The shared file an old config_karabiner.toml becomes, config-owned leaves
--- included: the boot's v22 config migration moves those into config.toml.
--- @param model table Decoded config_karabiner.toml.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean For the old document.
--- @return table document The shared tap_hold.toml content, unstamped.
function M.from_karabiner(model, ctx, is_table)
	return new_document(model, ctx, is_table, true)
end

--- The tap_hold.toml a save over no file writes: the keys, the global delay
--- and the Karabiner section; the config-owned leaves go to config.toml.
--- @param model table The model the save produced.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean
--- @return table document Unstamped.
function M.new_file(model, ctx, is_table)
	return new_document(model, ctx, is_table, false)
end




-- =================================
-- =================================
-- ======= 5/ config.toml ==========
-- =================================
-- =================================

--- The config-owned part of the Karabiner model, from a decoded config.toml:
--- `tap_holds` holds the switch and the two timings, `mod_combos` the whole
--- key combinations section with each pair under its macOS combination id.
--- Values are handed on as they are: a malformed one is the model's to report.
--- @param document table Decoded config.toml (an absent file is {}).
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean For the document.
--- @return table part `{ tap_holds = table|nil, mod_combos = any }`.
--- @return table notes `{ path, detail }` for each leaf macOS cannot run.
function M.config_to_karabiner(document, ctx, is_table)
	local part, notes = {}, {}
	local section = document[MODEL_TAP_HOLDS]
	if section ~= nil and not is_table(section) then
		notes[#notes + 1] = { path = MODEL_TAP_HOLDS, detail = "it must be a table; the neutral settings are used" }
	elseif section ~= nil then
		local tap_holds = {}
		for _, leaf in ipairs(SAME_TAP_HOLD_LEAVES) do tap_holds[leaf] = section[leaf] end
		if next(tap_holds) ~= nil then part[MODEL_TAP_HOLDS] = tap_holds end
	end
	local combos = document[M.COMBOS]
	if combos ~= nil and not is_table(combos) then
		part[MODEL_COMBOS] = combos
	elseif combos ~= nil then
		local out = {}
		for field, value in pairs(combos) do out[field] = value end
		out.config = nil
		local config = combos.config
		if config ~= nil and not is_table(config) then
			out.config = config
		elseif config ~= nil then
			out.config = {}
			for pair, entry in pairs(config) do
				local combo = ctx.combo_of_pair[pair]
				local first, second = tostring(pair):match("^(.-)" .. KeyCombinations.PAIR_SEPARATOR .. "(.+)$")
				if not (first and ctx.catalogue_ids[first] and ctx.catalogue_ids[second]) then
					notes[#notes + 1] = { path = M.COMBOS .. ".config." .. tostring(pair),
						detail = "no driver has this key combination" }
				elseif combo then
					if is_table(entry) then
						local slots = {}
						for field, value in pairs(entry) do
							slots[field] = SLOT_FIELDS[field] and action_to_model(ctx, value) or value
						end
						out.config[combo] = slots
					else
						out.config[combo] = entry
					end
				end
			end
		end
		part[MODEL_COMBOS] = out
	end
	return part, notes
end

-- Separates a leaf's section from its key in the leaf map of config_leaves.
local LEAF_SEPARATOR = "\0"

--- The config.toml leaves macOS owns in a model, keyed by section and key; a
--- slot set to "none" is absent.
local function config_leaves(model, ctx, is_table)
	local leaves = {}
	local function put(section, key, value)
		if value ~= nil then leaves[section .. LEAF_SEPARATOR .. key] = { section = section, key = key, value = value } end
	end
	local tap_holds = model[MODEL_TAP_HOLDS]
	if is_table(tap_holds) then
		for _, leaf in ipairs(SAME_TAP_HOLD_LEAVES) do put(MODEL_TAP_HOLDS, leaf, tap_holds[leaf]) end
	end
	local combos = model[MODEL_COMBOS]
	if is_table(combos) then
		for _, leaf in ipairs(SAME_COMBO_LEAVES) do put(M.COMBOS, leaf, combos[leaf]) end
		if is_table(combos.config) then
			for combo, entry in pairs(combos.config) do
				local pair = ctx.pair_of_combo[combo]
				if not pair then error("macOS key combination '" .. tostring(combo) .. "' has no pair id", 0) end
				if is_table(entry) then
					for _, slot in ipairs(COMBO_SLOTS) do
						put(M.COMBOS .. ".config." .. pair, slot, entry[slot] ~= NONE and action_to_file(ctx, entry[slot]) or nil)
					end
				else
					put(M.COMBOS .. ".config", pair, entry)
				end
			end
		end
	end
	return leaves
end

--- The config.toml rows a save writes: every config-owned leaf the model now
--- holds differently from the config.toml it read, sorted. Other leaves
--- (another driver's pairs, fields macOS does not own) are never named.
--- @param before table The part M.config_to_karabiner() read, not edited since.
--- @param after table The model the save produced.
--- @param ctx table See M.hs_context.
--- @param is_table function(value) -> boolean For both.
--- @return table rows Dense `{ section, key, value }` or `{ section, key, delete = true }`.
function M.config_rows(before, after, ctx, is_table)
	local old, new = config_leaves(before, ctx, is_table), config_leaves(after, ctx, is_table)
	local names = {}
	for name in pairs(old) do names[#names + 1] = name end
	for name in pairs(new) do if old[name] == nil then names[#names + 1] = name end end
	table.sort(names)
	local rows = {}
	for _, name in ipairs(names) do
		local left, right = old[name], new[name]
		if right == nil then
			rows[#rows + 1] = { section = left.section, key = left.key, delete = true }
		elseif left == nil or not same(left.value, right.value) then
			rows[#rows + 1] = { section = right.section, key = right.key, value = right.value }
		end
	end
	return rows
end

return M

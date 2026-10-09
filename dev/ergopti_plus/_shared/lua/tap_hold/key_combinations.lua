--- _shared/lua/tap_hold/key_combinations.lua

--- Shared ordered-pair admission and timing policy. Native effects remain owned
--- by the host tap-hold engine; no IO, timers, input injection or configuration.
local M = {
	TAP_SECTION = "shortcuts.key_combination_taps",
	HOLD_SECTION = "shortcuts.key_combination_holds",
	BINDING_SCOPE = "combination",
	PAIR_SEPARATOR = "_then_",
	NONE = "none",
}
local function id(value)
	return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
end
local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function M.pair(first, second)
	assert(id(first) and id(second) and first ~= second, "pair requires distinct catalogued keys")
	return first .. M.PAIR_SEPARATOR .. second
end
function M.new(options)
	assert(type(options) == "table" and type(options.keys) == "table")
	local known, order, pairs_by_second = {}, {}, {}
	for _, key in ipairs(options.keys) do
		assert(id(key) and not known[key], "catalogue key must be unique")
		known[key], order[#order + 1] = true, key
	end
	local taps, holds = options.taps or {}, options.holds or {}
	local source_thresholds = assert(options.thresholds, "native key thresholds required")
	local thresholds = {}
	for _, second in ipairs(order) do
		assert(finite(source_thresholds[second]) and source_thresholds[second] >= 0)
		thresholds[second] = source_thresholds[second]
		local candidates = {}
		for _, first in ipairs(order) do
			if first ~= second then
				local pair = M.pair(first, second)
				local tap, hold = taps[pair] or M.NONE, holds[pair] or M.NONE
				assert(id(tap) and type(hold) == "string", "slots must already be validated")
				if tap ~= M.NONE or hold ~= M.NONE then candidates[#candidates + 1] = { first = first, id = pair, tap = tap, hold = hold } end
			end
		end
		pairs_by_second[second] = candidates
	end
	local owner = {}
	local down, taken, retirement = {}, {}, nil
	local revision = assert(options.revision, "configuration lease revision required")
	local generation = assert(options.generation, "physical source generation required")
	local enabled = options.enabled == true
	local function authorized(event)
		return type(event) == "table" and type(event.key) == "string" and event.physical == true
			and type(event.source) == "string" and event.source ~= "" and not event.source:find("%z")
			and event.generation == generation and event.revision == revision and finite(event.at_ms)
			and (event.value == 0 or event.value == 1 or event.value == 2)
	end
	local function stamp(event) return event.source .. "\0" .. event.key end
	local function effect(kind, state)
		return { kind = kind, pair_id = state.pair.id, binding = M.BINDING_SCOPE .. "__" .. state.pair.id,
			first = state.pair.first, second = state.key, source = state.source,
			tap = state.pair.tap, hold = state.pair.hold }
	end
	local function activity(except)
		for token, state in pairs(taken) do if token ~= except then state.cancelled = true end end
	end
	function owner.process(event)
		if retirement ~= nil or not authorized(event) then return { consumed = false, effects = {}, refused = true } end
		local token, effects = stamp(event), {}
		if not known[event.key] then activity(); return { consumed = false, effects = effects } end
		local state = taken[token]
		if event.value == 2 then
			activity(token)
			if not state then return { consumed = false, effects = effects } end
			if state.pair.hold == M.NONE and state.pair.tap ~= M.NONE then effects[1] = effect("tap", state) end
			return { consumed = true, effects = effects }
		end
		if event.value == 0 then
			activity(token)
			down[token] = nil
			if not state then return { consumed = false, effects = effects } end
			taken[token] = nil
			if state.pair.hold ~= M.NONE then
				effects[#effects + 1] = effect("release_hold", state)
				if not state.cancelled and event.at_ms >= state.at_ms
					and event.at_ms - state.at_ms <= thresholds[state.key] and state.pair.tap ~= M.NONE then
					effects[#effects + 1] = effect("tap", state)
				end
			end
			return { consumed = true, effects = effects }
		end
		if down[token] then return { consumed = state ~= nil, effects = effects } end
		activity(token)
		local chosen
		if enabled then
			for _, pair in ipairs(pairs_by_second[event.key]) do
				-- Conservative first slice: an ordered pair belongs to one exact
				-- physical keyboard. Cross-device combinations are not admitted.
				if down[event.source .. "\0" .. pair.first] and not (event.blocked_first or {})[pair.first] then chosen = pair; break end
			end
		end
		down[token] = { key = event.key, source = event.source, at_ms = event.at_ms }
		if not chosen then return { consumed = false, effects = effects } end
		state = { pair = chosen, key = event.key, source = event.source, at_ms = event.at_ms, cancelled = false }
		taken[token] = state
		effects[#effects + 1] = effect("take_first", state)
		if chosen.hold ~= M.NONE then effects[#effects + 1] = effect("take_hold", state)
		elseif chosen.tap ~= M.NONE then effects[#effects + 1] = effect("tap", state) end
		return { consumed = true, effects = effects }
	end
	function owner.owns(key, source) return taken[source .. "\0" .. key] ~= nil end
	function owner.activity() activity() end
	function owner.retire()
		if retirement then return retirement.effects, retirement.token end
		local effects, tokens = {}, {}
		for token in pairs(taken) do tokens[#tokens + 1] = token end
		table.sort(tokens)
		for _, token in ipairs(tokens) do
			local state = taken[token]
			if state.pair.hold ~= M.NONE then effects[#effects + 1] = effect("release_hold", state) end
		end
		retirement = { token = {}, effects = effects }
		return effects, retirement.token
	end
	function owner.ack_retirement(token, settled)
		if not retirement or retirement.token ~= token or settled ~= true then return false end
		down, taken, enabled, retirement = {}, {}, false, nil
		return true
	end
	return owner
end

-- Pure third-slot policy. Native hosts still own buffering, physical provenance,
-- effect delivery and retirement; constructing this policy enables no engine.

function M.chord_settings(values)
	assert(type(values) == "table", "declared chord settings required")
	local delay = values.simultaneous_threshold_ms
	assert(finite(delay) and delay > 0, "chord delay must be a positive finite number")
	assert(type(values.combo_symmetric) == "boolean", "chord symmetry must be an exact boolean")
	return { simultaneous_threshold_ms = delay, combo_symmetric = values.combo_symmetric }
end

local function chord_token(value)
	return type(value) == "string" and value ~= "" and not value:find("%z")
end

function M.chord_policy(options)
	assert(type(options) == "table" and type(options.pairs) == "table", "declared chord catalogue required")
	local settings = M.chord_settings(options.settings)
	local directions, identifiers, canonical = {}, {}, {}
	local chords = options.chords or {}
	for _, entry in ipairs(options.pairs) do
		assert(type(entry) == "table" and chord_token(entry.id) and id(entry.first) and id(entry.second)
			and entry.first ~= entry.second and not identifiers[entry.id], "distinct chord pair required")
		local direction = entry.first .. "\0" .. entry.second
		local reverse = entry.second .. "\0" .. entry.first
		assert(not directions[direction], "duplicate chord direction")
		local action = chords[entry.id]
		if action == nil then action = M.NONE end
		assert(id(action), "chord action must already be validated")
		local row = { id = entry.id, first = entry.first, second = entry.second, action = action }
		directions[direction], identifiers[entry.id] = row, row
		canonical[entry.id] = directions[reverse] and canonical[directions[reverse].id] or row
	end
	local policy = {}
	function policy.canonical_pair(pair_id)
		local row = canonical[pair_id]
		return row and row.id or nil
	end
	function policy.choose(first, second, elapsed_ms)
		if not finite(elapsed_ms) or elapsed_ms < 0 or elapsed_ms > settings.simultaneous_threshold_ms then return nil end
		if not id(first) or not id(second) then return nil end
		local row = directions[first .. "\0" .. second]
		if row and settings.combo_symmetric then row = canonical[row.id] end
		if not row or row.action == M.NONE then return nil end
		return { pair_id = row.id, first = first, second = second, action = row.action,
			binding = M.BINDING_SCOPE .. "__" .. row.id }
	end
	return policy
end

-- Plan from an exact freshly read document, never from a boot-time slot cache.
-- Only known pairs' chord leaves change. Future records/parameters stay outside
-- the operation; all known participants are validated before any row is returned.
function M.plan_chord_copy(source, options)
	assert(type(source) == "string" and type(options) == "table" and type(options.entries) == "table",
		"exact source and declared copy catalogue required")
	assert(type(options.is_action) == "function", "native action admission required")
	assert(options.tap_section == nil or options.tap_section == M.TAP_SECTION, "copy source section must be explicitly declared")
	local Codec = require("toml_codec")
	local KeyPath = require("toml_codec.key_path")
	local document, shapes = Codec.decode_with_shapes(source)
	local function namespace(parent, key)
		local value = parent[key]
		if value == nil then return {} end
		assert(type(value) == "table" and not shapes.arrays[value], "chord source has an occupied namespace")
		return value
	end
	local combos = namespace(document, "mod_combos")
	local stored = namespace(combos, "config")
	local linux_taps = options.tap_section == M.TAP_SECTION
		and namespace(namespace(document, "shortcuts"), "key_combination_taps") or nil
	local declared = M.chord_settings(options.settings)
	local delay = combos.simultaneous_threshold_ms
	if delay == nil then delay = declared.simultaneous_threshold_ms end
	local symmetric = combos.symmetric
	if symmetric == nil then symmetric = declared.combo_symmetric end
	local settings = M.chord_settings({ simultaneous_threshold_ms = delay, combo_symmetric = symmetric })
	assert(combos.enabled == nil or type(combos.enabled) == "boolean", "chord source gate must be an exact boolean")
	local rows, output, seen = {}, {}, {}
	for _, entry in ipairs(options.entries) do
		assert(type(entry) == "table" and chord_token(entry.id) and not seen[entry.id], "unique copy pair required")
		seen[entry.id] = true
		local config = namespace(stored, entry.id)
		local slots = {}
		for _, slot in ipairs({ "tap", "hold", "combo" }) do
			local value = config[slot]
			if linux_taps then
				if slot == "tap" then value = linux_taps[entry.id]
				elseif slot == "hold" then value = M.NONE end
			end
			if value == nil then value = M.NONE end
			assert(id(value) and (value == M.NONE or options.is_action(value) == true), "chord source contains an unadmitted action")
			slots[slot] = value
		end
		output[entry.id] = { tap = slots.tap, hold = slots.hold, combo = slots.tap }
		if slots.tap ~= slots.combo then
			local row = { section = KeyPath.render({ "mod_combos", "config", entry.id }), key = "combo" }
			if slots.tap == M.NONE then row.delete = true else row.value = slots.tap end
			rows[#rows + 1] = row
		end
	end
	return { source = source, rows = rows, changes = #rows, mod_combos_config = output,
		mod_combos_enabled = combos.enabled, settings = settings }
end

return M

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
return M

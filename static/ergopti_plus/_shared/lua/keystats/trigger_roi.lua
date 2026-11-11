--- _shared/lua/keystats/trigger_roi.lua

--- ==============================================================================
--- MODULE: Trigger ROI Accounting
--- DESCRIPTION:
--- Windows-compatible software metrics over already admitted input. Drivers own
--- focus observation, clocks and persistence; this owner never queries the OS.
--- Counts survive collection pauses, while an interrupted word never survives
--- a context, privacy or synthetic-input boundary. Pending events retain their
--- original timestamp until the driver's durable queue accepts them.
--- ==============================================================================

local M = {}
local Utf8 = require("compat.utf8")
local Case = require("keystats.roi_case")
local Policy = require("keystats.roi_policy")

local BOUNDARIES = { [32] = true, [9] = true, [10] = true, [13] = true,
	[46] = true, [44] = true, [33] = true, [63] = true }
local DISCARD_KEYS = { Escape = true, PageUp = true, PageDown = true, End = true,
	Home = true, Left = true, Up = true, Right = true, Down = true, Delete = true }
local MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000

-- One character of a string already proven valid UTF-8; gsub copies any byte it
-- does not match (only NUL), which has no case mapping either.
local UTF8_CHARACTER = "[\1-\127\194-\244][\128-\191]*"

--- Uses the qualified Windows ROI profile; general Unicode case conversion has different semantics.
--- Each caller has validated the text, so one gsub over the generated table maps every
--- character (the per-codepoint decode through compat.utf8 cost 55 ms per corpus index).
local function lower_key(text)
	return (text:gsub(UTF8_CHARACTER, Case.lower))
end

--- Counts UTF-16 units, the Windows owner's StrLen contract, without accepting malformed UTF-8.
--- @param text string
--- @return integer|nil
function M.utf16_length(text)
	if type(text) ~= "string" then return nil end
	if not text:find("[\128-\255]") then return #text end
	local length = Utf8.len(text)
	if length == nil then return nil end
	-- In valid UTF-8 these bytes only lead a four-byte sequence: the characters
	-- outside the BMP, which count two UTF-16 units.
	local _, astral = text:gsub("[\240-\244]", "")
	return length + astral
end

--- Indexes only a registry's admitted mappings using the Windows lowercase exclusion rule.
--- @param mappings table Dense array of admitted { trigger } records.
--- @return table
function M.trigger_index(mappings)
	assert(type(mappings) == "table", "ROI requires admitted mappings")
	local index = {}
	for _, mapping in ipairs(mappings) do
		assert(type(mapping) == "table" and M.utf16_length(mapping.trigger) ~= nil,
			"ROI requires valid admitted trigger text")
		index[lower_key(mapping.trigger)] = true
	end
	return index
end

--- Looks up a trigger only after its registry has published a complete index.
--- @param index table|nil
--- @param word string
--- @return boolean|nil
function M.known_trigger(index, word)
	if type(index) ~= "table" or M.utf16_length(word) == nil then return nil end
	return index[lower_key(word)] == true
end

--- Creates one process-lifetime accounting state; restarting capture must reuse it.
--- @param now_ms number Monotonic start time.
--- @param text_enabled boolean True only when encryption is known to be neither requested nor active.
--- @return table
function M.new(now_ms, text_enabled)
	assert(type(now_ms) == "number" and now_ms == now_ms and now_ms >= 0 and now_ms < math.huge, "ROI requires a monotonic start time")
	assert(type(text_enabled) == "boolean", "ROI requires an explicit textual capture policy")
	return { text_enabled = text_enabled, saved = 0, fired = 0, words = {}, word_count = 0, last_use = {},
		word = {}, word_units = 0, overflow = false, generation = 0,
		pending = {}, last_check_ms = now_ms }
end

--- Drops only the in-progress fragment, never accepted counters or queued rows.
--- @param state table
function M.discard(state)
	state.word, state.word_units, state.overflow = {}, 0, false
	state.context = nil
	state.generation = state.generation + 1
end

--- Identifies the two ROI payloads that contain user text, without invoking caller metatables.
--- @param event table|nil Canonical event record with a type field.
--- @return boolean
function M.is_text_event(event)
	if type(event) ~= "table" then return false end
	local kind = rawget(event, "type")
	return kind == "new_trigger_candidate" or kind == "trigger_halflife"
end

--- Retires all unpersisted text when encryption is requested, without erasing numerical totals.
--- Drivers also retire their accepted but unwritten textual outbox operations at this boundary.
--- @param state table
--- @param enabled boolean Exact admission decision, never a key/provider readiness fallback.
function M.set_text_enabled(state, enabled)
	assert(type(enabled) == "boolean", "ROI requires an explicit textual capture policy")
	state.text_enabled = enabled
	if enabled then return end
	M.discard(state)
	state.words, state.word_count, state.last_use = {}, 0, {}
	local pending = {}
	for _, event in ipairs(state.pending) do
		if event.type == "roi_snapshot" then pending[#pending + 1] = event end
	end
	state.pending = pending
end

--- Accepts an already captured wall time; macOS formats epoch values outside its input callback.
local function valid_timestamp(value)
	return (type(value) == "string" and value ~= "")
		or (type(value) == "number" and value == value and value >= 0 and value < math.huge)
end

--- Whether supplied metadata identifies one application and native window.
--- Drivers can reject an identity before capturing timestamps or physical metadata.
--- @param context table|nil { app, window, title }.
--- @return boolean
function M.valid_context_identity(context)
	return type(context) == "table" and type(context.app) == "string"
		and context.app ~= "" and context.app ~= "Unknown"
		and type(context.title) == "string" and ((type(context.window) == "number" and context.window > 0 and context.window < math.huge)
			or (type(context.window) == "string" and context.window ~= ""))
end

--- Whether a supplied context identifies one admitted application and window.
local function valid_context(context)
	return M.valid_context_identity(context) and valid_timestamp(context.timestamp)
end

--- Publishes every observed context change, including changes with no intervening key.
--- @param state table
--- @param context table|nil { app, window, title, timestamp }; nil revokes admission.
--- @return boolean
function M.observe(state, context)
	if not state.text_enabled or not valid_context(context) then M.discard(state); return false end
	local previous = state.context
	if not previous or previous.app ~= context.app or previous.window ~= context.window
		or previous.title ~= context.title then M.discard(state) end
	state.context = { app = context.app, window = context.window, title = context.title,
		timestamp = context.timestamp }
	return true
end

--- Queues an immutable event; driver retries cannot change its observation time.
local function emit(state, kind, app, timestamp, fields)
	if type(app) ~= "string" or app == "" or not valid_timestamp(timestamp) then
		return false
	end
	fields.type, fields.app, fields.timestamp = kind, app, timestamp
	state.pending[#state.pending + 1] = fields
	return true
end

--- Mirrors AHK Map string enumeration, whose native comparison is over UTF-16 units.
local function utf16_sort_key(text)
	local bytes = {}
	local function append(unit)
		bytes[#bytes + 1] = string.char(math.floor(unit / 256), unit % 256)
	end
	for _, cp in Utf8.codes(text) do
		if cp <= 0xFFFF then append(cp)
		else
			cp = cp - 0x10000
			append(0xD800 + math.floor(cp / 0x400))
			append(0xDC00 + cp % 0x400)
		end
	end
	return table.concat(bytes)
end

--- Shrinks the frequency map deterministically while retaining the most repeated words.
local function prune(state)
	if state.word_count <= Policy.max_tracked_words then return end
	local ranked = {}
	for word, count in pairs(state.words) do
		if count > 1 then ranked[#ranked + 1] = { word = word, count = count, order = utf16_sort_key(word) } end
	end
	table.sort(ranked, function(a, b)
		if a.count == b.count then return a.order > b.order end
		return a.count > b.count
	end)
	state.words = {}
	state.word_count = math.min(#ranked, Policy.prune_target_words)
	for index = 1, state.word_count do
		local row = ranked[index]
		state.words[row.word] = row.count
	end
end

--- Completes one word only while the known-trigger lookup retains its context lease.
local function complete(state, known_trigger)
	local word, units, overflow = table.concat(state.word), state.word_units, state.overflow
	state.word, state.word_units, state.overflow = {}, 0, false
	if overflow or units < Policy.min_word_len or type(known_trigger) ~= "function" then return end
	local key = lower_key(word)
	local generation, context = state.generation, state.context
	local ok, known = pcall(known_trigger, key)
	if not ok or known ~= false or state.generation ~= generation or state.context ~= context then return end
	if state.words[key] == nil then state.word_count = state.word_count + 1 end
	local count = (state.words[key] or 0) + 1
	state.words[key] = count
	if count == Policy.repeat_threshold then
		emit(state, "new_trigger_candidate", context.app, context.timestamp,
			{ word = word, occurrences = count })
	end
	prune(state)
end

--- Observes admitted physical text; callers discard on synthetic or filtered input.
--- @param state table
--- @param text string
--- @param context table
--- @param known_trigger function Returns exactly false only for an unknown trigger.
--- @return boolean
function M.text(state, text, context, known_trigger)
	if not state.text_enabled or M.utf16_length(text) == nil or not M.observe(state, context) then M.discard(state); return false end
	local lease = state.context
	for _, cp in Utf8.codes(text) do
		if BOUNDARIES[cp] then
			complete(state, known_trigger)
			if state.context ~= lease then return false end
		elseif not state.overflow then
			local units = cp > 0xFFFF and 2 or 1
			if state.word_units + units > Policy.max_inprogress_word_len then
				state.word, state.word_units, state.overflow = {}, 0, true
			else
				state.word[#state.word + 1] = Utf8.char(cp)
				state.word_units = state.word_units + units
			end
		end
	end
	return true
end

--- Applies a physical editing key using platform-neutral names.
--- @param state table
--- @param key string Backspace, Enter, Tab, or a navigation/discard key.
--- @param context table
--- @param known_trigger function
--- @return boolean
function M.key(state, key, context, known_trigger)
	if not M.observe(state, context) then return false end
	if key == "Backspace" then
		local last = state.word[#state.word]
		if last and not state.overflow then
			state.word_units = state.word_units - M.utf16_length(last)
			state.word[#state.word] = nil
		end
	elseif key == "Enter" or key == "Tab" then complete(state, known_trigger)
	elseif DISCARD_KEYS[key] then M.discard(state) end
	return true
end

--- Counts an accepted expansion, keeping private trigger identities out of the state.
--- @param state table
--- @param trigger string
--- @param replacement string
--- @param is_private boolean
--- @param now_ms number Monotonic use time.
--- @param app string
--- @param timestamp string|number Observation wall time.
--- @return boolean
function M.hotstring(state, trigger, replacement, is_private, now_ms, app, timestamp)
	M.discard(state)
	local input, output = M.utf16_length(trigger), M.utf16_length(replacement)
	if not input or not output or type(now_ms) ~= "number" or now_ms ~= now_ms or now_ms < 0 or now_ms == math.huge
		or type(app) ~= "string" or app == "" or not valid_timestamp(timestamp) then return false end
	state.saved = state.saved + math.max(0, output - input)
	state.fired = state.fired + 1
	if not is_private and state.text_enabled then state.last_use[lower_key(trigger)] = now_ms end
	if state.fired % Policy.roi_snapshot_every == 0 then
		emit(state, "roi_snapshot", app, timestamp, { session_saved = state.saved, session_fired = state.fired })
	end
	return true
end

--- Emits process-session stale-trigger warnings at the Windows cadence.
--- @param state table
--- @param now_ms number
--- @param app string
--- @param timestamp string|number
--- @return boolean
function M.tick(state, now_ms, app, timestamp)
	if not state.text_enabled then return false end
	if type(app) ~= "string" or app == "" or not valid_timestamp(timestamp)
		or type(now_ms) ~= "number" or now_ms ~= now_ms or now_ms == math.huge or now_ms < state.last_check_ms
		or now_ms - state.last_check_ms < Policy.halflife_check_ms then return false end
	state.last_check_ms = now_ms
	for _, trigger in ipairs(require("table_util").sorted_keys(state.last_use)) do
		local age = now_ms - state.last_use[trigger]
		if age >= Policy.halflife_warn_days * MILLISECONDS_PER_DAY then
			emit(state, "trigger_halflife", app, timestamp,
				{ trigger = trigger, days_since_use = math.floor(age / MILLISECONDS_PER_DAY * 10 + 0.5) / 10 })
		end
	end
	return true
end

--- Emits the final cumulative snapshot; stopping capture does not reset the totals.
--- @param state table
--- @param app string
--- @param timestamp string|number
--- @return boolean
function M.finish(state, app, timestamp)
	M.discard(state)
	if state.fired == 0 then return true end
	return emit(state, "roi_snapshot", app, timestamp, { session_saved = state.saved, session_fired = state.fired })
end

--- Transfers queued rows only after exact acceptance, preserving a refused head for retry.
--- @param state table
--- @param record function Event sink; true acknowledges ownership transfer.
--- @return boolean
function M.drain(state, record)
	if state.draining or type(record) ~= "function" then return false end
	state.draining = true
	while #state.pending > 0 do
		local event = state.pending[1]
		local ok, accepted = pcall(record, event)
		if not ok or accepted ~= true then state.draining = false; return false end
		-- A sink can close text admission reentrantly and retire this exact row.
		if state.pending[1] == event then table.remove(state.pending, 1) end
	end
	state.draining = false
	return true
end

return M

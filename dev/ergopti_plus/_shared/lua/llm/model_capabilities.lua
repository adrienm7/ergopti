--- _shared/lua/llm/model_capabilities.lua

--- ==============================================================================
--- MODULE: Model Capabilities — Shared Lua Implementation
--- DESCRIPTION:
--- Some providers say in their model listing which reasoning controls each
--- model takes: OpenRouter's /models supported_parameters, the Anthropic
--- Models API capabilities, Gemini's models.list thinking flag. A control a
--- listing says a model lacks is not sent (thinking_off.lua resolve), so the
--- request goes out right the first time instead of through an HTTP 400 and
--- its retry.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the drivers fetch the listing with their own HTTP client, off the
---    prediction path (a deferred, separate request), and hand the decoded
---    answer here; no key or address reaches this module.
--- 2. A model the listing does not describe, or a field it does not state,
---    lacks nothing: only an explicit "not supported" skips a control.
--- 3. A per-provider cache with a time to live (thinking_off.json
---    capability_listing.ttl_hours): a stale or missing listing is fetched
---    again once, never twice at the same time, and the old listing serves
---    meanwhile.
--- 4. Bounded: at most MAX_MODELS models are kept per listing.
---
--- The AutoHotkey port is _shared/modules/llm/model_capabilities.ahk. Both
--- replay _shared/tests/corpus/llm/model_capabilities_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Most models one listing keeps; OpenRouter lists a few hundred
M.MAX_MODELS = 2000

-- The listing dialects and the array of models each one answers
M.LISTINGS = { openrouter = "data", anthropic = "data", gemini = "models" }

-- A provider id, as api_providers.json names them
local PROVIDER_PATTERN = "^[%l%d_]+$"

-- A page query: one name=number pair
local PAGE_QUERY_PATTERN = "^%a+=%d+$"




-- =============================================
-- =============================================
-- ======= 2/ Configuration ====================
-- =============================================
-- =============================================

--- Tells whether a decoded value is a JSON object: every key a string.
--- @param value any
--- @return boolean
local function is_object(value)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

--- Validates thinking_off.json capability_listing.
--- @param raw any The decoded section.
--- @return table|nil config { ttl_sec, providers = id -> listing, page_query = listing -> query }.
--- @return string|nil reason Why it is refused.
function M.parse_config(raw)
	if not is_object(raw) then return nil, "capability_listing must be an object" end
	local hours = raw.ttl_hours
	if type(hours) ~= "number" or hours <= 0 or hours % 1 ~= 0 then
		return nil, "capability_listing.ttl_hours must be a positive integer"
	end
	if not is_object(raw.providers) or next(raw.providers) == nil then
		return nil, "capability_listing.providers must be a non-empty object"
	end
	local providers, page_query = {}, {}
	for id, listing in pairs(raw.providers) do
		if not id:match(PROVIDER_PATTERN) or not M.LISTINGS[listing] then
			return nil, "capability_listing.providers holds an invalid entry " .. id
		end
		providers[id] = listing
	end
	if not is_object(raw.page_query) then return nil, "capability_listing.page_query must be an object" end
	for listing, query in pairs(raw.page_query) do
		if listing:sub(1, 1) ~= "_" then
			if not M.LISTINGS[listing] or type(query) ~= "string" or not query:match(PAGE_QUERY_PATTERN) then
				return nil, "capability_listing.page_query holds an invalid entry " .. listing
			end
			page_query[listing] = query
		end
	end
	return { ttl_sec = hours * 3600, providers = providers, page_query = page_query }, nil
end




-- =============================================
-- =============================================
-- ======= 3/ Listing ==========================
-- =============================================
-- =============================================

--- A set of the strings of a decoded array, nil when it is not one.
--- @param list any
--- @return table|nil
local function string_set(list)
	if type(list) ~= "table" then return nil end
	local set = {}
	for _, value in ipairs(list) do
		if type(value) ~= "string" then return nil end
		set[value] = true
	end
	return set
end

--- The supported flag of a decoded capability node, nil when unstated.
--- @param node any
--- @return boolean|nil
local function supported(node)
	if type(node) ~= "table" or type(node.supported) ~= "boolean" then return nil end
	return node.supported
end

--- The supported flags of a node's named children (types, effort levels).
--- @param node any
--- @return table name -> boolean
local function children(node)
	local out = {}
	if type(node) ~= "table" then return out end
	for name, child in pairs(node) do
		local flag = supported(child)
		if type(name) == "string" and flag ~= nil then out[name] = flag end
	end
	return out
end

--- Reads one model of a listing.
--- @param listing string
--- @param item table
--- @return string|nil id, table|nil record
local function read_model(listing, item)
	if listing == "openrouter" then
		local params = string_set(item.supported_parameters)
		if type(item.id) ~= "string" or not params then return nil end
		return item.id, { params = params }
	elseif listing == "anthropic" then
		local caps = item.capabilities
		if type(item.id) ~= "string" or type(caps) ~= "table" then return nil end
		local record = {}
		if type(caps.thinking) == "table" then
			record.thinking = { supported = supported(caps.thinking), types = children(caps.thinking.types) }
		end
		if type(caps.effort) == "table" then
			record.effort = { supported = supported(caps.effort), levels = children(caps.effort) }
		end
		return item.id, record
	end
	local id = type(item.name) == "string" and item.name:gsub("^models/", "") or nil
	if not id or type(item.thinking) ~= "boolean" then return nil end
	return id, { gemini_thinking = item.thinking }
end

--- Reads a decoded listing answer into per-model records.
--- @param listing string "openrouter", "anthropic" or "gemini".
--- @param decoded any The decoded JSON body.
--- @return table|nil records model id -> record.
--- @return string|nil reason "unsupported" or "unreadable".
function M.parse(listing, decoded)
	local key = M.LISTINGS[listing]
	if not key then return nil, "unsupported" end
	local list = type(decoded) == "table" and decoded[key] or nil
	if type(list) ~= "table" then return nil, "unreadable" end
	local records, count = {}, 0
	for _, item in ipairs(list) do
		if count >= M.MAX_MODELS then break end
		if type(item) == "table" then
			local id, record = read_model(listing, item)
			if id and records[id] == nil then
				records[id] = record
				count = count + 1
			end
		end
	end
	return records, nil
end

--- The record a listing holds for a model, nil when it says nothing.
--- @param records table|nil parse() output.
--- @param model string The model id as the request names it.
--- @return table|nil
function M.record(records, model)
	if type(records) ~= "table" or type(model) ~= "string" then return nil end
	return records[model] or records[(model:gsub("^models/", ""))]
end

--- Tells whether a listing says a model lacks a control.
--- @param record table|nil record() output.
--- @param kind string The control kind (thinking_off.json).
--- @param level any The control's level.
--- @param fields table The dialect template the control would send.
--- @return boolean
function M.lacks(record, kind, level, fields)
	if type(record) ~= "table" then return false end
	if record.params then
		for name in pairs(fields) do
			if not record.params[name] then return true end
		end
		return false
	end
	if kind == "anthropic_thinking" and record.thinking then
		return record.thinking.supported == false or record.thinking.types[level] == false
	end
	if kind == "anthropic_effort" and record.effort then
		return record.effort.supported == false or record.effort.levels[level] == false
	end
	if kind == "gemini_budget" or kind == "gemini_level" then return record.gemini_thinking == false end
	return false
end




-- =============================================
-- =============================================
-- ======= 4/ Cache ============================
-- =============================================
-- =============================================

--- Tells whether a provider's listing must be fetched: none yet, or older
--- than the time to live, and no fetch under way.
--- @param cache table provider id -> { records, at, pending }.
--- @param provider string
--- @param now number Epoch seconds.
--- @param ttl_sec number
--- @return boolean
function M.needs_fetch(cache, provider, now, ttl_sec)
	local entry = cache[provider]
	if entry == nil then return true end
	if entry.pending then return false end
	return entry.at == nil or now - entry.at >= ttl_sec or entry.at > now
end

--- Marks a provider's fetch as under way.
--- @param cache table
--- @param provider string
function M.begin(cache, provider)
	local entry = cache[provider] or {}
	entry.pending = true
	cache[provider] = entry
end

--- Ends a provider's fetch: new records replace the old ones; a failed fetch
--- keeps them and waits for the time to live before the next attempt.
--- @param cache table
--- @param provider string
--- @param records table|nil parse() output, nil when the fetch failed.
--- @param now number Epoch seconds.
function M.finish(cache, provider, records, now)
	local entry = cache[provider] or {}
	entry.pending = nil
	entry.at = now
	if records then entry.records = records end
	cache[provider] = entry
end

--- The records a provider's cache holds, nil when none.
--- @param cache table
--- @param provider string
--- @return table|nil
function M.records(cache, provider)
	local entry = cache[provider]
	return entry and entry.records or nil
end

return M

--- _shared/metrics/engine/view/studio_ngrams.lua

--- ==============================================================================
--- MODULE: Ergopti Studio N-gram Projection
--- DESCRIPTION:
--- Turns the keystats reader's character n-gram dictionaries into the one
--- payload Ergopti Studio analyses: the counts of the characters, bigrams and
--- trigrams the user really typed on this machine, and the same counts of the
--- final text (schema 2). macOS and Linux call it
--- from their layout editor window hosts; the Windows host builds the same
--- payload in windows/ui/layout_manager/editor_window.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Read only and local: the payload is built from the reader's projection of
---    db.sqlite and handed to the Studio page in the same window. Nothing here
---    writes the store or sends anything anywhere.
--- 2. Two texts: the top-level tables hold the physical keystrokes only (a
---    token's synthetic sources, hotstring expansions, AI completions and
---    other synthetic labels, the reader's hs, llm and o fields, did not come
---    from the keyboard, so they are subtracted from its count); the
---    final_field table holds every source counted, the text the user wanted.
---    The Comparer's text modes choose which one each layout types.
--- 3. Fail fast: an absent store and an incomplete read are refusals with a
---    stable code the page translates; a partial projection is never offered
---    as the user's data.
--- 4. One contract: the schema, the families and the refusal codes live in
---    _shared/metrics/data/studio_ngrams.json, read by every host.
--- 5. Computed once per store version: the tables are kept with the store's
---    revision (meta.rev, bumped by every ingest) and reused until it changes,
---    so the Studio scores layouts at once instead of re-reading the store.
--- 6. The driver injects its reader, its revision reader and its
---    file-existence check.
--- ==============================================================================

local M = {}

--- The shared contract (_shared/metrics/data/studio_ngrams.json), read once.
local function load_contract()
	local path = require("core.fs.engine.paths").shared("metrics/data/studio_ngrams.json")
	local file = assert(io.open(path, "rb"), "the Ergopti Studio n-gram contract is missing: " .. tostring(path))
	local raw = file:read("*a")
	file:close()
	local contract = require("core.text.engine.json").decode(raw)
	assert(type(contract) == "table" and type(contract.schema) == "number" and type(contract.source) == "string"
		and type(contract.families) == "table" and type(contract.codes) == "table"
		and type(contract.final_field) == "string" and contract.final_field ~= "",
		"the Ergopti Studio n-gram contract is malformed")
	return contract
end

local CONTRACT = load_contract()

--- Payload schema version, read by the Studio page.
M.SCHEMA = CONTRACT.schema

--- The reader families the Studio reads, by reader code and payload field.
M.FAMILIES = CONTRACT.families

--- The payload field of the final-text tables (every source counted).
M.FINAL_FIELD = CONTRACT.final_field

--- Refusal codes; the page shows `layout_editor.studio.keystats.<code>`.
M.CODES = CONTRACT.codes





-- =============================
-- =============================
-- ======= 1/ Projection =======
-- =============================
-- =============================

--- A count the store can hold: a NaN, an infinity or a count below one is none.
--- @param count number
--- @return number count Zero or more.
local function whole(count)
	if count ~= count or count == math.huge or count <= 0 then return 0 end
	return count
end

--- The number of physical keystrokes of one reader item.
--- @param item table Reader item { c, hs, llm, o }.
--- @return number count Zero or more.
local function physical_count(item)
	if type(item) ~= "table" then return 0 end
	local total = tonumber(item.c) or 0
	local synthetic = (tonumber(item.hs) or 0) + (tonumber(item.llm) or 0) + (tonumber(item.o) or 0)
	return whole(total - synthetic)
end

--- The final-text count of one reader item: every source counted.
--- @param item table Reader item { c, … }.
--- @return number count Zero or more.
local function final_count(item)
	if type(item) ~= "table" then return 0 end
	return whole(tonumber(item.c) or 0)
end

--- One text's tables: each family's counts by one rule, and the characters' total.
--- @param dict table Reader output.
--- @param count_of function Reader item → count.
--- @param into table The table to fill.
--- @return table into
local function project_text(dict, count_of, into)
	into.total = 0
	for _, family in ipairs(M.FAMILIES) do
		local counts = {}
		for token, item in pairs(type(dict[family.code]) == "table" and dict[family.code] or {}) do
			local count = type(token) == "string" and token ~= "" and count_of(item) or 0
			if count > 0 then counts[token] = count end
		end
		into[family.field] = counts
	end
	for _, count in pairs(into.chars) do into.total = into.total + count end
	return into
end

--- Projects reader dictionaries into the Studio payload.
--- @param dict table Reader output: { c = {token → item}, bg = …, tg = … }.
--- @return table payload { schema, source, chars, bigrams, trigrams, total,
---     [FINAL_FIELD] = { chars, bigrams, trigrams, total } }.
function M.project(dict)
	assert(type(dict) == "table", "studio_ngrams.project needs the reader's dictionaries")
	local payload = project_text(dict, physical_count, { schema = M.SCHEMA, source = CONTRACT.source })
	payload[M.FINAL_FIELD] = project_text(dict, final_count, {})
	return payload
end

-- The last complete projection: { path, stamp, ngrams }, or nil.
local _cache = nil

--- Forgets the cached projection (tests, and a store the user removed).
function M.reset_cache()
	_cache = nil
end

--- Reads the store and projects it, or refuses with a code. A store whose
--- revision is the cached one answers from the cache without a read.
--- @param deps table { path = string|nil, exists = function(path) -> boolean,
---     read = function(path) -> dict, complete,
---     stamp = function(path) -> string|nil (optional) }.
--- @return table result { ok = true, ngrams = payload, cached = boolean } or
---     { ok = false, code = string }.
function M.read(deps)
	assert(type(deps) == "table" and type(deps.exists) == "function" and type(deps.read) == "function",
		"studio_ngrams.read needs its exists and read ports")
	local path = deps.path
	if type(path) ~= "string" or path == "" or deps.exists(path) ~= true then
		_cache = nil
		return { ok = false, code = M.CODES.absent }
	end
	-- A revision that cannot be read is no revision: the store is read in full.
	local stamp = nil
	if type(deps.stamp) == "function" then
		local stamped, value = pcall(deps.stamp, path)
		if stamped and type(value) == "string" and value ~= "" then stamp = value end
	end
	if stamp and _cache and _cache.path == path and _cache.stamp == stamp then
		return { ok = true, ngrams = _cache.ngrams, cached = true }
	end
	local called, dict, complete = pcall(deps.read, path)
	if not called or type(dict) ~= "table" or complete ~= true then
		return { ok = false, code = M.CODES.unreadable }
	end
	local ngrams = M.project(dict)
	_cache = stamp and { path = path, stamp = stamp, ngrams = ngrams } or nil
	return { ok = true, ngrams = ngrams, cached = false }
end

return M

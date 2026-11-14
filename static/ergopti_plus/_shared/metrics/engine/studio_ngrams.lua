--- _shared/metrics/engine/studio_ngrams.lua

--- ==============================================================================
--- MODULE: Ergopti Studio N-gram Projection
--- DESCRIPTION:
--- Turns the keystats reader's character n-gram dictionaries into the one
--- payload Ergopti Studio analyses: the counts of the characters, bigrams and
--- trigrams the user really typed on this machine. macOS and Linux call it
--- from their layout editor window hosts; the Windows host builds the same
--- payload in windows/ui/layout_manager/editor_window.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Read only and local: the payload is built from the reader's projection of
---    db.sqlite and handed to the Studio page in the same window. Nothing here
---    writes the store or sends anything anywhere.
--- 2. Physical keystrokes only: a token's synthetic sources (hotstring
---    expansions, AI completions, other synthetic labels; the reader's hs, llm
---    and o fields) did not come from the keyboard, so they are subtracted from
---    its count before a layout is judged on them.
--- 3. Fail fast: an absent store and an incomplete read are refusals with a
---    stable code the page translates; a partial projection is never offered
---    as the user's data.
--- 4. One contract: the schema, the families and the refusal codes live in
---    _shared/metrics/data/studio_ngrams.json, read by every host.
--- 5. The driver injects its reader and its file-existence check.
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
		and type(contract.families) == "table" and type(contract.codes) == "table",
		"the Ergopti Studio n-gram contract is malformed")
	return contract
end

local CONTRACT = load_contract()

--- Payload schema version, read by the Studio page.
M.SCHEMA = CONTRACT.schema

--- The reader families the Studio reads, by reader code and payload field.
M.FAMILIES = CONTRACT.families

--- Refusal codes; the page shows `layout_editor.studio.keystats.<code>`.
M.CODES = CONTRACT.codes





-- =============================
-- =============================
-- ======= 1/ Projection =======
-- =============================
-- =============================

--- The number of physical keystrokes of one reader item.
--- @param item table Reader item { c, hs, llm, o }.
--- @return number count Zero or more.
local function physical_count(item)
	if type(item) ~= "table" then return 0 end
	local total = tonumber(item.c) or 0
	local synthetic = (tonumber(item.hs) or 0) + (tonumber(item.llm) or 0) + (tonumber(item.o) or 0)
	local count = total - synthetic
	-- A NaN or an infinity is no count: the store holds integers.
	if count ~= count or count == math.huge or count <= 0 then return 0 end
	return count
end

--- Projects reader dictionaries into the Studio payload.
--- @param dict table Reader output: { c = {token → item}, bg = …, tg = … }.
--- @return table payload { schema, source, chars, bigrams, trigrams, total }.
function M.project(dict)
	assert(type(dict) == "table", "studio_ngrams.project needs the reader's dictionaries")
	local payload = { schema = M.SCHEMA, source = CONTRACT.source, total = 0 }
	for _, family in ipairs(M.FAMILIES) do
		local counts = {}
		for token, item in pairs(type(dict[family.code]) == "table" and dict[family.code] or {}) do
			local count = type(token) == "string" and token ~= "" and physical_count(item) or 0
			if count > 0 then counts[token] = count end
		end
		payload[family.field] = counts
	end
	for _, count in pairs(payload.chars) do payload.total = payload.total + count end
	return payload
end

--- Reads the store and projects it, or refuses with a code.
--- @param deps table { path = string|nil, exists = function(path) -> boolean,
---     read = function(path) -> dict, complete }.
--- @return table result { ok = true, ngrams = payload } or { ok = false, code = string }.
function M.read(deps)
	assert(type(deps) == "table" and type(deps.exists) == "function" and type(deps.read) == "function",
		"studio_ngrams.read needs its exists and read ports")
	local path = deps.path
	if type(path) ~= "string" or path == "" or deps.exists(path) ~= true then
		return { ok = false, code = M.CODES.absent }
	end
	local called, dict, complete = pcall(deps.read, path)
	if not called or type(dict) ~= "table" or complete ~= true then
		return { ok = false, code = M.CODES.unreadable }
	end
	return { ok = true, ngrams = M.project(dict) }
end

return M

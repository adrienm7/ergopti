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
--- 7. Saved read: the last complete projection is kept beside the store, in
---    the contract's snapshot format (one header line, the format then the
---    store stamp, then the payload JSON), the file Windows writes too. A
---    window shows it at once, then the fresh read when the store changed
---    since: the page answers twice. A saved read out of its format, of
---    another schema or of another source is logged and never shown. A
---    metrics purge and a dashboard cache reset retire it (retire_snapshot).
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
		and type(contract.final_field) == "string" and contract.final_field ~= ""
		and type(contract.snapshot) == "table" and type(contract.snapshot.file) == "string"
		and contract.snapshot.file ~= "" and type(contract.snapshot.format) == "string"
		and contract.snapshot.format ~= "",
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

--- The saved read's file name and the prefix of its header line.
M.SNAPSHOT = { file = CONTRACT.snapshot.file, header = CONTRACT.snapshot.format .. " " }





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






-- =============================
-- =============================
-- ======= 2/ Saved read =======
-- =============================
-- =============================

--- Where a host keeps the last complete read of a store: beside it, in the
--- folder that already holds the same counts and that no sync carries.
--- @param store_path string The keystats store.
--- @return string path The saved read's file.
function M.snapshot_path(store_path)
	assert(type(store_path) == "string" and store_path ~= "", "studio_ngrams.snapshot_path needs the store's path")
	local directory = require("core.fs.engine.native_path").dirname(store_path)
	assert(directory, "the keystats store has no folder: " .. store_path)
	return directory .. "/" .. M.SNAPSHOT.file
end

--- Whether a decoded payload is one of this contract's: its schema and source.
--- @param payload any Decoded JSON.
--- @return boolean
local function fits_contract(payload)
	return type(payload) == "table" and payload.schema == M.SCHEMA and payload.source == CONTRACT.source
end

--- The text of one saved read: the header line, then the payload JSON.
--- @param stamp string The store stamp the read was made at, never empty.
--- @param ngrams table The payload, as project returns it.
--- @return string text
function M.encode_snapshot(stamp, ngrams)
	if type(stamp) ~= "string" or stamp == "" or stamp:find("[\r\n]") then
		error("A saved Ergopti Studio read needs its store stamp.", 2)
	end
	if not fits_contract(ngrams) then error("A saved Ergopti Studio read is one payload of the contract.", 2) end
	local json = require("core.text.engine.json").encode(ngrams)
	if type(json) ~= "string" or json:sub(1, 1) ~= "{" then
		error("A saved Ergopti Studio read is one JSON object.", 2)
	end
	return M.SNAPSHOT.header .. stamp .. "\n" .. json
end

--- Reads one saved read's text, failing fast on any other: a corrupt or
--- mismatched read is never shown as the user's data.
--- @param text string The file's content.
--- @return table saved { stamp = string, ngrams = payload }.
function M.decode_snapshot(text)
	if type(text) ~= "string" then error("The saved Ergopti Studio read is no text.", 2) end
	local line_end = text:find("\n", 1, true)
	local header = line_end and text:sub(1, line_end - 1) or ""
	local body = line_end and text:sub(line_end + 1) or ""
	local prefix = M.SNAPSHOT.header
	if header:sub(1, #prefix) ~= prefix or #header == #prefix or header:find("\r", 1, true)
		or body:sub(1, 1) ~= "{" or body:sub(-1) ~= "}" then
		error("The saved Ergopti Studio read is not in its format.", 2)
	end
	local decoded, payload = pcall(require("core.text.engine.json").decode, body)
	if not decoded or type(payload) ~= "table" then error("The saved Ergopti Studio read is corrupt.", 2) end
	if not fits_contract(payload) then
		error("The saved Ergopti Studio read is not of this schema or source.", 2)
	end
	return { stamp = header:sub(#prefix + 1), ngrams = payload }
end

--- Reads the saved read of a store through the host's port.
--- @param snapshot table { read = function(path) -> content, status }.
--- @param path string The saved read's file.
--- @return table|nil saved Nil when none is saved.
local function load_snapshot(snapshot, path)
	local content, status = snapshot.read(path)
	if status == "absent" then return nil end
	if status ~= "ok" then error("the saved Ergopti Studio read cannot be read: " .. path, 0) end
	return M.decode_snapshot(content)
end

--- Removes the saved read of a store (a metrics purge, a dashboard cache
--- reset): the Studio must never show at once what the user deleted. The
--- projection kept in memory goes with it.
--- @param store_path string The keystats store.
--- @param delete function(path) -> boolean, true when no file remains.
--- @return boolean retired True when no saved read remains.
function M.retire_snapshot(store_path, delete)
	assert(type(delete) == "function", "studio_ngrams.retire_snapshot needs its delete port")
	_cache = nil
	return delete(M.snapshot_path(store_path)) == true
end





-- ===========================
-- ===========================
-- ======= 3/ The read =======
-- ===========================
-- ===========================

--- Reads the store and projects it, or refuses with a code. A store whose
--- revision is the cached one answers from the cache without a read. With a
--- snapshot port the saved read answers first, and alone when it was made at
--- the store's current stamp; the fresh read that follows is saved in turn.
--- @param deps table { path = string|nil, exists = function(path) -> boolean,
---     read = function(path) -> dict, complete,
---     stamp = function(path) -> string|nil (optional),
---     snapshot = { read = function(path) -> content, status ("ok", "absent"
---         or a failure), write = function(path, text) -> boolean } (optional),
---     log = function(level, message, ...) (with snapshot),
---     defer = function(work) (optional: runs the fresh read once the saved
---         answer reached the page) }.
--- @param answer function Receives each result: { ok = true, ngrams = payload,
---     cached = boolean, saved = boolean } or { ok = false, code = string }.
function M.read(deps, answer)
	assert(type(deps) == "table" and type(deps.exists) == "function" and type(deps.read) == "function",
		"studio_ngrams.read needs its exists and read ports")
	assert(type(answer) == "function", "studio_ngrams.read needs its answer callback")
	local snapshot = deps.snapshot
	assert(snapshot == nil or (type(snapshot) == "table" and type(snapshot.read) == "function"
		and type(snapshot.write) == "function" and type(deps.log) == "function"),
		"studio_ngrams.read needs the snapshot's read and write ports and a log")
	local path = deps.path
	if type(path) ~= "string" or path == "" or deps.exists(path) ~= true then
		_cache = nil
		return answer({ ok = false, code = M.CODES.absent })
	end
	-- A revision that cannot be read is no revision: the store is read in full.
	local stamp = nil
	if type(deps.stamp) == "function" then
		local stamped, value = pcall(deps.stamp, path)
		if stamped and type(value) == "string" and value ~= "" then stamp = value end
	end
	if stamp and _cache and _cache.path == path and _cache.stamp == stamp then
		return answer({ ok = true, ngrams = _cache.ngrams, cached = true, saved = false })
	end
	-- The saved read first: « My typing » is the Studio's default corpus, and
	-- the first read after a restart pays the whole store.
	local saved_path = snapshot and M.snapshot_path(path) or nil
	local shown = false
	if snapshot then
		local loaded, saved = pcall(load_snapshot, snapshot, saved_path)
		if not loaded then
			deps.log("error", "The saved Ergopti Studio read is ignored: %s", tostring(saved))
		elseif saved then
			shown = true
			answer({ ok = true, ngrams = saved.ngrams, cached = true, saved = true })
			if stamp and saved.stamp == stamp then
				_cache = { path = path, stamp = stamp, ngrams = saved.ngrams }
				return
			end
		end
	end
	local function fresh()
		local called, dict, complete = pcall(deps.read, path)
		if not called or type(dict) ~= "table" or complete ~= true then
			return answer({ ok = false, code = M.CODES.unreadable })
		end
		local ngrams = M.project(dict)
		_cache = stamp and { path = path, stamp = stamp, ngrams = ngrams } or nil
		answer({ ok = true, ngrams = ngrams, cached = false, saved = false })
		if not (stamp and snapshot) then return end
		local encoded, written = pcall(function() return snapshot.write(saved_path, M.encode_snapshot(stamp, ngrams)) end)
		if not encoded then
			deps.log("error", "The Ergopti Studio read could not be saved: %s", tostring(written))
		elseif written ~= true then
			deps.log("error", "The Ergopti Studio read could not be saved beside the keystats store.")
		end
	end
	if shown and type(deps.defer) == "function" then return deps.defer(fresh) end
	return fresh()
end

return M

--- ui/metrics_typing/projection.lua

--- ==============================================================================
--- MODULE: Typing Metrics Incremental Projection
--- DESCRIPTION:
--- Builds the JSON the typing dashboard publishes, reusing the part of the
--- previous projection that covers past days. Only days after the cached
--- watermark are read again; a changed past-data fingerprint discards the
--- cache and rebuilds from scratch. All reads go through
--- `modules.keylogger.sqlite_reader`, the single owner of the aggregation.
---
--- FEATURES & RATIONALE:
--- 1. Exact increments: manifest cells belong to one day, and every n-gram
---    field is a sum, so cached past days plus freshly read later days equal a
---    full read (`sqlite_reader.merge_ngrams` owns the addition).
--- 2. Proved invalidation: a cache is reused only while
---    `sqlite_reader.fingerprint` of its watermark is unchanged. The new
---    watermark's fingerprint is taken before any read, so a write racing the
---    job is detected by the next job instead of being cached as current.
--- 3. Encoded once: past days keep their encoded JSON, so a live update
---    re-encodes only today's slice instead of the whole history.
--- 4. Bounded memory: at most MAX_RANGE_ENTRIES n-gram histories are kept, and
---    `reset()` drops everything (dashboard Reset clears the disk snapshot too).
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local PacedJson = require("infra.paced_json")

local LOG = "metrics_typing.projection"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- N-gram histories kept in memory: the default all-apps view plus one filter.
--- Each all-time history holds every distinct token, so the bound is memory.
local MAX_RANGE_ENTRIES = 2

--- Empty n-gram dict, encoded; the shape the frontend expects for no history.
local EMPTY_NGRAMS_JSON = PacedJson.encode({
	c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {},
})

--- Cached manifest days: { through, fingerprint, days = {date→table}, json = {date→string} }.
local _manifest = nil

--- Cached n-gram histories, most recent first:
--- { key, start, through, fingerprint, data, json }.
local _ranges = {}





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- Builds the cache key of a range request's history.
--- @param start_date string|nil Inclusive lower bound.
--- @param open_ended boolean True when the history follows yesterday.
--- @param through string Fixed upper bound when not open-ended.
--- @param apps table|nil Requested apps.
--- @return string key
local function range_key(start_date, open_ended, through, apps)
	local sorted = {}
	if type(apps) == "table" then
		for _, app in ipairs(apps) do sorted[#sorted + 1] = tostring(app) end
		table.sort(sorted)
	end
	return table.concat({
		start_date or "", open_ended and "open" or through, table.concat(sorted, "\1"),
	}, "\2")
end

--- Moves one cached history to the front and evicts past the bound.
--- @param entry table History entry.
local function remember_range(entry)
	for index = #_ranges, 1, -1 do
		if _ranges[index] == entry or _ranges[index].key == entry.key then table.remove(_ranges, index) end
	end
	table.insert(_ranges, 1, entry)
	while #_ranges > MAX_RANGE_ENTRIES do table.remove(_ranges) end
end

--- Finds the cached history for a key.
--- @param key string Cache key.
--- @return table|nil entry
local function find_range(key)
	for _, entry in ipairs(_ranges) do
		if entry.key == key then return entry end
	end
	return nil
end

--- Assembles an object from pre-encoded members, keys in ascending order.
--- @param members table key→encoded JSON.
--- @return string json
local function assemble_object(members)
	local keys = {}
	for key in pairs(members) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = {}
	for index, key in ipairs(keys) do
		parts[index] = PacedJson.encode(key) .. ":" .. members[key]
	end
	return "{" .. table.concat(parts, ",") .. "}"
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Drops every cached projection. Called by the dashboard Reset.
function M.reset()
	_manifest = nil
	_ranges = {}
	Logger.info(LOG, "Cached typing projections dropped.")
end

--- Opens one projection session. A session memoizes fingerprints so the
--- manifest and range reads of one job validate against the same values.
--- @param reader table `modules.keylogger.sqlite_reader`.
--- @param sqlite_path string Path to db.sqlite.
--- @param today string Current day (YYYY-MM-DD), fixed for the whole job.
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @return table session
function M.session(reader, sqlite_path, today, pacer)
	local yesterday = reader.split_bounds(nil, nil, today).historical_end
	local fingerprints = {}

	local function fingerprint(through)
		if fingerprints[through] == nil then
			local value, err = reader.fingerprint(sqlite_path, through, pacer)
			if not value then
				Logger.warn(LOG, "Past-data fingerprint through %s unavailable (%s); cached projections are rebuilt.",
					through, tostring(err))
			end
			fingerprints[through] = value or false
		end
		return fingerprints[through] or nil
	end

	--- Returns whether a cached entry is still exact through its watermark.
	local function still_valid(entry, target_through)
		if not entry or entry.through > target_through then return false end
		local current = fingerprint(entry.through)
		return current ~= nil and current == entry.fingerprint
	end

	local session = {}

	--- Projects the manifest.
	--- @return table manifest Decoded manifest (date→app→cell).
	--- @return string json Encoded manifest.
	function session.manifest()
		-- The new watermark is fingerprinted before anything is read
		local target_fp = fingerprint(yesterday)
		local days, encoded, read_from = {}, {}, nil
		if still_valid(_manifest, yesterday) then
			for date, day in pairs(_manifest.days) do
				if date <= _manifest.through then
					days[date] = day
					encoded[date] = _manifest.json[date]
				end
			end
			read_from = reader.next_day(_manifest.through)
			Logger.debug(LOG, "Manifest reused through %s; reading from %s.", _manifest.through, read_from)
		else
			Logger.info(LOG, "Manifest projected from scratch (%s).",
				_manifest and "past data changed" or "no cached projection")
		end
		for date, day in pairs(reader.read_manifest(sqlite_path, read_from, nil, pacer)) do
			days[date] = day
			encoded[date] = nil
		end
		for date, day in pairs(days) do
			if not encoded[date] then encoded[date] = PacedJson.encode(day, pacer) end
		end
		if target_fp then
			_manifest = { through = yesterday, fingerprint = target_fp, days = days, json = encoded }
		else
			_manifest = nil
		end
		return days, assemble_object(encoded)
	end

	--- Projects one range request exactly as `read_range_split_today` would.
	--- @param start_date string|nil Inclusive lower bound.
	--- @param end_date string|nil Inclusive upper bound.
	--- @param apps table|nil Requested apps.
	--- @return string json Encoded { historical, today }.
	function session.range(start_date, end_date, apps)
		if start_date == "" then start_date = nil end
		if end_date == "" then end_date = nil end
		local through = reader.split_bounds(start_date, end_date, today).historical_end
		local historical_json = EMPTY_NGRAMS_JSON
		if not start_date or start_date <= through then
			local open_ended = through == yesterday
			local key = range_key(start_date, open_ended, through, apps)
			local target_fp = fingerprint(through)
			local entry = find_range(key)
			if still_valid(entry, through) then
				if entry.through < through then
					local added = reader.read_ngrams(sqlite_path, reader.next_day(entry.through), through, apps, pacer)
					reader.merge_ngrams(entry.data, added)
					entry.json = PacedJson.encode(entry.data, pacer)
					Logger.info(LOG, "N-gram history extended from %s to %s.", entry.through, through)
				end
			else
				Logger.info(LOG, "N-gram history projected from scratch through %s (%s).", through,
					entry and "past data changed" or "no cached projection")
				local data = reader.read_ngrams(sqlite_path, start_date, through, apps, pacer)
				entry = { key = key, start = start_date, data = data, json = PacedJson.encode(data, pacer) }
			end
			entry.through = through
			entry.fingerprint = target_fp
			if target_fp then
				remember_range(entry)
			else
				for index = #_ranges, 1, -1 do
					if _ranges[index].key == key then table.remove(_ranges, index) end
				end
			end
			historical_json = entry.json
		end
		local today_idx = reader.read_today_split(sqlite_path, start_date, end_date, apps, pacer, today)
		return '{"historical":' .. historical_json .. ',"today":' .. PacedJson.encode(today_idx, pacer) .. "}"
	end

	return session
end

return M

--- ui/metrics_typing/projection.lua

--- ==============================================================================
--- MODULE: Typing Metrics Incremental Projection
--- DESCRIPTION:
--- Builds the JSON the typing dashboard publishes, reusing the part of the
--- previous projection that covers past days only when the reader can prove
--- its fingerprint identifies the historical data exactly. The current SQLite
--- reader cannot do so, so it rebuilds the projection on each request. All reads go through
--- `modules.keystats.sqlite_reader`, the single owner of the aggregation.
---
--- FEATURES & RATIONALE:
--- 1. Exact increments: manifest cells belong to one day, and every n-gram
---    field is a sum, so cached past days plus freshly read later days equal a
---    full read (`sqlite_reader.merge_ngrams` owns the addition).
--- 2. Proved invalidation: a cache is reused only when the reader explicitly
---    certifies an exact fingerprint and its watermark is unchanged. The new
---    watermark's fingerprint is taken before any read, so a write racing the
---    job is detected by the next job instead of being cached as current.
--- 3. Encoded once: past days keep their encoded JSON, so a live update
---    re-encodes only today's slice instead of the whole history.
--- 4. Bounded memory: at most MAX_RANGE_ENTRIES n-gram histories are kept, and
---    `reset()` drops everything (dashboard Reset clears the disk snapshot too).
--- 5. Partial reads are shown, never cached. A read that missed rows still
---    returns the counts it read, flagged `incomplete`, and leaves the cache as
---    it was so the next request retries the whole read.
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local PacedJson = require("infra.paced_json")
local TableUtil = require("table_util")

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
--- { key, start, through, fingerprint, data, json, serial }.
local _ranges = {}

--- Last serial given to an encoded history. Never reset, so a serial a page
--- still holds can never name a history encoded after a reset.
local _history_serial = 0





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
	local keys = TableUtil.sorted_keys(members)
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
--- @param reader table `modules.keystats.sqlite_reader`.
--- @param sqlite_path string Path to db.sqlite.
--- @param today string Current day (YYYY-MM-DD), fixed for the whole job.
--- @param pacer table|nil Pacer from `infra.paced_job`.
--- @return table session
function M.session(reader, sqlite_path, today, pacer)
	local yesterday = reader.split_bounds(nil, nil, today).historical_end
	local fingerprints = {}

	local function fingerprint(through)
		-- Aggregate totals are not an identity: compensated changes can leave
		-- them unchanged. A reader must explicitly certify an exact witness
		-- before any projection can be reused or advertised by serial.
		if reader.history_fingerprint_exact ~= true then return nil end
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
	--- @return boolean manifest_complete All requested manifest queries succeeded.
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
		local fresh, complete = reader.read_manifest(sqlite_path, read_from, nil, pacer)
		for date, day in pairs(fresh) do
			days[date] = day
			encoded[date] = nil
		end
		for date, day in pairs(days) do
			if not encoded[date] then encoded[date] = PacedJson.encode(day, pacer) end
		end
		-- A fingerprint certifies stored rows, not a projection's successful reads.
		if target_fp and complete == true then
			_manifest = { through = yesterday, fingerprint = target_fp, days = days, json = encoded }
		else
			_manifest = nil
		end
		return days, assemble_object(encoded), complete == true
	end

	--- Projects one range request exactly as `read_range_split_today` would.
	--- @param start_date string|nil Inclusive lower bound.
	--- @param end_date string|nil Inclusive upper bound.
	--- @param apps table|nil Requested apps.
	--- @param held_serial integer|false|nil Serial of the history the page holds;
	---     false for a payload saved to disk, which must name no serial: serials
	---     restart with the process, so a saved one could name another history.
	--- @return string json Encoded { historical, today }, plus `"incomplete":true`
	---     when a read missed rows. A cached history carries `historical_serial`;
	---     when it equals `held_serial`, `"historical_reused":true` replaces it.
	--- @return boolean range_complete All requested historical and today reads succeeded.
	function session.range(start_date, end_date, apps, held_serial)
		if start_date == "" then start_date = nil end
		if end_date == "" then end_date = nil end
		local through = reader.split_bounds(start_date, end_date, today).historical_end
		local historical_json = EMPTY_NGRAMS_JSON
		local historical_data = nil
		local history_complete = true
		local serial = nil
		if not start_date or start_date <= through then
			local open_ended = through == yesterday
			local key = range_key(start_date, open_ended, through, apps)
			local target_fp = fingerprint(through)
			local cached = find_range(key)
			-- The cached entry is never mutated: the next one is built aside and
			-- published only after every pausable step, so a job abandoned at a
			-- pause cannot leave merged days under the previous watermark.
			local data, json
			if still_valid(cached, through) then
				data, json, serial = cached.data, cached.json, cached.serial
				if cached.through < through then
					serial = nil
					local added
					added, history_complete = reader.read_ngrams(
						sqlite_path, reader.next_day(cached.through), through, apps, pacer)
					-- Merged into a copy: a refused day cannot alter the accepted
					-- history or its watermark, yet its partial counts are shown.
					data = reader.merge_ngrams(reader.merge_ngrams({}, cached.data, pacer), added, pacer)
					json = PacedJson.encode(data, pacer)
					if history_complete == true then
						Logger.info(LOG, "N-gram history extended from %s to %s.", cached.through, through)
					end
				end
			else
				Logger.info(LOG, "N-gram history projected from scratch through %s (%s).", through,
					cached and "past data changed" or "no cached projection")
				data, history_complete = reader.read_ngrams(sqlite_path, start_date, through, apps, pacer)
				json = PacedJson.encode(data, pacer)
			end
			if history_complete == true and target_fp then
				-- A fingerprint certifies stored rows, not a projection's successful reads.
				if serial == nil then
					_history_serial = _history_serial + 1
					serial = _history_serial
				end
				remember_range({ key = key, start = start_date, data = data, json = json,
					through = through, fingerprint = target_fp, serial = serial })
			else
				serial = nil
				if history_complete == true then
					for index = #_ranges, 1, -1 do
						if _ranges[index].key == key then table.remove(_ranges, index) end
					end
				else
					Logger.warn(LOG, "N-gram history read incomplete through %s; partial counts shown, accepted cache unchanged and next request retries.", through)
				end
			end
			historical_json = json
			historical_data = data
		end
		-- Future-dated rows can already exist after a local clock rollback. They
		-- are outside the past-only cache fingerprint and must be read afresh.
		local future_requested = (end_date and end_date > today)
			or (start_date and start_date > today and not end_date)
		if future_requested then
			local first = reader.next_day(today)
			if start_date and start_date > first then first = start_date end
			local future, complete = reader.read_ngrams(sqlite_path, first, end_date, apps, pacer)
			local merged = reader.merge_ngrams({}, historical_data or {}, pacer)
			reader.merge_ngrams(merged, future, pacer)
			historical_json = PacedJson.encode(merged, pacer)
			history_complete = history_complete == true and complete == true
			serial = nil
		end
		local today_idx, today_complete = reader.read_today_split(sqlite_path, start_date, end_date, apps, pacer, today)
		local range_complete = history_complete == true and today_complete == true
		local historical_member
		if held_serial == false then serial = nil end
		if serial ~= nil and serial == held_serial then
			-- The page holds this exact history: resending it each live update
			-- held the main thread about 250 ms (field report 2026-11-03).
			historical_member = string.format('"historical_reused":true,"historical_serial":%d', serial)
		elseif serial ~= nil then
			historical_member = '"historical":' .. historical_json .. string.format(',"historical_serial":%d', serial)
		else
			historical_member = '"historical":' .. historical_json
		end
		return "{" .. historical_member .. ',"today":' .. PacedJson.encode(today_idx, pacer)
			.. (range_complete and "" or ',"incomplete":true') .. "}", range_complete
	end

	return session
end

return M

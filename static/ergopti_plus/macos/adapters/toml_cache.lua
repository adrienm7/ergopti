--- adapters/toml_cache.lua

--- ==============================================================================
--- MODULE: TOML Hotstring Cache Adapter (Hammerspoon)
--- DESCRIPTION:
--- Disk-backed snapshot cache for the shared TOML hotstring parser. The parser
--- (shared/lua/toml_codec/reader.lua) walks every source byte by hand, which is
--- the single biggest contributor to the "Hotstring groups registered" boot
--- phase (~200 ms for the bundled files). This adapter serialises each parsed
--- result into a precompiled Lua chunk so that, on every boot where the source
--- file is unchanged, the parser loads the snapshot via the C-level Lua loader
--- (an order of magnitude faster) instead of re-parsing.
---
--- FEATURES & RATIONALE:
--- 1. Boundary isolation: lives in adapters/ — the only layer allowed to touch
---    the filesystem (io.open) and Hammerspoon APIs (hs.fs) — so the shared
---    reader stays pure. The reader sees only an injected load/store hook.
--- 2. Robust invalidation: a snapshot is served only when the source file's
---    modification time AND size match the values captured when it was written,
---    and the embedded schema version matches. Any mismatch (or a missing /
---    corrupt snapshot) is a silent miss that falls back to a normal parse.
--- 3. Fail-safe: every filesystem call is wrapped in pcall. A read-only cache
---    dir, a partial write, or a syntax error in a snapshot degrades to a parse,
---    never to a crash or — worse — stale data.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "adapters.toml_cache"




-- =====================================
-- =====================================
-- ======= 1/ Constants & State ========
-- =====================================
-- =====================================

--- Schema version embedded in every snapshot. Bump this whenever the shape of
--- the table returned by reader.parse() changes, so stale snapshots written by
--- an older parser are rejected (treated as a miss) instead of fed back with a
--- now-incompatible structure.
local CACHE_VERSION = 1

--- djb2 hash seed and modulus (32-bit) used to derive a collision-resistant
--- snapshot filename from the full source path.
local DJB2_SEED    = 5381
local DJB2_MULT    = 33
local DJB2_MODULUS = 4294967296  -- 2^32

--- Absolute cache directory; nil until init() succeeds. While nil every load()
--- returns a miss and every store() is a no-op, so the parser behaves exactly as
--- it did before the cache existed.
local _cache_dir = nil

--- Lightweight hit/miss counters, surfaced via M.stats() for diagnostics.
local _hits   = 0
local _misses = 0
local _writes = 0




-- =====================================
--- =====================================
-- ======= 2/ Internal helpers =========
--- =====================================
-- =====================================

--- Serialises an arbitrary parse-result value into a Lua literal appended to
--- `out`. Handles strings (via %q, byte-exact incl. UTF-8), integers, floats,
--- booleans, and nested array/map tables — the complete value space produced by
--- reader.parse(). Cycles and functions never occur in parsed TOML, so they are
--- not handled.
--- @param v any The value to serialise.
--- @param out table Accumulator of string fragments (table.concat'd by caller).
local function serialize(v, out)
	local t = type(v)
	if t == "string" then
		out[#out + 1] = string.format("%q", v)
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		if v ~= v then
			out[#out + 1] = "(0/0)"          -- NaN (never produced, defensive)
		elseif v == math.huge then
			out[#out + 1] = "math.huge"
		elseif v == -math.huge then
			out[#out + 1] = "-math.huge"
		elseif math.type(v) == "integer" then
			out[#out + 1] = string.format("%d", v)
		else
			-- %.17g round-trips an IEEE-754 double exactly.
			out[#out + 1] = string.format("%.17g", v)
		end
	elseif t == "table" then
		out[#out + 1] = "{"
		local n = #v
		for i = 1, n do
			serialize(v[i], out)
			out[#out + 1] = ","
		end
		for k, val in pairs(v) do
			local is_array_index = (type(k) == "number" and k == math.floor(k) and k >= 1 and k <= n)
			if not is_array_index then
				if type(k) == "string" then
					out[#out + 1] = "[" .. string.format("%q", k) .. "]="
					serialize(val, out)
					out[#out + 1] = ","
				elseif type(k) == "number" then
					local key = (math.type(k) == "integer")
						and string.format("%d", k) or string.format("%.17g", k)
					out[#out + 1] = "[" .. key .. "]="
					serialize(val, out)
					out[#out + 1] = ","
				end
				-- Non-string/number keys never appear in parsed TOML; drop them.
			end
		end
		out[#out + 1] = "}"
	else
		out[#out + 1] = "nil"
	end
end

--- Reads the modification time and size of a source file.
--- @param path string Absolute source path.
--- @return table|nil ``{ mtime = number, size = number }`` or nil on any failure.
local function source_attr(path)
	local ok, a = pcall(hs.fs.attributes, path)
	if not ok or type(a) ~= "table" then return nil end
	if type(a.modification) ~= "number" or type(a.size) ~= "number" then return nil end
	return { mtime = a.modification, size = a.size }
end

--- 32-bit djb2 hash of a string, used to disambiguate snapshot filenames.
--- @param s string Input.
--- @return number Non-negative 32-bit integer.
local function djb2(s)
	local h = DJB2_SEED
	for i = 1, #s do
		h = (h * DJB2_MULT + s:byte(i)) % DJB2_MODULUS
	end
	return h
end

--- Maps a source path to its snapshot file path inside the cache dir. Combines a
--- sanitised basename (for human readability) with a path hash (for uniqueness).
--- @param path string Absolute source path.
--- @return string Absolute snapshot path.
local function snapshot_path(path)
	local base = path:match("([^/\\]+)$") or "toml"
	base = base:gsub("[^%w%.%-_]", "_")
	return _cache_dir .. "/" .. base .. "_" .. string.format("%d", djb2(path)) .. ".lua"
end

--- Recursively ensures a directory exists (hs.fs.mkdir is non-recursive).
--- @param dir string Absolute directory path.
--- @return boolean True when the directory exists or was created.
local function ensure_dir(dir)
	if type(dir) ~= "string" or dir == "" then return false end
	local ok = pcall(function()
		local accum = dir:sub(1, 1) == "/" and "" or "."
		for seg in dir:gmatch("[^/\\]+") do
			accum = accum .. "/" .. seg
			if not hs.fs.attributes(accum) then hs.fs.mkdir(accum) end
		end
	end)
	if not ok then return false end
	local ok_a, a = pcall(hs.fs.attributes, dir)
	return ok_a and type(a) == "table" and a.mode == "directory"
end




-- =====================================
--- =====================================
-- ======= 3/ Public API ===============
--- =====================================
-- =====================================

--- Initialises the cache against a writable directory. Must be called once at
--- boot before the reader's cache provider is wired. On any failure the cache
--- stays disabled and the parser silently falls back to full parsing.
--- @param cache_dir string Absolute directory for snapshot files.
function M.init(cache_dir)
	Logger.start(LOG, "Initializing TOML hotstring cache…")
	if type(cache_dir) ~= "string" or cache_dir == "" then
		Logger.error(LOG, "init(): cache_dir must be a non-empty string — cache disabled.")
		return
	end
	if not ensure_dir(cache_dir) then
		Logger.warn(LOG, "init(): could not create cache dir '%s' — cache disabled.", cache_dir)
		return
	end
	_cache_dir = cache_dir
	_hits, _misses, _writes = 0, 0, 0
	Logger.success(LOG, "TOML hotstring cache ready at '%s'.", cache_dir)
end

--- Loads a precompiled snapshot for an unchanged source file.
--- @param path string Absolute source TOML path.
--- @return table|nil The parsed table, or nil on any miss (caller re-parses).
function M.load(path)
	if not _cache_dir or type(path) ~= "string" then return nil end

	local attr = source_attr(path)
	if not attr then _misses = _misses + 1; return nil end

	local file = snapshot_path(path)
	local ok_lf, chunk = pcall(loadfile, file)
	if not ok_lf or type(chunk) ~= "function" then _misses = _misses + 1; return nil end

	local ok_run, snap = pcall(chunk)
	if not ok_run or type(snap) ~= "table" then _misses = _misses + 1; return nil end

	if snap.ver ~= CACHE_VERSION
		or snap.mtime ~= attr.mtime
		or snap.size ~= attr.size
		or type(snap.data) ~= "table" then
		_misses = _misses + 1
		return nil
	end

	_hits = _hits + 1
	Logger.debug(LOG, "Snapshot hit for '%s'.", path)
	return snap.data
end

--- Writes (or refreshes) the snapshot for a freshly parsed source file.
--- @param path string Absolute source TOML path.
--- @param parsed table The table returned by reader.parse().
function M.store(path, parsed)
	if not _cache_dir or type(path) ~= "string" or type(parsed) ~= "table" then return end

	local attr = source_attr(path)
	if not attr then return end

	local parts = {}
	serialize(parsed, parts)
	local body = string.format(
		"return {ver=%d,mtime=%.17g,size=%.17g,data=%s}\n",
		CACHE_VERSION, attr.mtime, attr.size, table.concat(parts))

	local ok = pcall(function()
		local fh = io.open(snapshot_path(path), "w")
		if not fh then error("open failed") end
		fh:write(body)
		fh:close()
	end)
	if ok then
		_writes = _writes + 1
		Logger.debug(LOG, "Snapshot written for '%s' (%d bytes).", path, #body)
	else
		Logger.warn(LOG, "Failed to write snapshot for '%s' — cache miss next boot.", path)
	end
end

--- Returns cache activity counters for diagnostics.
--- @return table ``{ enabled, hits, misses, writes, dir }``.
function M.stats()
	return { enabled = _cache_dir ~= nil, hits = _hits, misses = _misses, writes = _writes, dir = _cache_dir }
end

return M

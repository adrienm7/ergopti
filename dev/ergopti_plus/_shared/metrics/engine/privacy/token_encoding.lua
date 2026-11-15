--- _shared/metrics/engine/privacy/token_encoding.lua

--- ==============================================================================
--- MODULE: Keystats Token Encoding
--- DESCRIPTION:
--- N-gram keys are tokens glued together, so a typed "[", "B", "S", "]" and one
--- Backspace used to share the spelling [BS]. Version 2 escapes the typed
--- bracket as [[ and reads the closed marker list of keystats_tokens.json. A key
--- then has one reading: at a "[", the next character tells an escape from a
--- marker. The Windows walker owns the same rule in AHK, and the dashboard in
--- JavaScript; token_encoding_vectors.json is replayed on all of them.
---
--- FEATURES & RATIONALE:
--- 1. Encoding happens at the walk. Raw events keep one entry per keystroke, so
---    they were never ambiguous and stay as written; every derived key is
---    rebuilt from them where the store allows it.
--- 2. migrate_key is only for a store that has derived keys and no replay. The
---    length of the n-gram family settles most old keys; where two readings
---    remain, the earliest marker wins, the reading a real history makes likely.
--- ==============================================================================

local Data = require("metrics.engine.privacy.tokens_data")
local TableUtil = require("core.text.engine.table_util")

local M = {}

M.VERSION = Data.version

-- The families whose keys glue tokens, and how many each key holds. Words have
-- no "[": it ends a word.
M.MIGRATED_FAMILIES = {
	ngram_chars = 1, ngram_bigrams = 2, ngram_trigrams = 3, ngram_quadgrams = 4,
	ngram_pentagrams = 5, ngram_hexagrams = 6, ngram_heptagrams = 7,
}

-- Beside a store whose keys a migration rewrites.
M.BACKUP_SUFFIX = ".pre-ngram-encoding-2.bak"

local LITERAL = Data.literal_bracket
local ALIASES = Data.aliases
local MARKERS = {}
for _, marker in ipairs(Data.markers) do MARKERS[marker] = true end





-- ===============================
-- ===============================
-- ======= 1/ Encoding ===========
-- ===============================
-- ===============================

--- The key form of one raw event.
--- @param char string The event's character or marker.
--- @return string
function M.event_token(char)
	if type(char) ~= "string" or not char:find("[", 1, true) then return char end
	if MARKERS[char] then return char end
	if ALIASES[char] then return ALIASES[char] end
	return (char:gsub("%[", LITERAL))
end

--- The marker or alias that starts at a position of a key, if any.
--- @param key string
--- @param position number Byte offset of a "[".
--- @return string|nil spelling The bytes of the marker as written.
local function marker_at(key, position)
	local closing = key:find("]", position, true)
	if not closing then return nil end
	local spelling = key:sub(position, closing)
	if MARKERS[spelling:upper()] or ALIASES[spelling:upper()] then return spelling end
	return nil
end

--- Splits a version 2 key into its tokens. A lone "[" with no marker reads as a
--- typed bracket, so a key this module did not write still renders.
--- @param key string
--- @return table tokens "[" for a typed bracket, a marker, or one UTF-8 character.
function M.tokens(key)
	local out, position = {}, 1
	while position <= #key do
		local byte = key:byte(position)
		if byte == 91 then -- "["
			if key:sub(position, position + 1) == LITERAL then
				out[#out + 1] = "["
				position = position + 2
			else
				local marker = marker_at(key, position)
				out[#out + 1] = marker or "["
				position = position + (marker and #marker or 1)
			end
		else
			local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
			out[#out + 1] = key:sub(position, position + width - 1)
			position = position + width
		end
	end
	return out
end





-- ===============================
-- ===============================
-- ======= 2/ Stored Keys ========
-- ===============================
-- ===============================

--- Rebuilds one version 1 key of a family of a known token count.
--- @param key string The flat key as stored.
--- @param count number Tokens the family's keys hold.
--- @return string key The version 2 key; every "[" escaped when no reading fits.
function M.migrate_key(key, count)
	if not key:find("[", 1, true) then return key end
	local function read(position, left)
		if position > #key then return left == 0 and "" or nil end
		if left == 0 then return nil end
		local byte = key:byte(position)
		if byte == 91 then
			local marker = marker_at(key, position)
			if marker then
				local rest = read(position + #marker, left - 1)
				if rest then return M.event_token(marker:upper()) .. rest end
			end
			local rest = read(position + 1, left - 1)
			return rest and (LITERAL .. rest) or nil
		end
		local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
		local rest = read(position + width, left - 1)
		return rest and (key:sub(position, position + width - 1) .. rest) or nil
	end
	return read(1, count) or (key:gsub("%[", LITERAL))
end

--- The rewrite of a store's keys, one statement per key that changes. Binary
--- literals carry the bytes, so no key needs SQL or shell quoting. OR ROLLBACK
--- abandons the whole transaction rather than merge two keys into one row.
--- @param keys table table name -> array of stored keys holding a "[".
--- @return table statements
function M.migration_statements(keys)
	local function literal(text)
		return "CAST(X'" .. text:gsub(".", function(c) return string.format("%02X", c:byte()) end) .. "' AS TEXT)"
	end
	local statements = {}
	for _, table_name in ipairs(TableUtil.sorted_keys(keys)) do
		local count = assert(M.MIGRATED_FAMILIES[table_name], "unknown n-gram family")
		local family = keys[table_name]
		table.sort(family)
		for _, key in ipairs(family) do
			local migrated = M.migrate_key(key, count)
			if migrated ~= key then
				statements[#statements + 1] = string.format("UPDATE OR ROLLBACK %s SET token=%s WHERE token=%s;",
					table_name, literal(migrated), literal(key))
			end
		end
	end
	return statements
end

return M

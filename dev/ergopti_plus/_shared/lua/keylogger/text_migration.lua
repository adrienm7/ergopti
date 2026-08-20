--- _shared/lua/keylogger/text_migration.lua

--- ==============================================================================
--- MODULE: Typed-Text Migration Plan (shared)
--- DESCRIPTION:
--- The one definition of what it means to convert ALREADY-STORED events_typing
--- rows between clear text and the at-rest envelope, shared by the Linux and
--- macOS drivers and mirrored by the AutoHotkey driver.
---
--- WHY A MIGRATION EXISTS AT ALL:
--- Turning the setting on only ever protected rows written from that moment on,
--- so the promise made to a user with a year of logs was empty exactly where it
--- mattered most. Turning it off had the mirror problem: the rows stayed
--- encrypted, readable only by the machine that wrote them. This module is the
--- plan both directions follow.
---
--- WHY ONLY THE LOCAL DEVICE'S ROWS:
--- The key derives from the machine id, so a row imported from another device
--- belongs to that device's key domain — this machine could not decrypt it, and
--- encrypting it here would lock its owner out of its own data. Every statement
--- built here is therefore scoped to one device_id, and the caller passes its
--- own. Foreign rows are left exactly as they arrived.
---
--- FEATURES & RATIONALE:
--- 1. Idempotent by construction. needs_conversion() answers "is this value
---    already in the target state?", so a migration interrupted halfway and
---    restarted converges instead of double-wrapping. Restart-safety is then a
---    property of the plan rather than a bookkeeping file that can go stale.
--- 2. Batched by construction. select_batch_sql() takes a cursor and a limit, so
---    no caller can accidentally load a year of keystrokes into memory.
--- 3. The IV rule lives in ONE place. The writers derive it from (device_id, id)
---    for `text` and (device_id, id .. "j") for `events_json`; a migration that
---    re-derived it differently would write rows the reader cannot decrypt. Both
---    now read the suffix from the same table.
--- 4. Pure. Every function is data-in, string-out: nothing here opens a database
---    or spawns anything, so a test can assert the exact SQL and the exact
---    conversion decision without a SQLite binary in sight.
--- ==============================================================================

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- The only table holding literal typed text.
M.TABLE = "events_typing"

--- The only two columns holding what the user actually typed, with the suffix
--- each one's IV input carries. MUST stay in lockstep with the writers
--- (linux sqlite_writer.insert_typing_events, macos _builders.typing,
--- windows KL_BuildInsertTyping): the IV is not stored for the writer's benefit
--- but recomputed from the row identity, so a suffix that drifts produces rows
--- that decrypt to garbage.
M.COLUMNS = {
	{ name = "text",        iv_suffix = ""  },
	{ name = "events_json", iv_suffix = "j" },
}

--- The two directions a migration can run in.
M.MODE_ENCRYPT = "encrypt"
M.MODE_DECRYPT = "decrypt"

--- Rows fetched per batch. Small enough that a machine with a year of logs never
--- holds more than a few hundred rows in memory, large enough that the per-batch
--- SQLite round trip is amortised over real work.
M.DEFAULT_BATCH_SIZE = 200

--- Field separator for the one-line-per-row read format. The fields around it are
--- a decimal id and hex digests, neither of which can contain it.
M.ROW_SEPARATOR = "|"





-- ===============================
-- ===============================
-- ======= 2/ Row Planning =======
-- ===============================
-- ===============================

--- Returns the identifier the per-row IV is derived from, for one column.
--- @param row_id number|string The events_typing row id.
--- @param column string        Column name, as listed in M.COLUMNS.
--- @return string|nil The IV input id, or nil when the column is not migratable.
function M.iv_event_id(row_id, column)
	for _, spec in ipairs(M.COLUMNS) do
		if spec.name == column then
			return tostring(row_id) .. spec.iv_suffix
		end
	end
	return nil
end

--- Decides whether one stored value still has to be converted.
--- This is the whole of the restart-safety story: a value already in the target
--- state is skipped, so re-running a half-finished migration converges instead of
--- double-wrapping an envelope or "decrypting" text that was never encrypted.
--- @param mode         string   M.MODE_ENCRYPT or M.MODE_DECRYPT.
--- @param value        any      The stored column value.
--- @param is_encrypted function Envelope test, supplied by the codec.
--- @return boolean True when the value must be rewritten.
function M.needs_conversion(mode, value, is_encrypted)
	if type(value) ~= "string" or value == "" then return false end
	if type(is_encrypted) ~= "function" then return false end
	local wrapped = is_encrypted(value) == true
	if mode == M.MODE_ENCRYPT then return not wrapped end
	if mode == M.MODE_DECRYPT then return wrapped end
	return false
end




-- ====================================
-- ====================================
-- ======= 3/ SQL Composition =========
-- ====================================
-- ====================================

--- Escapes a value for a single-quoted SQLite literal.
--- @param value any
--- @return string The literal body, WITHOUT its surrounding quotes.
function M.sql_quote(value)
	if type(value) ~= "string" then value = tostring(value == nil and "" or value) end
	return (value:gsub("'", "''"))
end

--- Counts the rows this migration is allowed to touch, so progress can be
--- reported as a fraction rather than as an ever-growing tally.
--- @param device_id string The LOCAL device; foreign rows are never counted.
--- @return string One SELECT statement.
function M.count_sql(device_id)
	-- Aliased because the macOS reader addresses columns by name: without it the
	-- column would be called "COUNT(*)" and the row would read back as nil.
	return string.format("SELECT COUNT(*) AS row_count FROM %s WHERE device_id = '%s';",
		M.TABLE, M.sql_quote(device_id))
end

--- Builds the batch read.
--- `after_id` is an exclusive cursor over the primary key, which is why the
--- statement can never re-read a row it has already returned and why a caller
--- cannot accidentally ask for the whole table.
--- @param device_id string  The LOCAL device.
--- @param after_id  number  Exclusive lower bound on the row id; 0 to start.
--- @param limit     number  Maximum rows to return.
--- @param opts      table|nil { hex = boolean } — hex packs the row into ONE
---   line of hex digits, which is the only delimiter-safe way to read typed text
---   back through a CLI whose output separator can occur inside the text itself.
--- @return string One SELECT statement.
function M.select_batch_sql(device_id, after_id, limit, opts)
	opts = opts or {}
	local projection
	if opts.hex then
		local fields = { "id" }
		for _, spec in ipairs(M.COLUMNS) do
			fields[#fields + 1] = string.format("COALESCE(hex(%s), '')", spec.name)
		end
		projection = table.concat(fields, string.format(" || '%s' || ", M.ROW_SEPARATOR))
	else
		local fields = { "id" }
		for _, spec in ipairs(M.COLUMNS) do
			fields[#fields + 1] = spec.name
		end
		projection = table.concat(fields, ", ")
	end
	return string.format(
		"SELECT %s FROM %s WHERE device_id = '%s' AND id > %d ORDER BY id LIMIT %d;",
		projection, M.TABLE, M.sql_quote(device_id),
		math.floor(tonumber(after_id) or 0), math.floor(tonumber(limit) or M.DEFAULT_BATCH_SIZE))
end

--- Builds the in-place rewrite for ONE row.
--- Only the columns that actually changed are assigned: the aggregates the
--- dashboard computes over — n-grams, counters, WPM, scancodes — are never named
--- by this statement, and encrypting them would cost every query a decryption it
--- does not need.
--- @param device_id   string The LOCAL device.
--- @param row_id      number The events_typing row id.
--- @param assignments table  Array of { name = column, value = new value }.
--- @return string|nil One UPDATE statement, or nil when nothing changed.
function M.update_row_sql(device_id, row_id, assignments)
	if type(assignments) ~= "table" or #assignments == 0 then return nil end
	local sets = {}
	for _, assignment in ipairs(assignments) do
		if not M.is_migratable_column(assignment.name) then return nil end
		sets[#sets + 1] = string.format("%s = '%s'", assignment.name, M.sql_quote(assignment.value))
	end
	return string.format("UPDATE %s SET %s WHERE device_id = '%s' AND id = %d;",
		M.TABLE, table.concat(sets, ", "), M.sql_quote(device_id), math.floor(tonumber(row_id) or 0))
end

--- Reports whether a column name is one this migration may write.
--- A guard rather than a convenience: a typo'd or caller-supplied column name
--- reaching update_row_sql() would UPDATE an aggregate with an encrypted blob.
--- @param name any
--- @return boolean
function M.is_migratable_column(name)
	for _, spec in ipairs(M.COLUMNS) do
		if spec.name == name then return true end
	end
	return false
end




-- ==================================
-- ==================================
-- ======= 4/ Value Decoding ========
-- ==================================
-- ==================================

--- Turns the hex form produced by select_batch_sql{hex=true} back into bytes.
--- @param hex any Hex digits, or "" for an absent value.
--- @return string The decoded bytes; "" when the input is not usable hex.
function M.decode_hex(hex)
	if type(hex) ~= "string" or hex == "" then return "" end
	if #hex % 2 ~= 0 or hex:match("^%x+$") == nil then return "" end
	return (hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end

--- Splits one line of select_batch_sql{hex=true} output into its fields.
--- @param line any One output line.
--- @return number|nil id, table|nil { [column] = decoded value }.
function M.parse_hex_row(line)
	if type(line) ~= "string" or line == "" then return nil, nil end
	local fields = {}
	for field in (line .. M.ROW_SEPARATOR):gmatch("([^" .. M.ROW_SEPARATOR .. "]*)" .. M.ROW_SEPARATOR) do
		fields[#fields + 1] = field
	end
	local row_id = tonumber(fields[1])
	if not row_id or #fields ~= #M.COLUMNS + 1 then return nil, nil end
	local values = {}
	for index, spec in ipairs(M.COLUMNS) do
		values[spec.name] = M.decode_hex(fields[index + 1])
	end
	return row_id, values
end

return M

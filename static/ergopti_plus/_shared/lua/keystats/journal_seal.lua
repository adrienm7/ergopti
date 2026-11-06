--- _shared/lua/keystats/journal_seal.lua

--- ==============================================================================
--- MODULE: Journal Sealing (Shared)
--- DESCRIPTION:
--- Seals the literal typed text of a typing row before it is written to the
--- today.log JSONL journal, and reopens it when the journal is read back. The
--- Windows mirror is KL_JournalSealEntry / KL_JournalUnsealEntry in
--- windows/modules/keystats/keystats_journal.ahk; both seal the same fields.
---
--- FEATURES & RATIONALE:
--- 1. "Encrypt logs on disk" used to seal only the SQL columns, while every
---    typing row first sat in today.log in clear until the day's rollover. A
---    sealed row keeps its aggregates readable and turns `text`, `rich_text`
---    and `events` into envelopes of the shared at-rest codec.
--- 2. The `_sealed` flag, not a content prefix, tells the reader to open the
---    fields: typed text may itself begin with an envelope marker.
--- 3. Fail closed both ways. A seal that cannot run returns nil so the caller
---    keeps the row instead of writing plaintext; a sealed field that cannot be
---    opened returns nil so the reader holds its checkpoint instead of
---    acknowledging text that never reached the database.
--- 4. The accepted entry is never mutated: the seal works on a shallow copy, so
---    the in-memory row keeps feeding the database writer in clear.
--- ==============================================================================

local M = {}

--- Typing-row fields that hold what the user literally typed.
M.FIELDS = { "text", "rich_text", "events" }

--- Journal member marking a sealed row.
M.MARK = "_sealed"




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Returns the journal form of an accepted entry.
--- @param entry table Accepted event.
--- @param ports table {
---   cipher = { is_enabled(), encrypt(device_id, event_id, plaintext) },
---   encode = function(value) -> string: JSON encoder for `events`,
---   iv_id = function(field) -> string: a per-row, per-field unique IV input }
--- @return table|nil sealed The entry itself or a sealed copy; nil when sealing failed.
--- @return string|nil err The field that could not be sealed.
function M.seal(entry, ports)
	if type(entry) ~= "table" or entry.type ~= "typing" or not ports.cipher.is_enabled() then
		return entry
	end
	local sealed = {}
	for key, value in pairs(entry) do sealed[key] = value end
	for _, field in ipairs(M.FIELDS) do
		local value = entry[field]
		if value ~= nil then
			local plain = field == "events" and ports.encode(value) or tostring(value)
			local envelope = ports.cipher.encrypt("journal", ports.iv_id(field), plain)
			if type(envelope) ~= "string" or (plain ~= "" and envelope == plain) then
				return nil, field
			end
			sealed[field] = envelope
		end
	end
	sealed[M.MARK] = 1
	return sealed
end

--- Reopens a sealed journal row; a plain row is returned unchanged.
--- @param entry table Decoded JSONL record, mutated in place.
--- @param ports table {
---   cipher = { decrypt(value) -> string: "" when an envelope cannot be read },
---   is_envelope = function(value) -> boolean,
---   decode = function(text) -> any: JSON decoder for `events` }
--- @return table|nil entry The opened record; nil when a sealed field cannot be opened.
--- @return string|nil err The field that could not be opened.
function M.unseal(entry, ports)
	if type(entry) ~= "table" or entry[M.MARK] == nil then return entry end
	for _, field in ipairs(M.FIELDS) do
		local value = entry[field]
		if value ~= nil and ports.is_envelope(value) then
			local plain = ports.cipher.decrypt(value)
			if type(plain) ~= "string" or plain == "" then return nil, field end
			if field == "events" then
				local ok, decoded = pcall(ports.decode, plain)
				if not ok or decoded == nil then return nil, field end
				entry[field] = decoded
			else
				entry[field] = plain
			end
		end
	end
	entry[M.MARK] = nil
	return entry
end

return M

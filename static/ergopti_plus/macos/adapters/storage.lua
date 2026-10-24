--- adapters/storage.lua

--- ==============================================================================
--- MODULE: Storage Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Storage port contract. Logical keys are
--- persisted below the private `ergopti.` prefix in the global hs.settings
--- domain, which survives Hammerspoon reloads and system reboots.
---
--- FEATURES & RATIONALE:
--- 1. Physical Namespace: foreign Hammerspoon defaults are invisible to every
---    public method, including keys() and clear().
--- 2. Fail-Safe Returns: adapter failures never masquerade as successful
---    writes, reads, or deletions.
--- 3. Defensive Boundaries: every hs.settings call is protected because native
---    defaults operations can raise.
--- 4. Explicit Migration: only a finite allowlist of historical Ergopti keys
---    can move into the namespace; unrelated settings are never touched.
--- ==============================================================================

local M = {}
local json = require("json")

local hs     = hs
local Logger = require("infra.logger")

local _owned_writer = nil

--- Resolves publication only after Storage has completed its boot ownership.
--- Eager Writer resolution softly loads i18n, whose native owner needs Storage.
--- @return table writer
local function owned_writer()
	if _owned_writer == nil then _owned_writer = require("toml_codec.writer") end
	return _owned_writer
end

local LOG = "adapters.storage"
local PHYSICAL_PREFIX = "ergopti."
local MIGRATION_MARKER = PHYSICAL_PREFIX .. "settings_namespace_migration_v1"

local LEGACY_FIXED_KEYS = {
	"i18n_locale",
	"llm.enabled",
	"llm_backend",
	"llm_debounce",
	"llm_max_words",
	"llm_min_words",
	"llm_temperature",
	"llm_context_length",
	"llm_pred_indent",
	"llm_nav_modifiers",
	"llm_val_modifiers",
	"llm_api_entries",
	"llm_api_entry_id",
	"llm_api_state_v1",
	"llm_api_keychain_cleanup_v1",
	"magickey_repeat_enabled",
}

local LEGACY_RENAMED_KEYS = {
	["ergopti_hs_boot_ready_v1"] = "hs_boot_ready_v1",
	["ergopti_reload_in_progress"] = "reload_in_progress",
	["ergopti_ui_restore_state"] = "ui_restore_state",
	["ergopti_plus.synthetic_input.next_tag_sequence_v2"] =
		"synthetic_input.next_tag_sequence_v2",
}

local LEGACY_DYNAMIC_PREFIXES = {
	"hotstrings_section_",
	"keyboard_shortcut_",
}





-- =========================================
-- =========================================
-- ======= 1/ Namespace Helpers ============
-- =========================================
-- =========================================

--- Maps a public logical key to the private Hammerspoon defaults domain.
--- Callers cannot pass an already-physical key and bypass ownership checks.
--- @param key any Logical settings key.
--- @return string|nil physical_key
--- @return string|nil detail
local function physical_key(key)
	if type(key) ~= "string" or key == "" then
		return nil, "key must be a non-empty string"
	end
	if key:sub(1, #PHYSICAL_PREFIX) == PHYSICAL_PREFIX then
		return nil, "key must be logical, not already namespaced"
	end
	return PHYSICAL_PREFIX .. key
end

--- Validates logical storage identity before an aggregate owns it.
--- @param key string
--- @return boolean valid
local function owned_logical_key(key) return physical_key(key) ~= nil end

-- The owned-alias gates, receipt authority and finalization shared with the
-- other Lua driver; capture, publish and restore below stay native.
local Owned = require("storage_owned")
local _owned = Owned.new({
	name = "adapters.storage", module = M, logical_key = owned_logical_key, logger = Logger, log = LOG,
})
local owned_copy, owned_cell_equal = Owned.copy, Owned.cell_equal
local _owned_gates, _owned_aliases, _owned_generations, _owned_receipts =
	_owned.gates, _owned.aliases, _owned.generations, _owned.receipts
local owned_authority, owned_updates, owned_live, owned_methods, owned_guard =
	_owned.authority, _owned.updates, _owned.live, _owned.methods, _owned.guard
M.acquire_owned, M.release_owned = _owned.acquire, _owned.release
M.pending_owned, M.forget_owned = _owned.pending, _owned.forget

--- Extracts every unique string from Hammerspoon's hybrid getKeys() table.
--- Native builds expose both dense values and name lookups; consuming only
--- pairs keys would otherwise attempt to clear numeric indexes 1, 2, ... .
--- @param result table Native getKeys result.
--- @return table keys Sorted unique physical keys.
local function normalize_native_keys(result)
	local seen = {}
	for key, value in pairs(result) do
		if type(key) == "string" then seen[key] = true end
		if type(value) == "string" then seen[value] = true end
	end
	local keys = {}
	for key in pairs(seen) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

--- Reads the native key catalogue without collapsing adapter failure.
--- @return boolean ok
--- @return table|string keys_or_error
local function native_keys_exact()
	local ok, result = pcall(hs.settings.getKeys)
	if not ok then return false, result end
	if type(result) ~= "table" then return false, "native key list is not a table" end
	return true, normalize_native_keys(result)
end

--- Compares settings values after native serialization may have copied tables.
--- @param left any
--- @param right any
--- @param seen table|nil
--- @return boolean equal
local function settings_values_equal(left, right, seen)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	seen = seen or {}
	if seen[left] == right then return true end
	seen[left] = right
	for key, value in pairs(left) do
		if not settings_values_equal(value, right[key], seen) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Logs one invalid logical-key attempt.
--- @param operation string
--- @param key any
--- @param detail string
local function log_invalid_key(operation, key, detail)
	Logger.error(LOG, "%s(): refused key '%s' — %s.", operation, tostring(key), detail)
end





-- =========================================
-- =========================================
-- ======= 2/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Stores a value under one logical key.
--- @param key string Logical settings key.
--- @param value any Value to persist.
--- @return boolean committed
function M.set(key, value)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("set", key, key_err); return false end
	if _owned_aliases[key] ~= nil then return false end
	local ok, result = pcall(hs.settings.set, native_key, value)
	if not ok or result == false then
		Logger.error(LOG, "set(): failed to write key '%s' — %s.", key, tostring(result))
		return false
	end
	_owned_generations[key] = (_owned_generations[key] or 0) + 1
	return true
end

--- Reads one logical key.
--- @param key string Logical settings key.
--- @param default_value any Returned when no value is stored.
--- @return any value
function M.get(key, default_value)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("get", key, key_err); return default_value end
	local ok, result = pcall(hs.settings.get, native_key)
	if not ok then
		Logger.error(LOG, "get(): failed to read key '%s' — %s.", key, tostring(result))
		return default_value
	end
	if result == nil then return default_value end
	return result
end

--- Reads a logical key while distinguishing absence from adapter failure.
--- @param key string Logical settings key.
--- @return boolean ok
--- @return any value
function M.read_exact(key)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("read_exact", key, key_err); return false, nil end
	local ok, result = pcall(hs.settings.get, native_key)
	if not ok then
		Logger.error(LOG, "read_exact(): failed to read key '%s' — %s.", key, tostring(result))
		return false, nil
	end
	return true, result
end

--- Tells whether a native clear that answered false left the key absent.
--- hs.settings.clear answers false when the key did not exist, which is a
--- completed delete; a key still readable afterwards is a refused one.
--- @param native_key string Physical settings key.
--- @return boolean absent True when nothing is stored under the key.
local function cleared_absent(native_key)
	local ok, remaining = pcall(hs.settings.get, native_key)
	return ok and remaining == nil
end

--- Deletes one logical key. Deleting a key that does not exist succeeds.
--- @param key string Logical settings key.
--- @return boolean committed
function M.delete(key)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("delete", key, key_err); return false end
	if _owned_aliases[key] ~= nil then return false end
	local ok, result = pcall(hs.settings.clear, native_key)
	if not ok or (result == false and not cleared_absent(native_key)) then
		Logger.error(LOG, "delete(): failed to clear key '%s' — %s.", key, tostring(result))
		return false
	end
	_owned_generations[key] = (_owned_generations[key] or 0) + 1
	return true
end

--- Deletes one logical key and verifies its absence.
--- @param key string Logical settings key.
--- @return boolean deleted
function M.delete_exact(key)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("delete_exact", key, key_err); return false end
	if _owned_aliases[key] ~= nil then return false end
	local ok, result = pcall(hs.settings.clear, native_key)
	if not ok or (result == false and not cleared_absent(native_key)) then
		Logger.error(LOG, "delete_exact(): failed to clear key '%s' — %s.", key, tostring(result))
		return false
	end
	local read_ok, remaining = pcall(hs.settings.get, native_key)
	if not read_ok then
		Logger.error(LOG, "delete_exact(): failed to verify key '%s' — %s.",
			key, tostring(remaining))
		return false
	end
	if remaining ~= nil then
		Logger.error(LOG, "delete_exact(): key '%s' remained after clear.", key)
		return false
	end
	_owned_generations[key] = (_owned_generations[key] or 0) + 1
	return true
end

--- Reports whether one logical key has a value.
--- @param key string Logical settings key.
--- @return boolean present
function M.has(key)
	local native_key, key_err = physical_key(key)
	if not native_key then log_invalid_key("has", key, key_err); return false end
	local ok, result = pcall(hs.settings.get, native_key)
	if not ok then
		Logger.error(LOG, "has(): failed to probe key '%s' — %s.", key, tostring(result))
		return false
	end
	return result ~= nil
end

--- Returns the logical keys owned by Ergopti.
--- @return table keys
function M.keys()
	local ok, result = native_keys_exact()
	if not ok then
		Logger.error(LOG, "keys(): failed to retrieve key list — %s.", tostring(result))
		return {}
	end
	local keys = {}
	for _, native_key in ipairs(result) do
		if native_key:sub(1, #PHYSICAL_PREFIX) == PHYSICAL_PREFIX then
			keys[#keys + 1] = native_key:sub(#PHYSICAL_PREFIX + 1)
		end
	end
	table.sort(keys)
	return keys
end

--- Deletes every Ergopti-owned key and proves each postcondition.
--- @return boolean committed
function M.clear()
	if next(_owned_aliases) ~= nil then return false end
	local keys_ok, native_keys = native_keys_exact()
	if not keys_ok then
		Logger.error(LOG, "clear(): failed to retrieve key list — %s.", tostring(native_keys))
		return false
	end
	local keys = {}
	for _, native_key in ipairs(native_keys) do
		if native_key:sub(1, #PHYSICAL_PREFIX) == PHYSICAL_PREFIX then
			keys[#keys + 1] = native_key:sub(#PHYSICAL_PREFIX + 1)
		end
	end
	for _, key in ipairs(keys) do
		if M.delete_exact(key) ~= true then
			Logger.error(LOG, "clear(): exact deletion refused for key '%s'.", key)
			return false
		end
	end
	Logger.debug(LOG, "clear(): removed %d key(s).", #keys)
	return true
end





-- =========================================
-- =========================================
-- ======= 3/ One-Time Legacy Migration ===
-- =========================================
-- =========================================

--- Moves one allowlisted legacy physical key into the private namespace.
--- An existing namespaced value wins; the legacy owner clears only after the
--- destination is proven durable by readback.
--- @param legacy_key string
--- @param logical_key string
--- @return boolean committed
--- @return string|nil detail
local function migrate_one(legacy_key, logical_key)
	local target_key, target_err = physical_key(logical_key)
	if not target_key then return false, target_err end
	if _owned_aliases[logical_key] ~= nil then return false, "logical alias is acquired" end
	local legacy_ok, legacy_value = pcall(hs.settings.get, legacy_key)
	if not legacy_ok then return false, tostring(legacy_value) end
	if legacy_value == nil then return true end

	local target_ok, target_value = pcall(hs.settings.get, target_key)
	if not target_ok then return false, tostring(target_value) end
	if target_value == nil then
		local write_ok, write_result = pcall(hs.settings.set, target_key, legacy_value)
		if not write_ok or write_result == false then return false, tostring(write_result) end
		local verify_ok, verified = pcall(hs.settings.get, target_key)
		if not verify_ok then return false, tostring(verified) end
		if not settings_values_equal(verified, legacy_value) then
			return false, "namespaced readback mismatch"
		end
	end

	local clear_ok, clear_result = pcall(hs.settings.clear, legacy_key)
	if not clear_ok or clear_result == false then return false, tostring(clear_result) end
	local verify_clear_ok, remaining = pcall(hs.settings.get, legacy_key)
	if not verify_clear_ok then return false, tostring(remaining) end
	if remaining ~= nil then return false, "legacy key remained after clear" end
	return true
end

--- Migrates the finite historical Ergopti allowlist and commits a marker last.
--- @return boolean committed
function M.migrate_legacy_namespace()
	local marker_ok, marker = pcall(hs.settings.get, MIGRATION_MARKER)
	if not marker_ok then
		Logger.error(LOG, "Legacy namespace migration marker could not be read — %s.",
			tostring(marker))
		return false
	end
	if marker == true then return true end

	local migrations = {}
	for _, legacy_key in ipairs(LEGACY_FIXED_KEYS) do migrations[legacy_key] = legacy_key end
	for legacy_key, logical_key in pairs(LEGACY_RENAMED_KEYS) do
		migrations[legacy_key] = logical_key
	end
	local keys_ok, native_keys = native_keys_exact()
	if not keys_ok then
		Logger.error(LOG, "Legacy namespace migration key scan failed — %s.",
			tostring(native_keys))
		return false
	end
	for _, native_key in ipairs(native_keys) do
		for _, legacy_prefix in ipairs(LEGACY_DYNAMIC_PREFIXES) do
			if native_key:sub(1, #legacy_prefix) == legacy_prefix then
				migrations[native_key] = native_key
			end
		end
	end

	if _owned_aliases[MIGRATION_MARKER:sub(#PHYSICAL_PREFIX + 1)] ~= nil then return false end
	for _, logical_key in pairs(migrations) do if _owned_aliases[logical_key] ~= nil then return false end end

	local legacy_keys = {}
	for legacy_key in pairs(migrations) do legacy_keys[#legacy_keys + 1] = legacy_key end
	table.sort(legacy_keys)
	for _, legacy_key in ipairs(legacy_keys) do
		local migrated, migration_err = migrate_one(legacy_key, migrations[legacy_key])
		if not migrated then
			Logger.error(LOG, "Legacy namespace migration failed for '%s' — %s.",
				legacy_key, tostring(migration_err))
			return false
		end
	end

	local marker_write_ok, marker_write_result = pcall(
		hs.settings.set,
		MIGRATION_MARKER,
		true
	)
	if not marker_write_ok or marker_write_result == false then
		Logger.error(LOG, "Legacy namespace migration marker could not be written — %s.",
			tostring(marker_write_result))
		return false
	end
	local marker_verify_ok, marker_verified = pcall(hs.settings.get, MIGRATION_MARKER)
	if not marker_verify_ok or marker_verified ~= true then
		Logger.error(LOG, "Legacy namespace migration marker readback failed.")
		return false
	end
	Logger.info(LOG, "Legacy settings namespace migration committed.")
	return true
end

--- Reads the complete acquired cohort from the actual native settings surface.
--- @param keys table
--- @return table cells
local function owned_native_cells(keys)
	local cells = {}
	for _, key in ipairs(keys) do
		local okay, value = pcall(hs.settings.get, assert(physical_key(key)))
		assert(okay, "native settings read refused")
		cells[key] = { present = value ~= nil, value = owned_copy(value) }
	end
	return cells
end

--- Checks every acquired alias and its cooperating same-value generation.
--- @param record table
--- @param cells table
--- @return boolean current
local function owned_native_current(record, cells)
	if not owned_live(record) or not rawequal(hs.settings, record.native) or not rawequal(hs.settings.get, record.native_get)
		or not rawequal(hs.settings.set, record.native_set) or not rawequal(hs.settings.clear, record.native_clear) then return false end
	for _, key in ipairs(record.keys) do
		if not owned_cell_equal(cells[key], record.expected[key])
			or (_owned_generations[key] or 0) ~= record.generations[key] then return false end
	end
	return true
end

--- Captures a detached cohort with a private, non-forgeable native receipt.
--- @param owner table
--- @return table|nil receipt
--- @return table|nil cells Detached present/value cells for shared policy checks.
function M.capture_owned(owner)
	if not rawequal(package.loaded["adapters.storage"], M) then return nil end
	local gate = _owned_gates[owner]
	if not gate or gate.busy or gate.debt ~= nil then return nil end
	local captured, cells = owned_guard(gate, function()
		local identity = { native = hs.settings, native_get = hs.settings.get, native_set = hs.settings.set,
			native_clear = hs.settings.clear, methods = owned_methods() }
		local snapshot, generations = owned_native_cells(gate.keys), {}
		if not owned_live(identity) or not rawequal(hs.settings, identity.native) or not rawequal(hs.settings.get, identity.native_get)
			or not rawequal(hs.settings.set, identity.native_set) or not rawequal(hs.settings.clear, identity.native_clear) then return nil end
		for _, key in ipairs(gate.keys) do generations[key] = _owned_generations[key] or 0 end
		gate.sequence = gate.sequence + 1
		local token = {}
		_owned_receipts[token] = { owner = owner, keys = owned_copy(gate.keys), snapshot = snapshot,
			expected = owned_copy(snapshot), generations = generations, epoch = gate.epoch,
			sequence = gate.sequence, pending = false, changed = {}, methods = identity.methods,
			native = identity.native, native_get = identity.native_get, native_set = identity.native_set, native_clear = identity.native_clear }
		if not rawequal(package.loaded["adapters.storage"], M) then return nil end
		return token, owned_copy(snapshot)
	end)
	return type(captured) == "table" and captured or nil, cells
end

--- Settles only actual native backup cleanup before another settings effect.
--- @param record table
--- @return boolean settled
local function owned_backup_settled(record)
	if not record.backup then return true end
	if owned_writer().retry_publication_cleanup(record.backup) ~= true then return false end

	return true
end

--- Resolves a write whose native acknowledgement or readback was interrupted.
--- A third-party replacement remains untouched and keeps the inverse pending.
--- @param record table
--- @return boolean resolved
local function owned_native_attempt_settled(record)
	local attempt = record.attempt
	if not attempt then return true end
	local cells = owned_native_cells(record.keys)
	local cell = cells[attempt.key]
	if owned_cell_equal(cell, attempt.after) then
		local previous = record.expected[attempt.key]
		record.expected[attempt.key] = owned_copy(attempt.after)
		-- A void native setter completion becomes an acknowledgement only after
		-- every captured alias and the exact live provider still match readback.
		if not owned_native_current(record, cells) then record.expected[attempt.key] = previous; return false end
		record.changed[attempt.key] = not (attempt.inverse and attempt.acknowledged) or nil
	elseif not owned_cell_equal(cell, attempt.before) then return false end
	record.attempt = nil
	return true
end

--- Interprets the actual primitive's return without inventing a setter Boolean.
--- Hammerspoon1.1.1 set returns no values; clear returns an actual Boolean.
--- Successful compatibility setters may return true, but all admitted results
--- still require matching whole-cohort readback in the settlement owner above.
--- @param after table Expected present/value cell.
--- @param called boolean Protected native call completion.
--- @param result any Actual primitive return.
--- @return boolean acknowledged
local function owned_native_ack(after, called, result)
	return called == true and (result == true or (after.present and result == nil))
end

--- Publishes just supplied cells after a verified backup and native source check.
--- Hammerspoon offers no atomic multi-key cross-process settings transaction.
--- @param owner table
--- @param receipt table
--- @param updates table Owned alias to present/value cell.
--- @param backup_path string Unoccupied durable backup destination.
--- @param files table Classified conditional native file adapter.
--- @return boolean published
function M.publish_owned(owner, receipt, updates, backup_path, files)
	local gate, record = owned_authority(owner, receipt, true)
	if not gate then return false end
	local detached = owned_updates(owner, updates)
	if not detached or type(backup_path) ~= "string" or (backup_path == "" or backup_path:find("\0", 1, true))
		or type(files) ~= "table" or type(files.read_with_status) ~= "function"
		or type(files.write_if_unchanged) ~= "function" then return false end
	return owned_guard(gate, function()
		if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
		record.used, record.files, record.updates = true, files, detached
		record.file_owner, record.file_methods = files, { read_with_status = files.read_with_status, write_if_unchanged = files.write_if_unchanged }
		local bytes = assert(json.encode({ format = "ergopti-owned-settings-v1", cells = record.snapshot }))
		record.backup = { path = backup_path, content = bytes }
		record.pending, gate.debt = true, record
		local backed, _, cleanup = owned_writer().publish_if_unchanged(backup_path, bytes, files, { status = "absent" })
		if type(cleanup) == "function" then record.backup.publication_cleanup = cleanup end
		record.backup.publication_effect = backed == true
		if not owned_backup_settled(record) then return false end
		if backed ~= true then record.pending, gate.debt = false, nil; return false end
		local verified, status = owned_writer().read_classified(backup_path, files)
		if status ~= "ok" or verified ~= bytes then record.pending, gate.debt = false, nil; return false end
		for _, key in ipairs(record.keys) do
			local after = detached[key]
			if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
			if after and not owned_cell_equal(after, record.expected[key]) then
				local before = owned_copy(record.expected[key])
				record.attempt = { key = key, before = before, after = after, inverse = record.restoring == true }
				local okay, result
				if after.present then okay, result = pcall(hs.settings.set, assert(physical_key(key)), owned_copy(after.value))
				else okay, result = pcall(hs.settings.clear, assert(physical_key(key))) end
				local acknowledged = owned_native_ack(after, okay, result)
				record.attempt.acknowledged = acknowledged
				if not owned_native_attempt_settled(record) then return false end
				if not acknowledged or not owned_cell_equal(record.expected[key], after) then
					if next(record.changed) == nil then record.pending, gate.debt = false, nil end
					return false
				end
			end
		end
		if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
		for key in pairs(detached) do
			_owned_generations[key] = (_owned_generations[key] or 0) + 1
			record.generations[key] = _owned_generations[key]
		end
		record.committed, record.pending, gate.debt = true, false, nil
		return true
	end)
end

--- Restores a retained committed/partial receipt while preserving foreign aliases.
--- @param owner table
--- @param receipt table
--- @return boolean restored
function M.restore_owned(owner, receipt)
	local gate, record = owned_authority(owner, receipt, false)
	if not gate then return false end
	return owned_guard(gate, function()
		if record.restored then return true end
		if next(record.changed) ~= nil or record.attempt ~= nil then record.pending, gate.debt = true, record end
		if not owned_backup_settled(record) or not owned_native_attempt_settled(record) then return false end
		if not record.used or (next(record.changed) == nil and record.attempt == nil) then
			record.restored, record.pending, gate.debt = true, false, nil; return true
		end
		if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
		record.pending, gate.debt, record.restoring = next(record.changed) ~= nil, record, true
		for _, key in ipairs(record.keys) do
			if record.changed[key] then
				if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
				local before, after = owned_copy(record.expected[key]), record.snapshot[key]
				record.attempt = { key = key, before = before, after = after, inverse = record.restoring == true }
				local okay, result
				if after.present then okay, result = pcall(hs.settings.set, assert(physical_key(key)), owned_copy(after.value))
				else okay, result = pcall(hs.settings.clear, assert(physical_key(key))) end
				local acknowledged = owned_native_ack(after, okay, result)
				record.attempt.acknowledged = acknowledged
				if not owned_native_attempt_settled(record) then return false end
				if not acknowledged or not owned_cell_equal(record.expected[key], after) then return false end
				record.changed[key] = nil
			end
		end
		if not owned_native_current(record, owned_native_cells(record.keys)) then return false end
		for key in pairs(record.updates or {}) do _owned_generations[key] = (_owned_generations[key] or 0) + 1 end
		record.restored, record.pending, gate.debt = true, false, nil
		return true
	end)
end

M.PHYSICAL_PREFIX = PHYSICAL_PREFIX

return M

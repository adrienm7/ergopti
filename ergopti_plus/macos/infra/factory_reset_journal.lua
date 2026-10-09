--- infra/factory_reset_journal.lua

--- ==============================================================================
--- MODULE: Durable Factory-Reset Journal
--- DESCRIPTION:
--- Persists the reset decision before configuration files leave their canonical
--- paths, then reconciles that decision before the next boot reads configuration.
--- A prepared transaction restores user bytes; a committed transaction consumes
--- its recovery shadows and lets factory defaults be seeded.
---
--- FEATURES & RATIONALE:
--- 1. Durable Decision: Prepared, committed, and cleared phases are published by
---    exact compare-and-swap writes. Backup filenames alone are never interpreted
---    as intent because successful reset and process death produce the same names.
--- 2. Exact Reconciliation: Each source/backup pair is locked, classified by inode,
---    and changed only through create-only hard links and exact unlink operations.
--- 3. Idempotent Boot: A crash during reconciliation leaves the prior durable phase;
---    the next boot observes the partial postcondition and resumes safely.
--- ==============================================================================

local M = {}

local FileSystem = require("adapters.file_system")
local JsonCodec = require("adapters.json_codec")
local Logger = require("infra.logger")

local LOG = "factory_reset_journal"
local VERSION = 1
local JOURNAL_SUFFIX = ".ergopti-reset-journal-v1.json"
local BACKUP_PREFIX = ".ergopti-reset-backup-"
local VALID_PHASES = { prepared = true, commit = true, cleared = true }
local unpack_args = table.unpack or unpack

--- Returns the single durable journal pathname owned by one configuration root.
--- @param config_path string Canonical config.toml pathname.
--- @return string|nil journal_path
function M.path_for(config_path)
	if type(config_path) ~= "string" or config_path == "" then return nil end
	return config_path .. JOURNAL_SUFFIX
end

--- Creates one process-local owner for a durable journal pathname.
--- @param journal_path string Path returned by path_for().
--- @param overrides table|nil Test-only dependency overrides.
--- @return table|nil owner
--- @return string|nil detail
function M.create(journal_path, overrides)
	overrides = type(overrides) == "table" and overrides or {}
	local fs = overrides.file_system or FileSystem
	local codec = overrides.json_codec or JsonCodec
	if type(journal_path) ~= "string" or journal_path == "" then
		return nil, "journal path must be a non-empty string"
	end
	for _, method in ipairs({
		"read_with_status", "create_if_absent", "write_if_unchanged",
		"classify_no_follow", "acquire_write_locks", "release_write_locks",
		"hard_link_create_only", "remove_exact",
	}) do
		if type(fs[method]) ~= "function" then return nil, "missing file-system method: " .. method end
	end
	if type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then
		return nil, "JSON codec is incomplete"
	end

	local owner = {
		journal_path = journal_path,
		current_bytes = nil,
		current_record = nil,
		lock_debt = nil,
	}

	local function canonical_identity(identity)
		if type(identity) ~= "table" then return nil end
		local dev = type(identity.dev) == "number" and tostring(identity.dev) or identity.dev
		local ino = type(identity.ino) == "number" and tostring(identity.ino) or identity.ino
		if type(dev) ~= "string" or not dev:match("^%d+$")
			or type(ino) ~= "string" or not ino:match("^%d+$") then return nil end
		return { dev = dev, ino = ino }
	end

	local function copy_entries(entries)
		local copy = {}
		for _, entry in ipairs(entries or {}) do
			copy[#copy + 1] = {
				path = entry.path,
				backup = entry.backup,
				existed = entry.existed == true,
				identity = entry.existed == true and canonical_identity(entry.identity) or nil,
			}
		end
		table.sort(copy, function(left, right) return left.path < right.path end)
		return copy
	end

	local function valid_entries(entries)
		if type(entries) ~= "table" then return nil, "entries must be an array" end
		local dense_count = 0
		for index in pairs(entries) do
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
				return nil, "entries must be a dense array"
			end
			dense_count = dense_count + 1
		end
		if dense_count ~= #entries then return nil, "entries must be a dense array" end
		local result, seen = {}, {}
		for index, entry in ipairs(entries) do
			if type(entry) ~= "table" or type(entry.path) ~= "string" or entry.path == ""
				or type(entry.backup) ~= "string" or entry.backup == ""
				or type(entry.existed) ~= "boolean" then
				return nil, "entry " .. tostring(index) .. " is malformed"
			end
			if entry.existed == true then
				if canonical_identity(entry.identity) == nil then
					return nil, "entry " .. tostring(index) .. " has no inode identity"
				end
			elseif entry.identity ~= nil then
				return nil, "entry " .. tostring(index) .. " has an unexpected inode identity"
			end
			local prefix = entry.path .. BACKUP_PREFIX
			local suffix = entry.backup:sub(#prefix + 1)
			if entry.backup:sub(1, #prefix) ~= prefix or not suffix:match("^%d+%-%d+$") then
				return nil, "entry " .. tostring(index) .. " has an invalid recovery path"
			end
			if seen[entry.path] or seen[entry.backup] then
				return nil, "entry " .. tostring(index) .. " duplicates a journal pathname"
			end
			seen[entry.path], seen[entry.backup] = true, true
			result[#result + 1] = {
				path = entry.path,
				backup = entry.backup,
				existed = entry.existed,
				identity = entry.existed == true and canonical_identity(entry.identity) or nil,
			}
		end
		return copy_entries(result)
	end

	local function encode_record(phase, entries)
		local encoded, encode_detail = codec.encode({
			version = VERSION,
			phase = phase,
			entries = phase == "cleared" and {} or copy_entries(entries),
		})
		if type(encoded) ~= "string" or encoded == "" then
			return nil, tostring(encode_detail or "JSON encoding returned no bytes")
		end
		return encoded
	end

	local function decode_record(bytes)
		local decoded, decode_detail = codec.decode(bytes)
		if type(decoded) ~= "table" or decoded.version ~= VERSION
			or VALID_PHASES[decoded.phase] ~= true then
			return nil, tostring(decode_detail or "invalid journal envelope")
		end
		local entries, entry_detail = valid_entries(decoded.entries)
		if not entries then return nil, entry_detail end
		if decoded.phase == "cleared" and #entries ~= 0 then
			return nil, "cleared journal contains recovery entries"
		end
		return { version = VERSION, phase = decoded.phase, entries = entries }
	end

	local function read_disk()
		local read_ok, content, status, detail = xpcall(function()
			return fs.read_with_status(journal_path)
		end, debug.traceback)
		if not read_ok then return nil, "error", tostring(content) end
		if status == "absent" and content == nil then return nil, "absent" end
		if status ~= "ok" or type(content) ~= "string" then
			return nil, "error", tostring(detail or status or "journal read was unclassified")
		end
		local record, decode_detail = decode_record(content)
		if not record then return nil, "error", decode_detail end
		owner.current_bytes, owner.current_record = content, record
		return record, "ok"
	end

	local function same_entries(left, right)
		left, right = copy_entries(left), copy_entries(right)
		if #left ~= #right then return false end
		for index, entry in ipairs(left) do
			local other = right[index]
			if entry.path ~= other.path or entry.backup ~= other.backup
				or entry.existed ~= other.existed then return false end
			if entry.existed == true and (entry.identity.dev ~= other.identity.dev
				or entry.identity.ino ~= other.identity.ino) then return false end
		end
		return true
	end

	local function transition(expected_phase, next_phase, next_entries)
		local record = owner.current_record
		if not record then
			local status
			record, status = read_disk()
			if status ~= "ok" then return false, "journal is not readable" end
		end
		if record.phase ~= expected_phase then
			return false, "journal phase is " .. tostring(record.phase) .. ", expected " .. expected_phase
		end
		local next_bytes, encode_detail = encode_record(next_phase, next_entries)
		if not next_bytes then return false, encode_detail end
		local write_ok, written, write_detail = xpcall(function()
			return fs.write_if_unchanged(journal_path, next_bytes, {
				status = "ok",
				content = owner.current_bytes,
			})
		end, debug.traceback)
		if write_ok and written == true then
			owner.current_bytes = next_bytes
			owner.current_record = { version = VERSION, phase = next_phase, entries = copy_entries(next_entries) }
			return true
		end
		-- Preserve a late-mutation postcondition so the exact inverse can still run.
		local observed, status = read_disk()
		if status == "ok" and observed.phase == next_phase
			and same_entries(observed.entries, next_entries) then
			owner.current_record = observed
		end
		return false, tostring(write_ok and write_detail or written)
	end

	local function classify(path)
		local call_ok, attributes, status, detail = xpcall(function()
			return fs.classify_no_follow(path)
		end, debug.traceback)
		if not call_ok then return nil, "error", tostring(attributes) end
		if status == "absent" and attributes == nil then return nil, "absent" end
		if status == "ok" and type(attributes) == "table" and attributes.mode == "file" then
			return attributes, "ok"
		end
		return nil, "error", tostring(detail or status or "pathname is not a regular file")
	end

	local function same_identity(left, right)
		left, right = canonical_identity(left), canonical_identity(right)
		return left ~= nil and right ~= nil
			and left.dev == right.dev and left.ino == right.ino
	end

	local function call_exact(fn, ...)
		local args = { ... }
		local call_ok, result, detail = xpcall(function()
			return fn(unpack_args(args))
		end, debug.traceback)
		if not call_ok or result ~= true then return false, tostring(call_ok and detail or result) end
		return true
	end

	local function settle_lock_debt()
		if not owner.lock_debt then return true end
		local release_ok, released, detail = xpcall(function()
			return fs.release_write_locks(owner.lock_debt)
		end, debug.traceback)
		if not release_ok or released ~= true then
			return false, tostring(release_ok and detail or released)
		end
		owner.lock_debt = nil
		return true
	end

	local function reconcile_entry(entry, phase)
		local debt_ok, debt_detail = settle_lock_debt()
		if debt_ok ~= true then return false, debt_detail end
		local acquire_ok, group, committed, acquire_detail = xpcall(function()
			return fs.acquire_write_locks({ entry.path, entry.backup })
		end, debug.traceback)
		if not acquire_ok or type(group) ~= "table" or committed ~= true then
			if type(group) == "table" then owner.lock_debt = group end
			return false, tostring(acquire_ok and acquire_detail or group)
		end
		owner.lock_debt = group
		local resolved = type(group.resolved_paths) == "table" and group.resolved_paths or {}
		local source = resolved[entry.path] or entry.path
		local backup = resolved[entry.backup] or entry.backup

		local operation_ok, operation_result, operation_detail = xpcall(function()
			local source_attr, source_status, source_detail = classify(source)
			local backup_attr, backup_status, backup_detail = classify(backup)
			if source_status == "error" or backup_status == "error" then
				return false, tostring(source_detail or backup_detail)
			end
			if entry.existed ~= true then
				return source_status == "absent" and backup_status == "absent",
					"an originally absent path gained reset bytes"
			end

			if phase == "prepared" then
				if source_status == "ok" and backup_status == "absent" then
					return same_identity(source_attr, entry.identity),
						"prepared source no longer has the captured identity"
				end
				if source_status == "ok" and backup_status == "ok"
					and same_identity(source_attr, backup_attr)
					and same_identity(source_attr, entry.identity) then
					local removed, detail = call_exact(fs.remove_exact, backup)
					if not removed then return false, detail end
					local after_source, after_source_status = classify(source)
					local _, after_backup_status = classify(backup)
					return after_source_status == "ok" and after_backup_status == "absent"
						and same_identity(after_source, source_attr), "linked restore postcondition failed"
				end
				if source_status == "absent" and backup_status == "ok" then
					if not same_identity(backup_attr, entry.identity) then
						return false, "recovery shadow no longer has the captured identity"
					end
					local linked, link_detail = call_exact(fs.hard_link_create_only, backup, source)
					if not linked then return false, link_detail end
					local linked_source, linked_source_status = classify(source)
					if linked_source_status ~= "ok" or not same_identity(linked_source, backup_attr) then
						return false, "restore hard-link postcondition failed"
					end
					local removed, remove_detail = call_exact(fs.remove_exact, backup)
					if not removed then return false, remove_detail end
					local final_source, final_source_status = classify(source)
					local _, final_backup_status = classify(backup)
					return final_source_status == "ok" and final_backup_status == "absent"
						and same_identity(final_source, backup_attr), "restored file postcondition failed"
				end
				return false, "prepared reset paths conflict"
			end

			if source_status == "absent" and backup_status == "absent" then return true end
			if source_status == "absent" and backup_status == "ok" then
				if not same_identity(backup_attr, entry.identity) then
					return false, "commit shadow no longer has the captured identity"
				end
				local removed, detail = call_exact(fs.remove_exact, backup)
				if not removed then return false, detail end
				local _, final_source_status = classify(source)
				local _, final_backup_status = classify(backup)
				return final_source_status == "absent" and final_backup_status == "absent",
					"committed reset cleanup postcondition failed"
			end
			if source_status == "ok" and backup_status == "ok"
				and same_identity(source_attr, backup_attr)
				and same_identity(source_attr, entry.identity) then
				local source_removed, source_remove_detail = call_exact(fs.remove_exact, source)
				if not source_removed then return false, source_remove_detail end
				local backup_removed, backup_remove_detail = call_exact(fs.remove_exact, backup)
				if not backup_removed then return false, backup_remove_detail end
				local _, final_source_status = classify(source)
				local _, final_backup_status = classify(backup)
				return final_source_status == "absent" and final_backup_status == "absent",
					"linked commit cleanup postcondition failed"
			end
			return false, "committed reset paths conflict"
		end, debug.traceback)

		local release_ok, released, release_detail = xpcall(function()
			return fs.release_write_locks(group)
		end, debug.traceback)
		if release_ok and released == true then owner.lock_debt = nil end
		if not operation_ok or operation_result ~= true then
			return false, tostring(operation_ok and operation_detail or operation_result)
		end
		if not release_ok or released ~= true then
			return false, tostring(release_ok and release_detail or released)
		end
		return true
	end

	--- Publishes a durable prepared decision before any file move.
	--- @param entries table Captured reset entries.
	--- @return boolean committed
	function owner:prepare(entries)
		local validated, validation_detail = valid_entries(entries)
		if not validated then
			Logger.error(LOG, "Factory-reset journal preparation refused: %s.", tostring(validation_detail))
			return false
		end
		local record, status, detail = read_disk()
		if status == "error" then
			Logger.error(LOG, "Factory-reset journal is unreadable: %s.", tostring(detail))
			return false
		end
		if status == "ok" and record.phase ~= "cleared" then
			Logger.error(LOG, "Factory-reset journal still owns phase '%s'.", tostring(record.phase))
			return false
		end
		local prepared_bytes, encode_detail = encode_record("prepared", validated)
		if not prepared_bytes then return false, encode_detail end
		if status == "absent" then
			local create_ok, created, create_status, create_detail = xpcall(function()
				return fs.create_if_absent(journal_path, prepared_bytes)
			end, debug.traceback)
			if create_ok and created == true then
				owner.current_bytes = prepared_bytes
				owner.current_record = { version = VERSION, phase = "prepared", entries = validated }
				return true
			end
			read_disk()
			Logger.error(LOG, "Factory-reset journal creation refused: %s.",
				tostring(create_ok and (create_detail or create_status) or created))
			return false
		end
		local transitioned, transition_detail = transition("cleared", "prepared", validated)
		if transitioned ~= true then
			Logger.error(LOG, "Factory-reset journal prepare transition refused: %s.",
				tostring(transition_detail))
		end
		return transitioned
	end

	--- Publishes the durable decision that the reset should survive process death.
	--- @return boolean committed
	function owner:mark_commit()
		local entries = owner.current_record and owner.current_record.entries or nil
		local committed, detail = transition("prepared", "commit", entries)
		if committed ~= true then Logger.error(LOG, "Factory-reset commit marker refused: %s.", tostring(detail)) end
		return committed
	end

	--- Reverts a refused reload handoff to the restorable prepared phase.
	--- @return boolean committed
	function owner:mark_prepared()
		local entries = owner.current_record and owner.current_record.entries or nil
		local committed, detail = transition("commit", "prepared", entries)
		if committed ~= true then Logger.error(LOG, "Factory-reset rollback marker refused: %s.", tostring(detail)) end
		return committed
	end

	--- Settles a fully restored prepared transaction without unlinking the journal.
	--- @return boolean committed
	function owner:clear()
		local record, status = read_disk()
		if status == "absent" or (status == "ok" and record.phase == "cleared") then return true end
		if status ~= "ok" or record.phase ~= "prepared" then return false end
		local committed, detail = transition("prepared", "cleared", {})
		if committed ~= true then Logger.error(LOG, "Factory-reset journal clear refused: %s.", tostring(detail)) end
		return committed
	end

	--- Reconciles one boot-time prepared or committed decision exactly once.
	--- @return boolean settled
	function owner:reconcile()
		local record, status, detail = read_disk()
		if status == "absent" then return true end
		if status ~= "ok" then
			Logger.error(LOG, "Factory-reset boot journal is unreadable: %s.", tostring(detail))
			return false
		end
		if record.phase == "cleared" then return true end
		for _, entry in ipairs(record.entries) do
			local reconciled, entry_detail = reconcile_entry(entry, record.phase)
			if reconciled ~= true then
				Logger.error(LOG, "Factory-reset boot reconciliation failed for '%s': %s.",
					entry.path, tostring(entry_detail))
				return false
			end
		end
		local cleared, clear_detail = transition(record.phase, "cleared", {})
		if cleared ~= true then
			Logger.error(LOG, "Factory-reset boot journal settlement refused: %s.", tostring(clear_detail))
			return false
		end
		Logger.info(LOG, "Factory-reset %s journal reconciled before configuration load.", record.phase)
		return true
	end

	--- Returns the currently persisted phase for diagnostics and tests.
	--- @return string|nil phase
	function owner:phase()
		local record, status = read_disk()
		return status == "ok" and record.phase or nil
	end

	return owner
end

return M

--- ui/menu/recoverable_file_moves.lua

--- ==============================================================================
--- MODULE: Recoverable Menu File Moves
--- DESCRIPTION:
--- Moves regular configuration files to collision-free backup paths while
--- retaining the exact inode, inverse path, and writer locks needed by a larger
--- menu transaction.
---
--- FEATURES & RATIONALE:
--- 1. Postcondition Ownership: A native link/unlink that mutates and then throws
---    is classified by inode and remains recoverable instead of being lost.
--- 2. Exact Inverse: Rollback never overwrites a newly-created source path and
---    only restores the hard link bound to the captured source inode.
--- 3. Retry Evidence: Locks and phase survive every refusal until the exact
---    source-restored and backup-absent inverse is observed.
--- ==============================================================================

local M = {}

local FileSystem = require("adapters.file_system")
local Logger = require("infra.logger")

local LOG = "menu_file_moves"
local BACKUP_SUFFIX = ".ergopti-reset-backup"
local backup_sequence = 0

--- Builds a session-unique recovery path without replacing an older backup.
--- @param path string Original configuration path.
--- @return string backup_path
local function default_backup_path(path)
	backup_sequence = backup_sequence + 1
	local timestamp_ok, timestamp = xpcall(os.time, debug.traceback)
	if not timestamp_ok or type(timestamp) ~= "number" then timestamp = 0 end
	return path .. BACKUP_SUFFIX .. "-" .. tostring(timestamp) .. "-" .. tostring(backup_sequence)
end

--- Creates one exact recoverable-move capability.
--- @param overrides table|nil Test-only dependency overrides.
--- @return table|nil mover
function M.create(overrides)
	overrides = type(overrides) == "table" and overrides or {}
	local read_with_status = overrides.read_with_status or FileSystem.read_with_status
	-- `move_no_replace`/`rename` is retained only as a compatibility seam for the
	-- older pure-Lua transaction fixtures. Production always uses the owned
	-- hard-link capability below; no shell utility participates in its contract.
	local move_no_replace = overrides.move_no_replace or overrides.rename
	local capability_mode = move_no_replace == nil
	local classify_no_follow = overrides.classify_no_follow
		or FileSystem.classify_no_follow
	local acquire_write_locks = overrides.acquire_write_locks
		or FileSystem.acquire_write_locks
	local release_write_locks = overrides.release_write_locks
		or FileSystem.release_write_locks
	local hard_link_create_only = overrides.hard_link_create_only
		or FileSystem.hard_link_create_only
	local remove_exact = overrides.remove_exact or FileSystem.remove_exact
	local backup_path = overrides.backup_path or default_backup_path
	local capability_dependencies_valid = type(classify_no_follow) == "function"
		and type(acquire_write_locks) == "function"
		and type(release_write_locks) == "function"
		and type(hard_link_create_only) == "function"
		and type(remove_exact) == "function"
	if type(read_with_status) ~= "function" or type(backup_path) ~= "function"
		or (capability_mode and not capability_dependencies_valid)
		or (not capability_mode and type(move_no_replace) ~= "function") then
		Logger.error(LOG, "Recoverable file-move dependencies are invalid.")
		return nil
	end

	--- Reads one path through the exact ok/absent/error classifier.
	--- @param path string Path to classify.
	--- @return string|nil content
	--- @return string status
	--- @return string|nil detail
	local function inspect(path)
		local call_ok, content, status, detail = xpcall(function()
			return read_with_status(path)
		end, debug.traceback)
		if not call_ok then return nil, "error", tostring(content) end
		if status == "absent" then return nil, "absent", detail end
		if status == "ok" and type(content) == "string" then return content, "ok", detail end
		return nil, "error", tostring(detail or status or "unclassified path")
	end

	--- Reads lstat-style identity through the owned adapter seam.
	--- @param path string Pathname to classify without following its final link.
	--- @return table|nil attributes
	--- @return string status `ok`, `absent`, or `error`.
	--- @return string|nil detail
	local function inspect_identity(path)
		local call_ok, attributes, status, detail = xpcall(function()
			return classify_no_follow(path)
		end, debug.traceback)
		if not call_ok then return nil, "error", tostring(attributes) end
		if status == "absent" and attributes == nil then return nil, "absent", detail end
		if status == "ok" and type(attributes) == "table" then
			return attributes, "ok", detail
		end
		return nil, "error", tostring(detail or status or "unclassified pathname")
	end

	--- Compares the stable pathname identity retained by the capability.
	--- @param attributes table|nil lstat result.
	--- @param identity table Captured `{ dev, ino }` pair.
	--- @return boolean exact
	local function identity_matches(attributes, identity)
		return type(attributes) == "table"
			and attributes.mode == "file"
			and type(identity) == "table"
			and attributes.dev == identity.dev
			and attributes.ino == identity.ino
	end

	--- Probes the three exact states reachable by link(source, backup)+unlink(source).
	--- No byte read is part of this terminal proof: both pathname observations run
	--- under the retained cooperative locks and bind to the captured inode.
	--- @param entry table Owned move capability.
	--- @return string state `original`, `linked`, `moved`, or `conflict`.
	--- @return string|nil detail
	local function classify_capability_state(entry)
		local source_attributes, source_status, source_detail =
			inspect_identity(entry.native_path)
		local backup_attributes, backup_status, backup_detail =
			inspect_identity(entry.native_backup)
		if source_status == "error" or backup_status == "error" then
			return "conflict", tostring(source_detail or backup_detail or "identity probe failed")
		end

		if entry.existed ~= true then
			if source_status == "absent" and backup_status == "absent" then
				return "original"
			end
			return "conflict", "an absent capture acquired a pathname"
		end

		local source_exact = source_status == "ok"
			and identity_matches(source_attributes, entry.identity)
		local backup_exact = backup_status == "ok"
			and identity_matches(backup_attributes, entry.identity)
		if source_exact and backup_status == "absent" then return "original" end
		if source_exact and backup_exact then return "linked" end
		if source_status == "absent" and backup_exact then return "moved" end
		return "conflict", "pathnames no longer bind to the captured inode"
	end

	--- Releases only the lock group retained by one exact entry.
	--- @param entry table Owned move capability.
	--- @return boolean released
	local function release_entry_locks(entry)
		if entry.locks_released == true then return true end
		if entry.locks == nil then
			entry.locks_released = true
			return true
		end
		local release_ok, released, detail = xpcall(function()
			return release_write_locks(entry.locks)
		end, debug.traceback)
		if not release_ok or released ~= true then
			Logger.error(LOG, "Recoverable move lock release remains pending for '%s': %s.",
			tostring(entry.path), tostring(release_ok and detail or released))
			return false
		end
		entry.locks = nil
		entry.locks_released = true
		return true
	end

	--- Calls one native pathname mutation while retaining its exact result shape.
	--- @param method function Native adapter method.
	--- @param ... any Arguments.
	--- @return boolean committed Literal true only.
	--- @return string|nil detail
	local function call_native_exact(method, ...)
		local arguments = table.pack(...)
		local call_ok, result, detail = xpcall(function()
			return method(table.unpack(arguments, 1, arguments.n))
		end, debug.traceback)
		if not call_ok then return false, tostring(result) end
		if result ~= true then return false, tostring(detail or result or "native refusal") end
		return true
	end

	--- Captures a regular-file inode under both ordered pathname locks.
	--- Invalid captures still return an entry when a lock capability exists, so the
	--- caller can journal and retry its exact release instead of orphaning it.
	--- @param path string Requested configuration pathname.
	--- @param recovery_path string Session-unique recovery pathname.
	--- @return table|nil entry
	--- @return string|nil detail
	local function capture_capability(path, recovery_path)
		local acquire_ok, locks, locked, lock_detail = xpcall(function()
			return acquire_write_locks({ path, recovery_path })
		end, debug.traceback)
		if not acquire_ok then
			return nil, "write-lock acquisition raised: " .. tostring(locks)
		end
		if locked ~= true then
			if type(locks) ~= "table" then return nil, tostring(lock_detail or "write locks refused") end
			return {
				path = path,
				backup = recovery_path,
				locks = locks,
				capture_valid = false,
				failure_detail = tostring(lock_detail or "write locks remain unsettled"),
			}, tostring(lock_detail)
		end
		if type(locks) ~= "table" then
			return nil, "write-lock acquisition returned no owner"
		end

		local entry = {
			path = path,
			backup = recovery_path,
			locks = locks,
			capture_valid = false,
			moved = false,
		}
		local resolved_paths = type(locks) == "table" and locks.resolved_paths or nil
		entry.native_path = type(resolved_paths) == "table" and resolved_paths[path] or path
		entry.native_backup = type(resolved_paths) == "table"
			and resolved_paths[recovery_path] or recovery_path

		-- Inspect the requested final components as well as the resolved native
		-- paths. This rejects a final symlink rather than silently moving its target.
		local requested_source, requested_source_status, source_detail = inspect_identity(path)
		local requested_backup, requested_backup_status, backup_detail = inspect_identity(recovery_path)
		if requested_source_status == "error" or requested_backup_status == "error" then
			entry.failure_detail = tostring(source_detail or backup_detail)
			return entry, entry.failure_detail
		end
		if requested_source_status == "ok" and requested_source.mode ~= "file" then
			entry.failure_detail = "source is not a regular file"
			return entry, entry.failure_detail
		end
		if requested_backup_status ~= "absent" then
			entry.failure_detail = "recovery destination is not absent"
			return entry, entry.failure_detail
		end

		local source_attributes, source_status, native_source_detail =
			inspect_identity(entry.native_path)
		local _, backup_status, native_backup_detail = inspect_identity(entry.native_backup)
		if source_status == "error" or backup_status == "error" then
			entry.failure_detail = tostring(native_source_detail or native_backup_detail)
			return entry, entry.failure_detail
		end
		if backup_status ~= "absent" then
			entry.failure_detail = "resolved recovery destination is not absent"
			return entry, entry.failure_detail
		end
		if requested_source_status ~= source_status then
			entry.failure_detail = "source route changed while acquiring locks"
			return entry, entry.failure_detail
		end
		if source_status == "absent" then
			entry.existed = false
			entry.content = nil
			entry.capture_valid = true
			return entry
		end
		if type(source_attributes) ~= "table" or source_attributes.mode ~= "file"
			or source_attributes.dev == nil or source_attributes.ino == nil then
			entry.failure_detail = "source has no regular-file inode identity"
			return entry, entry.failure_detail
		end
		if type(requested_source) ~= "table"
			or requested_source.dev ~= source_attributes.dev
			or requested_source.ino ~= source_attributes.ino then
			entry.failure_detail = "source route changed while acquiring locks"
			return entry, entry.failure_detail
		end

		local content, content_status, content_detail = inspect(entry.native_path)
		if content_status ~= "ok" then
			entry.failure_detail = tostring(content_detail or content_status)
			return entry, entry.failure_detail
		end
		local source_after, source_after_status = inspect_identity(entry.native_path)
		local _, backup_after_status = inspect_identity(entry.native_backup)
		local identity = { dev = source_attributes.dev, ino = source_attributes.ino }
		if source_after_status ~= "ok" or not identity_matches(source_after, identity)
			or backup_after_status ~= "absent" then
			entry.failure_detail = "move paths changed during capture"
			return entry, entry.failure_detail
		end

		entry.identity = identity
		entry.content = content
		entry.existed = true
		entry.capture_valid = true
		return entry
	end

	--- Reads both transaction paths twice and accepts only one stable observation.
	--- The move primitive prevents clobbering at publication; the repeated read
	--- prevents a mutation hidden inside either postcondition read from being
	--- certified by the other half of a split snapshot.
	--- @param entry table Captured move entry.
	--- @return table|nil observation
	local function stable_pair(entry)
		local function observe()
			local source_content, source_status = inspect(entry.path)
			local backup_content, backup_status = inspect(entry.backup)
			if source_status == "error" or backup_status == "error" then return nil end
			return {
				source_content = source_content,
				source_status = source_status,
				backup_content = backup_content,
				backup_status = backup_status,
			}
		end
		local first = observe()
		local second = observe()
		if not first or not second then return nil end
		for key, value in pairs(first) do
			if second[key] ~= value then return nil end
		end
		return second
	end

	--- Verifies the exact postcondition of a forward move.
	--- @param entry table Captured move entry.
	--- @return boolean committed
	local function forward_postcondition(entry)
		local observed = stable_pair(entry)
		return observed ~= nil
			and observed.source_content == nil
			and observed.source_status == "absent"
			and observed.backup_status == "ok"
			and observed.backup_content == entry.content
	end

	--- Verifies the exact postcondition of an inverse move.
	--- @param entry table Captured move entry.
	--- @return boolean committed
	local function inverse_postcondition(entry)
		local observed = stable_pair(entry)
		return observed ~= nil
			and observed.source_status == "ok"
			and observed.source_content == entry.content
			and observed.backup_content == nil
			and observed.backup_status == "absent"
	end

	--- Verifies that neither the forward move nor its inverse needs to mutate.
	--- @param entry table Captured move entry.
	--- @return boolean unchanged
	local function original_postcondition(entry)
		local observed = stable_pair(entry)
		if not observed then return false end
		if entry.existed == true then
			return observed.source_status == "ok"
				and observed.source_content == entry.content
				and observed.backup_status == "absent"
		end
		return observed.source_status == "absent"
			and observed.backup_status == "absent"
	end

	local mover = {}

	--- Captures exact bytes and reserves an absent recovery destination.
	--- @param path string Configuration path.
	--- @return table|nil entry
	--- @return string|nil detail
	function mover.capture(path)
		if type(path) ~= "string" or path == "" then
			Logger.error(LOG, "Cannot capture an empty configuration path.")
			return nil, "invalid-path"
		end
		local path_ok, recovery_path = xpcall(function() return backup_path(path) end, debug.traceback)
		if not path_ok or type(recovery_path) ~= "string" or recovery_path == ""
			or recovery_path == path then
			Logger.error(LOG, "Cannot reserve a recovery path for '%s': %s.",
				path, tostring(recovery_path))
			return nil, "invalid-backup-path"
		end

		if capability_mode then
			local entry, detail = capture_capability(path, recovery_path)
			if type(entry) ~= "table" then
				Logger.error(LOG, "Cannot acquire recoverable move capability for '%s': %s.",
					path, tostring(detail))
				return nil, detail or "capability-acquisition-failed"
			end
			if entry.capture_valid ~= true then
				Logger.error(LOG, "Recoverable move capture for '%s' is retained only for cleanup: %s.",
					path, tostring(detail or entry.failure_detail))
			end
			return entry, detail
		end

		local content, status, detail = inspect(path)
		if status == "error" then
			Logger.error(LOG, "Cannot classify '%s' before recoverable reset: %s.",
				path, tostring(detail))
			return nil, "source-classification-failed"
		end
		local _, backup_status, backup_detail = inspect(recovery_path)
		if backup_status ~= "absent" then
			Logger.error(LOG, "Recovery destination '%s' is not provably absent: %s.",
				recovery_path, tostring(backup_detail or backup_status))
			return nil, "backup-not-absent"
		end
		return {
			path = path,
			backup = recovery_path,
			content = content,
			existed = status == "ok",
			moved = false,
		}
	end

	--- Moves one captured file and retains late-mutation evidence on refusal.
	--- @param entry table Captured move entry.
	--- @return boolean committed
	function mover.move(entry)
		if type(entry) ~= "table" or type(entry.path) ~= "string" then
			Logger.error(LOG, "Recoverable move requires a captured entry.")
			return false
		end
		if capability_mode then
			if entry.capture_valid ~= true or entry.locks_released == true then
				Logger.error(LOG, "Recoverable move capability for '%s' is not admissible: %s.",
					entry.path, tostring(entry.failure_detail or "capture refused"))
				return false
			end

			local state, state_detail = classify_capability_state(entry)
			entry.phase = state
			if entry.existed ~= true then
				return state == "original"
			end
			if state == "moved" then
				entry.moved = true
				return true
			end
			if state ~= "original" then
				Logger.error(LOG, "Recoverable move precondition changed for '%s': %s.",
					entry.path, tostring(state_detail or state))
				return false
			end

			local linked, link_detail = call_native_exact(
				hard_link_create_only, entry.native_path, entry.native_backup)
			local after_link, after_link_detail = classify_capability_state(entry)
			entry.phase = after_link
			entry.moved = after_link == "moved"
			if linked ~= true then
				Logger.error(LOG, "Recoverable hard-link publication refused for '%s': %s.",
					entry.path, tostring(link_detail))
				return false
			end
			if after_link == "moved" then
				Logger.info(LOG, "Configuration moved to recovery path '%s'.", entry.backup)
				return true
			end
			if after_link ~= "linked" then
				Logger.error(LOG, "Recoverable hard-link postcondition failed for '%s': %s.",
					entry.path, tostring(after_link_detail or after_link))
				return false
			end

			local removed, remove_detail = call_native_exact(remove_exact, entry.native_path)
			local after_remove, after_remove_detail = classify_capability_state(entry)
			entry.phase = after_remove
			entry.moved = after_remove == "moved"
			if removed ~= true or after_remove ~= "moved" then
				Logger.error(LOG, "Recoverable source unlink did not commit for '%s': %s.",
					entry.path, tostring(remove_detail or after_remove_detail or after_remove))
				return false
			end
			Logger.info(LOG, "Configuration moved to recovery path '%s'.", entry.backup)
			return true
		end
		if entry.existed ~= true then return original_postcondition(entry) end
		if forward_postcondition(entry) then
			entry.moved = true
			return true
		end
		if not original_postcondition(entry) then
			Logger.error(LOG, "Recoverable move precondition changed for '%s'.", entry.path)
			return false
		end

		local call_ok, moved_result, move_detail = xpcall(function()
			return move_no_replace(entry.path, entry.backup)
		end, debug.traceback)
		local moved = forward_postcondition(entry)
		if moved then entry.moved = true end
		if not call_ok or moved_result ~= true or not moved then
			Logger.error(LOG, "Recoverable move did not commit for '%s': %s.",
				entry.path, tostring(call_ok and move_detail or moved_result))
			return false
		end
		Logger.info(LOG, "Configuration moved to recovery path '%s'.", entry.backup)
		return true
	end

	--- Restores one moved file without overwriting a replacement source.
	--- @param entry table Captured move entry.
	--- @return boolean committed
	function mover.restore(entry)
		if type(entry) ~= "table" or type(entry.path) ~= "string" then
			Logger.error(LOG, "Recoverable inverse requires a captured entry.")
			return false
		end
		if capability_mode then
			if entry.locks_released == true then return true end
			if entry.capture_valid ~= true then
				return release_entry_locks(entry)
			end

			local state, state_detail = classify_capability_state(entry)
			entry.phase = state
			if state == "conflict" then
				Logger.error(LOG, "Recovery precondition changed for '%s'; inode capability retained: %s.",
					entry.path, tostring(state_detail))
				return false
			end
			if state == "original" then
				entry.moved = false
				return release_entry_locks(entry)
			end
			if entry.existed ~= true then
				Logger.error(LOG, "Absent capture for '%s' acquired an unexpected pathname.", entry.path)
				return false
			end

			if state == "moved" then
				local relinked, relink_detail = call_native_exact(
					hard_link_create_only, entry.native_backup, entry.native_path)
				local after_relink, after_relink_detail = classify_capability_state(entry)
				entry.phase = after_relink
				if relinked ~= true then
					Logger.error(LOG, "Recoverable inverse hard-link refused for '%s': %s.",
						entry.path, tostring(relink_detail))
					return false
				end
				if after_relink == "original" then
					entry.moved = false
					return release_entry_locks(entry)
				end
				if after_relink ~= "linked" then
					Logger.error(LOG, "Recoverable inverse hard-link postcondition failed for '%s': %s.",
						entry.path, tostring(after_relink_detail or after_relink))
					return false
				end
				state = after_relink
			end

			if state ~= "linked" then
				Logger.error(LOG, "Recoverable inverse has an unknown phase for '%s': %s.",
					entry.path, tostring(state))
				return false
			end
			local removed, remove_detail = call_native_exact(remove_exact, entry.native_backup)
			local after_remove, after_remove_detail = classify_capability_state(entry)
			entry.phase = after_remove
			entry.moved = after_remove == "moved"
			if removed ~= true or after_remove ~= "original" then
				Logger.error(LOG, "Recoverable inverse unlink did not commit for '%s': %s.",
					entry.path, tostring(remove_detail or after_remove_detail or after_remove))
				return false
			end
			entry.moved = false
			if not release_entry_locks(entry) then return false end
			Logger.info(LOG, "Configuration restored from recovery path '%s'.", entry.backup)
			return true
		end
		if entry.existed ~= true then return original_postcondition(entry) end
		if inverse_postcondition(entry) then
			entry.moved = false
			return true
		end
		-- A forward refusal before mutation is already the exact inverse state.
		if original_postcondition(entry) then
			entry.moved = false
			return true
		end
		if not forward_postcondition(entry) then
			Logger.error(LOG, "Recovery precondition changed for '%s'; inverse retained.", entry.path)
			return false
		end

		local call_ok, restored_result, restore_detail = xpcall(function()
			return move_no_replace(entry.backup, entry.path)
		end, debug.traceback)
		local restored = inverse_postcondition(entry)
		if restored then entry.moved = false end
		if not call_ok or restored_result ~= true or not restored then
			Logger.error(LOG, "Recovery move did not commit for '%s': %s.",
				entry.path, tostring(call_ok and restore_detail or restored_result))
			return false
		end
		Logger.info(LOG, "Configuration restored from recovery path '%s'.", entry.backup)
		return true
	end

	return mover
end

return M

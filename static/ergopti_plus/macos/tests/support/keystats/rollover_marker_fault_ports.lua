--- tests/support/keystats/rollover_marker_fault_ports.lua

--- ==============================================================================
--- MODULE: Rollover Marker Fault Boundaries
--- DESCRIPTION:
--- One documented filesystem refusal at a time over actual private IO. A partial
--- write writes a real prefix; post-close refusal closes the exact native stream.
--- ==============================================================================
local M = {}

function M.install(options)
	local state = { armed = false, faults = 0, journal_removals = 0, marker_opens = 0,
		old_stream_closes = 0, marker_writes = 0, pending_publications = 0, terminal_publications = 0 }
	local case, phase, ledger, journal = options.case, options.phase, options.ledger, options.journal
	local adapter, json, fs, streams = options.adapter, options.json, options.fs, options.streams
	local open, remove, native_type = io.open, os.remove, io.type
	local underlying = setmetatable({}, { __mode = "k" })
	io.type = function(value) return native_type(underlying[value] or value) end
	local publish, release = adapter.write_if_unchanged, adapter.release_write_locks
	local function once(name)
		if not state.armed or state.faults ~= 0 or case ~= name then return false end
		state.faults = 1
		return true
	end
	local function receipt(content)
		local ok, value = pcall(json.decode, content)
		return ok and type(value) == "table" and value or nil
	end
	local function pending()
		local content, status = adapter.read_with_status(ledger .. ".append-journal.json")
		local value = status == "ok" and receipt(content)
		return value and value.version == 2 and value.kind == "rollover"
	end
	adapter.write_if_unchanged = function(path, content, expected, ...)
		if path == ledger .. ".append-journal.json" then
			local value = receipt(content)
			if value and value.version == 2 then
				state.pending_publications = state.pending_publications + 1
				if once("pending_publication_refused") then return false, "controlled pending publication refusal" end
			elseif value and value.version == 1 and value.phase == "settled"
				and value.batch:find("-- === day rollover", 1, true) then
				state.terminal_publications = state.terminal_publications + 1
				if once("terminal_publication_refused") then return false, "controlled terminal publication refusal" end
			end
		end
		return publish(path, content, expected, ...)
	end
	adapter.release_write_locks = function(group)
		if group and group.resolved_paths and group.resolved_paths[ledger]
			and state.armed and case == "release_refused_after_terminal" and state.faults == 0 then
			local content, status = adapter.read_with_status(ledger .. ".append-journal.json")
			local value = status == "ok" and receipt(content)
			if value and value.version == 1 and value.phase == "settled"
				and value.batch:find("-- === day rollover", 1, true) then
				state.faults = 1
				return false, "controlled retained native lock release"
			end
		end
		return release(group)
	end
	os.remove = function(path)
		if path == journal then
			if state.armed and (case == "old_identity_replaced" or case == "old_identity_grown"
				or case == "old_path_symlink") and state.faults == 0 then
				assert(pending(), "identity checkpoint requires a published pending receipt")
				state.faults = 1
				return nil, "controlled pre-retirement checkpoint", 13
			end
			if once("unlink_refused") then return nil, "controlled journal unlink refusal", 13 end
			local accepted, detail, code = remove(path)
			if accepted == true then state.journal_removals = state.journal_removals + 1 end
			return accepted, detail, code
		end
		return remove(path)
	end
	io.open = function(path, mode)
		local is_marker = path == ledger and (mode == "a" or mode == "ab") and state.armed
		local is_ordinary = path == ledger and (mode == "a" or mode == "ab")
			and case == "ordinary_pending_append" and state.armed
		if is_marker and not is_ordinary then
			state.marker_opens = state.marker_opens + 1
			assert(fs.symlinkattributes(journal) == nil, "marker must follow actual old journal retirement")
			if once("marker_open_refused") or once("nonprefix_marker_tail") then
				return nil, "controlled marker open refusal", 13
			end
		end
		local handle, detail, code = open(path, mode)
		if not handle then return handle, detail, code end
		if path == journal and mode == "a" then
			streams[#streams + 1] = handle
			if case == "old_stream_close_error_after_close" and phase == "prepare" then
				local proxy = {}
				function proxy:write(...) local ack, err, errno = handle:write(...); return ack and self or ack, err, errno end
				function proxy:setvbuf(...) return handle:setvbuf(...) end
				function proxy:close()
					state.old_stream_closes = state.old_stream_closes + 1
					local ack, err, errno = handle:close()
					assert(ack == true, err)
					if once("old_stream_close_error_after_close") then return nil, "controlled consumed-stream close error" end
					return ack, err, errno
				end
				underlying[proxy] = handle
				return proxy
			end
		end
		if is_marker or is_ordinary then
			local proxy = {}
			function proxy:write(bytes)
				state.marker_writes = state.marker_writes + 1
				if once("marker_partial_write") or once("ordinary_pending_append") then
					assert(handle:write(bytes:sub(1, 23)))
					return nil, "controlled partial native append", 28
				end
				local ack, err, errno = handle:write(bytes)
				return ack and self or ack, err, errno
			end
			function proxy:close()
				local ack, err, errno = handle:close()
				assert(ack == true, err)
				if once("marker_close_refused_after_close") then return nil, "controlled post-close refusal" end
				return ack, err, errno
			end
			underlying[proxy] = handle
			return proxy
		end
		return handle, detail, code
	end
	function state.restore()
		state.armed = false
		io.open, os.remove, io.type = open, remove, native_type
		adapter.write_if_unchanged, adapter.release_write_locks = publish, release
	end
	return state
end

return M

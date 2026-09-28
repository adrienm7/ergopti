--- _shared/lua/config_scope_transaction.lua

--- Owns a scoped preference publication and exact runtime compensation.
local M = {}
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

--- Creates a session owner with explicit platform and runtime boundaries.
--- Runtime apply/restore must return literal true after terminal completion.
--- Optional prepare_batch(path, updates, files) delegates an owned inline table
--- to its host; it must return true, detail, candidate bytes and exact source.
--- @param options table Path, unique backup path, manifest, files and runtime ports.
--- @return table owner Transaction owner retaining failed compensation debt.
function M.new(options)
	assert(type(options) == "table" and type(options.path) == "string"
		and type(options.backup_path) == "string" and options.path ~= options.backup_path,
		"scope transactions require distinct configuration and backup paths")
	assert(type(options.manifest) == "table" and type(options.manifest.scope_plan) == "function"
		and type(options.capture) == "function" and type(options.apply) == "function"
		and type(options.restore) == "function", "scope transaction ports are incomplete")
	assert(type(options.files) == "table" and type(options.files.read_with_status) == "function"
		and type(options.files.write) == "function" and type(options.files.write_if_unchanged) == "function",
		"scope transactions require serialized conditional publication")
	assert(options.prepare_batch == nil or type(options.prepare_batch) == "function", "invalid scope preparation owner")
	local prepare_batch = options.prepare_batch or Writer.prepare_batch
	local owner, debt, busy = {}, nil, false
	local function compensate()
		if debt == nil then return true end
		local ok, restored = pcall(options.restore, debt)
		if not ok or restored ~= true then return false end
		debt = nil
		return true
	end
	function owner.pending() return debt ~= nil or busy end
	function owner.retry_restore()
		if busy then return false end
		return compensate()
	end
	function owner.apply(scope, mode)
		if busy or debt ~= nil then return false, "a configuration transaction is still pending" end
		busy = true
		local called, committed, detail, content = pcall(function()
			local owned_paths = type(options.owned_paths) == "function" and options.owned_paths() or {}
			assert(type(owned_paths) == "table", "dynamic configuration ownership is unavailable")
			local plan = options.manifest.scope_plan(scope, mode, owned_paths, options.owners)
			if #plan.presets > 0 then return false, "scope requires separate preset ownership" end
			local updates = plan.operations
			local prepared, why, candidate, source = prepare_batch(options.path, updates, options.files)
			if prepared ~= true then return false, why end
			if type(candidate) ~= "string" or type(source) ~= "table"
				or (source.status ~= "ok" and source.status ~= "absent")
				or (source.status == "ok" and type(source.content) ~= "string") then
				return false, "scope preparation did not return an exact source and candidate"
			end
			local decoded = Codec.decode(candidate)
			if type(decoded) ~= "table" then return false, "scope candidate is not valid TOML" end
			local snapshot = options.capture()
			if type(snapshot) ~= "table" then return false, "runtime snapshot was not acknowledged" end
			if source.status == "ok" then
				local backed, backup_error = Writer.publish_if_unchanged(options.backup_path,
					source.content, options.files, { status = "absent" })
				if backed ~= true then return false, "backup refused: " .. tostring(backup_error) end
				local observed, status = Writer.read_classified(options.backup_path, options.files)
				if status ~= "ok" or observed ~= source.content then return false, "backup verification failed" end
			end
			-- Capture before invocation because a native callback can mutate and throw.
			debt = snapshot
			if options.apply(decoded, updates) ~= true then return false, "runtime application refused" end
			local published, publish_error = Writer.publish_if_unchanged(options.path,
				candidate, options.files, source)
			if published ~= true then return false, publish_error end
			debt = nil
			return true, nil, candidate
		end)
		busy = false
		if not called or committed ~= true then
			local restored = compensate()
			return false, restored and tostring(called and detail or committed) or "runtime rollback remains pending"
		end
		return true, nil, content
	end
	return owner
end

return M

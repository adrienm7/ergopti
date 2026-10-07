--- _shared/lua/config_scope_transaction.lua

--- Owns a scoped preference publication and exact runtime compensation.
--- A scope whose manifest declares a preset also publishes that preset's own
--- file, inside the same backup, conflict and compensation boundary.
local M = {}
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local preparation_lookup = assert(rawget(Writer, "preparation_admission"))
local function preparation_current(check)
	if check == nil then return true end
	if not rawequal(rawget(Writer, "preparation_admission"), preparation_lookup) then return false end
	if type(check) ~= "function" then return false end
	local called, current = pcall(check)
	return called and current == true
end

local function belongs(path, prefix)
	return path == prefix or path:sub(1, #prefix + 1) == prefix .. "."
end

local FileInverse = require("config_file_inverse")

--- Validates one preset owner port.
--- @param id string Preset identifier from the manifest.
--- @param port table Path, backup path, absorbed prefixes and pure renderer.
--- @param options table Transaction options, for path distinctness.
local function check_preset(id, port, options)
	assert(type(id) == "string" and id ~= "" and type(port) == "table", "invalid scope preset owner")
	assert(type(port.path) == "string" and type(port.backup_path) == "string"
		and port.path ~= port.backup_path and port.path ~= options.path
		and port.backup_path ~= options.backup_path and port.backup_path ~= options.path,
		"scope preset " .. id .. " requires its own distinct file and backup paths")
	assert(type(port.render) == "function", "scope preset " .. id .. " requires a pure renderer")
	assert(port.prefixes == nil or type(port.prefixes) == "table", "scope preset " .. id .. " has invalid prefixes")
end

--- Creates a session owner with explicit platform and runtime boundaries.
--- Runtime apply/restore must return literal true after terminal completion.
--- Optional prepare_batch(path, updates, files) delegates an owned inline table
--- to its host; it must return true, detail, candidate bytes and exact source.
--- Optional presets[id] = { path, backup_path, prefixes, render } owns the file
--- of a manifest preset: rows under `prefixes` are routed to it, and
--- render(mode, source_document, rows, shapes) returns its complete candidate
--- bytes; the optional canonical receipt keeps empty arrays distinct from maps.
--- Optional select(path) narrows a scope to the rows it returns true for: a
--- submenu that restores or clears one part of its scope (the script chords of
--- the Shortcuts scope) keeps the scope's owner, backup and compensation.
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
	assert(options.select == nil or type(options.select) == "function", "invalid scope row selection")
	assert(options.presets == nil or type(options.presets) == "table", "invalid scope preset owners")
	for id, port in pairs(options.presets or {}) do check_preset(id, port, options) end
	local prepare_batch = options.prepare_batch or Writer.prepare_batch
	local owner, debt, committed, busy = {}, nil, nil, false
	-- Debt is ordered: the runtime inverse first, then every published file in
	-- reverse. Each settled step is recorded so a retry never repeats it.
	local function compensate()
		if debt == nil then return true end
		if not debt.restoration_started and type(options.before_restore) == "function" then
			local called, admitted = pcall(options.before_restore, debt.snapshot)
			if not called or admitted ~= true then return false end
			debt.restoration_started = true
		end
		for _, receipt in ipairs(debt.cleanup or {}) do
			if Writer.retry_publication_cleanup(receipt) ~= true then return false end
		end
		for _, file in ipairs(debt.files) do
			if FileInverse.settle_publication(file) ~= true then return false end
		end
		if debt.runtime then
			local ok, restored = pcall(options.restore, debt.snapshot)
			if not ok or restored ~= true then return false end
			debt.runtime = false
		end
		for index = #debt.files, 1, -1 do
			local file = debt.files[index]
			if not file.restored then
				if not FileInverse.restore(file, options.files) then return false end
				file.restored = true
			end
		end
		if type(options.after_restore) == "function" then
			local called, settled = pcall(options.after_restore, debt.snapshot)
			if not called or settled ~= true then return false end
		end
		debt = nil
		return true
	end
	--- Reads one preset source and renders its detached candidate.
	local function prepare_preset(id, port, mode, rows)
		local content, status, detail = Writer.read_classified(port.path, options.files)
		if status ~= "ok" and status ~= "absent" then
			return nil, "preset " .. id .. " source is unreadable: " .. tostring(detail)
		end
		local document, shapes = Codec.decode_with_shapes(content or "")
		if type(document) ~= "table" then return nil, "preset " .. id .. " source is not valid TOML" end
		local candidate = port.render(mode, document, rows, shapes)
		if type(candidate) ~= "string" then return nil, "preset " .. id .. " rendered no candidate" end
		local decoded, candidate_shapes = Codec.decode_with_shapes(candidate)
		if type(decoded) ~= "table" then return nil, "preset " .. id .. " candidate is not valid TOML" end
		return {
			id = id, path = port.path, backup_path = port.backup_path,
			decoded = decoded, shapes = candidate_shapes, candidate = candidate,
			source = { status = status, content = status == "ok" and content or nil },
		}
	end
	--- Writes and verifies one exact backup before any destination is touched.
	local function back_up(file)
		if file.source.status ~= "ok" then return true end
		local backed, backup_error, retry_cleanup = Writer.publish_if_unchanged(file.backup_path,
			file.source.content, options.files, { status = "absent" })
		if type(retry_cleanup) == "function" then
			debt.cleanup[#debt.cleanup + 1] = { publication_cleanup = retry_cleanup }
		end
		if backed ~= true then return false, "backup refused: " .. tostring(backup_error) end
		local observed, status = Writer.read_classified(file.backup_path, options.files)
		if status ~= "ok" or observed ~= file.source.content then return false, "backup verification failed" end
		return true
	end
	function owner.pending() return debt ~= nil or busy end
	function owner.retry_restore()
		if busy then return false end
		return compensate()
	end
	--- Whether the last commit still retains an exact inverse for revert().
	function owner.committed() return committed ~= nil end
	--- Forgets the last commit's inverse once its composition has committed.
	function owner.release() committed = nil end
	--- Undoes the last commit: the runtime snapshot, then each file it published,
	--- only while that file still holds our bytes. A refusal is retained debt.
	--- @return boolean reverted
	--- @return string|nil detail
	function owner.revert()
		if busy or debt ~= nil then return false, "a configuration transaction is still pending" end
		if committed == nil then return false, "no committed publication to revert" end
		local files = {}
		for index, file in ipairs(committed.files) do
			files[index] = { path = file.path, source = file.source, candidate = file.candidate, restored = false }
		end
		debt, committed = { snapshot = committed.snapshot, runtime = true, files = files }, nil
		if compensate() then return true end
		return false, "the reverted configuration remains pending"
	end
	local function perform(scope, mode, requested)
		if busy or debt ~= nil then return false, "a configuration transaction is still pending" end
		busy, committed = true, nil
		local published = {}
		local called, ok, detail, content = pcall(function()
			-- Preset ownership is proven before any inventory can read a file.
			local presets = {}
			local initial_plan = options.manifest.scope_plan(scope, requested and "clear" or mode)
			if requested and #initial_plan.presets > 0 then return false, "edit requires a single-file scope" end
			for _, request in ipairs(initial_plan.presets) do
				local port = options.presets and options.presets[request.preset]
				if port == nil then return false, "scope requires separate preset ownership" end
				presets[#presets + 1] = { id = request.preset, port = port, rows = {} }
			end
			local owned_paths = type(options.owned_paths) == "function" and options.owned_paths() or {}
			assert(type(owned_paths) == "table", "dynamic configuration ownership is unavailable")
			local plan
			if requested then
				for _, row in ipairs(requested) do
					if options.validate_update(scope, row) ~= true then return false, "edit row is not owned or valid" end
				end
				plan = { operations = requested }
			else plan = options.manifest.scope_plan(scope, mode, owned_paths, options.owners) end
			local updates = {}
			for _, row in ipairs(plan.operations) do
				local path, target = row.section .. "." .. row.key, nil
				if options.select == nil or options.select(path) == true then
					for _, preset in ipairs(presets) do
						for _, prefix in ipairs(preset.port.prefixes or {}) do
							if belongs(path, prefix) then target = preset end
						end
					end
					local rows = target and target.rows or updates
					rows[#rows + 1] = row
				end
			end
			-- A preset scope with no configuration rows leaves config.toml alone:
			-- creating it would also end the first-run state of an absent file.
			local config, decoded, candidate, source, preparation_check
			if #updates > 0 or #presets == 0 then
				local prepared, why
				prepared, why, candidate, source = prepare_batch(options.path, updates, options.files)
				if prepared ~= true then return false, why end
				if type(candidate) ~= "string" or type(source) ~= "table"
					or (source.status ~= "ok" and source.status ~= "absent")
					or (source.status == "ok" and type(source.content) ~= "string") then
					return false, "scope preparation did not return an exact source and candidate"
				end
				preparation_check = preparation_lookup(options.path, source, candidate)
				if not preparation_current(preparation_check) then return false, "scope preparation epoch refused" end
				decoded = Codec.decode(candidate)
				if type(decoded) ~= "table" then return false, "scope candidate is not valid TOML" end
				config = { path = options.path, backup_path = options.backup_path, candidate = candidate,
					source = { status = source.status, content = source.status == "ok" and source.content or nil } }
			end
			local rendered, files = {}, {}
			for _, preset in ipairs(presets) do
				local file, why = prepare_preset(preset.id, preset.port, mode, preset.rows)
				if not file then return false, why end
				rendered[preset.id] = { decoded = file.decoded, shapes = file.shapes, candidate = file.candidate, source = file.source }
				files[#files + 1] = file
			end
			if config then files[#files + 1] = config end
			local function prepared_source_current()
				if not preparation_current(preparation_check) then return false end
				if preparation_check == nil then return true end
				local bytes, status = Writer.read_classified(config.path, options.files)
				return preparation_current(preparation_check) and status == config.source.status
					and (status ~= "ok" or bytes == config.source.content)
			end
			if not prepared_source_current() then return false, "scope preparation changed before capture" end
			local snapshot = options.capture(source, candidate, updates, rendered)
			if type(snapshot) ~= "table" then return false, "runtime snapshot was not acknowledged" end
			if not prepared_source_current() then return false, "scope preparation changed during capture" end
			debt = { snapshot = snapshot, runtime = false, files = published, cleanup = {} }
			for _, file in ipairs(files) do
				if not prepared_source_current() then return false, "scope preparation changed before backup" end
				local backed, why = back_up(file)
				if not backed then return false, why end
			end
			if not prepared_source_current() then return false, "scope preparation changed before runtime" end
			-- Capture before invocation because a native callback can mutate and throw.
			debt.runtime = true
			if options.apply(decoded, updates, source, candidate, rendered) ~= true then
				return false, "runtime application refused"
			end
			for _, file in ipairs(files) do
				local expected = file.source.status == "ok" and { status = "ok", content = file.source.content }
					or { status = "absent" }
				local done, publish_error, retry_cleanup = Writer.publish_if_unchanged(file.path, file.candidate, options.files, expected, nil, preparation_check)
				if done == true or type(retry_cleanup) == "function" then
					published[#published + 1] = { path = file.path, source = file.source, candidate = file.candidate,
						publication_cleanup = type(retry_cleanup) == "function" and retry_cleanup or nil }
				end
				if done ~= true then return false, publish_error end
			end
			if type(options.after_publish) == "function" and options.after_publish(snapshot) ~= true then
				return false, "publication delivery acknowledgement refused"
			end
			debt = nil
			committed = { snapshot = snapshot, files = published }
			return true, nil, candidate
		end)
		busy = false
		if not called or ok ~= true then
			committed = nil
			local restored = compensate()
			return false, restored and tostring(called and detail or ok) or "runtime rollback remains pending"
		end
		return true, nil, content
	end
	function owner.apply(scope, mode) return perform(scope, mode) end
	--- Applies detached owned edits through the same backup and exact inverse.
	--- The host's opt-in validator must acknowledge every assignment/parameter.
	function owner.apply_updates(scope, updates)
		if type(options.validate_update) ~= "function" or options.select ~= nil
			or type(updates) ~= "table" or getmetatable(updates) ~= nil or #updates == 0 then
			return false, "scope does not own edit rows"
		end
		local rows, paths, count = {}, {}, 0
		for index, row in pairs(updates) do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #updates
				or type(row) ~= "table" or getmetatable(row) ~= nil then return false, "invalid edit rows" end
			for key in pairs(row) do
				if key ~= "section" and key ~= "key" and key ~= "value" and key ~= "delete" and key ~= "intent" then return false, "invalid edit row field" end
			end
			if type(row.section) ~= "string" or row.section == "" or type(row.key) ~= "string" or row.key == ""
				or (row.delete ~= nil and row.delete ~= true)
				or (row.delete == true and row.value ~= nil)
				or (row.delete ~= true and type(row.value) ~= "string") then return false, "invalid edit row value" end
			local intentional, valid = pcall(require("shortcuts.assignment").is_intentional, row)
			if not intentional then return false, "invalid assignment intent" end
			local path = row.section .. "." .. row.key
			if paths[path] then return false, "duplicate edit row" end
			paths[path], count = true, count + 1
			rows[index] = { section = row.section, key = row.key, value = row.value, delete = row.delete, intent = row.intent }
		end
		if count ~= #updates then return false, "sparse edit rows" end
		return perform(scope, "edit", rows)
	end
	return owner
end

return M

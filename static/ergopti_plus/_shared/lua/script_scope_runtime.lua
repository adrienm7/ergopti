--- _shared/lua/script_scope_runtime.lua

--- Projects declared direct scope rows onto explicit native settings aliases.
--- The existing scope transaction retains the file/runtime inverse journal;
--- native receipts own only their captured field or settings source.
local M = {}
local Codec = require("toml_codec")
local KeyPath = require("toml_codec.key_path")
local Outdated = require("config_outdated")

local function entry_for(manifest, path)
	local find = manifest.find_declared_entry_by_path or manifest.find_entry_by_path
	assert(type(find) == "function", "script scope needs declaration metadata")
	return find(path)
end

local function available(entry, platform)
	assert(type(entry) == "table" and type(entry.platforms) == "table", "script scope needs explicit platform metadata")
	for _, tag in ipairs(entry.platforms) do if tag == platform then return true end end
	return false
end

local function effective(manifest, path, row)
	if row.delete then return manifest.default_for(path) end
	return row.value
end

local function validate(entry, value, platform)
	local kind = entry.type == "enum" and "string" or entry.type
	assert(kind == "string" or kind == "boolean", "script scalar owner has unsupported declaration metadata")
	assert(entry.type ~= "enum" or (type(entry.enum_values) == "table" and #entry.enum_values > 0),
		"script enum declaration has no explicit values")
	assert(type(value) == kind and Outdated.manifest_value_fits(entry, value, platform),
		"script scope value does not match its declaration: " .. tostring(entry.path))
end

--- Plans only directly declared rows backed by an available native alias.
--- @param manifest table Actual platform manifest reader.
--- @param platform string Canonical platform tag.
--- @param aliases table Canonical path -> native alias/field owner records.
--- @param mode string Recommended or clear.
--- @return table plan Detached direct plan with platform-available operations.
function M.plan(manifest, platform, aliases, mode)
	assert(type(aliases) == "table", "script scope needs its native alias map")
	local plan = manifest.direct_scope_plan("global", mode)
	local rows, selected = {}, {}
	for _, row in ipairs(plan.operations) do
		local path = row.section .. "." .. row.key
		local entry = entry_for(manifest, path)
		if available(entry, platform) then
			local owner = aliases[path]
			assert(type(owner) == "table" and type(owner.alias) == "string" and owner.alias ~= ""
				and type(owner.native) == "table", "available direct scope row has no native owner: " .. path)
			validate(entry, effective(manifest, path, row), platform)
			rows[#rows + 1], selected[path] = row, true
		end
	end
	local keys = {}
	for path in pairs(aliases) do
		assert(selected[path] == true, "native script alias is outside the available direct declaration: " .. tostring(path))
		keys[#keys + 1] = path
	end
	table.sort(keys)
	plan.operations = rows
	return plan, keys
end

local function source_value(document, path)
	local value = document
	for _, segment in ipairs(assert(KeyPath.parse(path))) do
		if value == nil then return nil end
		assert(type(value) == "table", "script scope source crosses a scalar")
		value = value[segment]
	end
	return value
end

--- Binds native receipts to the existing transaction's capture/apply/restore ports.
--- @param options table Manifest, platform, aliases, storage, token and backup ports.
--- @return table runtime Capture/apply/restore, direct manifest and native fences.
function M.new(options)
	assert(type(options) == "table" and type(options.token) == "table"
		and type(options.storage_backup_path) == "function", "script scope needs its native token and backup owner")
	local manifest, platform, aliases = options.manifest, options.platform, options.aliases
	local _, paths = M.plan(manifest, platform, aliases, "clear")
	local Storage, token, keys = options.storage, options.token, {}
	for _, method in ipairs({ "acquire_owned", "release_owned", "capture_owned", "publish_owned", "restore_owned", "forget_owned" }) do
		assert(type(Storage[method]) == "function", "script settings owner lacks " .. method)
	end
	local bound, captured = {}, {}
	local file_methods = {}
	local file_names = { "read_with_status", "write", "write_if_unchanged", "delete" }
	assert(type(options.files) == "table", "script scope needs its native file owner")
	for _, method in ipairs(file_names) do file_methods[method] = options.files[method] end
	local manifest_methods = {}
	for _, method in ipairs({ "direct_scope_plan", "default_for", "find_declared_entry_by_path", "find_entry_by_path" }) do
		manifest_methods[method] = manifest[method]
	end
	local function list_copy(value)
		if value == nil then return nil end
		local copy = {}
		for key, child in pairs(value) do copy[key] = child end
		return copy
	end
	local function same_list(value, snapshot)
		if value == nil or snapshot == nil then return value == snapshot end
		if type(value) ~= "table" then return false end
		for key, child in pairs(snapshot) do if value[key] ~= child then return false end end
		for key in pairs(value) do if snapshot[key] == nil then return false end end
		return true
	end
	local storage_methods = {}
	for _, method in ipairs({ "acquire_owned", "release_owned", "capture_owned", "publish_owned", "restore_owned", "forget_owned" }) do
		storage_methods[method] = Storage[method]
	end
	for _, path in ipairs(paths) do
		local descriptor = aliases[path]
		for _, method in ipairs({ "scope_acquire", "scope_release", "scope_capture", "scope_apply", "scope_restore", "scope_forget" }) do
			assert(type(descriptor.native[method]) == "function", "script field owner lacks " .. method)
		end
		assert(not bound[descriptor.alias], "script settings alias belongs to multiple declared rows")
		bound[descriptor.alias], keys[#keys + 1] = true, descriptor.alias
		local native = {}
		for _, method in ipairs({ "scope_acquire", "scope_release", "scope_capture", "scope_apply", "scope_restore", "scope_forget" }) do
			native[method] = descriptor.native[method]
		end
		local entry = entry_for(manifest, path)
		captured[path] = { descriptor = descriptor, alias = descriptor.alias, parent = descriptor.native, native = native,
			entry = entry, kind = entry.type, entry_path = entry.path, platforms = list_copy(entry.platforms),
			enum_values = list_copy(entry.enum_values), default = manifest.default_for(path) }
	end
	local function context_matches()
		if not rawequal(package.loaded["infra.manifest_reader"], manifest) then return false end
		if not rawequal(package.loaded["adapters.storage"], Storage)
			or not rawequal(package.loaded["adapters.file_system"], options.files) then return false end
		for _, method in ipairs(file_names) do if options.files[method] ~= file_methods[method] then return false end end
		for method, callback in pairs(manifest_methods) do if manifest[method] ~= callback then return false end end
		for method, callback in pairs(storage_methods) do if Storage[method] ~= callback then return false end end
		for _, path in ipairs(paths) do
			local record = captured[path]
			if not rawequal(aliases[path], record.descriptor) or record.descriptor.alias ~= record.alias
				or not rawequal(record.descriptor.native, record.parent) then return false end
			local entry = entry_for(manifest, path)
			if not rawequal(entry, record.entry) or entry.type ~= record.kind or entry.path ~= record.entry_path
				or not same_list(entry.platforms, record.platforms) or not same_list(entry.enum_values, record.enum_values)
				or manifest.default_for(path) ~= record.default then return false end
			for method, callback in pairs(record.native) do if record.parent[method] ~= callback then return false end end
		end
		return true
	end
	local fences = { { acquire = function(owner)
		if not context_matches() then return false end
		return storage_methods.acquire_owned(owner, keys)
	end, release = storage_methods.release_owned } }
	for _, path in ipairs(paths) do
		local native = captured[path].native
		fences[#fences + 1] = { acquire = native.scope_acquire, release = native.scope_release }
	end
	local runtime, active = { fences = fences }, nil
	runtime.manifest = { scope_plan = function(scope, mode)
		assert(scope == "global", "script owner cannot acquire another scope")
		return M.plan(manifest, platform, aliases, mode)
	end }
	function runtime.capture(_, source)
		if not context_matches() then return nil end
		local document = Codec.decode(source and source.content or "")
		assert(type(document) == "table", "script source is not valid TOML")
		local receipt, stored = storage_methods.capture_owned(token)
		if type(receipt) ~= "table" or type(stored) ~= "table" or not context_matches() then return nil end
		local snapshot = { storage = receipt, fields = {} }
		for _, path in ipairs(paths) do
			local descriptor, entry = captured[path], entry_for(manifest, path)
			local cell = stored[descriptor.alias]
			assert(type(cell) == "table" and type(cell.present) == "boolean", "script native source is incomplete")
			if cell.present then validate(entry, cell.value, platform) end
			local configured = source_value(document, path)
			if configured ~= nil then validate(entry, configured, platform) end
			local native = descriptor.native.scope_capture(token)
			if type(native) ~= "table" or not context_matches() then return nil end
			snapshot.fields[path] = native
		end
		active = snapshot
		return snapshot
	end
	function runtime.apply(_, rows)
		if active == nil or not context_matches() then return false end
		local cells, values, selected = {}, {}, {}
		for _, row in ipairs(rows) do
			local path = row.section .. "." .. row.key
			local descriptor = assert(captured[path], "script transaction attempted an unowned row")
			assert(not selected[path], "script transaction repeated an owned row")
			local value = effective(manifest, path, row)
			validate(entry_for(manifest, path), value, platform)
			-- Native legacy absence can detect an OS locale or another logger level.
			-- Persist the canonical effective scalar even when TOML remains sparse.
			local cell = { present = true, value = value }
			cells[descriptor.alias] = cell
			values[path], selected[path] = value, true
		end
		if storage_methods.publish_owned(token, active.storage, cells, options.storage_backup_path(), options.files) ~= true
			or not context_matches() then return false end
		for _, path in ipairs(paths) do
			if selected[path] and captured[path].native.scope_apply(token, active.fields[path], values[path]) ~= true then return false end
			if not context_matches() then return false end
		end
		return true
	end
	function runtime.restore(snapshot)
		if type(snapshot) ~= "table" or type(snapshot.fields) ~= "table" then return false end
		for index = #paths, 1, -1 do
			local path = paths[index]
			if captured[path].native.scope_restore(token, snapshot.fields[path]) ~= true then return false end
		end
		return storage_methods.restore_owned(token, snapshot.storage) == true
	end
	function runtime.forget()
		if active == nil then return true end
		for _, path in ipairs(paths) do
			if captured[path].native.scope_forget(token, active.fields[path]) ~= true then return false end
		end
		if storage_methods.forget_owned(token, active.storage) ~= true then return false end
		active = nil
		return true
	end
	return runtime
end

return M

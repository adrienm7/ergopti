--- _shared/lua/config_defaults.lua

--- Pure manifest projections shared by configuration readers and transactions.
--- Neutral absence, explicit recommendations and scope ownership are separate.
local M = {}

local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = clone(child) end
	return out
end

local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

local function belongs(path, prefix)
	return path == prefix or path:sub(1, #prefix + 1) == prefix .. "."
end

local function row(path, value, remove)
	local section, key = path:match("^(.*)%.([^%.]+)$")
	assert(section and key, "configuration paths require a section and key")
	if remove then return { section = section, key = key, delete = true } end
	return { section = section, key = key, value = clone(value) }
end

--- Builds a pure contract from one platform's generated manifest.
--- @param manifest table Generated feature and scope registry.
--- @return table contract Detached projections and batch operation builders.
function M.new(manifest)
	assert(type(manifest) == "table" and type(manifest.features) == "table"
		and type(manifest.scopes) == "table", "configuration manifest is incomplete")
	local index = {}
	for _, entry in ipairs(manifest.features) do
		assert(type(entry.path) == "string" and entry.default ~= nil and entry.recommended ~= nil,
			"configuration entry needs a path, neutral default and recommendation")
		assert(not index[entry.path], "duplicate configuration path: " .. entry.path)
		index[entry.path] = entry
	end
	local contract = {}
	local function dynamic_entry(path)
		local parent = path
		while parent do
			if index[parent] then return nil end
			parent = parent:match("^(.*)%.[^%.]+$")
		end
		for _, scope in pairs(manifest.scopes) do
			for _, definition in ipairs(scope.dynamic_defaults or {}) do
				if path:sub(1, #definition.prefix + 1) == definition.prefix .. "." then
					local tail, depth = path:sub(#definition.prefix + 2), 0
					for _ in tail:gmatch("[^%.]+") do depth = depth + 1 end
					if depth == definition.depth and (not definition.suffix or tail:match("[^%.]+$") == definition.suffix)
						and not tail:find("..", 1, true)
						and tail:sub(1, 1) ~= "."
						and tail:sub(-1) ~= "." then return definition end
				end
			end
		end
	end
	local function project(path, field)
		assert(type(path) == "string", "configuration path must be a string")
		local dynamic = dynamic_entry(path)
		if dynamic then return clone(dynamic[field]) end
		local prefix, suffix = path, {}
		while not index[prefix] do
			local parent, key = prefix:match("^(.*)%.([^%.]+)$")
			assert(parent, "unknown configuration path: " .. path)
			table.insert(suffix, 1, key)
			prefix = parent
		end
		local value = index[prefix][field]
		for _, key in ipairs(suffix) do
			assert(type(value) == "table" and value[key] ~= nil, "unknown configuration path: " .. path)
			value = value[key]
		end
		return clone(value)
	end
	function contract.default_for(path) return project(path, "default") end
	function contract.has_default(path)
		if dynamic_entry(path) then return true end
		local prefix, suffix = path, {}
		while not index[prefix] do
			local parent, key = prefix:match("^(.*)%.([^%.]+)$")
			if not parent then return false end
			table.insert(suffix, 1, key)
			prefix = parent
		end
		local value = index[prefix].default
		for _, key in ipairs(suffix) do
			if type(value) ~= "table" or value[key] == nil then return false end
			value = value[key]
		end
		return true
	end
	function contract.recommended_for(path) return project(path, "recommended") end
	function contract.document_defaults()
		local result = {}
		for _, entry in ipairs(manifest.features) do
			local node, parts = result, {}
			for part in entry.path:gmatch("[^%.]+") do parts[#parts + 1] = part end
			for index = 1, #parts - 1 do
				local key = parts[index]
				if node[key] == nil then node[key] = {} end
				assert(type(node[key]) == "table", "configuration path overlaps a scalar: " .. entry.path)
				node = node[key]
			end
			node[parts[#parts]] = clone(entry.default)
		end
		return result
	end
	function contract.scopes() return clone(manifest.scopes) end
	function contract.operation(path, value)
		local neutral = project(path, "default")
		-- An absent shortcut uses false while a configured chord is a table.
		-- Native owners validate assignments; a neutral sentinel is not a schema.
		assert(value ~= nil, "use a neutral value to delete configuration: " .. path)
		return row(path, value, equal(value, neutral))
	end
	local function collect_scope(scope_id)
		local prefixes, excluded, visiting, dynamic_definitions, presets = {}, {}, {}, {}, {}
		local function visit(id)
			local scope = manifest.scopes[id]
			assert(type(scope) == "table", "unknown configuration scope: " .. tostring(id))
			assert(not visiting[id], "cyclic configuration scopes: " .. id)
			visiting[id] = true
			if scope.preset ~= nil then
				assert(type(scope.preset) == "string" and scope.preset ~= "", "invalid configuration preset owner")
				presets[id] = scope.preset
			end
			for _, prefix in ipairs(scope.prefixes or {}) do prefixes[#prefixes + 1] = prefix end
			for _, path in ipairs(scope.restore_exclude or {}) do excluded[#excluded + 1] = path end
			for _, definition in ipairs(scope.dynamic_defaults or {}) do dynamic_definitions[definition] = true end
			for _, child in ipairs(scope.includes or {}) do visit(child) end
			visiting[id] = nil
		end
		visit(scope_id)
		return prefixes, excluded, dynamic_definitions, presets
	end
	function contract.scope_operations(scope_id, mode, owned_paths)
		assert(mode == "recommended" or mode == "clear", "unknown configuration scope operation")
		local prefixes, excluded, dynamic_definitions = collect_scope(scope_id)
		local operations = {}
		local function emit(path, value)
			if mode == "recommended" then
				for _, prefix in ipairs(excluded) do if belongs(path, prefix) then return end end
			end
			operations[#operations + 1] = mode == "clear" and row(path, value, true)
				or contract.operation(path, value)
		end
		for _, entry in ipairs(manifest.features) do
			local selected = false
			for _, prefix in ipairs(prefixes) do selected = selected or belongs(entry.path, prefix) end
			if selected then
				local value = entry.recommended
				if entry.type == "feature" then
					local keys = {}
					for key in pairs(value) do keys[#keys + 1] = key end
					table.sort(keys)
					for _, key in ipairs(keys) do emit(entry.path .. "." .. key, value[key]) end
				else
					emit(entry.path, value)
				end
			end
		end
		local emitted = {}
		for _, path in ipairs(owned_paths or {}) do
			assert(type(path) == "string", "owned configuration paths must be strings")
			local definition = dynamic_entry(path)
			assert(definition, "dynamic scope path is not declared: " .. path)
			if dynamic_definitions[definition] and not emitted[path] then
				emit(path, definition.recommended)
				emitted[path] = true
			end
		end
		return operations
	end
	--- Collects only declared dynamic leaves supplied by explicit runtime owners.
	--- @param scope_id string Selected scope identifier.
	--- @param providers table Named callbacks returning dense lists of owned paths.
	--- @return table paths Sorted, detached and deduplicated scope inventory.
	function contract.scope_inventory(scope_id, providers)
		assert(type(providers) == "table", "scope inventory requires runtime owners")
		local _, _, definitions = collect_scope(scope_id)
		local found, paths = {}, {}
		for name, provider in pairs(providers) do
			assert(type(name) == "string" and name ~= "" and type(provider) == "function", "invalid scope inventory owner")
			local owned = provider()
			assert(type(owned) == "table", "runtime inventory is unavailable: " .. name)
			local count = 0
			for index, path in pairs(owned) do
				assert(type(index) == "number" and index >= 1 and index % 1 == 0 and type(path) == "string",
					"runtime inventory must contain an array of paths: " .. name)
				count = count + 1
				local definition = dynamic_entry(path)
				assert(definition or contract.has_default(path), "runtime inventory path is not declared: " .. path)
				if definition and definitions[definition] and not found[path] then
					found[path] = true
					paths[#paths + 1] = path
				end
			end
			assert(count == #owned, "runtime inventory must be dense: " .. name)
		end
		table.sort(paths)
		return paths
	end

	--- Plans configuration rows separately from external preset owner requests.
	--- @param scope_id string Selected scope identifier.
	--- @param mode string Recommended restoration or clear.
	--- @param owned_paths table|nil Explicit runtime-owned dynamic paths.
	--- @return table plan Detached operations and required preset ownership.
	function contract.scope_plan(scope_id, mode, owned_paths)
		local operations = contract.scope_operations(scope_id, mode, owned_paths)
		local _, _, _, selected = collect_scope(scope_id)
		local scopes, presets = {}, {}
		for scope in pairs(selected) do scopes[#scopes + 1] = scope end
		table.sort(scopes)
		for _, scope in ipairs(scopes) do
			presets[#presets + 1] = { scope = scope, preset = selected[scope], mode = mode }
		end
		return { scope = scope_id, mode = mode, operations = operations, presets = presets }
	end

	return contract
end

return M

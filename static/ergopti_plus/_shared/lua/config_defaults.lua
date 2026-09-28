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
	function contract.scope_operations(scope_id, mode, owned_paths)
		assert(mode == "recommended" or mode == "clear", "unknown configuration scope operation")
		local prefixes, excluded, visiting, dynamic_definitions = {}, {}, {}, {}
		local function visit(id)
			local scope = manifest.scopes[id]
			assert(type(scope) == "table", "unknown configuration scope: " .. tostring(id))
			assert(not visiting[id], "cyclic configuration scopes: " .. id)
			visiting[id] = true
			for _, prefix in ipairs(scope.prefixes or {}) do prefixes[#prefixes + 1] = prefix end
			for _, path in ipairs(scope.restore_exclude or {}) do excluded[#excluded + 1] = path end
			for _, definition in ipairs(scope.dynamic_defaults or {}) do dynamic_definitions[definition] = true end
			for _, child in ipairs(scope.includes or {}) do visit(child) end
			visiting[id] = nil
		end
		visit(scope_id)
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
	return contract
end

return M

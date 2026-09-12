--- tests/support/compiled_lua_scope.lua

--- ==============================================================================
--- MODULE: Scoped Lua Compilation Reuse
--- DESCRIPTION:
--- Reuses compilation, never executed closures or module instances. Every hit
--- resolves and reads the current source; ownership ends with the callback.
--- ==============================================================================

local M = {}

--- Runs a synchronous test workload with content-validated Lua compilation reuse.
--- @param callback function Receives hit/miss counters; module execution stays fresh.
--- @return ... Exact callback results, including nil slots.
function M.with_scope(callback)
	assert(type(callback) == "function", "compiled Lua scope callback must be a function")
	local searchers = package.searchers
	assert(type(searchers) == "table" and type(searchers[2]) == "function", "Lua file searcher is required")
	local original = searchers[2]
	local searchpath, open, load_binary = package.searchpath, io.open, load
	local dump, info, upvalue = string.dump, debug.getinfo, debug.getupvalue
	local cache, stats = {}, { hits = 0, misses = 0 }
	local standard = info(original, "S").what == "C"
	local function read_source(path)
		local handle, reason = open(path, "rb")
		assert(handle, reason)
		local read = table.pack(pcall(handle.read, handle, "*a"))
		local closed = table.pack(pcall(handle.close, handle))
		if not read[1] then error(read[2], 0) end
		assert(read[2] ~= nil, read[3])
		if not closed[1] then error(closed[2], 0) end
		assert(closed[2], closed[3])
		return read[2]
	end
	searchers[2] = function(name)
		-- Custom searchers and nested scopes keep their original semantics.
		if not standard or package.searchpath ~= searchpath then return original(name) end
		local path = searchpath(name, package.path)
		if not path then return original(name) end
		local source = read_source(path)
		local previous = cache[name]
		if previous and previous.path == path and previous.source == source then
			stats.hits = stats.hits + 1
			-- Reusing the executed function would retain a module's mutated _ENV.
			return assert(load_binary(previous.bytecode, nil, "b")), previous.data
		end
		stats.misses = stats.misses + 1
		cache[name] = nil
		local result = table.pack(original(name))
		local loader, data = result[1], result[2]
		if type(loader) == "function" and info(loader, "S").what == "main" and data == path then
			local environment_name, environment = upvalue(loader, 1)
			local ordinary = environment_name == nil or (environment_name == "_ENV"
				and rawequal(environment, _G) and upvalue(loader, 2) == nil)
			if ordinary and searchpath(name, package.path) == path and read_source(path) == source then
				cache[name] = { path = path, source = source, bytecode = dump(loader), data = data }
			end
		end
		return table.unpack(result, 1, result.n)
	end
	local outcome = table.pack(pcall(callback, stats))
	package.searchers = searchers
	searchers[2] = original
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

return M

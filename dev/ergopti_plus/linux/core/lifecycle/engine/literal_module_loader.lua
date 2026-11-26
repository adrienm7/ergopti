--- core/lifecycle/engine/literal_module_loader.lua
--- Resolves this application's Lua and native modules without interpreting
--- filename bytes as package.path template separators or substitutions.
local M = {}

local function readable(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

local function symbol(name)
	name = name:match("^[^-]*%-(.*)$") or name
	return "luaopen_" .. name:gsub("%.", "_")
end

--- Installs app-owned searchers ahead of their corresponding host searchers.
--- @param driver string Literal driver directory, outside package.path templates.
--- @param shared string Literal shared Lua directory.
--- @param runtime string|nil Private runtime prefix.
--- @param mode string|nil Entry order: base, daemon, direct or child-direct.
--- @return table owner The loader already installed in this process, if any.
function M.install(driver, shared, runtime, mode)
	local existing = package.loaded["core.lifecycle.engine.literal_module_loader"]
	if existing then return existing end
	assert(type(driver) == "string" and driver ~= "" and type(shared) == "string" and shared ~= "")
	local base = {
		{ driver, ".lua" }, { driver, "/init.lua" },
		{ shared, ".lua" }, { shared, "/init.lua" },
	}
	local daemon = {
		{ driver, ".lua" }, { driver .. "/hotstrings/engine", ".lua" },
		{ shared, ".lua" }, { shared, "/init.lua" },
	}
	local lua_roots = {}
	local function append(entries)
		for _, entry in ipairs(entries) do lua_roots[#lua_roots + 1] = entry end
	end
	-- These lists mirror the templates prepended by each entry point. The
	-- daemon's own list precedes the launcher-provided list, when present.
	if mode == "daemon" or mode == "direct" or mode == "child-direct" then append(daemon) end
	if mode ~= "direct" and mode ~= "child-direct" then append(base) end
	--- Prepends the literal root/suffix pairs owned by one child entry point.
	--- @param entries table Ordered { root, suffix } pairs.
	function M.prepend(entries)
		for i = #entries, 1, -1 do
			local entry = entries[i]
			assert(type(entry[1]) == "string" and type(entry[2]) == "string")
			table.insert(lua_roots, 1, entry)
		end
	end
	local native_roots = {}
	if os.getenv("ERGOPTI_LITERAL_NATIVE_MODULES") == "1" then
		native_roots[#native_roots + 1] = driver .. "/native_modules"
	end
	if mode ~= "direct" and mode ~= "child-direct" and type(runtime) == "string" and runtime ~= "" then
		lua_roots[#lua_roots + 1] = { runtime .. "/share/lua/5.1", ".lua" }
		lua_roots[#lua_roots + 1] = { runtime .. "/share/lua/5.1", "/init.lua" }
		table.insert(native_roots, 1, runtime .. "/lib/lua/5.1")
	end
	local function lua_file(name)
		local relative = name:gsub("%.", "/")
		for _, entry in ipairs(lua_roots) do
			local path = entry[1] .. "/" .. relative .. entry[2]
			if readable(path) then return path end
		end
	end
	--- Resolves availability through the same Lua roots that require() consults.
	--- @param name string Dotted module name.
	--- @param path string Original host search path for modules outside the app.
	--- @return string|nil filename
	function M.searchpath(name, path)
		local found = lua_file(name)
		if found then return found end
		return package.searchpath(name, path)
	end
	local function lua_searcher(name)
		local path = lua_file(name)
		if not path then return "\n\tno application Lua file for " .. name end
		local loader, err = loadfile(path)
		if not loader then error("error loading module '" .. name .. "' from file '" .. path .. "':\n\t" .. err, 0) end
		return loader
	end
	local function c_searcher(name, root_only)
		local basename = name
		if root_only then basename = name:match("^([^.]+)%.") end
		if not basename then return "" end
		local relative = basename:gsub("%.", "/")
		for _, root in ipairs(native_roots) do
			local path = root .. "/" .. relative .. ".so"
			if readable(path) then
				local loader, err, stage = package.loadlib(path, symbol(name))
				if loader then return loader end
				if root_only and stage == "init" then return "\n\tno module '" .. name .. "' in file '" .. path .. "'" end
				error("error loading module '" .. name .. "' from file '" .. path .. "':\n\t" .. tostring(err), 0)
			end
		end
		return "\n\tno application native file for " .. name
	end
	local searchers = package.loaders or package.searchers
	assert(type(searchers) == "table", "Lua module searchers unavailable")
	table.insert(searchers, 2, lua_searcher)
	table.insert(searchers, 4, function(name) return c_searcher(name, false) end)
	table.insert(searchers, 6, function(name) return c_searcher(name, true) end)
	package.loaded["core.lifecycle.engine.literal_module_loader"] = M
	return M
end

return M

--- _shared/lua/program_providers.lua

--- Private discovery choices lower to the existing literal executable/argv contract.
local Json = require("json")
local Unicode = require("compat.utf8")
local Parameter = require("program_parameter")
local M = { MAX_SCAN = 256, MAX_CHOICES = 64, MAX_NAME_BYTES = 4096, MAX_ARGUMENT_BYTES = 1048576,
	MAX_CATALOGUE_BYTES = 65536, MAX_PATH_BYTES = 16384, MAX_PATH_DIRECTORIES = 128, MAX_SAFE_INTEGER = 9007199254740991 }

local function clean(value)
	return type(value) == "string" and not value:find("%z") and Unicode.len(value) ~= nil
end
local function dense(values)
	if type(values) ~= "table" or Json.is_null(values) then return false end
	local count = 0
	for index in pairs(values) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return false end
		count = count + 1
	end
	for index = 1, count do if rawget(values, index) == nil then return false end end
	return true
end
local function fields(value, allowed, expected)
	if type(value) ~= "table" or Json.is_null(value) then return false end
	local count = 0
	for key in pairs(value) do if not allowed[key] then return false end; count = count + 1 end
	return count == expected
end
local function absolute(value)
	return clean(value) and value:sub(1, 1) == "/"
end
local function basename(value)
	return clean(value) and value ~= "" and #value <= M.MAX_NAME_BYTES and value ~= "." and value ~= ".."
		and not value:find("/", 1, true)
end
local function receipt(value)
	return type(value) == "table" and clean(value.token) and value.token ~= ""
		and (value.kind == "directory" or value.kind == "other"
			or value.kind == "file" and type(value.readable) == "boolean" and type(value.executable) == "boolean")
end

--- Validates bundled provider descriptions, never machine paths or discovery results.
--- @param raw string Bundled JSON source.
--- @param platform string Native Lua driver: hs or linux.
--- @return table|nil providers, string|nil failure
function M.catalogue(raw, platform)
	if platform ~= "linux" and platform ~= "hs" then return nil, "unsupported_platform" end
	local ok, data = pcall(Json.decode_lossless, raw)
	if not ok or not fields(data, { version = true, providers = true }, 2) or data.version ~= 1
		or not Json.is_array(data.providers) or #data.providers == 0 then return nil, "invalid_catalogue" end
	local providers, ids, extensions = {}, {}, {}
	for _, source in ipairs(data.providers) do
		if not fields(source, { id = true, mode = true, extensions = true, commands = true, prefix = true }, 5)
			or not clean(source.id) or not source.id:match("^[a-z_]+$") or ids[source.id]
			or (source.mode ~= "script" and source.mode ~= "executable")
			or not Json.is_array(source.extensions) or not Json.is_array(source.prefix)
			or type(source.commands) ~= "table" or Json.is_array(source.commands) then return nil, "invalid_catalogue" end
		ids[source.id] = true
		for name, commands in pairs(source.commands) do
			if (name ~= "linux" and name ~= "hs" and name ~= "ahk") or not Json.is_array(commands)
				or source.mode == "script" and #commands == 0 then return nil, "invalid_catalogue" end
			for _, command in ipairs(commands) do
				if not clean(command) or not command:match("^[%w_.%-]+$") then return nil, "invalid_catalogue" end
			end
		end
		for _, argument in ipairs(source.prefix) do if not clean(argument) then return nil, "invalid_catalogue" end end
		for _, extension in ipairs(source.extensions) do
			if not clean(extension) or not extension:match("^[a-z][a-z0-9]*$") or extensions[extension] then
				return nil, "invalid_catalogue"
			end
			extensions[extension] = true
		end
		if source.commands[platform] then providers[#providers + 1] = source end
	end
	return providers
end

--- Owns one picker session's directory, interpreter and file receipts.
--- @param platform string Native driver: hs or linux.
--- @param raw string Bundled descriptor JSON.
--- @param ports table route, list, identity, interpreter and optional retire functions.
--- @return table|nil owner, string|nil failure
function M.new(platform, raw, ports)
	local providers, failure = M.catalogue(raw, platform)
	if not providers then return nil, failure end
	for _, name in ipairs({ "route", "list", "identity", "interpreter" }) do
		if type(ports) ~= "table" or type(ports[name]) ~= "function" then return nil, "ports_unavailable" end
	end
	if ports.retire ~= nil and type(ports.retire) ~= "function" then return nil, "ports_unavailable" end
	local owner, generation, current, busy = {}, 0, nil, false
	local function route()
		local ok, value = pcall(ports.route)
		return ok and absolute(value) and value or nil
	end
	local function identity(path)
		local ok, value, reason = pcall(ports.identity, path)
		if ok and value == nil and reason == "missing" then return nil, "missing" end
		if not ok or not receipt(value) then return nil, "identity_refused" end
		return { kind = value.kind, token = value.token, readable = value.readable, executable = value.executable }
	end
	local function guard(snapshot)
		if current ~= snapshot or generation ~= snapshot.generation or route() ~= snapshot.route then return false end
		local value = identity(snapshot.route)
		return value and value.kind == "directory" and value.token == snapshot.directory_token
			and current == snapshot and generation == snapshot.generation and route() == snapshot.route or false
	end
	local function guarded(callback)
		if busy then return nil, "busy" end
		busy = true
		local ok, value, reason = pcall(callback)
		busy = false
		if not ok then current = nil; return nil, "native_refused" end
		return value, reason
	end
	function owner.invalidate()
		generation, current = generation + 1, nil
		if ports.retire == nil then return true end
		local ok, settled = pcall(ports.retire)
		return ok and settled == true
	end
	function owner.discover()
		return guarded(function()
			generation, current = generation + 1, nil
			local epoch = generation
			local directory = route()
			if not directory then return nil, "route_unavailable" end
			local states, interpreters = {}, {}
			for _, provider in ipairs(providers) do
				local available = provider.mode == "executable"
				if not available then
					local ready, target, reason = pcall(ports.interpreter, provider.commands[platform])
					if not ready or target == nil and reason ~= "unavailable" then return nil, "interpreter_refused" end
					if target ~= nil then
						if type(target) ~= "table" or not absolute(target.executable) or not clean(target.token)
							or target.token == "" then return nil, "interpreter_refused" end
						local observed = identity(target.executable)
						if not observed or observed.kind ~= "file" or not observed.executable
							or observed.token ~= target.token then return nil, "interpreter_refused" end
						available = true
						interpreters[provider.id] = { executable = target.executable, token = target.token }
					end
				end
				states[#states + 1] = { id = provider.id, available = available,
					reason = not available and "interpreter_unavailable" or nil }
			end
			if generation ~= epoch or route() ~= directory then return nil, "stale_discovery" end
			local prior, reason = identity(directory)
			if generation ~= epoch or route() ~= directory then return nil, "stale_discovery" end
			if not prior then
				if reason == "missing" then return { choices = {}, providers = states, truncated = false } end
				return nil, reason
			end
			if prior.kind ~= "directory" then return nil, "route_unavailable" end
			local snapshot = { generation = epoch, route = directory, directory_token = prior.token, entries = {} }
			current = snapshot
			local ok, listed = pcall(ports.list, directory, M.MAX_SCAN)
			if not ok or type(listed) ~= "table" or dense(listed.names) == false or #listed.names > M.MAX_SCAN
				or type(listed.truncated) ~= "boolean" then current = nil; return nil, "discovery_refused" end
			local seen, names = {}, {}
			for _, name in ipairs(listed.names) do
				if not basename(name) or seen[name] then current = nil; return nil, "invalid_discovery" end
				seen[name], names[#names + 1] = true, name
			end
			table.sort(names)
			local choices, truncated = {}, listed.truncated
			for _, name in ipairs(names) do
				local path = directory .. "/" .. name
				local info, why = identity(path)
				if not info and why ~= "missing" then current = nil; return nil, "identity_refused" end
				if info and info.kind == "file" then
					local extension = name:match("%.([^%.]+)$")
					extension = extension and extension:lower()
					local selected, native_provider
					for _, provider in ipairs(providers) do
						if provider.mode == "executable" then native_provider = provider end
						for _, suffix in ipairs(provider.extensions) do if suffix == extension then selected = provider end end
					end
					selected = selected or info.executable and native_provider or nil
					if selected and (selected.mode == "executable" and info.executable
						or selected.mode == "script" and info.readable and interpreters[selected.id]) then
						if #choices >= M.MAX_CHOICES then truncated = true
						else
							local key = tostring(generation) .. ":" .. tostring(#choices + 1)
							snapshot.entries[key] = { provider = selected, path = path, token = info.token,
								interpreter = interpreters[selected.id] }
							choices[#choices + 1] = { key = key, provider = selected.id, label = name }
						end
					end
				end
			end
			if not guard(snapshot) then current = nil; return nil, "stale_discovery" end
			return { choices = choices, providers = states, truncated = truncated }
		end)
	end
	function owner.resolve(key, arguments)
		return guarded(function()
			local snapshot = current
			local entry = type(key) == "string" and snapshot and snapshot.entries[key]
			if not entry or not guard(snapshot) then return nil, "stale_discovery" end
			if dense(arguments) == false then return nil, "invalid_arguments" end
			local bytes = 0
			for _, value in ipairs(arguments) do
				if not clean(value) then return nil, "invalid_arguments" end
				bytes = bytes + #value
				if bytes > M.MAX_ARGUMENT_BYTES then return nil, "invalid_arguments" end
			end
			local info = identity(entry.path)
			if not info or info.kind ~= "file" or info.token ~= entry.token then return nil, "stale_discovery" end
			local executable, argv = entry.path, {}
			if entry.provider.mode == "script" then
				if not info.readable then return nil, "stale_discovery" end
				local target = identity(entry.interpreter.executable)
				if not target or target.kind ~= "file" or not target.executable
					or target.token ~= entry.interpreter.token then return nil, "stale_discovery" end
				local ready, selected = pcall(ports.interpreter, entry.provider.commands[platform])
				if not ready or type(selected) ~= "table" or selected.executable ~= entry.interpreter.executable
					or selected.token ~= entry.interpreter.token then return nil, "stale_discovery" end
				executable = entry.interpreter.executable
				for _, prefix in ipairs(entry.provider.prefix) do argv[#argv + 1] = prefix end
				argv[#argv + 1] = entry.path
			elseif not info.executable then return nil, "stale_discovery" end
			for _, value in ipairs(arguments) do argv[#argv + 1] = value end
			local scalar = Json.encode({ version = 1, executable = executable, arguments = Json.array(argv) })
			if not Parameter.parse(scalar, platform) then return nil, "invalid_program" end
			if not guard(snapshot) then return nil, "stale_discovery" end
			return scalar
		end)
	end
	return owner
end

return M

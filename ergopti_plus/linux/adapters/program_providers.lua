--- adapters/program_providers.lua

--- Native bounded script discovery; private paths never pass through a shell.
local Shared = require("program_providers")
local Json = require("json")
local Paths = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local loaded, Native = pcall(require, "luv")
if not loaded then Native = nil end
local M = {}
local catalogue_debt, catalogue_busy = nil, false

local function integer(value, nonnegative)
	return type(value) == "number" and value == value and value % 1 == 0
		and math.abs(value) <= Shared.MAX_SAFE_INTEGER and (not nonnegative or value >= 0)
end
local function absolute(value)
	return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("%z")
end
local function stamp(stat, canonical)
	if type(stat) ~= "table" or type(stat.type) ~= "string" or not absolute(canonical) then return nil end
	local parts = { stat.type, canonical }
	for _, key in ipairs({ "dev", "ino", "mode", "uid", "gid", "size" }) do
		if not integer(stat[key], true) then return nil end
		parts[#parts + 1] = stat[key]
	end
	for _, key in ipairs({ "mtime", "ctime" }) do
		local time = stat[key]
		if type(time) ~= "table" or not integer(time.sec) or not integer(time.nsec, true)
			or time.nsec >= 1000000000 then return nil end
		parts[#parts + 1], parts[#parts + 2] = time.sec, time.nsec
	end
	return Json.encode(Json.array(parts))
end

local function retire_catalogue()
	if catalogue_busy then return false end
	if catalogue_debt == nil then return true end
	catalogue_busy = true
	local ok, closed = pcall(catalogue_debt.native.fs_close, catalogue_debt.fd)
	if ok and closed == true then catalogue_debt = nil end
	catalogue_busy = false
	return catalogue_debt == nil
end
local function read_catalogue(native)
	if not retire_catalogue() then return nil end
	for _, name in ipairs({ "fs_open", "fs_fstat", "fs_read", "fs_close" }) do
		if type(native[name]) ~= "function" then return nil end
	end
	local ok, path = pcall(Paths.shared, "modules/actions/program_providers.json")
	if not ok or not absolute(path) then return nil end
	catalogue_busy = true
	-- O_RDONLY | O_NONBLOCK never waits on a substituted FIFO.
	local opened, fd = pcall(native.fs_open, path, 2048, 0)
	if not opened or type(fd) ~= "number" then catalogue_busy = false; return nil end
	catalogue_debt = { native = native, fd = fd }
	local read, raw = pcall(function()
		local stat = native.fs_fstat(fd)
		if type(stat) ~= "table" or stat.type ~= "file" then return nil end
		return native.fs_read(fd, Shared.MAX_CATALOGUE_BYTES + 1, 0)
	end)
	catalogue_busy = false
	if not retire_catalogue() or not read or type(raw) ~= "string" or #raw > Shared.MAX_CATALOGUE_BYTES then return nil end
	return raw
end

--- Creates a native session owner without opening a directory or launching a process.
--- @param options table|nil Native test ports; never user-supplied configuration.
--- @return table|nil owner, string|nil failure
function M.create(options)
	options = options or {}
	if not retire_catalogue() then return nil, "reader_refused" end
	local native = options.native or Native
	for _, name in ipairs({ "fs_lstat", "fs_stat", "fs_realpath", "fs_access", "fs_opendir", "fs_readdir", "fs_closedir" }) do
		if type(native) ~= "table" or type(native[name]) ~= "function" then return nil, "native_unavailable" end
	end
	local raw = options.catalogue or read_catalogue(native)
	if type(raw) ~= "string" then return nil, "invalid_catalogue" end
	local pending
	local function retire()
		if pending == nil then return true end
		local ok, closed = pcall(native.fs_closedir, pending)
		if not ok or closed ~= true then return false end
		pending = nil
		return true
	end
	local function access(path, permission)
		local ok, allowed, _, code = pcall(native.fs_access, path, permission)
		if ok and type(allowed) == "boolean" then return allowed end
		if ok and allowed == nil and (code == "EACCES" or code == "EPERM") then return false end
		return nil
	end
	local function identity(path)
		if not absolute(path) then return nil, "identity_refused" end
		local first, _, code = native.fs_lstat(path)
		if first == nil then return nil, code == "ENOENT" and "missing" or "identity_refused" end
		if first.type ~= "file" and first.type ~= "directory" then
			local token = stamp(first, path)
			return token and { kind = "other", token = token } or nil, "identity_refused"
		end
		local canonical = native.fs_realpath(path)
		local token = stamp(first, canonical)
		local target = canonical and native.fs_stat(canonical)
		if not token or stamp(target, canonical) ~= token then return nil, "identity_refused" end
		local readable, executable = false, false
		if first.type == "file" then
			readable, executable = access(canonical, "r"), access(canonical, "x")
			if readable == nil or executable == nil then return nil, "identity_refused" end
		end
		local after = native.fs_lstat(path)
		if native.fs_realpath(path) ~= canonical or stamp(after, canonical) ~= token then return nil, "identity_refused" end
		return { kind = first.type, token = token, readable = readable, executable = executable }
	end
	local function list(path, limit)
		if not retire() then return nil, "directory_close_refused" end
		local directory = native.fs_opendir(path, nil, 1)
		if directory == nil then return nil, "discovery_refused" end
		pending = directory
		local ok, names, truncated = pcall(function()
			local result = {}
			while true do
				local entries, error_message = native.fs_readdir(directory)
				if error_message ~= nil then return nil end
				if entries == nil or #entries == 0 then return result, false end
				if type(entries) ~= "table" or #entries ~= 1 or type(entries[1]) ~= "table"
					or type(entries[1].name) ~= "string" then return nil end
				local name = entries[1].name
				if name ~= "." and name ~= ".." then
					if #result == limit then return result, true end
					result[#result + 1] = name
				end
			end
		end)
		if not retire() then return nil, "directory_close_refused" end
		if not ok or names == nil then return nil, "discovery_refused" end
		return { names = names, truncated = truncated }
	end
	local function interpreter(commands)
		local path
		if options.path then path = options.path() else path = os.getenv("PATH") end
		if type(path) ~= "string" or #path > Shared.MAX_PATH_BYTES or path:find("%z") then return nil, "interpreter_refused" end
		local directories = {}
		for directory in (path .. ":"):gmatch("([^:]*):") do
			if absolute(directory) then
				if #directories == Shared.MAX_PATH_DIRECTORIES then return nil, "interpreter_refused" end
				directories[#directories + 1] = directory:gsub("/+$", "") .. "/"
			end
		end
		for _, command in ipairs(commands) do
			for _, directory in ipairs(directories) do
				local requested = directory .. command
				local stat = native.fs_lstat(requested)
				if stat ~= nil then
					local canonical = native.fs_realpath(requested)
					local value = canonical and identity(canonical)
					local requested_token = stamp(stat, requested)
					if value and value.kind == "file" and value.executable and requested_token
						and native.fs_realpath(requested) == canonical
						and stamp(native.fs_lstat(requested), requested) == requested_token then
						return { executable = canonical, token = value.token }
					end
				end
			end
		end
		return nil, "unavailable"
	end
	return Shared.new("linux", raw, {
		route = options.route or function()
			local config = ConfigPaths.get_config_dir()
			return absolute(config) and config:gsub("/+$", "") .. "/scripts" or nil
		end,
		list = list,
		identity = identity,
		interpreter = interpreter,
		retire = retire,
	})
end

M.new = M.create
return M

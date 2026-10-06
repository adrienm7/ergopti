--- adapters/program_providers.lua

--- ==============================================================================
--- MODULE: Native Program Provider Inventory
--- DESCRIPTION:
--- Supplies native metadata and bounded private enumeration to shared provider
--- policy. Discovery never opens or executes user files. Read/execute mode bits
--- are filesystem eligibility; the owned runner supplies actual access receipts.
--- ==============================================================================

local M = {}
local Shared = require("program_providers")
local ConfigPaths = require("infra.config_paths")
local Paths = require("infra.paths")
local FsDir = require("infra.fs_dir")
local hs = hs
local SAFE_INTEGER = Shared.MAX_SAFE_INTEGER
local MAX_PATH_DIRECTORIES = Shared.MAX_PATH_DIRECTORIES
local _read_debt, _file_busy = nil, false

local function retire_read()
	if _file_busy then return false end
	if not _read_debt then return true end
	_file_busy = true
	local ok, receipt = pcall(function() return _read_debt:close() end)
	if ok and receipt == true then _read_debt = nil end
	_file_busy = false
	return _read_debt == nil
end

local function read_owned(path, consume)
	if not retire_read() then return nil, "reader_refused" end
	_file_busy = true
	local opened, handle = pcall(io.open, path, "rb")
	if not opened or not handle then _file_busy = false; return nil, "read_unavailable" end
	_read_debt = handle
	local read, value = pcall(consume, handle)
	local closed, receipt = pcall(function() return handle:close() end)
	if closed and receipt == true then _read_debt = nil end
	_file_busy = false
	if _read_debt then return nil, "reader_refused" end
	if not read then return nil, "read_refused" end
	return value
end

local function absolute(path)
	return type(path) == "string" and path:sub(1, 1) == "/" and #path <= Shared.MAX_PATH_BYTES
		and not path:find("\0", 1, true)
end

local function inspect(method, path)
	local ok, value, failure = pcall(method, path)
	if not ok or failure ~= nil or type(value) ~= "table" then return nil end
	return value
end

local function realpath(path)
	local ok, value = pcall(hs.fs.pathToAbsolute, path)
	return ok and absolute(value) and value or nil
end

local function metadata_number(value, whole)
	if type(value) ~= "number" or value < 0 then return nil end
	if math.type(value) == "integer" then return tostring(value) end
	if value ~= value or value > SAFE_INTEGER or whole and value % 1 ~= 0 then return nil end
	return string.format(whole and "%.0f" or "%.17g", value)
end

local function fingerprint(attributes, canonical)
	if type(attributes) ~= "table" or not absolute(canonical) then return nil end
	local permissions = attributes.permissions
	if type(permissions) ~= "string" or not permissions:match("^[r%-][w%-][x%-][r%-][w%-][x%-][r%-][w%-][x%-]$") then return nil end
	local parts = { tostring(#canonical), canonical, attributes.mode, permissions }
	if type(attributes.mode) ~= "string" then return nil end
	for _, field in ipairs({ "dev", "ino", "uid", "gid", "size" }) do
		local value = metadata_number(attributes[field], true)
		if value == nil then return nil end
		parts[#parts + 1] = value
	end
	for _, field in ipairs({ "modification", "change" }) do
		local value = metadata_number(attributes[field], false)
		if value == nil then return nil end
		parts[#parts + 1] = value
	end
	return table.concat(parts, "\n")
end

local function missing(path)
	local parent, name = path:match("^(.*)/([^/]+)$")
	if not parent then return false end
	if parent == "" then parent = "/" end
	local listing = FsDir.collect_private(parent, Shared.MAX_SCAN)
	if not listing or listing.truncated then return false end
	for _, entry in ipairs(listing.names) do if entry == name then return false end end
	return true
end

local function identity(path)
	if not retire_read() or not absolute(path) then return nil, "identity_refused" end
	local attributes = inspect(hs.fs.symlinkAttributes, path)
	if not attributes then
		if missing(path) then return nil, "missing" end
		return nil, "identity_refused"
	end
	if attributes.mode ~= "file" and attributes.mode ~= "directory" then
		return { kind = "other", token = "other", readable = false, executable = false }
	end
	local canonical = realpath(path)
	local token = fingerprint(attributes, canonical)
	local target = canonical and inspect(hs.fs.attributes, canonical)
	if not token or fingerprint(target, canonical) ~= token then return nil, "identity_refused" end
	local after = inspect(hs.fs.symlinkAttributes, path)
	if realpath(path) ~= canonical or fingerprint(after, canonical) ~= token then return nil, "identity_refused" end
	return {
		kind = attributes.mode, token = token,
		readable = attributes.mode == "file" and attributes.permissions:find("r", 1, true) ~= nil,
		executable = attributes.mode == "file" and attributes.permissions:find("x", 1, true) ~= nil,
	}
end

local function interpreter(commands)
	local path = os.getenv("PATH")
	if not retire_read() or type(path) ~= "string" or #path > Shared.MAX_PATH_BYTES
		or path:find("\0", 1, true) then return nil, "interpreter_refused" end
	local directories = {}
	for directory in (path .. ":"):gmatch("(.-):") do
		if directory:sub(1, 1) == "/" then
			if #directories == MAX_PATH_DIRECTORIES then return nil, "interpreter_refused" end
			directories[#directories + 1] = directory:gsub("/+$", "")
		end
	end
	for _, command in ipairs(commands) do
		for _, directory in ipairs(directories) do
			local requested = directory .. "/" .. command
			local attributes = inspect(hs.fs.symlinkAttributes, requested)
			if attributes then
				local canonical = realpath(requested)
				-- The system Python pathname may launch the developer-tools installer;
				-- it is not evidence that an actual Python interpreter is installed.
				if canonical and not (command == "python3" and canonical == "/usr/bin/python3") then
					local value = identity(canonical)
					local after = inspect(hs.fs.symlinkAttributes, requested)
					if value and value.kind == "file" and value.executable
						and realpath(requested) == canonical
						and fingerprint(after, canonical) == fingerprint(attributes, canonical) then
						return { executable = canonical, token = value.token }
					end
				end
			end
		end
	end
	-- Native lstat errors have no errno. Unknown candidates are skipped, never
	-- classified as absent; unavailable means no verified eligible interpreter.
	return nil, "unavailable"
end

--- Constructs one picker-scoped provider owner without enumerating or executing.
--- @return table|nil owner Shared discovery and exact v1 resolver.
--- @return string|nil reason Closed failure category.
function M.create()
	if not retire_read() then return nil, "reader_refused" end
	if type(hs) ~= "table" or type(hs.fs) ~= "table"
		or type(hs.fs.symlinkAttributes) ~= "function" or type(hs.fs.attributes) ~= "function"
		or type(hs.fs.pathToAbsolute) ~= "function" or type(FsDir.collect_private) ~= "function" then
		return nil, "ports_unavailable"
	end
	local resolved, path = pcall(Paths.shared, "modules/actions/program_providers.json")
	if not resolved or not absolute(path) then return nil, "invalid_catalogue" end
	-- Bundled code/data loading is a separate trusted boundary from user files;
	-- this regular-file preflight is not an atomic pathname lease across open.
	local attributes = inspect(hs.fs.attributes, path)
	if not attributes or attributes.mode ~= "file" then return nil, "invalid_catalogue" end
	local raw = read_owned(path, function(handle) return handle:read(Shared.MAX_CATALOGUE_BYTES + 1) end)
	if type(raw) ~= "string" or #raw > Shared.MAX_CATALOGUE_BYTES then
		return nil, "invalid_catalogue"
	end
	return Shared.new("hs", raw, {
		route = function()
			local config = ConfigPaths.get_config_dir()
			if not absolute(config) then return nil end
			return config:gsub("/+$", "") .. "/scripts"
		end,
		list = FsDir.collect_private,
		identity = identity,
		interpreter = interpreter,
		retire = retire_read,
	})
end

return M

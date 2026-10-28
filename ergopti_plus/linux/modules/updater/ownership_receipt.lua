--- modules/updater/ownership_receipt.lua
--- ==============================================================================
--- MODULE: Complete Installation Receipt Admission
--- DESCRIPTION:
--- Uses the writer's canonical schema to prove every rollback-tree entry belongs
--- to the unchanged installed payload. Native regular readers preserve close
--- receipts and reject special files; metadata ambiguity never permits deletion.
--- ==============================================================================

local M = {}
local Fs = require("adapters.file_system")
local Crypto = require("adapters.crypto")
local NativePath = require("native_path")
local MAX_SAFE_INTEGER = 2 ^ 53 - 1 -- Exact numeric range shared by LuaJIT metadata.
local SCHEMA_KEYS = { MANIFEST = true, HEX_LENGTH = true, DRIVER_TREE = true, SHARED_TREE = true,
	LAUNCHER = true, EXTERNAL_RECORDS = true, DRIVER_SENTINEL = true, SHARED_SENTINEL = true }

local function relative_path(path)
	if type(path) ~= "string" or path == "" or path:find("[%z\r\n\t\\]")
		or path:sub(1, 1) == "/" or path:sub(-1) == "/" or path:find("//", 1, true) then return false end
	for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
	return true
end

--- Reads literal schema assignments from the same resource the Bash owner uses.
--- @param current string Active installation root.
--- @return table|nil schema
--- @return string|nil failure
function M.read_schema(current)
	local bytes = Fs.read(current .. "/linux/install/ownership_schema.sh")
	if type(bytes) ~= "string" or bytes:find("[%z\r]") then return nil, "ownership schema unavailable" end
	local schema = {}
	for line in (bytes .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local key, value = line:match("^OWNERSHIP_([A-Z_]+)='([^']*)'$")
			if not key or not SCHEMA_KEYS[key] or schema[key] then return nil, "ownership schema is malformed" end
			schema[key] = value
		end
	end
	for key in pairs(SCHEMA_KEYS) do if not schema[key] then return nil, "ownership schema is incomplete" end end
	local length = tonumber(schema.HEX_LENGTH)
	if not length or length <= 0 or length % 1 ~= 0 then return nil, "ownership digest length is invalid" end
	schema.hex_length = length
	for _, key in ipairs({ "MANIFEST", "DRIVER_TREE", "SHARED_TREE" }) do
		if not schema[key]:match("^[%w_.-]+$") or schema[key] == "." or schema[key] == ".." then
			return nil, "ownership schema component is invalid"
		end
	end
	if schema.DRIVER_TREE == schema.SHARED_TREE then return nil, "ownership tree roots overlap" end
	for _, key in ipairs({ "LAUNCHER", "DRIVER_SENTINEL", "SHARED_SENTINEL" }) do
		if not relative_path(schema[key]) then return nil, "ownership schema path is invalid" end
	end
	schema.external = {}
	for name in schema.EXTERNAL_RECORDS:gmatch("%S+") do
		if not name:match("^[a-z_]+$") or schema.external["@" .. name] then return nil, "ownership external record is invalid" end
		schema.external["@" .. name] = true
	end
	return schema
end

--- Parses the shared receipt wire shape without treating malformed rows as absent.
--- @param bytes string Manifest bytes admitted by a regular-file reader.
--- @param schema table Canonical writer schema.
--- @return table|nil record Files, directories and external rows.
--- @return string|nil failure
function M.parse(bytes, schema)
	if type(bytes) ~= "string" or bytes == "" or bytes:find("[%z\r]") or bytes:sub(-1) ~= "\n" then
		return nil, "ownership receipt is not complete LF text"
	end
	local record = { files = {}, directories = {}, external = {}, seen = {} }
	for line in bytes:gmatch("([^\n]*)\n") do
		local digest, path = line:match("^([0-9a-f]+)\t([^\t]+)$")
		if not digest or #digest ~= schema.hex_length or not relative_path(path) or record.seen[path] then
			return nil, "ownership receipt has an invalid or duplicate row"
		end
		record.seen[path] = true
		if schema.external[path] then
			record.external[#record.external + 1] = line .. "\n"
		elseif path == schema.LAUNCHER or path:sub(1, #schema.DRIVER_TREE + 1) == schema.DRIVER_TREE .. "/"
			or path:sub(1, #schema.SHARED_TREE + 1) == schema.SHARED_TREE .. "/" then
			record.files[path] = digest
			local parent = NativePath.dirname(path)
			while parent do record.directories[parent] = true; parent = NativePath.dirname(parent) end
		else return nil, "ownership receipt path escapes payload roots" end
	end
	if not record.files[schema.DRIVER_TREE .. "/" .. schema.DRIVER_SENTINEL]
		or not record.files[schema.SHARED_TREE .. "/" .. schema.SHARED_SENTINEL] then
		return nil, "ownership receipt lacks installation sentinels"
	end
	return record
end

local function integer(value, signed)
	return type(value) == "number" and value >= (signed and -MAX_SAFE_INTEGER or 0)
		and value <= MAX_SAFE_INTEGER and value % 1 == 0
end

local function snapshot(native, path, kind)
	local called, stat = pcall(native.fs_lstat, path)
	if not called or type(stat) ~= "table" or stat.type ~= kind then return nil end
	local parts = {}
	for _, key in ipairs({ "dev", "ino", "mode", "size" }) do
		if not integer(stat[key]) then return nil end
		parts[#parts + 1] = string.format("%.0f", stat[key])
	end
	local identity = parts[1] .. ":" .. parts[2]
	for _, key in ipairs({ "mtime", "ctime" }) do
		local stamp = stat[key]
		if type(stamp) ~= "table" or not integer(stamp.sec, true) or not integer(stamp.nsec)
			or stamp.nsec >= 1000000000 then return nil end
		parts[#parts + 1] = string.format("%.0f:%.0f", stamp.sec, stamp.nsec)
	end
	return table.concat(parts, ":"), identity
end

local function read_checked(native, path)
	local before = snapshot(native, path, "file")
	if not before then return nil end
	local bytes = Fs.read(path)
	if type(bytes) ~= "string" or snapshot(native, path, "file") ~= before then return nil end
	return bytes, before
end

--- Reads a current receipt without following links or confusing failures with absence.
--- @param path string Current receipt namespace.
--- @return string|nil bytes Complete bytes after stable native admission.
--- @return string status "ok", "absent" or "error".
function M.read_current(path)
	local loaded, native = pcall(require, "luv")
	if not loaded or type(native) ~= "table" or type(native.fs_lstat) ~= "function" then return nil, "error" end
	local called, fact, _, code = pcall(native.fs_lstat, path)
	if not called then return nil, "error" end
	if fact == nil and code == "ENOENT" then return nil, "absent" end
	if type(fact) ~= "table" or fact.type ~= "file" then return nil, "error" end
	local bytes = read_checked(native, path)
	if type(bytes) ~= "string" then return nil, "error" end
	return bytes, "ok"
end

--- Verifies complete payload membership, bytes and stable directory identity.
--- @param root string Rollback root, never followed through a final link.
--- @param current string Active installation holding the canonical schema.
--- @return string|nil identity Exact admitted device/inode within numeric bounds.
--- @return string|nil failure
function M.verify(root, current)
	local loaded, native = pcall(require, "luv")
	if not loaded or type(native) ~= "table" or type(native.fs_lstat) ~= "function" or type(native.fs_scandir) ~= "function"
		or type(native.fs_scandir_next) ~= "function" then return nil, "native ownership metadata unavailable" end
	local schema, reason = M.read_schema(current)
	if not schema then return nil, reason end
	local bytes, manifest_signature = read_checked(native, root .. "/" .. schema.MANIFEST)
	local record, parse_error = M.parse(bytes, schema)
	if not record then return nil, parse_error end
	local seen = {}
	local function walk(path, relative)
		local before, identity = snapshot(native, path, "directory")
		if not before then return nil end
		local request = native.fs_scandir(path)
		if not request then return nil end
		local entries = {}
		while true do
			local name, kind = native.fs_scandir_next(request)
			if not name then if kind ~= nil then return nil end; break end
			if name == "." or name == ".." or name:find("/", 1, true) then return nil end
			entries[#entries + 1] = name
		end
		local tree = relative:match("^[^/]+")
		local payload_tree = tree == schema.DRIVER_TREE or tree == schema.SHARED_TREE
		for _, name in ipairs(entries) do
			local child = relative == "" and name or relative .. "/" .. name
			local full = path .. "/" .. name
			if child == schema.MANIFEST then
				if snapshot(native, full, "file") ~= manifest_signature then return nil end
			elseif record.files[child] then
				local content = read_checked(native, full)
				if content == nil or Crypto.sha256(content) ~= record.files[child] then return nil end
				seen[child] = true
			elseif record.directories[child] then
				if not walk(full, child) then return nil end
			elseif payload_tree and snapshot(native, full, "directory") then
				-- Receipts enumerate files, not empty archive directories. Recurse
				-- only inside owned payload trees: any unlisted data or link still
				-- refuses, including a file nested below otherwise empty folders.
				if not walk(full, child) then return nil end
			else return nil end
		end
		if snapshot(native, path, "directory") ~= before then return nil end
		return identity
	end
	local called, identity = pcall(walk, root, "")
	if not called or not identity then return nil, "backup tree is modified, unowned or ambiguous" end
	for path in pairs(record.files) do if not seen[path] then return nil, "backup payload is incomplete" end end
	return identity
end

return M

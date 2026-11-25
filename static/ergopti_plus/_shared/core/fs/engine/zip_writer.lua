--- _shared/core/fs/engine/zip_writer.lua

--- ==============================================================================
--- MODULE: ZIP Archive Writer
--- DESCRIPTION:
--- Builds the bytes of a ZIP archive whose entries are stored uncompressed,
--- for « Export the logs (zip) » on macOS (Lua 5.4) and Linux (LuaJIT).
---
--- FEATURES & RATIONALE:
--- 1. No external tool. A Linux desktop does not always have `zip`, `bsdtar` or
---    a usable python3, and a tool missing on the tester's machine would make
---    the one export they are asked for fail. Stored entries need only CRC-32.
--- 2. Lua 5.4 integer operators are compiled with load(), LuaJIT uses its bit
---    library: one source parses under both interpreters (as sha256.lua).
--- 3. UTF-8 names (general purpose flag bit 11) and no ZIP64: the archive holds
---    a few days of logs, so an entry or archive at 4 GiB is refused loudly
---    instead of being written corrupt.
--- ==============================================================================

local M = {}

local MOD32 = 4294967296
local LIMIT = MOD32 - 1

--- The 32-bit operations of the running interpreter.
--- @return table ops { band, bxor, rshift }, every result in [0, 2^32).
local function bit_ops()
	if _VERSION ~= "Lua 5.1" then
		local compiled = assert(load([[
			return {
				band = function(a, b) return a & b end,
				bxor = function(a, b) return a ~ b end,
				rshift = function(a, n) return a >> n end,
			}
		]], "zip_writer_bit_ops", "t"))
		return compiled()
	end
	local bit = require("bit")
	local function u(value) return value % MOD32 end
	return {
		band = function(a, b) return u(bit.band(a, b)) end,
		bxor = function(a, b) return u(bit.bxor(a, b)) end,
		rshift = function(a, n) return u(bit.rshift(a, n)) end,
	}
end

local Ops = bit_ops()
local band, bxor, rshift = Ops.band, Ops.bxor, Ops.rshift

local CRC_TABLE = {}
for index = 0, 255 do
	local value = index
	for _ = 1, 8 do
		if band(value, 1) == 1 then
			value = bxor(rshift(value, 1), 0xEDB88320)
		else
			value = rshift(value, 1)
		end
	end
	CRC_TABLE[index] = value
end

--- CRC-32 (ISO-HDLC, the ZIP checksum) of a byte string.
--- @param data string
--- @return number crc In [0, 2^32).
function M.crc32(data)
	if type(data) ~= "string" then error("zip_writer.crc32: data must be a string", 2) end
	local crc = 0xFFFFFFFF
	for index = 1, #data do
		crc = bxor(rshift(crc, 8), CRC_TABLE[band(bxor(crc, data:byte(index)), 0xFF)])
	end
	return bxor(crc, 0xFFFFFFFF)
end

--- Little-endian unsigned integer of `size` bytes.
local function le(value, size)
	local bytes = {}
	for index = 1, size do
		bytes[index] = string.char(value % 256)
		value = math.floor(value / 256)
	end
	return table.concat(bytes)
end

--- MS-DOS date and time words of a local date table (1980 at the earliest).
--- @param stamp table { year, month, day, hour, min, sec }
--- @return number time, number date
local function dos_stamp(stamp)
	local year = math.max(stamp.year, 1980)
	local time = stamp.hour * 2048 + stamp.min * 32 + math.floor(stamp.sec / 2)
	local date = (year - 1980) * 512 + stamp.month * 32 + stamp.day
	return time, date
end

--- Builds a stored ZIP archive.
--- @param entries table Array of { name = string, data = string }; names are
---   relative, "/"-separated, unique, with no "..", no leading "/" and no "\".
--- @param stamp table Local date table every entry is dated with (os.date("*t")).
--- @return string bytes The complete archive.
function M.build(entries, stamp)
	if type(entries) ~= "table" or #entries == 0 then
		error("zip_writer.build: at least one entry is required", 2)
	end
	if type(stamp) ~= "table" or type(stamp.year) ~= "number" then
		error("zip_writer.build: stamp must be a date table", 2)
	end
	local time, date = dos_stamp(stamp)
	local locals, centrals, seen = {}, {}, {}
	local offset = 0
	for _, entry in ipairs(entries) do
		local name, data = entry.name, entry.data
		if type(name) ~= "string" or name == "" or name:sub(1, 1) == "/" or name:find("\\", 1, true)
			or name:find("\0", 1, true) or seen[name] then
			error("zip_writer.build: invalid or repeated entry name " .. tostring(name), 2)
		end
		for segment in name:gmatch("[^/]+") do
			if segment == ".." or segment == "." then error("zip_writer.build: entry name escapes the archive: " .. name, 2) end
		end
		if type(data) ~= "string" then error("zip_writer.build: entry data must be a string: " .. name, 2) end
		if #data >= LIMIT or #name > 0xFFFF then error("zip_writer.build: entry too large for ZIP: " .. name, 2) end
		seen[name] = true
		local crc = M.crc32(data)
		local header = "PK\3\4" .. le(20, 2) .. le(0x0800, 2) .. le(0, 2) .. le(time, 2) .. le(date, 2)
			.. le(crc, 4) .. le(#data, 4) .. le(#data, 4) .. le(#name, 2) .. le(0, 2) .. name
		locals[#locals + 1] = header
		locals[#locals + 1] = data
		centrals[#centrals + 1] = "PK\1\2" .. le(20, 2) .. le(20, 2) .. le(0x0800, 2) .. le(0, 2)
			.. le(time, 2) .. le(date, 2) .. le(crc, 4) .. le(#data, 4) .. le(#data, 4)
			.. le(#name, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4)
			.. le(offset, 4) .. name
		offset = offset + #header + #data
		if offset >= LIMIT then error("zip_writer.build: archive too large for ZIP", 2) end
	end
	local directory = table.concat(centrals)
	if #entries > 0xFFFF or offset + #directory >= LIMIT then error("zip_writer.build: archive too large for ZIP", 2) end
	return table.concat(locals) .. directory .. "PK\5\6" .. le(0, 2) .. le(0, 2) .. le(#entries, 2)
		.. le(#entries, 2) .. le(#directory, 4) .. le(offset, 4) .. le(0, 2)
end

return M

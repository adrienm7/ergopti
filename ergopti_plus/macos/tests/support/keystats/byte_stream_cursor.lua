--- tests/support/keystats/byte_stream_cursor.lua

--- ==============================================================================
--- MODULE: Journal Fixture Byte Cursor
--- DESCRIPTION:
--- Binds standard FILE seek/read positions to bytes independently captured by a
--- fixture's append sink. The cursor never decides whether a record is framed.
--- ==============================================================================

local M = {}

--- Add cursor operations to an append sink over its actual captured bytes.
--- @param handle table Fixture handle with write already defined.
--- @param bytes function Returns the current byte string owned by the fixture.
--- @return table handle The same native-style fixture handle.
function M.attach(handle, bytes)
	local position = 0
	function handle:seek(origin, offset)
		origin = origin == nil and "cur" or origin
		offset = offset == nil and 0 or offset
		assert(origin == "set" or origin == "cur" or origin == "end", "invalid seek origin")
		offset = assert(math.tointeger(offset), "invalid seek offset")
		local base = origin == "set" and 0 or (origin == "end" and #bytes() or position)
		local target = base + offset
		if target < 0 then return nil, "invalid seek position" end
		position = target
		return position
	end
	function handle:read(count)
		local source = bytes()
		if count == "*a" then
			local result = source:sub(position + 1)
			position = #source
			return result
		end
		if count == nil or count == "*l" then
			if position >= #source then return nil end
			local ending = source:find("\n", position + 1, true)
			local result = source:sub(position + 1, ending and ending - 1 or #source)
			position = ending or #source
			return result
		end
		assert(type(count) == "number" and count >= 0 and count % 1 == 0, "invalid byte read count")
		if position >= #source then return nil end
		local result = source:sub(position + 1, position + count)
		position = position + #result
		return result
	end
	local write = handle.write
	function handle:write(...)
		local result = table.pack(write(self, ...))
		position = #bytes()
		return table.unpack(result, 1, result.n)
	end
	return handle
end

return M

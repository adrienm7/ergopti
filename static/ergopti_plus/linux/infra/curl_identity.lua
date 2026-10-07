--- infra/curl_identity.lua

--- ==============================================================================
--- MODULE: Owned Exact Curl Image Identity (Linux)
--- DESCRIPTION:
--- Reads only fdinfo for explicitly owned regular-file descriptors. Decimal
--- kernel inode text never passes through a Lua number. Every descriptor stays
--- in one acquisition ledger until an explicit native close acknowledgement;
--- a refused/ambiguous close loses destructive authority and is never retried.
--- ==============================================================================

local M = {}
local FORMAT = "linux-fdinfo-v1"
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_UINT64 = "18446744073709551615"
local MAX_FDINFO_BYTES = 4096
local SCALARS = { "device", "size", "mtime_sec", "mtime_nsec", "ctime_sec", "ctime_nsec" }
local ALLOWED = { format = true, inode_decimal = true }
for _, key in ipairs(SCALARS) do ALLOWED[key] = true end

--- Validates exact unsigned decimal text without a numeric conversion.
--- @param value any
--- @return boolean
function M.is_uint64(value)
	if type(value) ~= "string" or #value == 0 or #value > 20 or value:find("[^0-9]") then return false end
	if #value > 1 and value:sub(1, 1) == "0" then return false end
	if #value < #MAX_UINT64 then return true end
	-- Compare ASCII bytes explicitly; no numeric conversion or locale collation.
	for index = 1, #MAX_UINT64 do
		local actual, bound = value:byte(index), MAX_UINT64:byte(index)
		if actual ~= bound then return actual < bound end
	end
	return true
end

local function safe_integer(value)
	return type(value) == "number" and value >= 0 and value <= MAX_SAFE_INTEGER and value % 1 == 0
end

--- Snapshots only the distinct native exact format; legacy guards stay separate.
--- @param value any
--- @return table|nil
function M.copy(value)
	if type(value) ~= "table" or value.format ~= FORMAT or not M.is_uint64(value.inode_decimal) then return nil end
	local output = { format = FORMAT, inode_decimal = value.inode_decimal }
	for key in pairs(value) do if not ALLOWED[key] then return nil end end
	for _, key in ipairs(SCALARS) do
		if not safe_integer(value[key]) then return nil end
		if (key == "mtime_nsec" or key == "ctime_nsec") and value[key] >= 1000000000 then return nil end
		output[key] = value[key]
	end
	return output
end

function M.equal(left, right)
	left, right = M.copy(left), M.copy(right)
	if not left or not right then return false end
	for key, value in pairs(left) do if right[key] ~= value then return false end end
	return true
end

--- Parses one complete bounded kernel fdinfo receipt.
--- @param bytes any
--- @return string|nil
function M.parse_fdinfo(bytes)
	if type(bytes) ~= "string" or #bytes == 0 or #bytes > MAX_FDINFO_BYTES
		or bytes:sub(-1) ~= "\n" or bytes:find("[%z\r]") then return nil end
	local inode, seen
	for line in bytes:gmatch("([^\n]*)\n") do
		if line:sub(1, 4) == "ino:" then
			if seen then return nil end
			seen = true
			inode = line:match("^ino:\t([0-9]+)$")
			if not M.is_uint64(inode) then return nil end
		end
	end
	return inode
end

local function regular_snapshot(stat, inode)
	if type(stat) ~= "table" or stat.type ~= "file" or type(stat.mtime) ~= "table"
		or type(stat.ctime) ~= "table" then return nil end
	return M.copy({ format = FORMAT, inode_decimal = inode, device = stat.dev, size = stat.size,
		mtime_sec = stat.mtime.sec, mtime_nsec = stat.mtime.nsec,
		ctime_sec = stat.ctime.sec, ctime_nsec = stat.ctime.nsec })
end

local function open_flags(native)
	local constants = native.constants
	if type(constants) ~= "table" or constants.O_RDONLY ~= 0 then return nil end
	local nonblock = constants.O_NONBLOCK
	if not safe_integer(nonblock) or nonblock <= 0 or nonblock > 2147483647 then return nil end
	local remaining = nonblock
	while remaining > 1 do
		if remaining % 2 ~= 0 then return nil end
		remaining = remaining / 2
	end
	-- libuv's fs_open adds O_CLOEXEC itself; luv does not export that flag.
	-- O_NONBLOCK avoids waiting on a replacement FIFO before fstat refuses it.
	return constants.O_RDONLY + nonblock
end

--- Creates a physical owner before any native descriptor can be acquired.
--- Synchronous native filesystem calls cannot leave an untracked worker request.
--- @param native table
--- @param report function|nil Fixed diagnostic only.
--- @return table
function M.new(native, report)
	local token = { _records = {}, _listeners = {}, _constructing = false,
		_sealed = false, _settled = false, _cancelled = false, _uncertain = false }
	local flags = type(native) == "table" and open_flags(native) or nil
	local function settle()
		if token._settled or token._constructing or not token._sealed or token._uncertain then return end
		for _, record in ipairs(token._records) do if record.state ~= "closed" then return end end
		token._settled = true
		local listeners = token._listeners
		token._listeners = {}
		for _, listener in ipairs(listeners) do
			local ok = pcall(listener)
			if not ok and type(report) == "function" then report("Exact image settlement observer raised.") end
		end
	end
	function token:is_settled() return self._settled end
	function token:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if self._settled then
			local ok = pcall(listener)
			if not ok and type(report) == "function" then report("Exact image settlement observer raised.") end
		else self._listeners[#self._listeners + 1] = listener end
		return true
	end
	local function close(record)
		if record.state ~= "open" then return end
		-- Reentry sees this destructive operation already in flight. Any error
		-- loses authority; Linux close errors can occur after descriptor removal.
		record.state = "closing"
		local called, accepted, native_error, native_status = pcall(native.fs_close, record.fd)
		if called and (accepted == true or accepted == 0) and native_error == nil and native_status == nil then
			record.state = "closed"
		else
			record.state = "uncertain-close"
			token._uncertain = true
		end
	end
	function token:cancel()
		self._cancelled = true
		if not self._constructing then self._sealed = true end
		for _, record in ipairs(self._records) do close(record) end
		settle()
		return self._settled
	end
	local function acquire(path)
		if token._cancelled then return nil end
		local called, descriptor, native_error, native_status = pcall(native.fs_open, path, flags, 0)
		if not called then
			-- A throw can occur after native allocation but before a typed FD
			-- receipt. Retain uncertainty without inventing destructive authority.
			token._uncertain = true
			return nil
		end
		local record
		if safe_integer(descriptor) and descriptor <= 2147483647 then
			record = { fd = descriptor, state = "open" }
			token._records[#token._records + 1] = record
		end
		if not record or native_error ~= nil or native_status ~= nil then
			if record then
				record.state = "uncertain-acquisition"; token._uncertain = true
			elseif descriptor ~= nil or not ((type(native_error) == "string" and native_error ~= "")
				or (type(native_status) == "string" and native_status ~= "")) then
				-- Only a typed nil/native-error receipt acknowledges no acquisition.
				-- Malformed FD/absence receipts confer no destructive authority.
				token._uncertain = true
			end
			return nil, native_status
		end
		if token._cancelled then close(record); return nil end
		return record
	end
	local function native_value(method, ...)
		if token._cancelled then return nil end
		local called, value, native_error, native_status = pcall(native[method], ...)
		if not called or native_error ~= nil or native_status ~= nil or token._cancelled then return nil end
		return value
	end
	local function snapshot(record)
		if not record or record.state ~= "open" or token._cancelled then return nil end
		local stat = native_value("fs_fstat", record.fd)
		if type(stat) ~= "table" or stat.type ~= "file" then return nil end
		local info = acquire("/proc/self/fdinfo/" .. tostring(record.fd))
		if not info then return nil end
		local bytes = native_value("fs_read", info.fd, MAX_FDINFO_BYTES + 1, 0)
		local eof = type(bytes) == "string" and #bytes <= MAX_FDINFO_BYTES
			and native_value("fs_read", info.fd, 1, #bytes) or nil
		local inode = eof == "" and M.parse_fdinfo(bytes) or nil
		close(info)
		if info.state ~= "closed" or token._cancelled then return nil end
		return regular_snapshot(stat, inode)
	end
	local function observe(image, planned)
		if token._sealed or token._constructing then return nil end
		token._constructing = true
		local identity, executable
		local available = flags ~= nil
		for _, name in ipairs({ "fs_open", "fs_fstat", "fs_read", "fs_close" }) do
			if type(native) ~= "table" or type(native[name]) ~= "function" then available = false end
		end
		if image and type(native.fs_readlink) ~= "function" then available = false end
		if available then
			local live = acquire(image or planned)
			if live then
				if image then
					executable = native_value("fs_readlink", "/proc/self/fd/" .. tostring(live.fd))
					if type(executable) ~= "string" or #executable > 4096 or executable:sub(1, 1) ~= "/"
						or not executable:match("/curl$") or executable:find("[%z\r\n]") then executable = nil end
				else executable = planned end
				local live_identity = executable and snapshot(live) or nil
				if image and live_identity then
					local next_file = acquire(executable)
					local next_identity = next_file and snapshot(next_file) or nil
					if M.equal(live_identity, next_identity) then identity = live_identity end
				else identity = live_identity end
			end
		end
		for _, record in ipairs(token._records) do close(record) end
		token._constructing, token._sealed = false, true
		settle()
		if not token._settled or token._cancelled then return nil end
		return identity, identity and executable or nil
	end
	function token:observe_owned_child(pid)
		if self._sealed or self._constructing then return nil end
		if not safe_integer(pid) or pid <= 0 or pid > 2147483647 then
			self._sealed = true; settle(); return nil
		end
		return observe("/proc/" .. tostring(pid) .. "/exe", nil)
	end
	function token:observe_planned(executable)
		if self._sealed or self._constructing then return nil end
		if type(executable) ~= "string" or #executable > 4096 or executable:sub(1, 1) ~= "/"
			or executable:find("[%z\r\n]") then self._sealed = true; settle(); return nil end
		return observe(nil, executable)
	end
	--- Captures bounded regular-file bytes under this existing descriptor ledger.
	--- Missing conditional files match curl's explicit empty-validator behavior.
	function token:read_regular(path, maximum, missing_allowed)
		if self._sealed or self._constructing or flags == nil or type(path) ~= "string"
			or path == "" or path:find("%z") or not safe_integer(maximum) or maximum < 1 then return nil end
		self._constructing = true
		local bytes
		local live, status = acquire(path)
		if not live and status == "ENOENT" and missing_allowed == true then bytes = ""
		elseif live then
			local before = snapshot(live)
			if before and before.size <= maximum then
				local content = native_value("fs_read", live.fd, maximum + 1, 0)
				local eof = type(content) == "string" and #content <= maximum
					and native_value("fs_read", live.fd, 1, #content) or nil
				local after = snapshot(live)
				if eof == "" and M.equal(before, after) then bytes = content end
			end
		end
		for _, record in ipairs(self._records) do close(record) end
		self._constructing, self._sealed = false, true
		settle()
		return self._settled and not self._cancelled and bytes or nil
	end
	return token
end

return M

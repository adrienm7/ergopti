--- tests/support/exact_identity_ports.lua

--- ==============================================================================
--- MODULE: Exact Identity Ports
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Independent descriptor ports: all scalar metadata and uint64 strings are
--- authored literal facts, never obtained from the producer or rounded doubles.
local M = {}

function M.new(configuration)
	local config = configuration or {}
	local state = { descriptors = {}, opens = {}, closes = {}, calls = {}, next_fd = 100, method_calls = {} }
	local native = { constants = { O_RDONLY = 0, O_NONBLOCK = 2048 } }
	local function call(method, fd)
		state.calls[#state.calls + 1] = { method = method, fd = fd }
		state.method_calls[method] = (state.method_calls[method] or 0) + 1
		if config.hook then config.hook(method, fd, state) end
		local error_case = config.fail_method == method and (config.fail_call == nil or config.fail_call == state.method_calls[method])
		if error_case and config.fail_shape == "throw" then error("independent native refusal") end
		return error_case
	end
	local function status(value, failed)
		if not failed then return value end
		if config.fail_shape == "error" then return value, "independent EIO", nil end
		if config.fail_shape == "status" then return value, nil, "EIO" end
		return nil, "independent EIO", "EIO"
	end
	function native.fs_open(path, flags, mode)
		state.opens[#state.opens + 1] = { path = path, flags = flags, mode = mode }
		local failed = call("fs_open")
		if failed and config.fail_shape ~= "error" and config.fail_shape ~= "status" then return status(nil, true) end
		state.next_fd = state.next_fd + 1
		local tag = path:find("/fdinfo/", 1, true) and "fdinfo" or path:find("/proc/73/exe", 1, true) and "live" or "planned"
		state.descriptors[state.next_fd] = { path = path, tag = tag, open = true }
		return status(state.next_fd, failed)
	end
	function native.fs_fstat(fd)
		local failed = call("fs_fstat", fd)
		local stat = { type = config.nonregular and "fifo" or "file", dev = 11, ino = 123, size = 71,
			mtime = { sec = 123, nsec = 456 }, ctime = { sec = 789, nsec = 12 } }
		if config.unsafe_device then stat.dev = 9007199254740992 end
		if config.invalid_nsec then stat.mtime.nsec = 1000000000 end
		if config.changed_size and state.descriptors[fd].tag == "planned" then stat.size = 72 end
		return status(stat, failed)
	end
	function native.fs_readlink(path)
		local failed = call("fs_readlink", path)
		return status(config.image_path or "/independent/bin/curl", failed)
	end
	function native.fs_read(fd, bound, offset)
		local failed = call("fs_read", fd)
		local descriptor = assert(state.descriptors[fd])
		local observed_fd = tonumber(descriptor.path:match("/fdinfo/(%d+)$"))
		local inode = state.descriptors[observed_fd].tag == "planned" and config.planned_inode
			or config.live_inode or "9223372036855093009"
		local bytes = config.fdinfo or "pos:\t0\nflags:\t0104000\nmnt_id:\t91\nino:\t" .. inode .. "\n"
		if offset ~= 0 then bytes = config.no_eof and "x" or "" end
		return status(bytes, failed)
	end
	function native.fs_close(fd)
		state.closes[#state.closes + 1] = fd
		-- A native EIO can be reported after actual descriptor removal. This
		-- fixture deliberately models that ambiguity; a second close is unsafe.
		state.descriptors[fd].open = false
		local failed = call("fs_close", fd)
		return status(true, failed)
	end
	if config.missing_constants then native.constants = nil end
	if config.missing_port then native[config.missing_port] = nil end
	return native, state
end

function M.identity(inode)
	return { format = "linux-fdinfo-v1", inode_decimal = inode or "9223372036855093009",
		device = 11, size = 71, mtime_sec = 123, mtime_nsec = 456, ctime_sec = 789, ctime_nsec = 12 }
end

return M

--- tests/hardware/run_http_output_target_native.lua
--- ==============================================================================
--- MODULE: Native Retained HTTP Output Receipts
--- DESCRIPTION:
--- Checks actual loopback curl, anonymous parent output and physical retirement.
--- This native profile requires Linux LuaJIT/FFI and does not qualify proxy policy.
--- ==============================================================================

--- controls/native_http_output_target.lua
--- Actual loopback curl, parent-only file writes, original native ownership ACKs.
--- No proxy/TLS/updater/digest/installer qualification follows from loopback.
local uv, ffi = require("luv"), require("ffi")
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local Core = require("adapters.curl_http_client")
local Clock = require("infra.monotonic")
ffi.cdef("int fcntl(int fd, int command, ...);")
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-http-output-XXXXXX"))
local expected = "owned-http\0" .. string.rep("archive-parent-bytes", 8192)
local handles, lease, operation, fd = {}, nil, nil, nil
local passed, failed, checks = 0, 0, 0
local results, terminal = {}, {}
local writes, outstanding, peak = 0, 0, 0
local native_write = uv.fs_write
local function expect(ok, name)
	checks = checks + 1
	if ok then passed = passed + 1; print("PASS " .. name)
	else failed = failed + 1; io.stderr:write("FAIL " .. name .. "\n") end
end
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	return false
end
local function close_owned(handle)
	local receipt = handles[handle]
	if not receipt or receipt.state == "closed" or receipt.state == "closing" then return end
	assert(receipt.state == "open" and not uv.is_closing(handle), "foreign native server close")
	local attempt = {admitted = false, seen = false}
	receipt.state, receipt.attempt = "closing", attempt
	local called, ack, err = pcall(uv.close, handle, function()
		if receipt.attempt ~= attempt then return end
		attempt.seen = true
		if attempt.admitted then receipt.state = "closed" end
	end)
	assert(called and ack ~= false and err == nil, "actual server close refused")
	assert(attempt.seen or uv.is_closing(handle), "server close schedule unavailable")
	attempt.admitted = true
	if attempt.seen then receipt.state = "closed" end
end
local function anonymous_outputs()
	local scan = assert(uv.fs_scandir("/proc/self/fd"))
	local result = {}
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then break end
		local candidate = tonumber(name)
		local stat = candidate and uv.fs_fstat(candidate)
		local alias = candidate and uv.fs_readlink("/proc/self/fd/" .. name)
		-- scandir's transient directory descriptor is not an output inode.
		-- Match independent current native regular/anonymous/private-dir facts,
		-- never a numeric before/after set difference or destructive authority.
		if stat and stat.type == "file" and alias and alias:find(directory .. "/#", 1, true) == 1
			and alias:sub(-10) == " (deleted)" then
			local info = assert(io.open("/proc/self/fdinfo/" .. name, "rb"))
			local bytes = info:read("*a")
			info:close()
			local inode = assert(bytes:match("\nino:%s*(%d+)"), "exact native inode receipt missing")
			assert(inode ~= "0" and #inode <= 20)
			result[#result + 1] = { fd = candidate, alias = alias, inode = inode,
				close_on_exec = ffi.C.fcntl(candidate, 1) == 1 }
		end
	end
	return result
end

local ok, err = xpcall(function()
	assert(#anonymous_outputs() == 0)
	local owner = {}
	lease = assert(Output.native().reserve(directory, owner, function(exact) return exact == owner end,
		Clock.now_ms() + 4000), "actual anonymous writer unavailable")
	local observed = anonymous_outputs()
	expect(#observed == 1, "actual HTTP output has exactly one retained anonymous regular inode")
	assert(#observed == 1); fd = observed[1].fd
	expect(observed[1].close_on_exec, "retained writable output is CLOEXEC before curl dispatch")
	local ticket = assert(lease:begin())
	local target = assert(Target.create(lease, ticket))
	local server = assert(uv.new_tcp()); handles[server] = {state = "open"}
	assert(uv.tcp_bind(server, "127.0.0.1", 0))
	local address = assert(uv.tcp_getsockname(server))
	local server_error
	assert(uv.listen(server, 8, function(accept_error)
		if accept_error then server_error = accept_error; return end
		local client = assert(uv.new_tcp()); handles[client] = {state = "open"}
		assert(uv.accept(server, client))
		local request, responded = "", false
		assert(uv.read_start(client, function(read_error, chunk)
			if read_error then server_error = read_error; close_owned(client); return end
			if not chunk then close_owned(client); return end
			request = request .. chunk
			if #request > 4096 then server_error = "oversized fixture request"; close_owned(client); return end
			if not responded and request:find("\r\n\r\n", 1, true) then
				responded = true
				assert(request:find("GET /archive HTTP/", 1, true) == 1, "unexpected native request")
				assert(uv.read_stop(client))
				local header = "HTTP/1.1 200 OK\r\nContent-Length: " .. #expected
					.. "\r\nConnection: close\r\nContent-Type: application/octet-stream\r\n\r\n"
				assert(uv.write(client, header .. expected, function(write_error)
					if write_error then server_error = write_error end
					close_owned(client)
				end))
			end
		end))
	end))
	uv.fs_write = function(descriptor, chunk, offset, callback)
		assert(descriptor == fd, "writer borrowed a foreign descriptor")
		writes, outstanding = writes + 1, outstanding + 1
		peak = math.max(peak, outstanding)
		return native_write(descriptor, chunk, offset, function(write_error, count)
			outstanding = outstanding - 1
			callback(write_error, count)
		end)
	end
	operation = Core.dispatch_owned("http://127.0.0.1:" .. address.port .. "/archive", {}, nil,
		{method = "GET", buffered = false, owner = "native-parent-output", timeout_ms = 3000,
			max_download_bytes = #expected, output_target = target, authorized = function() return true end,
			on_native_terminal = function(result)
				terminal[#terminal + 1] = result
				assert(outstanding == 0, "native logical terminal preceded filesystem ACK")
			end}, nil, function(result)
			results[#results + 1] = result
			assert(outstanding == 0, "native success preceded filesystem ACK")
			close_owned(server)
		end)
	expect(operation.started == true, "actual owned curl pipeline dispatches without pathname output")
	expect(await(function() return #results > 0 and operation:is_settled() end),
		"actual curl group and all native handles acknowledge physical settlement")
	assert(not server_error, tostring(server_error))
	expect(#results == 1 and results[1].ok == true and results[1].status == 200,
		"actual local HTTP status publishes one successful bounded result")
	expect(#terminal == 1 and terminal[1].ok == true,
		"one truthful native terminal waits filesystem acknowledgements")
	expect(writes > 1 and peak == 1 and outstanding == 0,
		"multiple real parent filesystem writes enforce one outstanding bounded chunk")
	expect(lease:attempt_settled(ticket) and lease:bytes(ticket) == #expected,
		"actual EOF and owned child retirement retain every body byte")
	local observation = assert(io.open("/proc/self/fd/" .. fd, "rb"))
	local bytes = observation:read("*a"); observation:close()
	expect(bytes == expected, "actual retained file equals independent NUL-bearing HTTP corpus")
	expect(lease:begin(ticket) == nil, "delivered actual bytes refuse relay truncation")
	lease:cancel()
	expect(await(function() return lease:is_settled() end),
		"actual output and original deadline close acknowledgements retire parent lease")
	expect(uv.fs_fstat(fd) == nil, "actual owned output descriptor was physically removed")
end, debug.traceback)
if not ok then failed = failed + 1; io.stderr:write(tostring(err) .. "\n") end
if lease then lease:cancel() end
if operation and not operation:is_settled() then operation:request_cancel() end
for handle in pairs(handles) do
	local closed, close_error = pcall(close_owned, handle)
	if not closed then failed = failed + 1; io.stderr:write("Server cleanup debt: " .. tostring(close_error) .. "\n") end
end
expect(await(function() return not uv.loop_alive() end), "actual loopback/core/writer resources drain their loop")
uv.fs_write = native_write
expect(outstanding == 0, "cleanup has no unacknowledged native filesystem write")
expect(not operation or operation:is_settled(), "cleanup retains no owned curl/group/handle debt")
expect(not lease or lease:is_settled(), "cleanup acknowledges exact parent output/deadline retirement")
expect(not fd or uv.fs_fstat(fd) == nil, "cleanup independently observes exact descriptor removal")
local removed, _, code = uv.fs_rmdir(directory)
expect(removed == true, "native anonymous output leaves no directory debt: " .. tostring(code))
print(string.format("native HTTP parent output: %d passed, %d failures, %d checks", passed, failed, checks))
os.exit(failed == 0 and 0 or 1)

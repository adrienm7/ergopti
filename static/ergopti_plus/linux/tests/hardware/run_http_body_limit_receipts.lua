--- tests/hardware/run_http_body_limit_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Buffered HTTP Body Limit Receipts
--- DESCRIPTION:
--- Exercises exact body bounds through production curl and a real loopback
--- listener. Content-Length and chunked responses, successful and refused HTTP
--- receipts, and buffered GET/POST share the same byte boundary. No native
--- process, socket or filesystem API is mocked.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native body limit checks require an ordinary user")
local owner = "native-buffered-body-limit"
local checks, failures, requests = 0, 0, 0
local sockets, server_handles = {}, {}

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat uv.run("nowait"); if predicate() then return end; uv.sleep(1) until uv.hrtime() >= deadline
	error("owned native body limit request did not settle")
end

local function retired()
	local retained = false
	uv.walk(function(handle)
		if not server_handles[handle] and not uv.is_closing(handle) then retained = true end
	end)
	return not retained
end

local server = uv.new_tcp()
server_handles[server] = true
assert(server:bind("127.0.0.1", 0))
assert(server:listen(16, function(err)
	assert(not err, tostring(err))
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	server_handles[socket] = true
	assert(server:accept(socket))
	local bytes, answered = "", false
	assert(uv.read_start(socket, function(failure, chunk)
		assert(not failure, tostring(failure))
		if not chunk then close(socket); return end
		bytes = bytes .. chunk
		if not answered and bytes:find("\r\n\r\n", 1, true) then
			answered, requests = true, requests + 1
			uv.read_stop(socket)
			local status, size, framing = bytes:match("^%u+ /(%d+)/(%d+)/(%a+) ")
			assert(status and size and framing, "fixture received an unexpected actual request")
			local body = string.rep("x", tonumber(size))
			local response = "HTTP/1.1 " .. status .. " Receipt\r\nConnection: close\r\n"
			if framing == "chunked" then
				response = response .. "Transfer-Encoding: chunked\r\n\r\n"
				for index = 1, #body do response = response .. "1\r\n" .. body:sub(index, index) .. "\r\n" end
				response = response .. "0\r\n\r\n"
			else response = response .. "Content-Length: " .. #body .. "\r\n\r\n" .. body end
			assert(uv.write(socket, response, function() close(socket) end))
		end
	end))
end))
local url = "http://127.0.0.1:" .. server:getsockname().port

for _, method in ipairs({ "get", "post", "get_owned" }) do
	for _, status in ipairs({ 200, 401 }) do
		for _, size in ipairs({ 0, 3, 4, 5, 13, 64, 2 * 1024 * 1024, 2 * 1024 * 1024 + 1 }) do
			local limit = size >= 2 * 1024 * 1024 and 2 * 1024 * 1024 or 4
			local framings = limit == 4 and { "length", "chunked" } or { "length" }
			for _, framing in ipairs(framings) do
				checks = checks + 1
				local name = string.format("%s HTTP %d %s body=%d limit=%d", method, status, framing, size, limit)
				local ok, err = xpcall(function()
					local result, callbacks, before = nil, 0, requests
					local function complete(value) result, callbacks = value, callbacks + 1 end
					local options = { owner = owner, max_body_bytes = limit, timeout_ms = 1000 }
					local target = url .. "/" .. status .. "/" .. size .. "/" .. framing
					if method == "get_owned" then
						local operation = HTTP.get_owned(target, {}, options, complete)
						assert(operation.started)
					elseif method == "get" then assert(HTTP.get(target, {}, options, complete))
					else assert(HTTP.post(target, {}, "{}", complete, options)) end
					wait_for(function() return result ~= nil end)
					assert(callbacks == 1 and requests == before + 1 and not HTTP.isActive(owner))
					if size > limit then
						assert(result.ok == false and result.status == 0 and result.body == ""
							and result.error_body == nil and result.error == "response body exceeds limit",
							"oversized actual response was published inside the curl receipt allowance")
					else
						assert(result.status == status and result.ok == (status == 200))
						assert((status == 200 and result.body or result.error_body) == string.rep("x", size))
					end
				end, debug.traceback)
				HTTP.cancel(owner)
				wait_for(retired)
				if ok then print("PASS " .. name) else
					failures = failures + 1
					io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
				end
			end
		end
	end
end

close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "native body limit fixture retained native handles")
print(string.format("Native HTTP body limit receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

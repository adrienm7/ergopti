--- tests/hardware/run_http_literal_url_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Literal HTTP URL Receipts
--- DESCRIPTION:
--- Sends caller URLs through every production curl request path to an actual
--- loopback listener. Brackets and braces are URL bytes, never curl ranges or
--- lists that reject a valid query or send extra requests to different targets.
--- IPv6 and percent-encoded URLs retain native parsing and exact ownership.
--- No native process, socket or filesystem API is mocked.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "literal URL checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-url-XXXXXX"))
local destination = root .. "/download"
local checks, failures = 0, 0
local sockets, servers, server_handles, requests = {}, {}, {}, {}
local owner = "native-literal-url"
local payload = "Synthetic literal URL POST body"

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat uv.run("nowait"); if predicate() then return end; uv.sleep(1) until uv.hrtime() >= deadline
	error("owned native literal URL request did not settle")
end

local function retired()
	local retained = false
	uv.walk(function(handle)
		if not server_handles[handle] and not uv.is_closing(handle) then retained = true end
	end)
	return not retained
end

local function listen(host)
	local server = uv.new_tcp()
	servers[#servers + 1], server_handles[server] = server, true
	assert(server:bind(host, 0))
	assert(server:listen(16, function(err)
		assert(not err, tostring(err))
		local socket = uv.new_tcp()
		sockets[#sockets + 1], server_handles[socket] = socket, true
		assert(server:accept(socket))
		local bytes, answered = "", false
		assert(uv.read_start(socket, function(failure, chunk)
			assert(not failure, tostring(failure))
			if not chunk then close(socket); return end
			bytes = bytes .. chunk
			local ending = bytes:find("\r\n\r\n", 1, true)
			local length = ending and tonumber(bytes:sub(1, ending):lower():match("content%-length:%s*(%d+)")) or 0
			if not answered and ending and #bytes >= ending + 3 + length then
				answered = true
				local method, target = bytes:match("^(%u+) ([^ ]+) ")
				assert(method and target, "fixture received an invalid native request line")
				requests[#requests + 1] = { method = method, target = target,
					body = bytes:sub(ending + 4, ending + 3 + length) }
				uv.read_stop(socket)
				assert(uv.write(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc",
					function() close(socket) end))
			end
		end))
	end))
	return "http://" .. (host == "::1" and "[::1]" or host) .. ":" .. server:getsockname().port
end

local ipv4, ipv6 = listen("127.0.0.1"), listen("::1")
local cases = {
	{ target = "/literal?ordinary=value" },
	{ target = "/literal?filter[name]=value" },
	{ target = "/literal?filter[]=value" },
	{ target = "/literal?range=[a-c]" },
	{ target = "/literal?set={one,two}" },
	{ target = "/literal?range=[1-2]&set={one,two}" },
	{ target = "/literal?single={owned}" },
	{ target = "/literal?q=[text" },
	{ target = "/literal?q=%5Ba-c%5D%7Bone,two%7D" },
	{ target = "/literal/[1-2]/{one,two}" },
	{ target = "/literal?ipv6=value", origin = ipv6 },
}

for _, method in ipairs({ "get", "get_owned", "post", "postStream", "download" }) do
	for _, case in ipairs(cases) do
		checks = checks + 1
		local name = method .. " sends one literal target " .. case.target
		local ok, err = xpcall(function()
			local result, callbacks, before, chunks, operation = nil, 0, #requests, {}, nil
			local function complete(value) result, callbacks = value, callbacks + 1 end
			local options = { owner = owner, timeout_ms = 1000 }
			local url = (case.origin or ipv4) .. case.target
			if method == "get" then assert(HTTP.get(url, {}, options, complete))
			elseif method == "get_owned" then operation = HTTP.get_owned(url, {}, options, complete); assert(operation.started)
			elseif method == "post" then assert(HTTP.post(url, {}, payload, complete, options))
			elseif method == "download" then assert(HTTP.download(url, {}, destination, options, complete))
			else assert(HTTP.postStream(url, {}, payload, options, function(bytes) chunks[#chunks + 1] = bytes end, complete)) end
			wait_for(function() return result ~= nil end)
			assert(result.ok and result.status == 200 and callbacks == 1, "curl rejected literal URL syntax")
			assert(#requests == before + 1, "one caller URL expanded into multiple native wire requests")
			local received = requests[before + 1]
			local post = method == "post" or method == "postStream"
			assert(received.target == case.target and received.method == (post and "POST" or "GET")
				and received.body == (post and payload or ""), "curl changed the caller target or body")
			if method == "download" then
				local file = assert(io.open(destination, "rb"))
				assert(file:read("*a") == "abc" and file:close())
			elseif method == "postStream" then assert(table.concat(chunks) == "abc")
			else assert(result.body == "abc", "multiple URL receipts contaminated the response body") end
			assert(not HTTP.isActive(owner))
			if operation then assert(operation:is_settled(), "owned GET published before physical cleanup settled") end
		end, debug.traceback)
		HTTP.cancel(owner)
		wait_for(retired)
		if ok then print("PASS " .. name) else
			failures = failures + 1
			io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
		end
	end
end

for _, server in ipairs(servers) do close(server) end
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "literal URL fixture retained native resource ownership")
assert(uv.fs_unlink(destination))
assert(uv.fs_rmdir(root))
print(string.format("Native literal HTTP URL receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

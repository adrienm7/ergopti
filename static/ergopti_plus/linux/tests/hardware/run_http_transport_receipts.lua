--- tests/hardware/run_http_transport_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux HTTP Protocol Boundary Receipts
--- DESCRIPTION:
--- Refuses non-HTTP protocols before retiring held actual curl responses. Local
--- file URLs must never emit file bytes to stream callbacks or overwrite a
--- download target. Real loopback HTTP controls retain all four public methods.
--- No process/socket API is mocked.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native protocol checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-transport-XXXXXX"))
local path = root .. "/etag"
local destination = root .. "/download"
local owner = "native-http-transport"
local checks, failures = 0, 0
local sockets, held, server_handles = {}, {}, {}
local last_headers, requests = "", 0

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat uv.run("nowait"); if predicate() then return end; uv.sleep(1) until uv.hrtime() >= deadline
	error("owned native protocol request did not settle")
end

local function write(target, bytes)
	local file = assert(io.open(target, "wb"))
	assert(file:write(bytes) and file:close())
end

local function read(target)
	local file = assert(io.open(target, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function native_clients_retired()
	local retained = false
	uv.walk(function(handle)
		if not server_handles[handle] and not uv.is_closing(handle) then retained = true end
	end)
	return not retained
end

local response = "HTTP/1.1 200 OK\r\nETag: \"native-saved\"\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
local function respond(socket)
	if uv.is_closing(socket) then return end
	-- Cleanup may observe a client intentionally retired by a replacement.
	local ok, accepted = pcall(uv.write, socket, response, function() close(socket) end)
	if not ok or not accepted then close(socket) end
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
			answered = true
			last_headers, requests = bytes, requests + 1
			uv.read_stop(socket)
			if bytes:match("^GET /held ") then held[#held + 1] = socket else respond(socket) end
		end
	end))
end))
local url = "http://127.0.0.1:" .. server:getsockname().port

local function check(name, test)
	checks = checks + 1
	local before = #held
	local ok, err = xpcall(test, debug.traceback)
	for index = before + 1, #held do respond(held[index]) end
	HTTP.cancel(owner)
	wait_for(native_clients_retired)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local invalid = {}
for _, method in ipairs({ "get", "post", "postStream", "download" }) do
	for _, target in ipairs({ "file://" .. path, "FILE://" .. path, "file:" .. path,
		"ftp://127.0.0.1:9/native", "ftps://127.0.0.1:9/native", "gopher://127.0.0.1:9/native",
		"data:text/plain,synthetic", "telnet://127.0.0.1:9/native" }) do
		invalid[#invalid + 1] = { name = method .. " " .. target:match("^([^:]+)"), method = method, url = target }
	end
end

local function dispatch(method, target, options, complete, chunk)
	if method == "get" then return HTTP.get(target, {}, options, complete) end
	if method == "post" then return HTTP.post(target, {}, "{}", complete, options) end
	if method == "download" then return HTTP.download(target, {}, destination, options, complete) end
	return HTTP.postStream(target, {}, "{}", options, chunk or function() end, complete)
end

for _, case in ipairs(invalid) do
	check(case.name .. " retains the actual valid response owner", function()
		write(path, "\"native-retained\"\n")
		write(destination, "Retained download bytes")
		local good, bad, callbacks, before_held, before_requests = nil, nil, 0, #held, requests
		assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) good = value end))
		wait_for(function() return #held == before_held + 1 end)
		assert(HTTP.isActive(owner), "fixture did not hold an actual curl request")
		local options = { owner = owner, timeout_ms = 100 }
		for key, value in pairs(case.options or {}) do options[key] = value end
		local function complete(value) bad = value; callbacks = callbacks + 1 end
		local chunks = {}
		local protected, dispatched = pcall(dispatch, case.method, case.url, options, complete,
			function(bytes) chunks[#chunks + 1] = bytes end)
		assert(#chunks == 0, "non-HTTP source emitted native file/protocol bytes")
		assert(protected and dispatched == false, "invalid curl metadata escaped as an exception or dispatch")
		assert(bad and bad.ok == false and bad.status == 0 and callbacks == 1)
		assert(type(bad.error) == "string" and not bad.error:find("private-suffix", 1, true)
			and not bad.error:find("Synthetic private header value", 1, true))
		assert(HTTP.isActive(owner), "invalid replacement cancelled the actual in-flight curl owner")
		respond(held[#held])
		wait_for(function() return good ~= nil end)
		assert(good.ok and good.status == 200 and good.body == "abc")
		assert(requests == before_requests + 1, "invalid replacement contacted an extra native endpoint")
		assert(read(path) == "\"native-retained\"\n" and read(destination) == "Retained download bytes")
	end)
end

for _, method in ipairs({ "get", "post", "postStream", "download" }) do
	for _, scheme in ipairs({ "http", "HTTP" }) do
		check(method .. " retains actual " .. scheme .. " requests", function()
			local result, chunks = nil, {}
			local target = url:gsub("^http", scheme) .. "/direct"
			assert(dispatch(method, target, { owner = owner, timeout_ms = 1000 }, function(v) result = v end,
				function(bytes) chunks[#chunks + 1] = bytes end))
			wait_for(function() return result ~= nil end)
			assert(result.ok and result.status == 200)
			if method == "download" then assert(read(destination) == "abc")
			elseif method == "postStream" then assert(table.concat(chunks) == "abc")
			else assert(result.body == "abc") end
		end)
	end
end

close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "native protocol fixture retained resource ownership")
assert(uv.fs_unlink(path))
assert(uv.fs_unlink(destination))
assert(uv.fs_rmdir(root))
print(string.format("Native HTTP protocol boundary receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

--- tests/hardware/run_http_url_nul_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Curl URL Byte Receipts
--- DESCRIPTION:
--- Drives actual curl through production buffered, streaming and download APIs.
--- A raw URL NUL is silently truncated by curl's stdin config parser, allowing
--- a successful request to a different address. Invalid URLs must be refused
--- before native side effects or superseding a valid request owner. Loopback
--- socket, file and literal percent-escape controls use no simulated native API.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native URL checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-url-nul-XXXXXX"))
local checks, failures, requests, last_path = 0, 0, 0, nil
local sockets = {}

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait")
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("owned native URL request did not settle")
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes) and file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local server = uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
assert(server:listen(16, function(err)
	assert(not err, tostring(err))
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	assert(server:accept(socket))
	local bytes, answered = "", false
	assert(uv.read_start(socket, function(failure, chunk)
		assert(not failure, tostring(failure))
		if not chunk then close(socket); return end
		bytes = bytes .. chunk
		local header_end = bytes:find("\r\n\r\n", 1, true)
		local length = header_end and tonumber(bytes:sub(1, header_end):lower():match("content%-length:%s*(%d+)")) or 0
		if not answered and header_end and #bytes >= header_end + 3 + (length or 0) then
			answered = true
			requests = requests + 1
			last_path = assert(bytes:match("^%u+ ([^ ]+) HTTP/"))
			uv.read_stop(socket)
			assert(uv.write(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc", function(write_error)
				assert(not write_error, tostring(write_error))
				close(socket)
			end))
		end
	end))
end))
local url = "http://127.0.0.1:" .. server:getsockname().port .. "/native"
local owner = "native-http-url-nul"
local destination = root .. "/retained-download"

for _, method in ipairs({ "get", "post", "download", "postStream" }) do
	check("actual " .. method .. " refuses NUL instead of requesting the shorter URL", function()
		write(destination, "Retained native bytes")
		local result, callbacks, chunks, before = nil, 0, 0, requests
		local options = { timeout_ms = 1000, owner = owner }
		local function complete(value) result = value; callbacks = callbacks + 1 end
		local target = url .. "\0private-suffix"
		local dispatched
		if method == "get" then dispatched = HTTP.get(target, {}, options, complete)
		elseif method == "post" then dispatched = HTTP.post(target, {}, "{}", complete, options)
		elseif method == "download" then dispatched = HTTP.download(target, {}, destination, options, complete)
		else dispatched = HTTP.postStream(target, {}, "{}", options, function() chunks = chunks + 1 end, complete) end
		wait_for(function() return callbacks == 1 end)
		assert(dispatched == false and result.ok == false and result.status == 0,
			"a NUL-bearing URL reached and acknowledged its shorter actual HTTP endpoint")
		assert(type(result.error) == "string" and not result.error:find("private-suffix", 1, true))
		assert(requests == before and chunks == 0 and not HTTP.isActive(owner))
		assert(read(destination) == "Retained native bytes", "invalid URL changed a caller-owned download")
	end)
end

check("invalid native URL does not supersede a valid in-flight owner", function()
	local good, bad, before = nil, nil, requests
	local options = { timeout_ms = 1000, owner = owner }
	assert(HTTP.get(url, {}, options, function(value) good = value end))
	assert(HTTP.isActive(owner))
	local dispatched = HTTP.get(url .. "\0ignored", {}, options, function(value) bad = value end)
	if dispatched then wait_for(function() return bad ~= nil end) end
	assert(dispatched == false and bad and bad.ok == false)
	assert(HTTP.isActive(owner), "invalid metadata retired the valid native process owner")
	wait_for(function() return good ~= nil end)
	assert(good.ok and good.status == 200 and good.body == "abc")
	assert(requests == before + 1 and not HTTP.isActive(owner))
end)

check("literal URL percent escape remains an actual distinct endpoint", function()
	local result, before = nil, requests
	assert(HTTP.get(url .. "%00literal", {}, { timeout_ms = 1000, owner = owner }, function(value) result = value end))
	wait_for(function() return result ~= nil end)
	assert(result.ok and result.status == 200 and requests == before + 1)
	assert(last_path == "/native%00literal", "representable URI text was rejected or decoded before dispatch")
end)

check("header and body preflight refuse unrepresentable config bytes", function()
	for _, field in ipairs({ "header", "body" }) do
		local result, before, callbacks = nil, requests, 0
		local function complete(value)
			callbacks = callbacks + 1
			result = value
		end
		local options = { timeout_ms = 1000, owner = owner }
		if field == "header" then
			assert(HTTP.get(url, { ["X-Native"] = "prefix\0suffix" }, options, complete) == false)
			assert(result and not HTTP.isActive(owner), "header refusal must precede native allocation")
		else
			assert(HTTP.post(url, {}, "a\0retained bytes", complete, options) == false,
				"body refusal must precede native dispatch")
			assert(result and not HTTP.isActive(owner), "body refusal must acknowledge before native allocation")
		end
		wait_for(function() return result ~= nil end)
		assert(callbacks == 1, "invalid config must acknowledge exactly once")
		assert(result.ok == false and result.status == 0 and type(result.error) == "string")
		assert(requests == before and not HTTP.isActive(owner), "failed config unexpectedly reached the native endpoint")
	end
end)

HTTP.cancel(owner)
close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "native URL checks retained process or socket ownership")
assert(uv.fs_unlink(destination))
assert(uv.fs_rmdir(root))
print(string.format("Native HTTP URL byte receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

--- tests/fixtures/native_network_check_refusal.lua

--- ==============================================================================
--- MODULE: Actual Network Check Terminal Callback Regression
--- DESCRIPTION:
--- Runs the field-check ports over the real managed HTTP adapter. Unsupported
--- PAC URLs complete synchronously, a real loopback curl response completes
--- asynchronously, and terminal HTTP shutdown deliberately suppresses delivery.
--- Dispatch acceptance must never become a second completion receipt.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_network_check_refusal%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Http = require("adapters.http_client")
local Proxy = require("adapters.system_proxy")
local Ports = require("adapters.network_check_ports")
local callbacks, failures, checks = 0, 0, 0
local sockets, requests = {}, 0
local server = assert(uv.new_tcp())

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function await(predicate)
	local deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait")
		if predicate() then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("actual field-check operation did not retire")
end

local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("actual unsupported PAC refusal completes once", function()
	local status, body
	callbacks = 0
	Ports.new().fetch_pac("file:///var/tmp/owned-proxy.pac", function(code, bytes)
		callbacks, status, body = callbacks + 1, code, bytes
	end)
	assert(callbacks == 1, "actual PAC refusal delivered " .. callbacks .. " callbacks")
	assert(status == 0 and body == "", "actual transport refusal was replaced")
	assert(not Http.isActive(Ports.OWNER))
end)

check("actual synchronous request refusal finishes the chain once", function()
	local code, steps
	callbacks = 0
	Ports.new({
		feed_url = function() return "https://feed.invalid/\0refused" end,
		lookup = Proxy.lookup_owned,
		http_get = Http.get,
	}).chain(function(value, result) callbacks, code, steps = callbacks + 1, value, result end)
	assert(callbacks == 1, "actual request refusal delivered " .. callbacks .. " callbacks")
	assert(code == 0 and steps.route_lookup.value == "proxy-request-invalid")
	assert(steps.transfer.state == "fail" and steps.transfer.value == "failed")
	assert(not Http.isActive(Ports.OWNER) and not Proxy.is_owned(Ports.OWNER .. ".route"))
end)

assert(server:bind("127.0.0.1", 0))
assert(server:listen(4, function(err)
	assert(not err)
	local socket = assert(uv.new_tcp())
	sockets[#sockets + 1] = socket
	assert(server:accept(socket))
	local bytes = ""
	assert(uv.read_start(socket, function(failure, chunk)
		assert(not failure)
		if not chunk then close(socket); return end
		bytes = bytes .. chunk
		if bytes:find("\r\n\r\n", 1, true) then
			requests = requests + 1
			assert(uv.read_stop(socket))
			assert(uv.write(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc", function(write_error)
				assert(not write_error)
				close(socket)
			end))
		end
	end))
end))

check("actual asynchronous PAC response retains its one terminal receipt", function()
	local status, body
	callbacks = 0
	Ports.new().fetch_pac("http://127.0.0.1:" .. server:getsockname().port .. "/proxy.pac", function(code, bytes)
		callbacks, status, body = callbacks + 1, code, bytes
	end)
	assert(callbacks == 0, "actual native request completed before the event loop")
	await(function() return callbacks >= 1 and not Http.isActive(Ports.OWNER) end)
	assert(callbacks == 1 and status == 200 and body == "abc" and requests == 1)
end)

Http.cancel(Ports.OWNER)
for _, socket in ipairs(sockets) do close(socket) end
close(server)
await(function() return not uv.loop_alive() end)
local retained_handles = 0
uv.walk(function() retained_handles = retained_handles + 1 end)
assert(retained_handles == 0, "actual field-check fixture retained native handles")

check("actual terminal HTTP shutdown suppresses field-check publication", function()
	assert(Http.shutdown())
	callbacks = 0
	Ports.new().fetch_pac("file:///var/tmp/owned-proxy.pac", function() callbacks = callbacks + 1 end)
	Ports.new({
		feed_url = function() return "https://feed.invalid/\0refused" end,
		lookup = Proxy.lookup_owned,
		http_get = Http.get,
	}).chain(function() callbacks = callbacks + 1 end)
	assert(callbacks == 0, "dispatch refusal published after terminal HTTP shutdown")
	assert(not uv.loop_alive())
end)

print(string.format("Native network check callbacks: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

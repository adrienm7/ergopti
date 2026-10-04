--- tests/hardware/run_http_redirect_receipts.lua

--- ==============================================================================
--- MODULE: Native Linux HTTP Redirect Confidentiality Receipts
--- DESCRIPTION:
--- Two actual loopback origins observe production curl GET, POST, streaming
--- and download requests. Synthetic credentials must reach only their caller's
--- origin; public redirects and direct credentialed responses remain usable.
--- No curl, socket, process or filesystem API is simulated.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native redirect checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-redirect-XXXXXX"))
local destination = root .. "/download"
local handles, initial, redirected = {}, {}, {}
local checks, failures = 0, 0
local owner = "native-http-redirect-receipt"
local credential = "SyntheticNativeRedirectCredential"

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function server(response)
	local listener = uv.new_tcp()
	handles[#handles + 1] = listener
	assert(listener:bind("127.0.0.1", 0))
	assert(listener:listen(16, function(err)
		assert(not err, tostring(err))
		local socket = uv.new_tcp()
		handles[#handles + 1] = socket
		assert(listener:accept(socket))
		local bytes, answered = "", false
		assert(uv.read_start(socket, function(failure, chunk)
			assert(not failure, tostring(failure))
			if not chunk then close(socket); return end
			bytes = bytes .. chunk
			local end_header = bytes:find("\r\n\r\n", 1, true)
			local length = end_header and tonumber(bytes:sub(1, end_header):lower():match("content%-length:%s*(%d+)")) or 0
			if not answered and end_header and #bytes >= end_header + 3 + (length or 0) then
				answered = true
				uv.read_stop(socket)
				assert(uv.write(socket, response(bytes), function(write_error)
					assert(not write_error, tostring(write_error))
					close(socket)
				end))
			end
		end))
	end))
	return "http://127.0.0.1:" .. listener:getsockname().port
end

local success = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
local target = server(function(bytes)
	redirected[#redirected + 1] = bytes:lower()
	return success
end)
local origin = server(function(bytes)
	initial[#initial + 1] = bytes:lower()
	if bytes:match("^%u+ /direct ") then return success end
	return "HTTP/1.1 302 Found\r\nLocation: " .. target .. "/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
end)

local function request(method, headers, path, follows)
	local result, callbacks, body = nil, 0, ""
	local options = { owner = owner, timeout_ms = 1000, follow_redirects = follows }
	local function complete(value) result = value; callbacks = callbacks + 1 end
	local dispatched
	if method == "get" then dispatched = HTTP.get(origin .. path, headers, options, complete)
	elseif method == "post" then dispatched = HTTP.post(origin .. path, headers, "{}", complete, options)
	elseif method == "download" then dispatched = HTTP.download(origin .. path, headers, destination, options, complete)
	else dispatched = HTTP.postStream(origin .. path, headers, "{}", options,
		function(chunk) body = body .. chunk end, complete) end
	assert(dispatched, "original native request was refused")
	local deadline = uv.hrtime() + 3000000000
	repeat uv.run("nowait"); uv.sleep(1) until result or uv.hrtime() >= deadline
	assert(result and callbacks == 1 and not HTTP.isActive(owner), "native redirect request did not settle once")
	assert(options.follow_redirects == follows, "adapter changed caller-owned options")
	return result, body
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local sensitive = { "Api-Key", "Authorization", "Cookie", "Cookie2", "Proxy-Authorization", "X-Api-Key", "X-Goog-Api-Key" }
for _, name in ipairs(sensitive) do
	for _, method in ipairs({ "get", "post", "postStream", "download" }) do
		check(method .. " does not auto-follow caller " .. name, function()
			local before = #redirected
			local result = request(method, { [name] = credential }, "/redirect", true)
			assert(initial[#initial]:find(name:lower() .. ": " .. credential:lower(), 1, true),
				"caller credential was removed from its original native origin")
			assert(#redirected == before, "credentialed native request crossed the origin boundary")
			assert(result.ok == false and result.status == 302 and result.error == "HTTP 302")
		end)
	end
	check("direct native " .. name .. " request remains usable", function()
		local before = #redirected
		local result = request("get", { [name] = credential }, "/direct", true)
		assert(result.ok and result.status == 200 and result.body == "abc" and #redirected == before)
		assert(initial[#initial]:find(name:lower() .. ": " .. credential:lower(), 1, true))
	end)
end

for _, method in ipairs({ "get", "post", "postStream", "download" }) do
	check("public native " .. method .. " still follows redirects", function()
		local before = #redirected
		local result, body = request(method, { Accept = "application/json" }, "/redirect", true)
		assert(result.ok and result.status == 200 and #redirected == before + 1)
		assert(redirected[#redirected]:find("accept: application/json", 1, true))
		if method == "postStream" then assert(body == "abc")
		elseif method == "download" then
			local file = assert(io.open(destination, "rb"))
			assert(file:read("*a") == "abc" and file:close())
		else assert(result.body == "abc") end
	end)
end

check("explicit public no-follow option retains its original receipt", function()
	local before = #redirected
	local result = request("get", {}, "/redirect", false)
	assert(result.ok == false and result.status == 302 and #redirected == before)
end)

HTTP.cancel(owner)
for _, handle in ipairs(handles) do close(handle) end
uv.run()
assert(not uv.loop_alive(), "native redirect checks retained process or socket ownership")
assert(uv.fs_unlink(destination))
assert(uv.fs_rmdir(root))
print(string.format("Native HTTP redirect receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

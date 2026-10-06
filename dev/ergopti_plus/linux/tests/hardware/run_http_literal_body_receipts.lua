--- tests/hardware/run_http_literal_body_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Literal HTTP Body Receipts
--- DESCRIPTION:
--- Sends caller bodies through the production buffered/streaming curl paths to
--- an actual loopback listener. Leading @ must remain text, never load a file
--- or stdin. Unicode, newlines and config escapes retain exact body bytes.
--- No native process/socket API is mocked; all fixture files are privately owned.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "literal body checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-body-XXXXXX"))
local path = root .. "/literal 'é\nsource"
local source = "Synthetic owned file bytes, never caller body"
local file = assert(io.open(path, "wb"))
assert(file:write(source) and file:close())
local checks, failures, requests = 0, 0, 0
local sockets, server_handles = {}, {}
local last_body = nil
local owner = "native-literal-body"

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat uv.run("nowait"); if predicate() then return end; uv.sleep(1) until uv.hrtime() >= deadline
	error("owned native body request did not settle")
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
		local ending = bytes:find("\r\n\r\n", 1, true)
		local length = ending and tonumber(bytes:sub(1, ending):lower():match("content%-length:%s*(%d+)"))
		if not answered and ending and #bytes >= ending + 3 + (length or 0) then
			answered = true
			assert(bytes:match("^POST /literal "), "fixture did not receive an actual POST")
			requests, last_body = requests + 1, bytes:sub(ending + 4, ending + 3 + (length or 0))
			uv.read_stop(socket)
			assert(uv.write(socket, "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc",
				function(write_error) assert(not write_error, tostring(write_error)); close(socket) end))
		end
	end))
end))
local url = "http://127.0.0.1:" .. server:getsockname().port .. "/literal"

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	HTTP.cancel(owner)
	wait_for(retired)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local cases = {
	{ name = "existing owned file reference", body = "@" .. path },
	{ name = "missing owned file reference", body = "@" .. root .. "/missing" },
	{ name = "stdin reference", body = "@-" },
	{ name = "single at sign", body = "@" },
	{ name = "double at sign", body = "@@literal" },
	{ name = "ordinary at-prefixed text", body = "@literal text" },
	{ name = "empty body", body = "" },
	{ name = "Unicode body", body = "écriture 日本語 😀" },
	{ name = "quotes and backslashes", body = "{\"q\":\"' \\\\ literal\"}" },
	{ name = "literal CRLF and at-prefixed second line", body = "first\r\n@second\nlast\r" },
	{ name = "literal percent escape", body = "literal%00body" },
	{ name = "leading tab and spaces", body = "\t  exact trailing bytes \t" },
}
for _, method in ipairs({ "post", "postStream" }) do
	for _, case in ipairs(cases) do
		check(method .. " sends " .. case.name .. " literally", function()
			local result, callbacks, chunks, before = nil, 0, {}, requests
			local function complete(value) result = value; callbacks = callbacks + 1 end
			local options = { owner = owner, timeout_ms = 1000 }
			local headers = { ["Content-Type"] = "application/json" }
			if method == "post" then assert(HTTP.post(url, headers, case.body, complete, options))
			else assert(HTTP.postStream(url, headers, case.body, options, function(bytes) chunks[#chunks + 1] = bytes end, complete)) end
			wait_for(function() return result ~= nil end)
			assert(result.ok and result.status == 200 and callbacks == 1,
				"literal caller bytes were interpreted as a native file/stream reference")
			assert(requests == before + 1 and last_body == case.body, "actual received body differs from caller bytes")
			if method == "post" then assert(result.body == "abc") else assert(table.concat(chunks) == "abc") end
			local retained = assert(io.open(path, "rb"))
			assert(retained:read("*a") == source and retained:close(), "owned source file changed")
			assert(not HTTP.isActive(owner))
		end)
	end
end

close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "literal body fixture retained native ownership")
assert(uv.fs_unlink(path))
assert(uv.fs_rmdir(root))
print(string.format("Native literal HTTP body receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

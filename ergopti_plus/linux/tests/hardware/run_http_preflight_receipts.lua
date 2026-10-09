--- tests/hardware/run_http_preflight_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux HTTP Replacement Preflight Receipts
--- DESCRIPTION:
--- Holds an actual production curl response open while submitting an invalid
--- replacement. Configuration/argv refusal must precede owner cancellation and
--- native timer/pipe allocation. Real ETag files, valid replacement and owner
--- isolation controls retain native behavior. No process/socket API is mocked.
--- ==============================================================================

local uv = require("luv")
local HTTP = require("adapters.http_client")
local Curl = require("adapters.curl_http_client")
assert(uv.getuid() ~= 0, "native preflight checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-http-preflight-XXXXXX"))
local path = root .. "/etag"
local destination = root .. "/download"
local owner = "native-http-preflight"
local checks, failures = 0, 0
local sockets, held, server_handles = {}, {}, {}
local last_headers, requests = "", 0

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

local function wait_for(predicate)
	local deadline = uv.hrtime() + 4000000000
	repeat uv.run("nowait"); if predicate() then return end; uv.sleep(1) until uv.hrtime() >= deadline
	error("owned native preflight request did not settle")
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
		if not server_handles[handle] then retained = true end
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
	Curl.cancel("independent-owned-invalid")
	wait_for(native_clients_retired)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local invalid = {
	{ name = "NUL ETag compare", options = { etag_compare = path .. "\0private-suffix" } },
	{ name = "NUL ETag save", options = { etag_save = path .. "\0private-suffix" } },
	{ name = "NUL download destination", download = destination .. "\0private-suffix" },
	{ name = "numeric ETag compare", options = { etag_compare = 42 } },
	{ name = "numeric ETag save", options = { etag_save = 42 } },
	{ name = "mixed header key types", headers = { [1] = "literal", ["X-Native"] = "literal" } },
	{ name = "numeric URL", url = 42 },
	{ name = "empty URL", url = "" },
	{ name = "raising header value", headers = { ["X-Native"] = setmetatable({}, {
		__tostring = function() error("Synthetic private header value") end,
	}) } },
}

for _, owned in ipairs({ false, true }) do
	for _, case in ipairs(invalid) do
		check((owned and "owned " or "") .. case.name .. " retains the actual valid response owner", function()
			write(path, "\"native-retained\"\n")
			write(destination, "Retained download bytes")
			local good, bad, callbacks, before_held, before_requests = nil, nil, 0, #held, requests
			assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) good = value end))
			wait_for(function() return #held == before_held + 1 end)
			assert(HTTP.isActive(owner), "fixture did not hold an actual curl request")
			local options = { owner = owner, timeout_ms = 100 }
			for key, value in pairs(case.options or {}) do options[key] = value end
			local function complete(value) bad = value; callbacks = callbacks + 1 end
			local operation
			local protected, dispatched = pcall(function()
				if owned then
					if case.download then options.output_path = case.download end
					operation = HTTP.get_owned(case.url or (url .. "/direct"), case.headers or {}, options, complete)
					return operation.started
				end
				if case.download then return HTTP.download(url .. "/direct", {}, case.download, options, complete) end
				return HTTP.get(case.url or (url .. "/direct"), case.headers or {}, options, complete)
			end)
			assert(protected and dispatched == false, "invalid curl metadata escaped as an exception or dispatch")
			wait_for(function() return bad ~= nil end)
			if owned then assert(operation:is_settled(), "invalid owned replacement retained native cleanup debt") end
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
end

check("valid replacement still retires its previous actual owner", function()
	local old, current, before = nil, nil, #held
	assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) old = value end))
	wait_for(function() return #held == before + 1 end)
	assert(HTTP.get(url .. "/direct", {}, { owner = owner, timeout_ms = 1000 }, function(value) current = value end))
	wait_for(function() return current ~= nil end)
	assert(current.ok and current.body == "abc" and old == nil and not HTTP.isActive(owner))
end)

check("valid owned replacement composes once and retires its regular predecessor", function()
	local old, current, before, conversions = nil, nil, #held, 0
	assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) old = value end))
	wait_for(function() return #held == before + 1 end)
	local header = setmetatable({}, { __tostring = function()
		conversions = conversions + 1
		return "Synthetic native header"
	end })
	local operation = HTTP.get_owned(url .. "/direct", { ["X-Native"] = header },
		{ owner = owner, timeout_ms = 1000 }, function(value) current = value end)
	assert(operation.started and conversions == 1)
	wait_for(function() return current ~= nil end)
	assert(operation:is_settled() and current.ok and current.body == "abc" and old == nil and not HTTP.isActive(owner))
end)

check("first owned construction failure retains late native close acknowledgments", function()
	-- This one historical scenario specifies native late-allocation construction
	-- debt. The stronger public no-allocation counterpart is exercised below.
	local HTTP = setmetatable({ get_owned = Curl.get_owned }, { __index = HTTP })
	local good, bad, before, before_requests = nil, nil, #held, requests
	assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) good = value end))
	wait_for(function() return #held == before + 1 end)
	local header = setmetatable({}, { __tostring = function() error("Synthetic private header value") end })
	local operation = HTTP.get_owned(url .. "/direct", { ["X-Native"] = header },
		{ owner = "independent-owned-invalid", timeout_ms = 1000 }, function(value) bad = value end)
	assert(operation.started == false and not operation:is_settled() and bad == nil,
		"first owned construction must retain its late allocation cleanup contract")
	local acknowledged = false
	operation:on_settled(function() acknowledged = true end)
	wait_for(function() return bad ~= nil end)
	assert(acknowledged and operation:is_settled() and bad.ok == false and bad.error == "curl request construction failed")
	assert(HTTP.isActive(owner) and requests == before_requests + 1)
	respond(held[#held])
	wait_for(function() return good ~= nil end)
	assert(good.ok and good.body == "abc")
end)

check("managed first malformed owned metadata refuses before all native allocation", function()
	local before_handles, before_requests, before_fds = {}, requests, {}
	uv.walk(function(handle) before_handles[handle] = true end)
	local scan = assert(uv.fs_scandir("/proc/self/fd"))
	while true do local name = uv.fs_scandir_next(scan); if not name then break end; before_fds[name] = true end
	local callbacks, result, conversions = 0, nil, 0
	local header = setmetatable({}, { __tostring = function()
		conversions = conversions + 1
		error("Synthetic fixed public metadata refusal")
	end })
	local operation = HTTP.get_owned(url .. "/direct", { ["X-Native"] = header },
		{ owner = "independent-public-invalid", timeout_ms = 1000 }, function(value) result, callbacks = value, callbacks + 1 end)
	assert(operation.started == false and operation:is_settled() and conversions == 1)
	assert(result and not result.ok and result.status == 0 and result.body == "" and callbacks == 1)
	assert(requests == before_requests)
	uv.walk(function(handle) assert(before_handles[handle], "preflight acquired a native handle") end)
	local after = assert(uv.fs_scandir("/proc/self/fd"))
	while true do local name = uv.fs_scandir_next(after); if not name then break end; assert(before_fds[name], "preflight acquired an FD") end
end)

check("owned cleanup ownership rejects metadata without evaluating it", function()
	local good, bad, before, conversions = nil, nil, #held, 0
	local predecessor = HTTP.get_owned(url .. "/held", {}, { owner = owner, timeout_ms = 1500 },
		function(value) good = value end)
	assert(predecessor.started)
	wait_for(function() return #held == before + 1 end)
	local header = setmetatable({}, { __tostring = function()
		conversions = conversions + 1
		error("Synthetic private header value")
	end })
	local refused = HTTP.get_owned(url .. "/direct", { ["X-Native"] = header }, { owner = owner },
		function(value) bad = value end)
	assert(refused.started == false and refused:is_settled() and bad.error == "previous request cleanup pending")
	assert(conversions == 0 and HTTP.isActive(owner))
	respond(held[#held])
	wait_for(function() return good ~= nil end)
	assert(predecessor:is_settled() and good.ok and good.body == "abc")
end)

check("literal native ETag files retain compare and save behavior", function()
	write(path, "\"native-compared\"\n")
	local result
	assert(HTTP.get(url .. "/direct", {}, { owner = owner, timeout_ms = 1000,
		etag_compare = path, etag_save = destination }, function(value) result = value end))
	wait_for(function() return result ~= nil end)
	assert(result.ok and result.body == "abc")
	assert(last_headers:lower():find('if%-none%-match:%s*"native%-compared"'))
	assert(read(destination) == "\"native-saved\"\n")
end)

check("invalid independent owner cannot affect a held native response", function()
	local good, bad, before = nil, nil, #held
	assert(HTTP.get(url .. "/held", {}, { owner = owner, timeout_ms = 1500 }, function(value) good = value end))
	wait_for(function() return #held == before + 1 end)
	assert(HTTP.get(url .. "/direct", {}, { owner = "independent-invalid", etag_compare = path .. "\0suffix" },
		function(value) bad = value end) == false)
	assert(bad and bad.ok == false and HTTP.isActive(owner))
	respond(held[#held])
	wait_for(function() return good ~= nil end)
	assert(good.ok and good.body == "abc")
end)

close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "native preflight fixture retained resource ownership")
assert(uv.fs_unlink(path))
assert(uv.fs_unlink(destination))
assert(uv.fs_rmdir(root))
print(string.format("Native HTTP preflight receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

--- tests/hardware/run_cli_exit_receipts.lua
--- Production HTTP and digest adapters run actual curl/sha256sum. Owned shell
--- wrappers delegate unchanged argv, then terminate by a real signal or exit.
--- All output comes from the GNU tools; no CLI output or libuv API is mocked.
--- The wrapper is a controlled subprocess fixture, not a physical input test.
local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Http = require("adapters.http_client")
local Digest = require("adapters.file_digest")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-cli-exits-XXXXXX"))
local previous_path = assert(uv.os_getenv("PATH"))
local previous_mode = uv.os_getenv("ERGOPTI_NATIVE_EXIT_RECEIPT")
local files, sockets = {}, {}
local checks, failures = 0, 0
local BODY = '{"native":true}\n'
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes) and file:close())
	files[#files + 1] = path
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function close(handle)
	if not uv.is_closing(handle) then uv.close(handle) end
end

for _, program in ipairs({ "curl", "sha256sum" }) do
	local native = assert(Shell.exec_line("command -v " .. program))
	assert(native:sub(1, 1) == "/", "fixture requires an absolute native tool path")
	local path = root .. "/" .. program
	write(path, "#!/bin/sh\n" .. Shell.quote(native) .. ' "$@"\n'
		.. 'result=$?\n[ "$result" -eq 0 ] || exit "$result"\n'
		.. 'case "$ERGOPTI_NATIVE_EXIT_RECEIPT" in\nsuccess) exit 0;;\nexit7) exit 7;;\n'
		.. '*) kill -"$ERGOPTI_NATIVE_EXIT_RECEIPT" "$$"; exit 99;;\nesac\n')
	assert(uv.fs_chmod(path, 448))
end
assert(uv.os_setenv("PATH", root .. ":" .. previous_path))
local digest_path = root .. "/payload"
write(digest_path, "abc")

local server = uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
local url = "http://127.0.0.1:" .. server:getsockname().port .. "/receipt"
local received = 0
assert(server:listen(16, function(err)
	assert(not err, tostring(err))
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	assert(server:accept(socket))
	local input, handled = "", false
	assert(socket:read_start(function(read_error, chunk)
		assert(not read_error, tostring(read_error))
		if not chunk then close(socket); return end
		if handled then return end
		input = input .. chunk
		local boundary = input:find("\r\n\r\n", 1, true)
		if not boundary then return end
		local length = tonumber(input:sub(1, boundary):lower():match("content%-length:%s*(%d+)")) or 0
		if #input < boundary + 3 + length then return end
		handled, received = true, received + 1
		assert(socket:write("HTTP/1.1 200 Fixture\r\nConnection: close\r\nContent-Length: "
			.. #BODY .. "\r\n\r\n" .. BODY, function(write_error)
			assert(not write_error, tostring(write_error))
			socket:shutdown(function() close(socket) end)
		end))
	end))
end))

--- Settles all request handles while retaining only the owned HTTP listener.
local function settle(done)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		local request_live = false
		uv.walk(function(handle)
			local kind = uv.handle_get_type(handle)
			if not uv.is_closing(handle) and (kind == "process" or kind == "pipe" or kind == "timer") then
				request_live = true
			end
		end)
		if done() and not request_live then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native request did not retire before its fixture deadline")
end

for _, method in ipairs({ "get", "post", "download", "stream", "sha256" }) do
	for _, mode in ipairs({ "success", "exit7", "15", "9", "10", "12" }) do
		checks = checks + 1
		local ok, err = xpcall(function()
			assert(uv.os_setenv("ERGOPTI_NATIVE_EXIT_RECEIPT", mode))
			local result, callbacks, chunks = nil, 0, ""
			local destination = root .. "/download-" .. mode
			local before_requests = received
			local function done(value) result, callbacks = value, callbacks + 1 end
			local accepted
			if method == "get" then accepted = Http.get(url, {}, {}, done)
			elseif method == "post" then accepted = Http.post(url, {}, "{}", done)
			elseif method == "download" then
				files[#files + 1] = destination
				accepted = Http.download(url, {}, destination, {}, done)
			elseif method == "stream" then
				accepted = Http.postStream(url, {}, "{}", {}, function(chunk) chunks = chunks .. chunk end, done)
			else
				accepted = Digest.sha256(digest_path, {}, function(value, failure)
					done({ ok = value ~= nil, digest = value, error = failure })
				end)
			end
			assert(accepted, "production dispatch refused the actual tool wrapper")
			settle(function() return callbacks > 0 end)
			assert(callbacks == 1 and not Http.isActive() and not Digest.isActive())
			if method ~= "sha256" then
				assert(received == before_requests + 1 and result.status == 200, "actual curl did not finish its loopback request")
				if method == "download" then assert(read(destination) == BODY) end
				if method == "stream" then assert(chunks == BODY) end
			end
			if mode == "success" then
				assert(result.ok == true and result.error == nil)
				if method == "sha256" then assert(result.digest == ABC_SHA256)
				elseif method == "get" or method == "post" then assert(result.body == BODY) end
			else
				local status = mode == "exit7" and 7 or 128 + tonumber(mode)
				assert(result.ok == false, "native signal was mistaken for successful exit")
				assert(type(result.error) == "string" and result.error:find(tostring(status), 1, true), tostring(result.error))
				if method == "sha256" then assert(result.digest == nil)
				else assert(result.body == "", "failed process exposed a successful buffered body") end
			end
		end, debug.traceback)
		if ok then print("PASS " .. method .. " native exit " .. mode) else
			failures = failures + 1
			io.stderr:write("FAIL " .. method .. " native exit " .. mode .. ": " .. tostring(err) .. "\n")
		end
	end
end

assert(Http.cancel() and Digest.cancel())
for _, socket in ipairs(sockets) do close(socket) end
close(server)
uv.run("nowait")
assert(not uv.loop_alive(), "native fixture leaked handles")
assert(uv.os_setenv("PATH", previous_path))
if previous_mode then assert(uv.os_setenv("ERGOPTI_NATIVE_EXIT_RECEIPT", previous_mode))
else assert(uv.os_unsetenv("ERGOPTI_NATIVE_EXIT_RECEIPT")) end
for _, path in ipairs(files) do assert(uv.fs_unlink(path)) end
assert(uv.fs_rmdir(root))
print(string.format("Native CLI exit receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

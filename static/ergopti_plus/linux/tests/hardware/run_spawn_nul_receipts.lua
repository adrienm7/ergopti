--- tests/hardware/run_spawn_nul_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux Spawn Byte Boundaries
--- DESCRIPTION:
--- Drives real libuv process, digest and curl owners with NUL-bearing executable
--- names, argv and file paths. execve cannot represent embedded NUL; silently
--- using the shorter C string may execute another program or overwrite a file.
--- Ordinary-user files, literal argv and loopback HTTP controls retain valid
--- native behavior. No process API, command output or hardware input is mocked.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")
local Process = require("adapters.process_runner")
local Digest = require("adapters.file_digest")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native byte boundary checks require an ordinary user")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-spawn-nul-XXXXXX"))
local checks, failures, requests = 0, 0, 0
local sockets = {}

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
	error("owned native operation did not settle")
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

local program = root .. "/program"
local invoked = root .. "/invoked"
write(program, "#!/bin/sh\nprintf invoked >> " .. Shell.quote(invoked) .. '\nprintf "<%s>" "$@"\n')
assert(uv.fs_chmod(program, 448))

for _, invalid in ipairs({ "executable", "argument" }) do
	check("native shell runner refuses NUL-bearing " .. invalid .. " before execution", function()
		write(invoked, "")
		local callbacks = 0
		local name = invalid == "executable" and program .. "\0ignored" or program
		local args = invalid == "argument" and { "literal", "prefix\0private-suffix" } or {}
		local handle, reason = Shell.run_async(name, args, { timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
		if handle then wait_for(function() return callbacks == 1 end) end
		assert(handle == nil and callbacks == 0, "unrepresentable native bytes dispatched a shortened executable or argv")
		assert(type(reason) == "string" and reason:find(invalid == "argument" and "argument 2" or "executable", 1, true))
		assert(not reason:find("private-suffix", 1, true))
		assert(read(invoked) == "", "a refused spawn still executed the shorter native program")
	end)
	check("native process runner refuses NUL-bearing " .. invalid .. " exactly once", function()
		write(invoked, "")
		local callbacks, result = 0, nil
		local name = invalid == "executable" and program .. "\0ignored" or program
		local args = invalid == "argument" and { "literal", "prefix\0private-suffix" } or {}
		local dispatched = Process.run(name, args, { timeout_ms = 1000 }, function(value) result = value; callbacks = callbacks + 1 end)
		wait_for(function() return callbacks == 1 end)
		assert(dispatched == false and result.exit_code == -1 and type(result.error) == "string")
		assert(result.error:find(invalid == "argument" and "argument 2" or "executable", 1, true))
		assert(not result.error:find("private-suffix", 1, true))
		assert(read(invoked) == "", "a refused process still executed a shorter native target")
	end)
end

local payload = root .. "/payload"
write(payload, "abc")
check("native file digest refuses NUL instead of hashing a shorter existing path", function()
	local callbacks, value, reason = 0, nil, nil
	local dispatched = Digest.sha256(payload .. "\0private-suffix", { timeout_ms = 1000 }, function(result, err)
		value, reason, callbacks = result, err, callbacks + 1
	end)
	wait_for(function() return callbacks == 1 end)
	assert(dispatched == false and value == nil and type(reason) == "string")
	assert(reason:find("argument 4", 1, true) and not reason:find("private-suffix", 1, true))
	assert(not Digest.isActive())
end)

local server = uv.new_tcp()
assert(server:bind("127.0.0.1", 0))
assert(server:listen(16, function(err)
	assert(not err, tostring(err))
	local socket = uv.new_tcp()
	sockets[#sockets + 1] = socket
	assert(server:accept(socket))
	local received, answered = "", false
	assert(uv.read_start(socket, function(failure, chunk)
		assert(not failure, tostring(failure))
		if not chunk then close(socket); return end
		received = received .. chunk
		if not answered and received:find("\r\n\r\n", 1, true) then
			answered = true
			requests = requests + 1
			uv.read_stop(socket)
			assert(uv.write(socket, 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nETag: "native-receipt"\r\nConnection: close\r\n\r\nabc', function(write_error)
				assert(not write_error, tostring(write_error))
				close(socket)
			end))
		end
	end))
end))
local url = "http://127.0.0.1:" .. server:getsockname().port .. "/native"
local owner = "native-spawn-nul-receipt"
local kept = root .. "/kept"
for _, option in ipairs({ "output_path", "etag_compare", "etag_save" }) do
	check("native curl refuses NUL-bearing " .. option .. " without network or file side effects", function()
		write(kept, '"retained-etag"\n')
		local options = { timeout_ms = 1000, owner = owner }
		options[option] = kept .. "\0private-suffix"
		local callbacks, result, before = 0, nil, requests
		local dispatched
		local function complete(value) result = value; callbacks = callbacks + 1 end
		if option == "output_path" then dispatched = HTTP.download(url, {}, options[option], options, complete)
		else dispatched = HTTP.get(url, {}, options, complete) end
		wait_for(function() return callbacks == 1 end)
		assert(dispatched == false and result.ok == false and type(result.error) == "string")
		assert(result.error:find("argument", 1, true) and not result.error:find("private-suffix", 1, true))
		assert(requests == before and not HTTP.isActive(owner), "invalid argv reached the actual loopback server")
		assert(read(kept) == '"retained-etag"\n', "invalid argv overwrote a shorter existing native path")
	end)
end

local literal = "é漢\n'$(false)'"
check("native shell runner preserves empty and literal NUL-free arguments", function()
	local result
	assert(Shell.run_async(program, { "", literal }, { timeout_ms = 1000 }, function(value) result = value end))
	wait_for(function() return result ~= nil end)
	assert(result.ok and result.stdout == "<><" .. literal .. ">")
end)
check("native process runner preserves empty and literal NUL-free arguments", function()
	local result
	assert(Process.run(program, { "", literal }, { timeout_ms = 1000 }, function(value) result = value end))
	wait_for(function() return result ~= nil end)
	assert(result.exit_code == 0 and result.error == nil and result.stdout == "<><" .. literal .. ">")
end)
check("native file digest retains the independent healthy vector", function()
	local value, reason, completed
	assert(Digest.sha256(payload, { timeout_ms = 1000 }, function(result, err) value, reason, completed = result, err, true end))
	wait_for(function() return completed end)
	assert(value == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" and reason == nil)
end)
check("native curl retains a healthy literal-path download", function()
	local destination = root .. "/download é'\nfile"
	local result, before = nil, requests
	assert(HTTP.download(url, {}, destination, { timeout_ms = 1000, owner = owner }, function(value) result = value end))
	wait_for(function() return result ~= nil end)
	assert(result.ok and result.status == 200 and read(destination) == "abc")
	assert(requests == before + 1 and not HTTP.isActive(owner))
end)

close(server)
for _, socket in ipairs(sockets) do close(socket) end
uv.run()
assert(not uv.loop_alive(), "native argv checks retained process or socket ownership")
local scan = assert(uv.fs_scandir(root))
while true do
	local name = uv.fs_scandir_next(scan)
	if not name then break end
	assert(uv.fs_unlink(root .. "/" .. name))
end
assert(uv.fs_rmdir(root))
print(string.format("Native spawn byte receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

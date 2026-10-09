--- tests/hardware/run_cli_exit_receipts.lua
--- Production HTTP and digest adapters run actual curl/sha256sum. Owned shell
--- wrappers delegate unchanged argv, then terminate by a real signal or exit.
--- All output comes from the GNU tools; no CLI output or libuv API is mocked.
--- The wrapper is a controlled subprocess fixture, not a physical input test.
local uv = require("luv")
local ffi = require("ffi")
ffi.cdef[[
	int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5);
	int waitpid(int pid, int *status, int options);
]]
-- Own and reap fixture descendants after their wrapper exits, rather than
-- leaving zombies to the container's init. This changes only this process.
assert(ffi.C.prctl(36, 1, 0, 0, 0) == 0, "native fixture requires Linux child-subreaper support")
local Shell = require("adapters.shell_runner")
local Http = require("adapters.http_client")
local Digest = require("adapters.file_digest")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-cli-exits-XXXXXX"))
local previous_path = assert(uv.os_getenv("PATH"))
local previous_mode = uv.os_getenv("ERGOPTI_NATIVE_EXIT_RECEIPT")
local previous_receipt = uv.os_getenv("ERGOPTI_NATIVE_DESCENDANT_RECEIPT")
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
		.. 'orphan*)\ncase "$ERGOPTI_NATIVE_EXIT_RECEIPT" in\n'
		.. 'orphan-stubborn-*) /bin/sh -c \'trap "" TERM; printf ready > "$ERGOPTI_NATIVE_DESCENDANT_RECEIPT.ready"; exec sleep 30\' &\n'
		.. 'child=$!; while [ ! -f "$ERGOPTI_NATIVE_DESCENDANT_RECEIPT.ready" ]; do sleep 0.001; done;;\n'
		.. '*) sleep 30 & child=$!;;\nesac\n'
		.. 'printf "%s %s\\n" "$$" "$child" > "$ERGOPTI_NATIVE_DESCENDANT_RECEIPT"; exit 0;;\n'
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
local function await(done)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		if done() then return true end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	return false
end

local current_adoption

local function running(pid)
	if current_adoption and current_adoption.child == pid and current_adoption.consumed then return false end
	local file = io.open("/proc/" .. pid .. "/stat", "rb")
	if not file then return false end
	local stat = assert(file:read("*a"))
	assert(file:close())
	local state = assert(stat:match("^%d+ %(.+%) (%a) "))
	local observed, suffix = stat:match("^(%d+) %(.+%) %a (.*)$")
	local fields = {}
	if suffix then for value in suffix:gmatch("%S+") do fields[#fields + 1] = value end end
	local fact
	if observed and #fields >= 19 and fields[1]:match("^%d+$")
		and fields[2]:match("^%d+$") and fields[19]:match("^%d+$") then
		fact = { pid = observed, parent = fields[1], group = fields[2], birth = fields[19], state = state }
	end
	return state ~= "Z" and state ~= "X", fact
end

local function identities(path)
	local file = io.open(path, "rb")
	if not file then return end
	local bytes = assert(file:read("*a"))
	assert(file:close())
	local leader, child = bytes:match("^(%d+) (%d+)\n$")
	return tonumber(leader), tonumber(child)
end

-- The same exact-child syscall serves intermediate adoption and final cleanup.
local function reap_once(child)
	local receipt = current_adoption
	if receipt and receipt.child == child and receipt.consumed then return true end
	local status = ffi.new("int[1]")
	local pid = ffi.C.waitpid(child, status, 1) -- WNOHANG; only this owned PID.
	local acknowledged = pid == child or (pid == -1 and ffi.errno() == 10) -- ECHILD: this owner already reaped it.
	if acknowledged and receipt and receipt.child == child then receipt.consumed = true end
	return acknowledged
end

local function reap(child)
	assert(await(function()
		return reap_once(child)
	end), "owned native descendant did not reap")
end

local function capture_adoption(child, leader)
	local alive, initial = running(child)
	local _, own = running("self")
	local self_pid = tostring(uv.os_getpid())
	if not alive or not initial or not own or initial.pid ~= tostring(child)
		or initial.group ~= tostring(leader) or initial.parent ~= self_pid or own.pid ~= self_pid then return nil end
	return { child = child, leader = leader, birth = initial.birth, self_pid = self_pid, self_birth = own.birth }
end

local function reap_adopted(receipt)
	if not receipt then return end
	local _, own_before = running("self")
	local _, current = running(receipt.child)
	local _, own_after = running("self")
	-- The fixture is the actual adopting parent. A zombie retains its PID until
	-- this exact waitpid, allowing curl's unchanged ESRCH group proof to finish.
	if not own_before or not own_after or not current
		or own_before.pid ~= receipt.self_pid or own_after.pid ~= receipt.self_pid
		or own_before.birth ~= receipt.self_birth or own_after.birth ~= receipt.self_birth
		or current.pid ~= tostring(receipt.child) or current.birth ~= receipt.birth
		or current.parent ~= receipt.self_pid or current.group ~= tostring(receipt.leader)
		or current.state ~= "Z" then return end
	reap_once(receipt.child)
end

local function settle(done, adoption)
	local deadline = uv.hrtime() + 5000000000
	repeat
		uv.run("nowait")
		reap_adopted(adoption)
		local request_live = false
		uv.walk(function(handle)
			local kind = uv.handle_get_type(handle)
			-- A closing transport handle still owes its actual close callback.
			if kind == "process" or kind == "pipe" or kind == "timer" then
				request_live = true
			end
		end)
		if done() and not request_live then return end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	error("native request did not retire before its fixture deadline")
end

for _, method in ipairs({ "get", "post", "download", "stream", "sha256" }) do
	for _, mode in ipairs({ "success", "exit7", "15", "9", "10", "12",
		"orphan-deadline", "orphan-cancel", "orphan-stubborn-deadline", "orphan-stubborn-cancel" }) do
		checks = checks + 1
		local receipt = root .. "/child-" .. method .. "-" .. mode
		local orphan = mode:sub(1, 7) == "orphan-"
		local cancelled = mode:find("cancel", 1, true) ~= nil
		local leader, child
		local adoption
		current_adoption = nil
		if orphan then
			files[#files + 1] = receipt
			if mode:find("stubborn", 1, true) then files[#files + 1] = receipt .. ".ready" end
		end
		local ok, err = xpcall(function()
			assert(uv.os_setenv("ERGOPTI_NATIVE_EXIT_RECEIPT", mode))
			assert(uv.os_setenv("ERGOPTI_NATIVE_DESCENDANT_RECEIPT", receipt))
			local result, callbacks, chunks = nil, 0, ""
			local destination = root .. "/download-" .. mode
			local before_requests = received
			local function done(value) result, callbacks = value, callbacks + 1 end
			local options = { timeout_ms = 500 }
			local accepted
			if method == "get" then accepted = Http.get(url, {}, options, done)
			elseif method == "post" then accepted = Http.post(url, {}, "{}", done, options)
			elseif method == "download" then
				files[#files + 1] = destination
				accepted = Http.download(url, {}, destination, options, done)
			elseif method == "stream" then
				accepted = Http.postStream(url, {}, "{}", options, function(chunk) chunks = chunks .. chunk end, done)
			else
				accepted = Digest.sha256(digest_path, options, function(value, failure)
					done({ ok = value ~= nil, digest = value, error = failure })
				end)
			end
			assert(accepted, "production dispatch refused the actual tool wrapper")
			if orphan then
				assert(await(function()
					leader, child = identities(receipt)
					return leader and not running(leader)
				end), "native wrapper did not exit before its deadline")
				assert(running(child), "positive native descendant control is absent")
				adoption = capture_adoption(child, leader)
				current_adoption = adoption
				if cancelled then
					local cancel = method == "sha256" and Digest.cancel or Http.cancel
					assert(cancel() == true)
				end
			end
			settle(function()
				if cancelled then return not Http.isActive() and not Digest.isActive() end
				return callbacks > 0
			end, adoption)
			assert(callbacks == (cancelled and 0 or 1) and not Http.isActive() and not Digest.isActive())
			if orphan then
				assert(await(function() return not running(child) end), "native descendant survived leader retirement")
			end
			if method ~= "sha256" then
				assert(received == before_requests + 1, "actual curl did not finish its loopback request")
				if not orphan then assert(result.status == 200, "real HTTP receipt lost its status") end
				if method == "download" then assert(read(destination) == BODY) end
				if method == "stream" then assert(chunks == BODY) end
			end
			if cancelled then assert(result == nil, "cancellation published a stale completion")
			elseif orphan then assert(result.ok == false and result.error == "timeout")
			elseif mode == "success" then
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
		if orphan then
			-- Consumed PID/group identity must never signal or wait on a reused integer.
			local consumed = adoption and adoption.consumed
			if not consumed then leader, child = identities(receipt) end
			if leader and not consumed then uv.kill(-leader, "sigkill") end
			if child then
				if not consumed and running(child) then uv.kill(child, "sigkill") end
				reap(child)
			end
		end
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
if previous_receipt then assert(uv.os_setenv("ERGOPTI_NATIVE_DESCENDANT_RECEIPT", previous_receipt))
else assert(uv.os_unsetenv("ERGOPTI_NATIVE_DESCENDANT_RECEIPT")) end
for _, path in ipairs(files) do assert(uv.fs_unlink(path)) end
assert(uv.fs_rmdir(root))
print(string.format("Native CLI exit receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

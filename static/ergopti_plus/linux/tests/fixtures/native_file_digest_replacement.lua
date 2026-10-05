--- tests/fixtures/native_file_digest_replacement.lua
--- ==============================================================================
--- MODULE: Native File Digest Replacement Ownership Regression
--- DESCRIPTION:
--- Invalid replacement paths cannot retire an already dispatched native digest.
--- Real FIFOs keep sha256sum pending until an actual writer supplies the known
--- abc vector. Native special-file deadlines and cancellation control cleanup.
--- No libuv call, process output, allocation or signal receipt is simulated.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_file_digest_replacement%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. package.path
local uv = require("luv")
local ffi = require("ffi")
ffi.cdef("int mkfifo(const char *pathname, unsigned int mode);")
local Digest = require("adapters.file_digest")
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-digest-replacement-XXXXXX"))
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local checks, failures, paths, processes = 0, 0, {}, {}

local function await(predicate)
	local deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	return false
end

local function fifo(name)
	local path = directory .. "/" .. name
	assert(ffi.C.mkfifo(path, 384) == 0, "native FIFO allocation failed")
	paths[#paths + 1] = path
	return path
end

local function process_alive(pid)
	local file = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
	if not file then return false end
	local text = file:read("*a")
	file:close()
	local state = assert(text:match("^%d+ %(.+%) (%a) "), "missing native process-state receipt")
	return state ~= "Z" and state ~= "X"
end

local function owned_pid()
	local pid
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "process" and not uv.is_closing(handle) then
			assert(not pid, "fixture has more than one candidate digest")
			pid = uv.process_get_pid(handle)
		end
	end)
	assert(pid, "fixture did not acquire a native process")
	processes[#processes + 1] = pid
	return pid
end

local function cleanup()
	Digest.cancel()
	for _, pid in ipairs(processes) do
		if process_alive(pid) then uv.kill(-pid, "sigkill"); uv.kill(pid, "sigkill") end
	end
	assert(await(function() return not uv.loop_alive() end), "fixture retained native handles")
	for _, path in ipairs(paths) do assert(uv.fs_unlink(path)) end
	paths, processes = {}, {}
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	cleanup()
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

for _, invalid in ipairs({ "embedded NUL", "embedded NUL with a raising callback", "relative path" }) do
	check("refused " .. invalid .. " preserves the original native FIFO digest", function()
		local path = fifo(invalid)
		local value, reason, callbacks = nil, nil, 0
		assert(Digest.sha256(path, { timeout_ms = 1500 }, function(result, err)
			value, reason, callbacks = result, err, callbacks + 1
		end))
		local pid = owned_pid()
		assert(await(function() return process_alive(pid) and Digest.isActive() end))
		local rejected, rejection, refusals = nil, nil, 0
		local candidate = invalid == "relative path" and "relative" or (path .. "\0invalid")
		assert(not Digest.sha256(candidate, {}, function(result, err)
			rejected, rejection, refusals = result, err, refusals + 1
			if invalid == "embedded NUL with a raising callback" then error("intentional refusal callback exception") end
		end), "malformed candidate was dispatched")
		assert(refusals == 1 and rejected == nil and type(rejection) == "string")
		assert(Digest.isActive() and process_alive(pid) and callbacks == 0,
			"refused candidate retired the original digest")
		local writer, writer_code
		writer = assert(uv.spawn("python3", { args = { "-c",
			"import sys; open(sys.argv[1], 'wb').write(b'abc')", path } }, function(code)
			writer_code = code
			uv.close(writer)
		end))
		processes[#processes + 1] = uv.process_get_pid(writer)
		assert(await(function() return not uv.loop_alive() end), "original digest did not finish")
		assert(value == ABC_SHA256 and reason == nil and callbacks == 1 and writer_code == 0,
			"original native digest lost its terminal result")
		assert(not Digest.isActive() and not process_alive(pid))
	end)
end

check("accepted replacement still cancels the previous native FIFO digest", function()
	local old_callbacks, callbacks, value, reason = 0, 0, nil, nil
	assert(Digest.sha256(fifo("replaced"), { timeout_ms = 1500 }, function() old_callbacks = old_callbacks + 1 end))
	local pid = owned_pid()
	local path = directory .. "/accepted"
	local file = assert(io.open(path, "wb"))
	assert(file:write("abc"))
	assert(file:close())
	paths[#paths + 1] = path
	assert(Digest.sha256(path, {}, function(result, err) value, reason, callbacks = result, err, callbacks + 1 end))
	assert(await(function() return not uv.loop_alive() end))
	assert(old_callbacks == 0 and callbacks == 1 and value == ABC_SHA256 and reason == nil)
	assert(not Digest.isActive() and not process_alive(pid))
end)

for _, kind in ipairs({ "unopened FIFO", "unbounded /dev/zero" }) do
	check("native deadline retires " .. kind, function()
		local path = kind == "unopened FIFO" and fifo("deadline") or "/dev/zero"
		local value, reason, callbacks = nil, nil, 0
		local started = uv.hrtime()
		assert(Digest.sha256(path, { timeout_ms = 100 }, function(result, err)
			value, reason, callbacks = result, err, callbacks + 1
		end))
		local pid = owned_pid()
		assert(await(function() return not uv.loop_alive() end))
		local elapsed_ms = (uv.hrtime() - started) / 1000000
		assert(value == nil and reason == "timeout" and callbacks == 1)
		assert(elapsed_ms >= 60 and elapsed_ms < 2500, "native deadline was not bounded")
		assert(not Digest.isActive() and not process_alive(pid), "timed-out native child survived")
	end)
end

check("explicit native FIFO cancellation stays silent and releases its child", function()
	local callbacks = 0
	assert(Digest.sha256(fifo("cancel"), { timeout_ms = 1500 }, function() callbacks = callbacks + 1 end))
	local pid = owned_pid()
	assert(Digest.cancel() and Digest.cancel() and not Digest.isActive())
	assert(await(function() return not uv.loop_alive() end))
	assert(callbacks == 0 and not process_alive(pid))
end)

assert(uv.fs_rmdir(directory))
print(string.format("Native file digest replacement: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

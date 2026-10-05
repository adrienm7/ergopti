--- tests/fixtures/native_file_digest_owners.lua
--- ==============================================================================
--- MODULE: Native File Digest Owner Isolation Regression
--- DESCRIPTION:
--- Drives actual FileDigest and updater cancellation through real sha256sum
--- children, owned FIFOs and independent abc receipts. Named requests and the
--- legacy default owner cannot replace or cancel each other's work. No backend,
--- allocation, process output or signal receipt is mocked.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_file_digest_owners%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv, ffi = require("luv"), require("ffi")
ffi.cdef("int mkfifo(const char *pathname, unsigned int mode);")
local Digest = require("adapters.file_digest")
local Updater = require("modules.updater.manager")
assert(Updater._file_digest == Digest, "updater must use the actual shared adapter")
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-digest-owners-XXXXXX"))
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local checks, failures, paths, processes, writer_failures = 0, 0, {}, {}, 0

local function await(predicate)
	local deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(1)
	until uv.hrtime() >= deadline
	return false
end

local function alive(pid)
	local file = io.open("/proc/" .. pid .. "/stat", "r")
	if not file then return false end
	local text = file:read("*a"); file:close()
	local state = assert(text:match("^%d+ %(.+%) (%a) "))
	return state ~= "Z" and state ~= "X"
end

local function fifo(name)
	local path = directory .. "/" .. name
	assert(ffi.C.mkfifo(path, 384) == 0)
	paths[#paths + 1] = path
	return path
end

local function dispatch(path, owner)
	local result = { callbacks = 0 }
	assert(Digest.sha256(path, { timeout_ms = 2000, owner = owner }, function(value, err)
		result.value, result.error, result.callbacks = value, err, result.callbacks + 1
	end))
	uv.walk(function(handle)
		if uv.handle_get_type(handle) == "process" and not uv.is_closing(handle) then
			local pid = uv.process_get_pid(handle)
			if not processes[pid] then result.pid = pid; processes[pid] = true end
		end
	end)
	assert(result.pid, "native digest process was not acquired")
	return result
end

local function feed(path)
	local writer
	writer = assert(uv.spawn("python3", { args = { "-c",
		"import sys; open(sys.argv[1], 'wb').write(b'abc')", path } }, function(code)
		if code ~= 0 then writer_failures = writer_failures + 1 end
		uv.close(writer)
	end))
	processes[uv.process_get_pid(writer)] = true
end

local function completed(result)
	assert(result.callbacks == 1 and result.value == ABC_SHA256 and result.error == nil,
		"native owner lost its independent abc receipt")
	assert(not alive(result.pid), "completed native digest child survived")
end

local function cleanup()
	for _, owner in ipairs({ "default", "layout_registry", "updater" }) do Digest.cancel(owner) end
	for pid in pairs(processes) do if alive(pid) then uv.kill(-pid, "sigkill"); uv.kill(pid, "sigkill") end end
	assert(await(function() return not uv.loop_alive() end), "fixture leaked native handles")
	for _, path in ipairs(paths) do
		local removed, _, code = uv.fs_unlink(path)
		assert(removed or code == "ENOENT", "fixture could not retire an owned path")
	end
	assert(writer_failures == 0, "native FIFO writer failed")
	paths, processes = {}, {}
end

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	cleanup()
	if ok then print("PASS " .. name) else
		failures = failures + 1; io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("real updater cancellation preserves the layout owner's native digest", function()
	local path = fifo("layout")
	local layout = dispatch(path, "layout_registry")
	assert(Updater.get_state() == "idle" and Updater.cancel_update())
	assert(Digest.isActive("layout_registry") and alive(layout.pid) and layout.callbacks == 0,
		"idle updater cancellation retired another owner's digest")
	feed(path)
	assert(await(function() return not uv.loop_alive() end))
	completed(layout)
end)

check("production layout digest collaborator forwards its owner and completes its hash", function()
	local function upvalue(fn, name)
		for index = 1, 100 do
			local key, value = debug.getupvalue(fn, index)
			if not key then break end
			if key == name then return value end
		end
		error("production collaborator not found: " .. name)
	end
	local Registry = require("modules.keymap.layout_registry")
	local resolve = upvalue(Registry.refresh, "resolve_deps")
	local deps = upvalue(resolve, "default_deps")
	local factory = upvalue(deps, "file_sha256")
	local hash = factory(directory .. "/", 2000)
	paths[#paths + 1] = directory .. "/.digest.tmp"
	local value, reason, callbacks = nil, nil, 0
	-- Invoke the actual private collaborator; no network refresh or installation.
	hash("abc", function(result, err) value, reason, callbacks = result, err, callbacks + 1 end)
	assert(Digest.isActive("layout_registry") and not Digest.isActive(), "production layout digest lost its owner")
	assert(Updater.cancel_update())
	assert(await(function() return not uv.loop_alive() end))
	assert(value == ABC_SHA256 and reason == nil and callbacks == 1)
	assert(not uv.fs_stat(directory .. "/.digest.tmp"), "production collaborator retained its staging file")
end)

check("named replacement retires only the same owner's native process", function()
	local path = fifo("retained")
	local layout = dispatch(path, "layout_registry")
	local old_update = dispatch(fifo("replaced"), "updater")
	local replacement = directory .. "/replacement"
	local file = assert(io.open(replacement, "wb")); assert(file:write("abc")); assert(file:close())
	paths[#paths + 1] = replacement
	local update = dispatch(replacement, "updater")
	assert(await(function() return update.callbacks == 1 and not alive(old_update.pid) end))
	completed(update)
	assert(old_update.callbacks == 0 and Digest.isActive("layout_registry") and alive(layout.pid),
		"named replacement crossed the owner boundary")
	assert(not Digest.isActive("updater"))
	feed(path); assert(await(function() return not uv.loop_alive() end)); completed(layout)
end)

check("named cancellation and absent-owner cancellation leave the other owner live", function()
	local path = fifo("survivor")
	local layout = dispatch(path, "layout_registry")
	local update = dispatch(fifo("cancelled"), "updater")
	assert(Digest.cancel("absent") and Digest.cancel("updater") and Digest.cancel("updater"))
	assert(await(function() return not alive(update.pid) end))
	assert(update.callbacks == 0 and not Digest.isActive("updater"))
	assert(Digest.isActive("layout_registry") and alive(layout.pid))
	feed(path); assert(await(function() return not uv.loop_alive() end)); completed(layout)
end)

check("legacy cancellation cannot retire a named native owner", function()
	local legacy = dispatch(fifo("legacy"), nil)
	local path = fifo("named")
	local update = dispatch(path, "updater")
	assert(Digest.cancel() and Digest.cancel())
	assert(await(function() return not alive(legacy.pid) end))
	assert(legacy.callbacks == 0 and not Digest.isActive())
	assert(Digest.isActive("updater") and alive(update.pid))
	feed(path); assert(await(function() return not uv.loop_alive() end)); completed(update)
end)

check("a refused named request preserves both incumbent native owners", function()
	local layout_path, update_path = fifo("refused-layout"), fifo("refused-updater")
	local layout, update = dispatch(layout_path, "layout_registry"), dispatch(update_path, "updater")
	local refusals = 0
	assert(not Digest.sha256(layout_path .. "\0invalid", { owner = "layout_registry" }, function(value, err)
		assert(value == nil and err:find("NUL", 1, true)); refusals = refusals + 1
	end))
	assert(refusals == 1 and Digest.isActive("layout_registry") and Digest.isActive("updater"))
	assert(alive(layout.pid) and alive(update.pid) and layout.callbacks == 0 and update.callbacks == 0)
	feed(layout_path); feed(update_path)
	assert(await(function() return not uv.loop_alive() end)); completed(layout); completed(update)
end)

assert(uv.fs_rmdir(directory))
print(string.format("Native file digest owners: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

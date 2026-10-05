--- tests/fixtures/native_file_digest_allocations.lua
--- Native FileDigest partial-allocation ownership regression.
--- Constructor throws/nil refusals are explicitly simulated. Previously acquired
--- libuv handles, foreign timer, sha256sum child, output and closure are native.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_file_digest_allocations%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Digest, Timers = require("adapters.file_digest"), require("adapters.timer_scheduler")
local directory = assert(uv.fs_mkdtemp("/tmp/ergopti-digest-allocation-XXXXXX"))
local path = directory .. "/abc"
local file = assert(io.open(path, "wb")); assert(file:write("abc")); assert(file:close())
local foreign = Timers.every(10, function() error("foreign timer fired unexpectedly") end)
assert(foreign.armed); uv.unref(foreign.timer)
local originals = { new_pipe = uv.new_pipe, new_timer = uv.new_timer, spawn = uv.spawn }
local failures, checks = 0, 0
for _, mode in ipairs({ "raised", "nil" }) do
	for _, slot in ipairs({ 2, 3 }) do
		checks = checks + 1
		local allocated, calls, spawns, callbacks, result = {}, 0, 0, 0, nil
		local function allocate(method, ...)
			calls = calls + 1
			if calls == slot then
				if mode == "raised" then error("explicit simulated later allocation refusal") end
				return nil -- Explicit simulated constructor refusal.
			end
			local handle = originals[method](...); allocated[#allocated + 1] = handle; return handle
		end
		uv.new_pipe = function(...) return allocate("new_pipe", ...) end
		uv.new_timer = function(...) return allocate("new_timer", ...) end
		uv.spawn = function(...) spawns = spawns + 1; return originals.spawn(...) end
		local ok, err = xpcall(function()
			local dispatched = Digest.sha256(path, { owner = "allocation-regression" }, function(value, failure)
				callbacks, result = callbacks + 1, { value = value, error = failure }
			end)
			assert(dispatched == false and callbacks == 1 and result.value == nil
				and result.error == "libuv handle allocation failed", "allocation refusal changed API receipt")
			assert(spawns == 0 and not Digest.isActive("allocation-regression"), "refusal acquired a child/owner")
			local retained = 0
			for _, handle in ipairs(allocated) do if not uv.is_closing(handle) then retained = retained + 1 end end
			assert(retained == 0, "production retained " .. retained .. " actual partial allocations")
			for _ = 1, 3 do uv.run("nowait") end
			local handles = 0
			uv.walk(function(handle)
				handles = handles + 1
				assert(handle == foreign.timer, "production retained an owned native handle after drain")
			end)
			assert(handles == 1 and uv.is_active(foreign.timer) and Timers.activeCount() == 1,
				"allocation refusal damaged the foreign timer")
		end, debug.traceback)
		for key, value in pairs(originals) do uv[key] = value end
		-- Red baselines can leak; fixture cleanup occurs only after ownership assertions.
		for _, handle in ipairs(allocated) do if not uv.is_closing(handle) then uv.close(handle) end end
		for _ = 1, 3 do uv.run("nowait") end
		local name = "slot=" .. slot .. " mode=" .. mode
		if ok then print("PASS " .. name) else
			failures = failures + 1
			io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
		end
	end
end
local value, failure, callbacks, pid = nil, nil, 0, nil
uv.spawn = function(...)
	local process, child_pid, err = originals.spawn(...)
	pid = child_pid
	return process, child_pid, err
end
assert(Digest.sha256(path, { owner = "allocation-regression" }, function(hash, err)
	value, failure, callbacks = hash, err, callbacks + 1
end))
uv.spawn = originals.spawn
uv.run()
assert(callbacks == 1 and value == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" and failure == nil)
assert(type(pid) == "number" and uv.fs_stat("/proc/" .. pid) == nil, "actual sha256sum child was not reaped")
assert(not Digest.isActive("allocation-regression") and uv.is_active(foreign.timer) and Timers.activeCount() == 1)
assert(Timers.cancel(foreign)); uv.run()
local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
assert(remaining == 0, "fixture left native handles")
assert(uv.fs_unlink(path) and uv.fs_rmdir(directory))
print(string.format("digest native allocation: %d checks, %d failures; actual hash/reaping and foreign timer pass", checks, failures))
if failures > 0 then os.exit(1) end

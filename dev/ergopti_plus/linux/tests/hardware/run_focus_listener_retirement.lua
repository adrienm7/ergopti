--- tests/hardware/run_focus_listener_retirement.lua
--- ==============================================================================
--- MODULE: Native Focus Revocation Listener Retirement
--- DESCRIPTION:
--- The genuine focus transport and process owner host a protocol-only worker.
--- Listener refusals must preserve cancellation, physical cleanup and diagnostics.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")
local Json = require("json")
local ErrorDescription = require("error_description")

if arg[2] == "--worker" then
	local output = assert(io.open(arg[3], "w"))
	local control = assert(io.open(arg[4], "r"))
	local pid = assert(io.open(arg[6], "w")); assert(pid:write(tostring(uv.os_getpid()))); assert(pid:close())
	local now = uv.hrtime() / 1000000
	assert(output:write(Json.encode({ kind = "ready", sequence = 1, request = 0, at_ms = now }) .. "\n"))
	assert(output:write(Json.encode({ kind = "snapshot", sequence = 2, request = 0, at_ms = now,
		role = 61, bus = ":1.123", path = "/fixture", active_scope = true }) .. "\n"))
	assert(output:flush())
	local deadline = uv.hrtime() + 5000000000
	while not uv.fs_stat(arg[5]) and uv.hrtime() < deadline do uv.sleep(1) end
	if arg[7] == "eof" then assert(output:close()); uv.sleep(5000) end
	control:close()
	os.exit(0)
end

require("compat.utf8").install()
local Watch = require("adapters.atspi_focus_watch")
local Owned = require("adapters.owned_process")
local Logger = require("logger.shim")
local original_error = Logger.error
local failures, completed = {}, 0

local function drain(predicate)
	local deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(1)
	until uv.hrtime() > deadline
	return false
end

local function fifo_descriptors(path)
	local count = 0
	for name in uv.fs_scandir_next, assert(uv.fs_scandir("/proc/self/fd")) do
		local target = uv.fs_readlink("/proc/self/fd/" .. name)
		if target and target:sub(1, #path) == path then count = count + 1 end
	end
	return count
end

for _, trigger in ipairs({ "stop", "eof", "worker" }) do
	for _, kind in ipairs({ "string", "foreign" }) do
		local directory = assert(uv.fs_mkdtemp(assert(uv.os_tmpdir()) .. "/focus-listener-XXXXXX"))
		local signal_path, pid_path = directory .. "/go", directory .. "/pid"
		local operation, events, control, throwing, diagnostics
		diagnostics = {}
		local watcher = Watch.new({ start_process = function(executable, arguments, options, done)
			events, control = arguments[2], arguments[5]
			operation = Owned.start(executable, { root .. "/tests/hardware/run_focus_listener_retirement.lua", root,
				"--worker", events, control, signal_path, pid_path, trigger }, options, done)
			return operation
		end })
		local failure = kind == "string" and "native listener refusal" or setmetatable({}, {
			__tostring = function() error("foreign renderer refused") end,
		})
		watcher.on_change(function(snapshot) if throwing and snapshot == nil then error(failure, 0) end end)
		Logger.error = function(_, template, detail) diagnostics[#diagnostics + 1] = { template, detail } end
		local ok, detail = xpcall(function()
			assert(watcher.start())
			assert(drain(function() watcher.pump(); return watcher.snapshot() ~= nil end), "native receipt never arrived")
			assert(fifo_descriptors(events) == 1 and fifo_descriptors(control) == 1, "native FIFO descriptors must actually be held")
			assert(uv.fs_lstat(events) == nil and uv.fs_lstat(control) == nil, "ready must unlink private endpoint names")
			local file = assert(io.open(pid_path, "r")); local pid = assert(tonumber(file:read("*a"))); assert(file:close())
			throwing = true
			if trigger == "stop" then watcher.stop() else
				local signal = assert(io.open(signal_path, "w")); assert(signal:close())
				assert(drain(function() watcher.pump(); return #diagnostics > 0 end), "revocation must report its listener refusal")
			end
			assert(drain(watcher.is_settled), "native process and endpoint retirement must finish")
			assert(operation:is_settled())
			local alive, _, errno = uv.kill(pid, 0)
			assert(alive == nil and errno == "ESRCH", "the exact worker must be reaped")
			local group_alive, _, group_errno = uv.kill(-pid, 0)
			assert(group_alive == nil and group_errno == "ESRCH", "the original process group must be absent")
			assert(fifo_descriptors(events) == 0 and fifo_descriptors(control) == 0)
			assert(uv.fs_lstat(events:match("^(.*)/[^/]+$")) == nil, "the private transport directory must be removed")
			assert(#diagnostics == 1 and diagnostics[1][1] == "Native focus revocation listener failed: %s")
			assert(diagnostics[1][2] == (kind == "string" and "native listener refusal" or "error object (table)"))
			assert(watcher.snapshot() == nil and watcher.stop())
		end, function(failure) return debug.traceback(ErrorDescription.describe(failure), 2) end)
		throwing = false
		watcher.stop(); assert(drain(watcher.is_settled))
		uv.run("nowait")
		local handles = 0; uv.walk(function() handles = handles + 1 end); assert(handles == 0)
		Logger.error = original_error
		if uv.fs_stat(signal_path) then assert(uv.fs_unlink(signal_path)) end
		if uv.fs_stat(pid_path) then assert(uv.fs_unlink(pid_path)) end
		assert(uv.fs_rmdir(directory))
		if ok then completed = completed + 1 else failures[#failures + 1] = trigger .. "/" .. kind .. ": " .. detail end
	end
end
for _, failure in ipairs(failures) do io.stderr:write(failure .. "\n") end
print("Native focus listener retirement: " .. completed .. "/6 scenarios, worker/group ESRCH, zero FIFO descriptors and native handles")
assert(#failures == 0)

--- tests/hardware/run_watcher_runtime_retirement.lua
--- ==============================================================================
--- MODULE: Main Watcher Runtime Retirement Regression
--- DESCRIPTION:
--- Runs the exact Main callback/shutdown bindings with genuine native watchers
--- or finite owner receipts. A failed pump cannot erase unacknowledged cleanup.
--- ==============================================================================

local root, mode = assert(arg[1]), assert(arg[2])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Guard = require("infra.runtime_guard")
local file = assert(io.open(root .. "/ergopti_hotstrings.lua", "rb"))
local source = assert(file:read("*a")); assert(file:close())
local pump_source = assert(source:match('(if file_watchers then%s+local owner = file_watchers.-)%s+%-%- One bounded batch per tick'), "actual Main periodic watcher binding required")
local stop_source = assert(source:match('name = "file watchers",%s+wait_for_ack = true,%s+stop = (function%(%)%s+if file_watchers.-end),'), "actual Main shutdown watcher binding required")
assert(pump_source ~= "" and stop_source ~= "", "source bindings must never be vacuous")
local compile = loadstring or load
local bind = assert(compile("local file_watchers,RuntimeGuard=...\nlocal file_watchers_retiring=false\nlocal function pump()\n"
	.. pump_source .. "\nend\nlocal shutdown_stop=" .. stop_source .. "\nreturn pump,shutdown_stop,function()return file_watchers end", "@actual-main-watcher-bindings"))

if mode ~= "native" then
	local pumps, stops, acknowledged = 0, 0, false
	local owner = {
		pump = function() pumps = pumps + 1; error("controlled watcher pump failure", 0) end,
		stop = function()
			stops = stops + 1
			if acknowledged then return true end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "zero" then return 0 end
			if mode == "one" then return 1 end
			if mode == "throw" then error("controlled watcher stop failure", 0) end
			error("unknown owner receipt control")
		end,
	}
	local pump, shutdown_stop, current = bind(owner, Guard)
	pump()
	local called, result = pcall(shutdown_stop)
	print("MAIN_WATCHER_RECEIPT " .. require("json").encode({ mode=mode,retained=current()==owner,shutdown_called=called,shutdown_ack=called and result==true,pumps=pumps,stops=stops }))
	assert(current() == owner and (not called or result == false), "Main must retain every owner without literal cleanup acknowledgement")
	pump(); pump()
	assert(pumps == 1 and stops >= 4, "retirement must retry only stop, never the failed pump")
	acknowledged = true
	pump()
	assert(current() == nil and shutdown_stop() == true and pumps == 1, "literal acknowledgement must release the owner")
	return
end

local uv = require("luv")
assert(debug.getinfo(uv.new_fs_event, "S").what == "C", "actual native watchers required")
local watcher = require("infra.file_watchers")
local original_pump, original_stop = watcher.pump, watcher.stop
local directory = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-watcher-runtime-XXXXXX"))
local path = directory .. "/owned.toml"
local text = assert(io.open(path, "wb")); assert(text:write("owned=true\n")); assert(text:close())
local function native_count()
	local count = 0; uv.walk(function() count = count + 1 end); return count
end
local pumps, stops = 0, 0
local ok, failure = xpcall(function()
	watcher.start({hotstrings_dir=directory,on_reload=function() end})
	assert(native_count() > 0, "real native handles must be acquired")
	assert(original_stop() == false and native_count() > 0, "real stop must wait for physical close callbacks")
	uv.run("nowait")
	assert(original_stop() == true and native_count() == 0)
	watcher.start({hotstrings_dir=directory,on_reload=function() end})
	watcher.pump = function() pumps = pumps + 1; error("controlled watcher pump failure", 0) end
	watcher.stop = function() stops = stops + 1; return original_stop() end
	local pump, shutdown_stop, current = bind(watcher, Guard)
	pump()
	local acknowledged, retired = shutdown_stop(), original_stop()
	print("MAIN_WATCHER_NATIVE " .. require("json").encode({retained=current()==watcher,shutdown_ack=acknowledged,real_retired=retired,native_handles=native_count(),pumps=pumps,stops=stops}))
	assert(current() == watcher and acknowledged == false and retired == false,
		"Main must not acknowledge discarded native watcher retirement debt")
	pump(); pump()
	assert(pumps == 1 and stops >= 4, "pending retirement cannot resume the failed producer")
	uv.run("nowait")
	pump()
	assert(current() == nil and shutdown_stop() == true and pumps == 1)
	assert(original_stop() == true and native_count() == 0, "real native close acknowledgements must retire every handle")
end, debug.traceback)
watcher.pump, watcher.stop = original_pump, original_stop
local retired = original_stop()
if not retired then uv.run("nowait"); retired = original_stop() end
assert(retired == true and native_count() == 0, "negative baseline must also retire its actual native handles")
assert(uv.fs_unlink(path)); assert(uv.fs_rmdir(directory))
print("MAIN_WATCHER_CLEANUP native_handles=0 directory_absent=true")
assert(ok, failure)

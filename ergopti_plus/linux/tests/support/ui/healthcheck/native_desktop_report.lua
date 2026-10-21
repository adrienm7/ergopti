--- tests/support/ui/healthcheck/native_desktop_report.lua

--- ==============================================================================
--- MODULE: Real GTK Desktop Report Shutdown Probe (Linux)
--- DESCRIPTION:
--- Runs actual Report, Main coordinator, event loop and launcher. The external
--- supervisor owns the intentionally transferred application after receiving.
--- ==============================================================================

local root = assert(os.getenv("ERGOPTI_TEST_DRIVER_ROOT"))
local private = assert(os.getenv("ERGOPTI_DIAGNOSTIC_DESKTOP_PROBE_DIR"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local uv, Json = require("luv"), require("json")
local mode = assert(arg[1])
local baseline = os.getenv("ERGOPTI_DESKTOP_BASELINE_ROOT")
if baseline then
	package.loaded["ui.healthcheck.report"] = assert(loadfile(baseline .. "/ui/healthcheck/report.lua"))()
	require("tests.helpers").driver_root = function() return baseline end
end
local Report, Loop = require("ui.healthcheck.report"), require("adapters.event_loop")
local Scenario = require("tests.support.ui.healthcheck.desktop_scenario")
local original_spawn, spawned = uv.spawn, {}
uv.spawn = function(program, options, callback)
	local process, pid, reason = original_spawn(program, options, callback)
	if process then spawned[#spawned + 1] = pid end
	return process, pid, reason
end

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a"); fh:close(); return text
end

local function alive(receipt)
	local stat = read("/proc/" .. receipt.pid .. "/stat")
	if not stat then return false end
	local fields = {}
	for field in assert(stat:match("^%d+ %(.+%) (.+)$")):gmatch("%S+") do fields[#fields + 1] = field end
	return fields[20] == receipt.start_ticks and fields[1] ~= "Z" and fields[1] ~= "X"
end

local live, callbacks, answer = true, 0, nil
local admitted_at = uv.hrtime()
local request = Report.perform({ action = "open_path", id = "log_today" },
	{ log_today = private .. "/report ' literal é.txt" }, {}, {}, nil, nil, {
		current = function() return live end,
		complete = function(result) callbacks = callbacks + 1; answer = result end,
	})
local deadline, ready = uv.hrtime() + 35000000000, nil
if mode ~= "enoent" then
	local ready_deadline = uv.hrtime() + 3000000000
	repeat
		uv.run("nowait"); uv.sleep(2)
		local raw = read(private .. "/ready")
		if raw then ready = assert(Json.decode(raw)) end
	until ready or uv.hrtime() >= ready_deadline
	assert(ready and ready.gtk_window_id > 0 and alive(ready), "real GTK file handler did not map")
	assert(#spawned == 1, "exactly one driver-owned confirmation child is required")
	if not baseline then
		assert(ready.pgid ~= spawned[1], "GUI must not share the confirmation helper group")
		assert(ready.stdio_devnull == true, "desktop intent inherited a driver stream")
	end
end
if mode == "crash" then
	local parent, worker = uv.os_getpid(), assert(spawned[1])
	local function start_ticks(pid)
		local fields = {}
		for field in assert(read("/proc/" .. string.format("%d", pid) .. "/stat")):match("^%d+ %(.+%) (.+)$"):gmatch("%S+") do fields[#fields + 1] = field end
		return fields[20]
	end
	local fh = assert(io.open(private .. "/daemon-ready.tmp", "wb"))
	assert(fh:write(Json.encode({ parent_pid = parent, parent_start_ticks = start_ticks(parent),
		worker_pid = worker, worker_start_ticks = start_ticks(worker) })))
	assert(fh:close())
	assert(uv.fs_rename(private .. "/daemon-ready.tmp", private .. "/daemon-ready"))
	-- The external supervisor sends the real SIGKILL. No driver callback or
	-- rescue can earn the watchdog's eventual physical wait receipt.
	repeat uv.run("nowait"); uv.sleep(2) until uv.hrtime() >= deadline
	error("supervisor never killed the native daemon parent")
end
if mode == "normal" or mode == "deadline" or mode == "enoent" then
	repeat uv.run("nowait"); uv.sleep(5) until callbacks > 0 or uv.hrtime() >= deadline
	assert(callbacks == 1 and answer ~= nil, "launcher did not return its actual outcome")
	if mode == "normal" then assert(answer.ok == true, "normal launcher failed")
	else assert(answer.ok == false, "refused launch or deadline must not be successful") end
	if mode == "enoent" then assert(answer.exit_code == 69, "worker did not preserve its actual spawn refusal") end
	if mode == "deadline" then
		local elapsed = (uv.hrtime() - admitted_at) / 1000000
		assert(elapsed >= 30000 and elapsed < 35000, "canonical 30000ms deadline was changed")
		print(Json.encode({ mode = mode, requested_timeout_ms = 30000, observed_elapsed_ms = elapsed }))
	end
end
local opener = package.loaded["adapters.desktop_opener"]
local shutdown, observed = Scenario.shutdown({
	loaded = { ["adapters.desktop_opener"] = opener },
	webview_shutdown = function() live = false; request.cancel(); return true end,
	loop_stop = Loop.stop,
})
local original_new_idle, loop_idle = uv.new_idle, nil
uv.new_idle = function(...)
	local handle = original_new_idle(...)
	loop_idle = handle
	return handle
end
local requested = false
Loop.run({ onIdle = function()
	if not requested then requested = true; shutdown.request("desktop report shutdown control") else shutdown.poll() end
end })
uv.new_idle = original_new_idle
uv.sleep(20)
local survived = ready and alive(ready) or false
local handles, foreign_handles = 0, 0
uv.walk(function(handle)
	handles = handles + 1
	if handle ~= loop_idle then foreign_handles = foreign_handles + 1
	else assert(uv.is_closing(handle), "event loop idle close was not requested") end
end)
print(Json.encode({ mode = mode, baseline = baseline ~= nil, real_gtk_mapped = ready ~= nil,
	accepted_gui_survived_shutdown = survived, main_pending = shutdown.is_pending(), loop_stops = observed.stops,
	business_callbacks = callbacks, native_handles_at_loop_return = handles,
	helper_handles_at_loop_return = foreign_handles, worker_count = #spawned }))
assert(not shutdown.is_pending() and observed.stops == 1, "Main did not retain the exact helper retirement")
assert(callbacks == (mode == "cancel" and 0 or 1), "business publication crossed cancellation")
if ready then assert(survived, "confirmation cancellation or deadline killed the accepted GTK application") end
assert(foreign_handles == 0, "helper handles survived Main shutdown")
if opener then assert(opener.shutdown() == true, "desktop helper ledger still owns debt") end
for _, pid in ipairs(spawned) do
	local sent, _, errno = uv.kill(-pid, 0)
	assert(sent == nil and errno == "ESRCH", "driver-owned helper group survived")
end
-- EventLoop closes its own idle after its run returns. Observe that exact
-- close callback outside every native callback; no helper debt is drained here.
local drain_deadline = uv.hrtime() + 1000000000
repeat uv.run("nowait") until not uv.loop_alive() or uv.hrtime() >= drain_deadline
handles = 0
uv.walk(function() handles = handles + 1 end)
assert(handles == 0 and not uv.loop_alive(), "native fixture retained loop cleanup debt")
uv.spawn = original_spawn
print("PASS actual Main/Report desktop confirmation", mode, "native_handles=0 external_gui_lifetime=true")

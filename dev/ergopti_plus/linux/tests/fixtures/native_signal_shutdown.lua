--- tests/fixtures/native_signal_shutdown.lua
--- ==============================================================================
--- MODULE: Native Daemon Signal Shutdown Regression
--- DESCRIPTION:
--- Runs the actual daemon signal installer and final signal registry against
--- real luv watchers in an owned child without posix.signal. Repeated terminal
--- signals must retain external cleanup debt even when diagnostics throw;
--- close callbacks retire every handle.
--- ==============================================================================
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/fixtures/native_signal_shutdown%.lua$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
local uv = require("luv")

if arg[1] == "child" then
	if arg[2] == "help" then
		package.loaded["luv"] = nil
		package.preload["luv"] = function() error("fixture intentionally has no luv for CLI help") end
		package.loaded["posix.signal"] = nil
		package.preload["posix.signal"] = function() error("fixture intentionally has no posix.signal") end
		assert(require("infra.signal_handlers").is_settled(), "pure signal module load acquired native state")
		arg[0], arg[1], arg[2] = root .. "/ergopti_hotstrings.lua", "--help", nil
		dofile(root .. "/ergopti_hotstrings.lua")
		error("actual CLI help did not exit")
	end
	local file = assert(io.open(root .. "/ergopti_hotstrings.lua", "r"))
	local text = file:read("*a"); file:close()
	local installer = assert(text:match("(local function install_signal_handlers%(%).-)%s*%-%- ========================================="))
	local final = text:match("final_wait%s*=%s*(%b{})") or "{}"
	local teardown = assert(text:match('(shutdown.request%("event loop returned"%).-)%s*if file_watchers then'))
	local function compile(body, env)
		if setfenv then return setfenv(assert(loadstring(body, "actual daemon signal code")), env) end
		return assert(load(body, "actual daemon signal code", "t", env))
	end
	package.loaded["posix.signal"] = nil
	package.preload["posix.signal"] = function() error("fixture intentionally has no posix.signal") end
	local state = { ready = false, terminal = 0, reloads = 0, loops = 0, closes = 0, ticks = 0 }
	local owners = {}
	local final_registry = compile("return " .. final, setmetatable({ privacy_owners = owners }, { __index = _G }))()
	local coordinator = require("infra.shutdown_coordinator").new({
		pre_wait = { { name = "external native cleanup", wait_for_ack = true, stop = function() return state.ready end } },
		final_wait = final_registry,
		keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
		event_loop = { stop = function() state.loops = state.loops + 1; uv.stop() end },
	})
	local env = setmetatable({ shutdown = coordinator, privacy_owners = owners,
		Logger = { info = function()
			state.terminal = state.terminal + 1
			if arg[2] == "logger" then error("terminal diagnostic failed") end
		end,
			debug = function() end, error = function() end },
		injector = { close_fast_channel = function() state.closes = state.closes + 1; return true end },
		perform_reload = function() state.reloads = state.reloads + 1 end,
		tooltip_preview = false, llm_overlay = false,
	}, { __index = _G })
	if arg[2] == "partial" then
		state.ready = true
		local original, allocations = uv.new_signal, 0
		uv.new_signal = function()
			allocations = allocations + 1
			if allocations == 2 then return nil end -- Explicit native constructor refusal seam.
			return original()
		end
		env.install_signal_handlers = compile(installer .. "\nreturn install_signal_handlers", env)()
		env.event_loop = require("adapters.event_loop")
		local admission = assert(text:match("(%-%- Admit graceful terminal signals.-)\n\tBootProfiler.stage%(\"input hooks\"%)"))
		local capture_reached = false
		env.fixture_capture = function() capture_reached = true end
		local accepted, reason = pcall(compile(admission .. "\nfixture_capture()", env))
		uv.new_signal = original
		assert(not accepted and tostring(reason):find("refusing input capture", 1, true), "partial signal startup continued")
		assert(not capture_reached and allocations == 2 and state.closes == 0)
		assert(not coordinator.is_pending() and require("infra.signal_handlers").is_settled())
		uv.run() -- Outside every callback: drain the loop adapter's own closing handles.
		local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
		assert(remaining == 0, "partial signal admission retained native handles")
		print("PASS native partial: input never admitted, genuine close callbacks, zero handles")
		return
	end
	compile(installer .. "\nreturn install_signal_handlers()", env)()
	local timer = assert(uv.new_timer())
	local sent, initial_hup, late_hup = 0, false, false
	uv.timer_start(timer, 1, 5, function()
		state.ticks = state.ticks + 1
		assert(state.ticks < 300, "native signal cleanup failed to settle")
		if arg[2] == "reload" and state.reloads == 0 and not initial_hup then
			initial_hup = true; assert(uv.kill(uv.os_getpid(), "sighup")); return
		end
		if arg[2] == "reload" and state.reloads == 0 then return end
		if sent == 0 then sent = 1; assert(uv.kill(uv.os_getpid(), "sigterm")); return end
		if state.ready then coordinator.poll(); return end
		if state.terminal == 0 then return end
		assert(state.closes == 0 and state.loops == 0, "shutdown released output or loop before external ACK")
		assert(coordinator.is_pending(), "external native cleanup was not retained")
		if not late_hup then late_hup = true; assert(uv.kill(uv.os_getpid(), "sighup")); return end
		assert(state.reloads == (arg[2] == "reload" and 1 or 0), "HUP reloaded during shutdown")
		if sent < 3 then sent = sent + 1; assert(uv.kill(uv.os_getpid(), sent == 2 and "sigint" or "sigterm")); return end
		if state.terminal < 3 then return end
		state.ready = true
		coordinator.poll()
	end)
	uv.run()
	assert(not coordinator.is_pending() and state.loops == 1 and state.terminal == 3)
	compile(teardown, env)()
	assert(state.closes == 1 and require("infra.signal_handlers").is_settled())
	uv.timer_stop(timer); uv.close(timer); uv.run()
	local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
	assert(remaining == 0, "native signal child retained handles")
	print("PASS native " .. arg[2] .. ": 3 terminal signals, external ACK, final close ACK, zero handles")
	return
end

local scratch = assert(uv.fs_mkdtemp("/tmp/ergopti-native-signals-XXXXXX"))
local function remove_tree(path)
	local scan = assert(uv.fs_scandir(path))
	while true do
		local name, kind = uv.fs_scandir_next(scan)
		if not name then break end
		local child = path .. "/" .. name
		if kind == "directory" then remove_tree(child) else assert(uv.fs_unlink(child)) end
	end
	assert(uv.fs_rmdir(path))
end
local env = uv.os_environ()
env.HOME, env.XDG_CONFIG_HOME, env.XDG_CACHE_HOME, env.XDG_STATE_HOME = scratch, scratch .. "/config", scratch .. "/cache", scratch .. "/state"
env.DISPLAY, env.WAYLAND_DISPLAY, env.DBUS_SESSION_BUS_ADDRESS = "", "", ""
local environment = {}
for key, value in pairs(env) do environment[#environment + 1] = key .. "=" .. value end
for _, mode in ipairs({ "term", "reload", "partial", "help", "logger" }) do
	local result, process
	local timer = assert(uv.new_timer())
	local stdout, stderr = assert(uv.new_pipe(false)), assert(uv.new_pipe(false))
	local output, errors = "", ""
	process = assert(uv.spawn(assert(uv.exepath()), {
		args = { source, "child", mode }, env = environment, stdio = { nil, stdout, stderr },
	}, function(code, signal)
		result = { code = code, signal = signal }
		uv.close(process); uv.timer_stop(timer); uv.close(timer)
	end))
	uv.read_start(stdout, function(err, data)
		assert(not err, err)
		if data then output = output .. data; assert(#output < 65536, "unbounded fixture stdout")
		else uv.read_stop(stdout); uv.close(stdout) end
	end)
	uv.read_start(stderr, function(err, data)
		assert(not err, err)
		if data then errors = errors .. data; assert(#errors < 65536, "unbounded fixture stderr")
		else uv.read_stop(stderr); uv.close(stderr) end
	end)
	uv.timer_start(timer, 2500, 0, function() uv.process_kill(process, "sigkill") end)
	uv.run()
	if not result or result.code ~= 0 or result.signal ~= 0 then
		io.stderr:write(output, errors)
		remove_tree(scratch)
		error("native " .. mode .. " child failed: exit=" .. tostring(result and result.code) .. " signal=" .. tostring(result and result.signal))
	end
	if mode == "help" then
		assert(output:find("Usage:", 1, true) and output:find("--help", 1, true), "actual CLI help emitted no usage")
		print("PASS native help: actual Main exits zero without luv or POSIX, pure owner load")
	else io.write(output) end
end
remove_tree(scratch)
local remaining = 0; uv.walk(function() remaining = remaining + 1 end)
assert(remaining == 0, "native signal parent retained child handles")
print("Native daemon signal shutdown: 5 cases passed")

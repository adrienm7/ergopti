--- tests/hardware/run_window_switch_operation.lua

--- Actual X11 workers with explicit controlled kernel-source receipts.
require("compat.utf8").install()
local uv = require("luv")
local Switch = require("adapters.window_switch")
local pulses, result, elapsed = 0, nil, uv.hrtime()
local pump = uv.new_timer()
uv.timer_start(pump, 1, 5, function() pulses = pulses + 1 end)
local Runner = require("adapters.program_runner")
local groups, leaders, allowed = {}, {}, true
local mode = arg[3] or "normal"
local foreign, replace_transport = nil, nil
local port = setmetatable({}, { __index = uv })
port.spawn = function(executable, options, callback)
	local handle, pid = uv.spawn(executable, options, callback)
	if handle then groups[pid], leaders[pid] = true, true end
	return handle, pid
end
local reaper, cancel = nil, nil
local debt, barrier, namespace, fault = false, false, nil, nil
local preactivation = mode:match("^preactivation_") ~= nil
do
	local ffi = require("ffi")
	ffi.cdef[[int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5); int waitpid(int pid, int *status, int options);]]
	assert(ffi.C.prctl(36, 1, 0, 0, 0) == 0)
	reaper = uv.new_timer()
	uv.timer_start(reaper, 1, 5, function()
		local request = assert(uv.fs_scandir("/proc"))
		while true do
			local name = uv.fs_scandir_next(request)
			if not name then break end
			local pid = tonumber(name)
			if pid and not leaders[pid] then
				local file = io.open("/proc/" .. name .. "/stat", "rb")
				if file then
					local bytes = file:read("*a"); file:close()
					local state, parent, group
					if bytes then state, parent, group = bytes:match("%) ([A-Z]) (%d+) (%d+)") end
					if tonumber(parent) == uv.os_getpid() and groups[tonumber(group)] and state == "Z" then
						assert(ffi.C.waitpid(pid, nil, 1) == pid, "exact owned adopted child did not reap")
					end
				end
			end
		end
	end)
end
local native = setmetatable({}, { __index = uv })
native.fs_mkdtemp = function(template)
	local directory = uv.fs_mkdtemp(template)
	namespace = directory
	return directory
end
local ports = { native = native, runner = { spawn = function(executable, arguments, completed, admitted)
	if mode == "foreign_initial_start" and arguments[4] == "snapshot" then replace_transport("initial") end
	if arg[6] and arg[6] ~= "" then arguments[3] = arg[6] end
	return Runner.spawn(executable, arguments, completed, admitted, port)
end } }
local owner = Switch.new(function() return function() return allowed end end, ports)
replace_transport = function(name)
	assert(namespace and not foreign)
	local path = namespace .. "/" .. name
	local backup = namespace .. "-owned-original-" .. name
	assert(uv.fs_rename(path, backup))
	local fd = assert(uv.fs_open(path, "wx", 384))
	local marker = name == "permit" and "PERMIT 2\n" or "OWNED FOREIGN TRANSPORT\n"
	assert(uv.fs_write(fd, marker, 0) == #marker)
	local stat = assert(uv.fs_fstat(fd)); assert(uv.fs_close(fd))
	foreign = { path = path, backup = backup, dev = stat.dev, ino = stat.ino, marker = marker }
end
local physical_generation, paused, Gestures, configuration = 1, false, nil, nil
if mode == "binding" or mode == "canonical" or mode == "physical" or mode == "dispatch" or preactivation then
	-- Only injected observation ports change: production capture and admission
	-- still belong to the real manager and the actual canonical file.
	local original_new = Switch.new
	Switch.new = function(capture) return original_new(capture, ports) end
	package.loaded["adapters.keyboard_hook"] = { physical_source_receipt = function()
		return { generation = physical_generation, ready = true }
	end }
	local global_combos = 0
	package.loaded["modules.gestures.combo_emitter"] = { press = function() global_combos = global_combos + 1; return true end }
	Gestures = require("modules.gestures.manager")
	assert(Gestures.init({ persist = true, config_path = arg[4], is_paused = function() return paused end }) ~= false)
	owner = {
		run = function(_, done)
			if mode ~= "dispatch" then return Gestures.run_window_switch("tap_3", done) end
			Gestures.execute_action("alt_tab_monitor", "tap_3")
			assert(global_combos == 0, "scoped dispatcher emitted a global shortcut")
			local pending = Gestures.window_switches_pending()
			Gestures.when_window_switches_settled(function() done("settled") end)
			return pending
		end,
		stop = Gestures.stop_window_switches,
		has_pending = Gestures.window_switches_pending,
	}
end
assert(owner.run("owned_native_fixture", function(value)
	result = value
	uv.timer_stop(pump)
	uv.close(pump)
	if reaper then uv.timer_stop(reaper); uv.close(reaper) end
	if cancel then uv.timer_stop(cancel); uv.close(cancel) end
end), "native scoped operation was not accepted")
local function restore_foreign()
	if not foreign then return false end
	for group in pairs(groups) do
		local value, _, code = uv.kill(-group, 0)
		if value == 0 then return false end
		assert(code == "ESRCH", "owned group absence was not proven")
	end
	assert(owner.has_pending(), "foreign transport debt was falsely released")
	local stat = assert(uv.fs_lstat(foreign.path))
	assert(stat.dev == foreign.dev and stat.ino == foreign.ino and stat.type == "file")
	local file = assert(io.open(foreign.path, "rb")); local content = file:read("*a"); assert(file:close())
	local untouched = content == foreign.marker
	assert(uv.fs_unlink(foreign.path)); assert(uv.fs_rename(foreign.backup, foreign.path))
	foreign = nil
	assert(untouched, "worker overwrote a foreign transport inode")
	return true
end
local function guarded(callback)
	return function()
		local ok, reason = pcall(callback)
		if not ok then fault = reason; owner.stop() end
	end
end
if mode == "foreign_initial_snapshot" or mode == "foreign_digest_snapshot" or mode == "foreign_final_acknowledged" then
	cancel = uv.new_timer()
	uv.timer_start(cancel, 1, 5, guarded(function()
		if foreign then restore_foreign(); return end
		if barrier or not uv.fs_lstat(arg[5]) then return end
		barrier = true
		replace_transport(mode == "foreign_final_acknowledged" and "acknowledged" or mode:match("^foreign_(%w+)_snapshot$"))
	end))
elseif mode == "foreign_initial_start" then
	cancel = uv.new_timer()
	uv.timer_start(cancel, 1, 5, guarded(function() restore_foreign() end))
elseif preactivation then
	cancel = uv.new_timer()
	uv.timer_start(cancel, 1, 5, guarded(function()
		if foreign then restore_foreign(); return end
		if barrier or not namespace then return end
		local request = io.open(namespace .. "/request", "rb")
		if not request then return end
		local content = request:read("*a"); request:close()
		if content ~= "READY 2\n" then return end
		barrier = true
		-- This receipt exists only after the worker's last native source query.
		-- The parent has not yet issued PERMIT 2, so this is a causal race.
		local permit = assert(io.open(namespace .. "/permit", "rb"))
		assert(permit:read("*a") ~= "PERMIT 2\n", "mutation missed preactivation barrier")
		assert(permit:close())
		local replaced = mode:match("^preactivation_foreign_(%w+)$")
		if replaced then
			assert(replaced == "acknowledged" or replaced == "request" or replaced == "permit" or replaced == "digest" or replaced == "initial")
			replace_transport(replaced)
		elseif mode == "preactivation_canonical" then
			local file = assert(io.open(arg[4], "ab")); assert(file:write("\n# Pre-activation canonical edit.\n")); assert(file:close())
		elseif mode == "preactivation_physical" then
			physical_generation = 2
		elseif mode == "preactivation_pause" then
			paused = true
			debt = owner.stop() == false and owner.has_pending()
			assert(debt, "pause acknowledged physical retirement before owned worker exit")
		elseif mode == "preactivation_program_binding" then
			local scalar = require("json").encode({ version = 1, executable = "/bin/true", arguments = { "owned-program-binding" } })
			configuration = require("infra.program_binding_transaction").new({
				binding = "tap_3", scalar = scalar, path = arg[4], backup_path = arg[4] .. ".owned-program-binding",
				is_paused = function() return paused end,
			})
			local file = assert(io.open(arg[4], "rb")); local before = file:read("*a"); assert(file:close())
			assert(configuration.apply() == false, "program picker published before native window retirement")
			assert(configuration.pending() == false, "refused picker acquired a configuration lease")
			assert(Gestures.get_action("tap_3") == "alt_tab_monitor")
			file = assert(io.open(arg[4], "rb")); assert(file:read("*a") == before); assert(file:close())
			debt = owner.has_pending(); assert(debt)
		elseif mode == "preactivation_scope" then
			local file = assert(io.open(arg[4], "rb")); local before = file:read("*a"); assert(file:close())
			assert(Gestures.apply_scope("clear") == false, "scope writer entered before native window retirement")
			file = assert(io.open(arg[4], "rb")); assert(file:read("*a") == before); assert(file:close())
			debt = owner.has_pending(); assert(debt)
		elseif mode == "preactivation_set_action" then
			local file = assert(io.open(arg[4], "rb")); local before = file:read("*a"); assert(file:close())
			assert(Gestures.set_action("tap_3", "none") == false, "configuration published before native retirement")
			debt = owner.has_pending()
			assert(debt, "configuration invalidation lost owned retirement debt")
			file = assert(io.open(arg[4], "rb")); assert(file:read("*a") == before); assert(file:close())
			assert(Gestures.get_action("tap_3") == "alt_tab_monitor")
		else error("unknown preactivation fixture") end
	end))
elseif mode ~= "normal" and mode ~= "binding" and mode ~= "dispatch" then
	cancel = uv.new_timer()
	uv.timer_start(cancel, mode == "pause_focus" and 350 or 50, 0, guarded(function()
		if mode == "canonical" then
			local file = assert(io.open(arg[4], "ab")); assert(file:write("\n# Independent canonical edit.\n")); assert(file:close())
		elseif mode == "physical" then physical_generation = 2
		elseif mode == "source" then allowed = false else
			local acknowledged = owner.stop()
			debt = acknowledged == false and owner.has_pending()
			assert(debt, "cancellation falsely acknowledged physical retirement")
		end
	end))
end
uv.run()
assert(fault == nil, fault)
if preactivation or mode == "foreign_initial_snapshot" or mode == "foreign_digest_snapshot" or mode == "foreign_final_acknowledged" then assert(barrier, "native query replacement barrier was never observed")
elseif mode ~= "normal" and mode ~= "source" and mode ~= "binding" and mode ~= "canonical" and mode ~= "physical" and mode ~= "dispatch" and mode ~= "foreign_initial_start" then assert(debt) end
if mode == "preactivation_set_action" then
	assert(debt)
	assert(Gestures.set_action("tap_3", "none") == true, "configuration did not recover after exact retirement")
	assert(Gestures.get_action("tap_3") == "none")
end
if mode == "preactivation_program_binding" then
	assert(configuration.apply() == true, "program picker failed to publish after exact native retirement")
	assert(configuration.pending() == false)
	assert(Gestures.get_action("tap_3") == "run_program")
end
assert(result ~= nil, "native scoped operation did not complete")
assert(pulses >= tonumber(arg[2] or "1"), "grabbed-input pump did not progress during native work")
assert(not owner.has_pending(), "operation falsely completed with debt")
local handles = 0
uv.walk(function() handles = handles + 1 end)
assert(handles == 0, "native window owner retained live handles")
print(string.format("window_ack=%s pulses=%d elapsed_ms=%d handles=%d barrier=%s",tostring(result),pulses,math.floor((uv.hrtime()-elapsed)/1000000),handles,tostring(barrier)))
os.exit((mode == "dispatch" and result == "settled" or result == (arg[1] == "true")) and 0 or 1)

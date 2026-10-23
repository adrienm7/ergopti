--- tests/unit/adapters/installed_source/test_installed_physical_source.lua

--- ==============================================================================
--- MODULE: Installed Physical Source Task Port
--- DESCRIPTION:
--- Pins how adapters/installed_physical_source.lua serves the physical capture
--- owner over a modelled native module: a closed task set, the native clock, a
--- pulled stream with an acknowledgement backlog, and settlement that only the
--- native retirement can report.
---
--- ROOT CAUSES ENCODED: (a) a stream handle that settled when a stop was merely
--- requested would release accounting while the Console and the capture child
--- still ran; (b) a Lua-side Console would fight the launcher's for the owned
--- sockets; (c) a refused task must be a settled handle, never an exception that
--- aborts the capture owner halfway.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A manual timer: armed callbacks run only when the test ticks.
--- @return table timer { after, every, cancel, tick, armed }
local function new_timer()
	local timer, queue = { commits = true }, {}
	function timer.after(_, callback)
		local handle = { callback = callback, once = true }
		if timer.commits then queue[#queue + 1] = handle end
		return handle, timer.commits
	end
	function timer.every(_, callback)
		local handle = { callback = callback }
		if timer.commits then queue[#queue + 1] = handle end
		return handle, timer.commits
	end
	function timer.cancel(handle)
		for index, candidate in ipairs(queue) do
			if candidate == handle then table.remove(queue, index); return true end
		end
		return false
	end
	--- Runs every armed callback once; one-shot callbacks are disarmed first.
	function timer.tick()
		local current = {}
		for _, handle in ipairs(queue) do current[#current + 1] = handle end
		for _, handle in ipairs(current) do
			if handle.once then timer.cancel(handle) end
			handle.callback()
		end
	end
	function timer.armed() return #queue end
	return timer
end

--- A modelled native module whose owner records every call.
--- @return table world { native, owner, calls, ... }
local function new_world()
	local world = { calls = {}, output = {}, written = "", write_budget = nil, exit_code = nil,
		start_ok = true, stopping = false, retired_after_stop = true, acquisitions = 0, clock = {
			version = 1, domain = "mach_absolute_time", numer = 125, denom = 3 } }
	local owner = {}
	local function record(name) world.calls[#world.calls + 1] = name end
	function owner:start() record("start"); return world.start_ok end
	function owner:read()
		record("read")
		if world.read_fails then return nil end
		return table.remove(world.output, 1) or ""
	end
	function owner:write(bytes)
		record("write")
		if world.write_fails then return nil end
		local accepted = world.write_budget and math.min(world.write_budget, #bytes) or #bytes
		if world.write_budget then world.write_budget = world.write_budget - accepted end
		world.written = world.written .. bytes:sub(1, accepted)
		return accepted
	end
	function owner:request_stop() record("request_stop"); world.stopping = true end
	function owner:retired() record("retired"); return world.stopping and world.retired_after_stop end
	function owner:completion() return world.exit_code end
	function owner:shutdown() record("shutdown"); world.final = true end
	function owner:closed() return world.final == true and world.closed ~= false end
	owner.clock = function() return world.clock end
	world.owner = owner
	world.native = { acquire = function()
		world.acquisitions = world.acquisitions + 1
		if world.refuse_acquire then return nil end
		return owner
	end }
	return world
end

local LAUNCHER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

--- Loads the port over the modelled world.
--- @param tweak function|nil Receives the world before the port is built.
--- @return table port
--- @return table world
--- @return table timer
--- @return table shell Recorded shell spawns.
local function load_port(tweak)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.installed_physical_source"] = nil
	local Source = require("adapters.installed_physical_source")
	local world, timer, shell = new_world(), new_timer(), { spawns = {} }
	if tweak then tweak(world) end
	function shell.spawn(executable, args, on_done)
		shell.spawns[#shell.spawns + 1] = { executable = executable, args = args, on_done = on_done }
		return { shell = true }
	end
	local port = Source.new({
		timer = timer,
		shell = shell,
		codec = { encode = function(value)
			return string.format('{"version":%d,"domain":"%s","numer":%d,"denom":%d}', value.version, value.domain,
				value.numer, value.denom)
		end },
		resolve = function()
			if world.unresolvable then return nil, "no bundle" end
			return { launcher = LAUNCHER, native = world.native }
		end,
	})
	return port, world, timer, shell
end

--- Counts the entries of a call list.
--- @param calls table List of names.
--- @param name string Name to count.
--- @return integer count
local function count(calls, name)
	local total = 0
	for _, call in ipairs(calls) do
		if call == name then total = total + 1 end
	end
	return total
end





-- =====================================
-- =====================================
-- ======= 1/ Resolution And Set =======
-- =====================================
-- =====================================

helpers.describe("installed source port: the closed task set", function()
	helpers.it("derives the module path from the bundle-bound launcher only", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.installed_physical_source"] = nil
		local Source = require("adapters.installed_physical_source")
		helpers.assert_eq(Source.module_path(LAUNCHER),
			"/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos/adapters/native/installed_physical_source.so")
		helpers.assert_nil(Source.module_path("/usr/local/bin/ErgoptiPlus"))
		helpers.assert_nil(Source.module_path(nil))
	end)

	helpers.it("forwards only a codesign verification to the shell runner", function()
		local port, _, _, shell = load_port()
		local handle = port.spawn("/usr/bin/codesign", { "--verify", "--strict", "-R=x", LAUNCHER }, function() end)
		helpers.assert_eq(handle, { shell = true })
		helpers.assert_eq(#shell.spawns, 1)
		local refused = port.spawn("/usr/bin/codesign", { "--sign", "-", LAUNCHER })
		helpers.assert_eq(refused.start(), false)
		helpers.assert_eq(refused.isSettled(), true)
		helpers.assert_eq(#shell.spawns, 1)
	end)

	helpers.it("refuses every other executable, role and argument vector with a settled handle", function()
		local port, world = load_port()
		for _, case in ipairs({
			{ "/bin/sh", { "-c", "true" } },
			{ "/Library/Application Support/ErgoptiPlus/Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console", {} },
			{ LAUNCHER .. "x", { "--installed-physical-source" } },
			{ LAUNCHER, {} },
			{ LAUNCHER, { "--installed-physical-source", "extra" } },
			{ LAUNCHER, { "--uninstall" } },
		}) do
			local handle = port.spawn(case[1], case[2])
			helpers.assert_eq(handle.start(), false, case[1])
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(handle.wasStartAttempted(), false)
		end
		helpers.assert_eq(world.acquisitions, 0, "a refused vector must never acquire the native owner")
	end)

	helpers.it("names an unresolvable bundle instead of falling back to a shell task", function()
		local port, world, _, shell = load_port(function(w) w.unresolvable = true end)
		local available, reason = port.available()
		helpers.assert_eq(available, false)
		helpers.assert_eq(reason, "no bundle")
		helpers.assert_eq(port.spawn(LAUNCHER, { "--installed-physical-source" }).start(), false)
		helpers.assert_eq(#shell.spawns, 0)
		helpers.assert_eq(world.acquisitions, 0)
	end)

	helpers.it("reports availability without acquiring the native owner", function()
		local port, world = load_port()
		helpers.assert_eq(port.available(), true)
		helpers.assert_eq(world.acquisitions, 0)
	end)

	helpers.it("acquires the owner once for the clock and the stream, and refuses when it is withheld", function()
		local port, world = load_port()
		port.spawn(LAUNCHER, { "--hs274-clock" })
		port.spawn(LAUNCHER, { "--installed-physical-source" })
		helpers.assert_eq(world.acquisitions, 1)
		local denied, denied_world = load_port(function(w) w.refuse_acquire = true end)
		local handle = denied.spawn(LAUNCHER, { "--hs274-clock" })
		helpers.assert_eq(handle.start(), false)
		helpers.assert_eq(handle.isSettled(), true)
		helpers.assert_eq(denied_world.acquisitions, 1)
		local again = denied.spawn(LAUNCHER, { "--hs274-clock" })
		helpers.assert_eq(again.start(), false)
		helpers.assert_eq(denied_world.acquisitions, 1, "a lost owner is never re-acquired in this VM")
	end)
end)





-- =========================
-- =========================
-- ======= 2/ Clock  =======
-- =========================
-- =========================

helpers.describe("installed source port: the native clock", function()
	helpers.it("answers asynchronously with the native timebase and then settles", function()
		local port, _, timer = load_port()
		local done = {}
		local handle = port.spawn(LAUNCHER, { "--hs274-clock" }, function(code, stdout) done[#done + 1] = { code, stdout } end)
		local settled = 0
		helpers.assert_eq(handle.onSettled(function() settled = settled + 1 end), true)
		helpers.assert_eq(handle.start(), true)
		helpers.assert_eq(#done, 0, "the answer must not arrive inside start")
		helpers.assert_eq(handle.isSettled(), false)
		timer.tick()
		helpers.assert_eq(done, { { 0, '{"version":1,"domain":"mach_absolute_time","numer":125,"denom":3}\n' } })
		helpers.assert_eq(settled, 1)
		helpers.assert_eq(handle.isSettled(), true)
		helpers.assert_eq(handle.start(), false)
	end)

	helpers.it("reports a failed clock as a non-zero exit, never as a fabricated timebase", function()
		local port, _, timer = load_port(function(w) w.clock = nil end)
		local done = {}
		local handle = port.spawn(LAUNCHER, { "--hs274-clock" }, function(code, stdout) done[#done + 1] = { code, stdout } end)
		handle.start()
		timer.tick()
		helpers.assert_eq(done, { { 1, "" } })
		helpers.assert_eq(handle.isSettled(), true)
	end)

	helpers.it("settles at once, delivering nothing, when it is terminated before the answer", function()
		local port, _, timer = load_port()
		local done = 0
		local handle = port.spawn(LAUNCHER, { "--hs274-clock" }, function() done = done + 1 end)
		handle.start()
		helpers.assert_eq(handle.terminate(), true)
		helpers.assert_eq(handle.isSettled(), true)
		timer.tick()
		helpers.assert_eq(done, 0)
	end)

	helpers.it("refuses to start when its answer cannot be scheduled", function()
		local port, _, timer = load_port()
		local handle = port.spawn(LAUNCHER, { "--hs274-clock" })
		timer.commits = false
		helpers.assert_eq(handle.start(), false)
		helpers.assert_eq(handle.isSettled(), true)
	end)
end)





-- =============================
-- =============================
-- ======= 3/ The Stream =======
-- =============================
-- =============================

--- Starts a stream and returns its pieces.
--- @param tweak function|nil World tweak.
--- @return table record { handle, world, timer, chunks, exits, settled }
local function open_stream(tweak)
	local port, world, timer = load_port(tweak)
	local record = { world = world, timer = timer, port = port, chunks = {}, exits = {}, settled = 0 }
	record.handle = port.spawn(LAUNCHER, { "--installed-physical-source" },
		function(code) record.exits[#record.exits + 1] = code end,
		function(_, stdout) record.chunks[#record.chunks + 1] = stdout end)
	record.handle.onSettled(function() record.settled = record.settled + 1 end)
	return record
end

helpers.describe("installed source port: the stream", function()
	helpers.it("starts the module's owner once and pumps chunks to the consumer", function()
		local s = open_stream()
		helpers.assert_eq(s.handle.start(), true)
		helpers.assert_eq(s.handle.start(), false)
		helpers.assert_eq(count(s.world.calls, "start"), 1)
		helpers.assert_eq(s.handle.wasStartAttempted(), true)
		s.world.output = { '{"kind":"prepared"}\n', "" , '{"kind":"batch"}\n' }
		s.timer.tick()
		s.timer.tick()
		s.timer.tick()
		helpers.assert_eq(s.chunks, { '{"kind":"prepared"}\n', '{"kind":"batch"}\n' })
		helpers.assert_eq(s.handle.isSettled(), false)
	end)

	helpers.it("queues acknowledgements and writes the backlog a partial write left", function()
		local s = open_stream(function(w) w.write_budget = 4 end)
		s.handle.start()
		helpers.assert_eq(s.handle.set_input('{"ack":"1"}\n'), true)
		helpers.assert_eq(s.world.written, '{"ac')
		for _ = 1, 2 do
			s.world.write_budget = 4
			s.timer.tick()
		end
		helpers.assert_eq(s.world.written, '{"ack":"1"}\n')
	end)

	helpers.it("refuses oversized, empty or untimely acknowledgements", function()
		local s = open_stream(function(w) w.write_budget = 0 end)
		helpers.assert_eq(s.handle.set_input("x\n"), false, "not running yet")
		s.handle.start()
		helpers.assert_eq(s.handle.set_input(""), false)
		helpers.assert_eq(s.handle.set_input(string.rep("x", 65537)), false)
		helpers.assert_eq(s.handle.set_input(string.rep("x", 65536)), true)
		helpers.assert_eq(s.handle.set_input("y"), false, "the backlog is bounded")
		helpers.assert_eq(s.handle.close_input(), false)
	end)

	helpers.it("revokes the stream when a write is refused", function()
		local s = open_stream(function(w) w.write_fails = true; w.retired_after_stop = false end)
		s.handle.start()
		helpers.assert_eq(s.handle.set_input("a\n"), false)
		s.timer.tick()
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		helpers.assert_eq(s.handle.isSettled(), false)
	end)

	helpers.it("revokes the stream when a read fails and settles only on native retirement", function()
		local s = open_stream(function(w) w.read_fails = true; w.retired_after_stop = false end)
		s.handle.start()
		s.timer.tick()
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		helpers.assert_eq(s.handle.isSettled(), false, "a requested stop is not a retirement")
		s.timer.tick()
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1, "the stop is requested once")
		helpers.assert_eq(s.settled, 0)
		s.world.retired_after_stop = true
		s.timer.tick()
		helpers.assert_eq(s.handle.isSettled(), true)
		helpers.assert_eq(s.settled, 1)
		helpers.assert_eq(s.timer.armed(), 0, "a settled stream leaves no timer behind")
	end)

	helpers.it("reports the child's own exit once, then retires and settles", function()
		local s = open_stream()
		s.handle.start()
		s.world.exit_code = 70
		s.timer.tick()
		helpers.assert_eq(s.exits, { 70 })
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		helpers.assert_eq(s.handle.isSettled(), true)
		helpers.assert_eq(s.settled, 1)
	end)

	helpers.it("terminates in two steps: accepted and pending, then settled by the module", function()
		local s = open_stream(function(w) w.retired_after_stop = false end)
		s.handle.start()
		local accepted, status = s.handle.terminate()
		helpers.assert_eq({ accepted, status }, { true, "pending" })
		accepted, status = s.handle.terminate()
		helpers.assert_eq({ accepted, status }, { true, "pending" })
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		s.world.retired_after_stop = true
		accepted, status = s.handle.terminate()
		helpers.assert_eq({ accepted, status }, { true, "settled" })
		helpers.assert_eq(s.settled, 1)
		helpers.assert_eq(s.exits, {}, "a requested stop reports no exit while no code was observed")
	end)

	helpers.it("settles an unstarted stream on terminate without touching the module", function()
		local s = open_stream()
		helpers.assert_eq(s.handle.terminate(), true)
		helpers.assert_eq(s.handle.isSettled(), true)
		helpers.assert_eq(#s.world.calls, 0)
	end)

	helpers.it("keeps a refused start unsettled until the module retires its owner", function()
		local s = open_stream(function(w) w.start_ok = false; w.retired_after_stop = false end)
		helpers.assert_eq(s.handle.start(), false)
		helpers.assert_eq(s.handle.isSettled(), false)
		s.timer.tick()
		helpers.assert_eq(s.handle.isSettled(), false)
		s.world.retired_after_stop = true
		s.timer.tick()
		helpers.assert_eq(s.handle.isSettled(), true)
		helpers.assert_eq(s.settled, 1)
	end)

	helpers.it("revokes a started stream whose pump cannot be scheduled", function()
		local s = open_stream()
		s.timer.commits = false
		helpers.assert_eq(s.handle.start(), false)
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		helpers.assert_eq(s.handle.isSettled(), true)
	end)

	helpers.it("contains a raising consumer by revoking the stream", function()
		local port, world, timer = load_port(function(w) w.retired_after_stop = false end)
		local handle = port.spawn(LAUNCHER, { "--installed-physical-source" }, nil, function() error("consumer broke") end)
		handle.start()
		world.output = { "line\n" }
		timer.tick()
		helpers.assert_eq(count(world.calls, "request_stop"), 1)
		helpers.assert_eq(handle.isSettled(), false)
	end)

	helpers.it("latches no pump when a native call raises", function()
		local s = open_stream(function(w) w.retired_after_stop = false end)
		s.handle.start()
		s.world.owner.read = function() error("native error") end
		s.timer.tick()
		helpers.assert_eq(count(s.world.calls, "request_stop"), 1)
		s.world.owner.read = function() return "" end
		s.world.retired_after_stop = true
		s.timer.tick()
		helpers.assert_eq(s.handle.isSettled(), true)
	end)

	helpers.it("notifies an observer registered after settlement at once", function()
		local s = open_stream()
		s.handle.terminate()
		local seen = 0
		helpers.assert_eq(s.handle.onSettled(function() seen = seen + 1 end), true)
		helpers.assert_eq(seen, 1)
		helpers.assert_eq(s.handle.onSettled("not a function"), false)
	end)
end)





-- ============================
-- ============================
-- ======= 4/ Shutdown  =======
-- ============================
-- ============================

helpers.describe("installed source port: shutdown", function()
	helpers.it("reports closed when nothing was acquired and forwards the final request otherwise", function()
		local port, world = load_port()
		helpers.assert_eq(port.closed(), true)
		port.shutdown()
		helpers.assert_eq(count(world.calls, "shutdown"), 0)
		port.spawn(LAUNCHER, { "--hs274-clock" })
		helpers.assert_eq(port.closed(), false)
		port.shutdown()
		helpers.assert_eq(count(world.calls, "shutdown"), 1)
		helpers.assert_eq(port.closed(), true)
	end)

	helpers.it("does not report closed while the module still holds its image", function()
		local port, world = load_port(function(w) w.closed = false end)
		port.spawn(LAUNCHER, { "--hs274-clock" })
		port.shutdown()
		helpers.assert_eq(count(world.calls, "shutdown"), 1)
		helpers.assert_eq(port.closed(), false)
	end)
end)

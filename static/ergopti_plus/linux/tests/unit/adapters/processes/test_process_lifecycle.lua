--- tests/unit/adapters/processes/test_process_lifecycle.lua
---
--- ==============================================================================
--- MODULE: Process Snapshot Failures Must Not Synthesize Mass Events
--- DESCRIPTION:
--- A failed process snapshot used to read as an empty machine: the tick diffed
--- it against the last known set, firing a quit callback for EVERY known
--- process, then a launch callback for every one of them when the snapshot
--- recovered. A transient failure therefore looked like the whole desktop
--- quitting and relaunching within four seconds.
---
--- The snapshot reads the kernel's process table, /proc/<pid>/stat, in this
--- process: the `ps` it used to fork is absent from minimal Arch, Fedora and
--- openSUSE images. These tests drive the real M.start()/M.tick() over a real
--- fixture tree laid out like /proc and assert on the exact callback sequences.
--- ==============================================================================

local helpers = require("tests.helpers")
local uv = require("luv")

--- Removes a fixture tree in this process: a test that counts forks cannot
--- clean up through a shell.
--- @param path string
local function remove_tree(path)
	local stat = uv.fs_lstat(path)
	if stat == nil then return end
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_tree(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else
		assert(uv.fs_unlink(path))
	end
end

--- A real directory laid out like /proc: one numeric directory per process
--- holding its stat line. set() replaces the table, fail() removes it so a
--- listing is refused (ENOENT), as a missing or unmounted /proc would be.
--- @return table fixture { root, set(rows), fail(), retire() }
local function fake_proc()
	local base = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-proc-XXXXXX"))
	local root = base .. "/proc"
	local fixture = { root = root }
	--- @param rows table Array of names, or of { name, state } pairs.
	function fixture.set(rows)
		remove_tree(root)
		assert(uv.fs_mkdir(root, 448))
		for index, row in ipairs(rows) do
			local name, state = row, "S"
			if type(row) == "table" then name, state = row[1], row[2] end
			local pid = tostring(100 + index)
			assert(uv.fs_mkdir(root .. "/" .. pid, 448))
			local file = assert(io.open(root .. "/" .. pid .. "/stat", "wb"))
			assert(file:write(pid .. " (" .. name .. ") " .. state .. " 1 " .. pid .. " " .. pid .. " 0 -1 4194304\n"))
			assert(file:close())
		end
		-- Entries of /proc that are not processes are never read as one.
		assert(uv.fs_mkdir(root .. "/sys", 448))
		local stray = assert(io.open(root .. "/uptime", "wb"))
		assert(stray:write("1.00 2.00\n"))
		assert(stray:close())
	end
	function fixture.fail() remove_tree(root) end
	function fixture.retire() remove_tree(base) end
	return fixture
end

--- Runs body with a fresh lifecycle module reading a fake process table.
--- @param initial table|false The table at start(), or false for a failed one.
--- @param body function Receives (M, proc, launched, quit).
local function with_proc(initial, body)
	local proc = fake_proc()
	if initial then proc.set(initial) end
	local M = helpers.load_module("adapters.process_lifecycle")
	M._set_proc_root_for_test(proc.root)
	local launched, quit = {}, {}
	M.onAppLaunch(function(name) launched[#launched + 1] = name end)
	M.onAppQuit(function(name) quit[#quit + 1] = name end)
	local ok, err = pcall(body, M, proc, launched, quit)
	M.stop()
	M._set_proc_root_for_test(nil)
	proc.retire()
	if not ok then error(err, 0) end
end

local AB = { "a", "b" }
local ABC = { "a", "b", "c" }
local AC = { "a", "c" }

-- process_every = floor(2.0 / 0.25) = 8: the process poll runs on these ticks.
local PROCESS_TICK = 8

helpers.describe("linux-process-poll-demand", function()
	local function with_demand(body)
		local names = { "adapters.window_info", "infra.native_directory", "adapters.process_lifecycle" }
		local saved, queries, listing = {}, 0, { "existing" }
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		package.loaded["adapters.window_info"] = {
			focused_snapshot = function() return { appId = "editor", windowTitle = "stable" }, "x11:1" end,
		}
		local proc = fake_proc()
		local real_directory = helpers.load_module("infra.native_directory")
		package.loaded["infra.native_directory"] = {
			entries = function(path)
				queries = queries + 1
				proc.set(listing)
				return real_directory.entries(path)
			end,
		}
		local ok, failure = pcall(function()
			local lifecycle = helpers.load_module("adapters.process_lifecycle")
			lifecycle._set_proc_root_for_test(proc.root)
			body(lifecycle, function() return queries end, function(value) listing = value end)
			lifecycle.stop()
			lifecycle._set_proc_root_for_test(nil)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		proc.retire()
		helpers.assert_true(ok, tostring(failure))
	end

	helpers.it("linux-process-poll-demand: focus-only users never read the process table", function()
		with_demand(function(lifecycle, queries)
			lifecycle.onFocusChange(function() end)
			lifecycle.start()
			for tick = 1, PROCESS_TICK * 20 do lifecycle.tick(tick) end
			helpers.assert_eq(queries(), 0, "process enumeration has no consumer in the focus-only daemon")
		end)
	end)

	helpers.it("linux-process-poll-demand: a late subscriber adopts a fresh baseline before emitting changes", function()
		with_demand(function(lifecycle, queries, set_listing)
			lifecycle.start()
			lifecycle.tick(PROCESS_TICK)
			set_listing({ "current" })
			local launched, quit = {}, {}
			lifecycle.onAppLaunch(function(name) launched[#launched + 1] = name end)
			lifecycle.onAppQuit(function(name) quit[#quit + 1] = name end)
			lifecycle.tick(PROCESS_TICK * 2)
			helpers.assert_eq(queries(), 1, "the first demanded poll establishes current ownership")
			helpers.assert_eq(launched, {}, "unobserved history is not a launch")
			helpers.assert_eq(quit, {}, "unobserved history is not a quit")
			set_listing({ "next" })
			lifecycle.tick(PROCESS_TICK * 3)
			helpers.assert_eq(launched, { "next" })
			helpers.assert_eq(quit, { "current" })
		end)
	end)
end)

helpers.describe("linux-native-focus-identity", function()
	helpers.it("(linux-focus-coherent-poll) queries one native snapshot per unchanged lifecycle tick", function()
		local names = { "adapters.shell_runner", "infra.display_server", "adapters.window_info", "adapters.process_lifecycle" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, failure = pcall(function()
			local shell = helpers.load_module("adapters.shell_runner")
			local display = helpers.load_module("infra.display_server")
			display._set_for_test(display.X11, "focus poll fixture")
			local probes = 0
			shell._set_runner(function(command)
				if command:find("xdotool", 1, true) then probes = probes + 1 end
				if command:find("getactivewindow", 1, true) then return "1\n" end
				if command:find("getwindowname", 1, true) then return "Unchanged editor\n" end
				if command:find("getwindowpid", 1, true) then return "1337\n" end
				if command:find("/proc/1337/comm", 1, true) then return "editor\n" end
				return ""
			end)
			helpers.load_module("adapters.window_info")
			local lifecycle = helpers.load_module("adapters.process_lifecycle")
			lifecycle.start()
			probes = 0
			for tick = 1, 5 do lifecycle.tick(tick) end
			lifecycle.stop()
			shell._reset_runner()
			helpers.assert_eq(probes, 10, "five polls need one window ID and one title query each, never a second focus snapshot")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		helpers.assert_true(ok, tostring(failure))
	end)

	helpers.it("(linux-native-focus-identity) emits focus changes between identical metadata windows", function()
		local original = package.loaded["adapters.window_info"]
		local identity, title = "x11:1337:1", "Untitled"
		package.loaded["adapters.window_info"] = {
			focused_snapshot = function() return { appId = "editor", windowTitle = title }, identity end,
		}
		local events = {}
		local ok, failure = pcall(function()
			with_proc(AB, function(lifecycle)
				lifecycle.onFocusChange(function(app, caption) events[#events + 1] = { app, caption } end)
				lifecycle.start(); lifecycle.tick(1)
				helpers.assert_eq(#events, 0, "unchanged native focus is not a transition")
				identity = "x11:1337:2"
				lifecycle.tick(2)
				helpers.assert_eq(events, { { "editor", "Untitled" } },
					"a second native window must invalidate matcher and AI context even with identical metadata")
				title = "Private window"
				lifecycle.tick(3)
				helpers.assert_eq(events[2], { "editor", "Private window" }, "title changes still invalidate privacy context")
			end)
		end)
		package.loaded["adapters.window_info"] = original
		helpers.assert_true(ok, tostring(failure))
	end)
end)

helpers.describe("linux-process-table-receipts", function()
	helpers.it("linux-process-table-receipts: snapshots fork no program", function()
		-- Focus is answered by a stub, so any fork left is the process snapshot's.
		local original = package.loaded["adapters.window_info"]
		package.loaded["adapters.window_info"] = {
			focused_snapshot = function() return { appId = "editor", windowTitle = "stable" }, "x11:1" end,
		}
		local forked = {}
		local real_popen, real_execute = io.popen, os.execute
		io.popen = function(command) forked[#forked + 1] = command; return nil end
		os.execute = function(command) forked[#forked + 1] = command; return nil end
		local ok, failure = pcall(with_proc, ABC, function(M, proc, launched)
			M.start()
			proc.set({ "a", "b", "c", "d" })
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, { "d" }, "the in-process read still observes a launch")
		end)
		io.popen, os.execute = real_popen, real_execute
		package.loaded["adapters.window_info"] = original
		helpers.assert_true(ok, tostring(failure))
		helpers.assert_eq(forked, {}, "minimal images ship no ps: the table is read from /proc")
	end)

	helpers.it("linux-process-table-receipts: a zombie has quit before its parent reaps it", function()
		with_proc(ABC, function(M, proc, launched, quit)
			M.start()
			proc.set({ "a", "b", { "c", "Z" } })
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, { "c" }, "an exited application cannot linger as running")
			proc.set({ "a", "b", { "c", "X" } })
			M.tick(PROCESS_TICK * 2)
			helpers.assert_eq(quit, { "c" }, "a dead task is not a relaunch")
			helpers.assert_eq(launched, {})
		end)
	end)

	helpers.it("linux-process-table-receipts: a name with parentheses and spaces is read whole", function()
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.set({ "a", "b", "ep) (x y" })
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, { "ep) (x y" }, "comm ends at the last parenthesis of the stat line")
			proc.set(AB)
			M.tick(PROCESS_TICK * 2)
			helpers.assert_eq(quit, { "ep) (x y" })
		end)
	end)

	helpers.it("linux-process-table-receipts: an unreadable stat line fails the whole snapshot", function()
		with_proc(ABC, function(M, proc, launched, quit)
			M.start()
			proc.set(AB)
			local file = assert(io.open(proc.root .. "/101/stat", "wb"))
			assert(file:write("101 no parenthesis S 1\n"))
			assert(file:close())
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, {}, "a format the reader does not know cannot prove a quit")
			helpers.assert_eq(launched, {})
		end)
	end)

	helpers.it("linux-process-table-receipts: a process gone between listing and read is absent, not a failure", function()
		with_proc(ABC, function(M, proc, launched, quit)
			M.start()
			proc.set(AC)
			-- A listed process whose stat has vanished: the kernel answers ENOENT.
			assert(uv.fs_mkdir(proc.root .. "/999", 448))
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, { "b" }, "the vanished entry is skipped and the real delta still fires")
			helpers.assert_eq(launched, {})
		end)
	end)
end)

helpers.describe("linux-process-snapshot-receipts", function()
	helpers.it("linux-process-snapshot-receipts: a failed table cannot replace a successful baseline", function()
		with_proc(ABC, function(M, proc, launched, quit)
			M.start()
			proc.fail()
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, {}, "an unreadable table cannot prove any process quit")
			helpers.assert_eq(launched, {})
			proc.set(AC)
			M.tick(PROCESS_TICK * 2)
			helpers.assert_eq(quit, { "b" }, "recovery diffs only the last successful baseline")
			helpers.assert_eq(launched, {}, "a failure cannot synthesize a recovery launch")
		end)
	end)
	helpers.it("linux-process-snapshot-receipts: a failed table cannot seed startup ownership", function()
		with_proc(false, function(M, proc, launched, quit)
			M.start()
			proc.set(ABC)
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, {}, "the first trustworthy snapshot silently adopts existing processes")
			helpers.assert_eq(quit, {})
		end)
	end)
end)

helpers.describe("linux-process-header-receipts", function()
	helpers.it("linux-process-header-receipts: COMMAND launches and quits as an ordinary process", function()
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.set({ "a", "b", "COMMAND" })
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, { "COMMAND" }, "no reader header can reserve a legitimate application name")
			proc.set(AB)
			M.tick(PROCESS_TICK * 2)
			helpers.assert_eq(quit, { "COMMAND" })
		end)
	end)
end)

helpers.describe("linux-process-name-byte-receipts", function()
	for index, name in ipairs({ " ep lead", "ep trail ", " ep both ", "   " }) do
		helpers.it("linux-process-name-byte-receipts: native whitespace case " .. index .. " launches and quits exactly", function()
			with_proc(AB, function(M, proc, launched, quit)
				M.start()
				proc.set({ "a", "b", name })
				M.tick(PROCESS_TICK)
				helpers.assert_eq(launched, { name }, "native name bytes cannot be treated as column padding")
				proc.set(AB)
				M.tick(PROCESS_TICK * 2)
				helpers.assert_eq(quit, { name })
			end)
		end)
	end
	helpers.it("linux-process-name-byte-receipts: a live neighbor cannot hide a distinct whitespace identity", function()
		with_proc({ "a", "b", "ep pair" }, function(M, proc, launched, quit)
			M.start()
			proc.set({ "a", "b", "ep pair", " ep pair " })
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, { " ep pair " })
			proc.set({ "a", "b", "ep pair" })
			M.tick(PROCESS_TICK * 2)
			helpers.assert_eq(quit, { " ep pair " }, "trimmed alias cannot hide the neighbor's real retirement")
			proc.set(AB)
			M.tick(PROCESS_TICK * 3)
			helpers.assert_eq(quit, { " ep pair ", "ep pair" })
		end)
	end)
end)

helpers.describe("process_lifecycle: a failed snapshot fires nothing (ps-storm)", function()

	helpers.it("ps-storm: a failed table reports no quits and no launches", function()
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.fail()
			M.tick(PROCESS_TICK)
			helpers.assert_eq(#quit, 0,
				"a failed snapshot is not an empty machine — quitting every process is fabricated")
			helpers.assert_eq(#launched, 0,
				"and nothing launched either")
		end)
	end)

	helpers.it("ps-storm: recovery after a failure reports only the real delta", function()
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.fail()
			M.tick(PROCESS_TICK)
			proc.set(ABC)
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, {},
				"no process quit across a failed table and its recovery")
			helpers.assert_eq(launched, { "c" },
				"only the genuinely new process reports as launched")
		end)
	end)

	helpers.it("ps-storm: an empty table is a failure, not an empty desktop", function()
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.set({})
			M.tick(PROCESS_TICK)
			helpers.assert_eq(#quit, 0,
				"a table without one process must not quit every known process")
			helpers.assert_eq(#launched, 0)
		end)
	end)

	helpers.it("ps-storm: the ordinary diff still reports real launches and quits", function()
		-- Without this, the cases above pass on a module that never diffs at
		-- all — which is precisely the failure being fenced here, one level down.
		with_proc(AB, function(M, proc, launched, quit)
			M.start()
			proc.set(ABC)
			M.tick(PROCESS_TICK)
			helpers.assert_eq(launched, { "c" }, "a real launch must still fire")
			proc.set(AC)
			M.tick(PROCESS_TICK)
			helpers.assert_eq(quit, { "b" }, "a real quit must still fire")
		end)
	end)

end)

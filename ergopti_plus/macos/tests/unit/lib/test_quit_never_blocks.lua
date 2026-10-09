--- tests/unit/lib/test_quit_never_blocks.lua

--- ==============================================================================
--- MODULE: A User Quit Can Never Hang the App
--- DESCRIPTION:
--- Menubar Quit intermittently left ErgoptiPlus "not responding" until it was
--- killed in Activity Monitor (hs-quit-never-blocks).
---
--- ROOT CAUSE ENCODED:
--- 1. The quit teardown shelled out synchronously on the Hammerspoon main thread:
---    hs.execute(cmd, true) runs a login AND interactive shell with no timeout
---    (three pkill sweeps plus a pgrep/lsof sweep), and the MLX listener proof
---    ran two synchronous lsof commands even when no server had been started.
--- 2. Nothing bounded the asynchronous stages: a lease fence or synthetic-input
---    drain that never settled kept the process alive forever, and a fence
---    failure silently cancelled the quit.
---
--- The first half drives the real menu_llm sweeps with every synchronous
--- process primitive rigged to throw. The second drives the real coordinator and
--- EmergencyExit with never-settling stages and fires the armed deadline.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ No Synchronous Shell-Out =======
-- ===========================================
-- ===========================================

--- Runs fn with every synchronous process primitive replaced by a recorder
--- that throws, so a regression both fails loudly and is counted.
--- @param fn function Body to run.
--- @return table blocked Recorded synchronous calls.
local function with_blocking_primitives_forbidden(fn)
	local blocked = {}
	local saved_execute, saved_popen = os.execute, io.popen
	local saved_hs_execute = hs.execute
	local function forbid(name)
		return function(command)
			blocked[#blocked + 1] = name .. ": " .. tostring(command)
			error("synchronous " .. name .. " on the quit path: " .. tostring(command))
		end
	end
	os.execute = forbid("os.execute")
	io.popen = forbid("io.popen")
	hs.execute = forbid("hs.execute")
	local ok, err = xpcall(fn, debug.traceback)
	os.execute, io.popen, hs.execute = saved_execute, saved_popen, saved_hs_execute
	if not ok then error(err, 0) end
	return blocked
end

helpers.describe("quit teardown helper sweeps never block (hs-quit-never-blocks)", function()
	helpers.it("(hs-quit-never-blocks) LLM helper and orphan MLX sweeps are async tasks", function()
		helpers.with_stub_scope({ "adapters.shell_runner", "ui.menu.menu_llm" }, function()
			local spawns = {}
			package.loaded["adapters.shell_runner"] = {
				_active_tasks = {},
				spawn = function(executable, arguments, on_done)
					local record = { executable = executable, arguments = arguments,
						on_done = on_done, started = false }
					spawns[#spawns + 1] = record
					return { start = function() record.started = true; return true end }
				end,
			}
			local MenuLLM = helpers.load_with_stubs("ui.menu.menu_llm")
			local helper_result, orphan_result
			local blocked = with_blocking_primitives_forbidden(function()
				helper_result = MenuLLM.terminate_helper_processes()
				orphan_result = MenuLLM.terminate_orphan_mlx_server()
			end)

			helpers.assert_eq(blocked, {}, "no synchronous process primitive may run at Quit")
			helpers.assert_eq(helper_result, true)
			helpers.assert_eq(orphan_result, true)
			helpers.assert_eq(#spawns, 5, "three helper sweeps plus two orphan MLX sweeps")
			for _, record in ipairs(spawns) do
				helpers.assert_true(record.executable:sub(1, 1) == "/",
					"sweeps must use absolute binaries: " .. tostring(record.executable))
				helpers.assert_true(record.started, "every sweep must actually be dispatched")
				helpers.assert_eq(record.on_done, nil,
					"a completion callback could log after the exit-time sink was finalized")
				for _, argument in ipairs(record.arguments) do
					helpers.assert_true(argument ~= "-l" and argument ~= "-i"
						and argument ~= "-li" and argument ~= "-il",
						"no login or interactive shell may run at Quit")
				end
			end
			local listener = spawns[5]
			helpers.assert_eq(listener.executable, "/bin/sh")
			helpers.assert_true(listener.arguments[2]:find("/usr/sbin/lsof -nP -tiTCP:3460", 1, true) ~= nil,
				"the listener sweep must skip DNS/port-name resolution")
			-- with_stub_scope restores the cache too; explicit for the suite ratchet
			package.loaded["adapters.shell_runner"] = nil
		end)
	end)

	helpers.it("(hs-quit-never-blocks) a refused sweep is reported, never waited on", function()
		helpers.with_stub_scope({ "adapters.shell_runner", "ui.menu.menu_llm" }, function()
			package.loaded["adapters.shell_runner"] = {
				_active_tasks = {},
				spawn = function()
					return { start = function() return false end }
				end,
			}
			local MenuLLM = helpers.load_with_stubs("ui.menu.menu_llm")
			local result
			local blocked = with_blocking_primitives_forbidden(function()
				result = MenuLLM.terminate_helper_processes()
			end)
			helpers.assert_eq(blocked, {})
			helpers.assert_eq(result, false, "a refused dispatch must be an explicit failure")
			package.loaded["adapters.shell_runner"] = nil
		end)
	end)
end)





-- =============================================
-- =============================================
-- ======= 2/ Bounded User Quit Deadline =======
-- =============================================
-- =============================================

--- Loads the real coordinator and EmergencyExit over exact stage doubles.
--- @param options table Stage behavior.
--- @return table coordinator
--- @return table calls
local function load_coordinator(options)
	local calls = { exits = {}, fatal_exits = {}, errors = {}, teardowns = 0 }
	local function noop() end
	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop, success = noop, done = noop,
		error = function(_, fmt, ...)
			calls.errors[#calls.errors + 1] = string.format(fmt, ...)
		end,
	}
	package.loaded["infra.emergency_exit"] = nil
	package.loaded["infra.termination_coordinator"] = nil
	local coordinator = require("infra.termination_coordinator")
	helpers.assert_true(coordinator.init({
		request_lease = function(_, callback)
			calls.lease_callback = callback
			if options.lease == "fenced" then callback(true, "stopped") end
			if options.lease == "failed" then callback(false, "stop-timeout") end
			return true
		end,
		drain_input = function(callback)
			calls.input_callback = callback
			if options.input ~= "never" then callback() end
			return true
		end,
		teardown = function()
			calls.teardowns = calls.teardowns + 1
			return true
		end,
		begin_drain = function(callback) callback(true, "drained"); return true end,
		finalize_teardown = function() return true end,
		reload = function() return true end,
		exit = function(code) calls.exits[#calls.exits + 1] = code end,
		fatal_exit = function(code) calls.fatal_exits[#calls.fatal_exits + 1] = code end,
		fatal_exit_code = 70,
		schedule = function(delay, callback)
			calls.deadline = delay
			calls.deadline_callback = callback
			return { stop = function() calls.deadline_stopped = true; return true end }
		end,
		user_exit_deadline_seconds = require("infra.timings").sec("ui", "user_quit_deadline_ms"),
		mark_reload = function() return true end,
		clear_reload = function() return true end,
	}))
	return coordinator, calls
end

--- Returns the forced-exit diagnostic, if any.
--- @param calls table Coordinator call record.
--- @return string|nil
local function forced_exit_message(calls)
	for _, message in ipairs(calls.errors) do
		if message:find("Forcing process exit", 1, true) then return message end
	end
	return nil
end

helpers.describe("user quit has one global deadline (hs-quit-never-blocks)", function()
	helpers.it("(hs-quit-never-blocks) force-exits a lease fence that never settles", function()
		helpers.with_fresh_modules({
			"infra.logger", "infra.emergency_exit", "infra.termination_coordinator",
		}, function()
			local coordinator, calls = load_coordinator({ lease = "never" })
			helpers.assert_eq(coordinator.request_user_exit("menu_quit"), true)
			helpers.assert_eq(calls.deadline, 12,
				"the deadline comes from the shared timing registry")
			helpers.assert_eq(#calls.fatal_exits, 0, "nothing exits before the deadline")

			calls.deadline_callback()
			helpers.assert_eq(calls.fatal_exits, { 70 },
				"a stuck quit must end with the non-zero fatal status")
			helpers.assert_eq(calls.teardowns, 0,
				"F17 consumers stay live: native stdin EOF revokes the lease")
			local message = forced_exit_message(calls)
			helpers.assert_true(message ~= nil
				and message:find("karabiner-lease-fence", 1, true) ~= nil,
				"the forced exit must name the stuck stage: " .. tostring(message))
		end)
	end)

	helpers.it("(hs-quit-never-blocks) force-exits a synthetic-input drain that never settles", function()
		helpers.with_fresh_modules({
			"infra.logger", "infra.emergency_exit", "infra.termination_coordinator",
		}, function()
			local coordinator, calls = load_coordinator({ lease = "fenced", input = "never" })
			helpers.assert_eq(coordinator.request_user_exit("menu_quit"), true)
			helpers.assert_eq(#calls.fatal_exits, 0)
			calls.deadline_callback()
			helpers.assert_eq(calls.fatal_exits, { 70 })
			local message = forced_exit_message(calls)
			helpers.assert_true(message ~= nil
				and message:find("synthetic-input-drain", 1, true) ~= nil,
				"the forced exit must name the stuck stage: " .. tostring(message))
		end)
	end)

	helpers.it("(hs-quit-never-blocks) a failed lease fence exits instead of cancelling Quit", function()
		helpers.with_fresh_modules({
			"infra.logger", "infra.emergency_exit", "infra.termination_coordinator",
		}, function()
			local coordinator, calls = load_coordinator({ lease = "never" })
			coordinator.request_user_exit("menu_quit")
			calls.lease_callback(false, "stop-timeout")
			helpers.assert_eq(calls.fatal_exits, { 70 },
				"a user quit must not silently keep the app running")
			helpers.assert_true(calls.deadline_stopped, "the fired fallback retires the deadline")
		end)
	end)

	helpers.it("(hs-quit-never-blocks) a settling quit exits zero before the deadline", function()
		helpers.with_fresh_modules({
			"infra.logger", "infra.emergency_exit", "infra.termination_coordinator",
		}, function()
			local coordinator, calls = load_coordinator({ lease = "never" })
			helpers.assert_eq(coordinator.request_user_exit("menu_quit"), true)
			calls.lease_callback(true, "stopped")
			-- The double returns where os.exit never does, so only the first
			-- terminal is the one production would take
			helpers.assert_eq(calls.exits[1], 0, "a normal user quit keeps status zero")
			helpers.assert_eq(calls.teardowns, 1)
			helpers.assert_eq(forced_exit_message(calls), nil,
				"a settling quit must not reach the deadline fallback first")
		end)
	end)
end)

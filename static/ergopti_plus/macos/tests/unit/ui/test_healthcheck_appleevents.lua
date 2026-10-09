--- tests/unit/ui/test_healthcheck_appleevents.lua

--- ==============================================================================
--- MODULE: External AppleEvent Diagnostic Ownership Controls
--- DESCRIPTION:
--- The actual host body runs over inert ShellRunner and scheduler ports. These
--- controls do not acquire a native process, change a setting or send an event.
--- ==============================================================================

local helpers = require("tests.helpers")
local MODULE = "ui.healthcheck.appleevents"
local FIXTURE_MODULES = { MODULE, "adapters.shell_runner", "adapters.timer_scheduler", "infra.logger" }
local NONCE = "00000000000000000000000000000001"

local function with_probe(options, body)
	options = options or {}
	local saved_shell = package.loaded["adapters.shell_runner"]
	local saved_hs = hs
	helpers.with_stub_scope(FIXTURE_MODULES, function()
		local world = { now = 0, tasks = {}, timers = {}, replies = {}, cancelled = 0, log = {} }
		package.loaded["infra.logger"] = {
			trace = function() end, done = function() end,
			error = function(_, text) world.log[#world.log + 1] = text end,
		}
		hs = {
			processInfo = { processID = 41, bundlePath = "/owned/Example.app", bundleID = "owned.example",
				executablePath = "/owned/Example.app/Contents/MacOS/Hammerspoon" },
			host = { uuid = function() return NONCE end },
			timer = { absoluteTime = function() return world.now * 1e6 end },
			allowAppleScript = function(...)
				assert(select("#", ...) == 0, "Diagnostics must never call the scripting setter")
				return options.allowed ~= false
			end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			now_ns = function() return world.now * 1e6 end,
			after = function(delay, callback)
				if options.timer_refused then return nil, false end
				local held = { callback = callback, delay = delay }
				world.timers[#world.timers + 1] = held
				return held, true
			end,
			onSettled = function(held, callback) held.observer = callback return true end,
			cancel = function(held)
				if options.stop_refused then return false end
				held.stopped = true
				if held.observer then held.observer() end
				return true
			end,
		}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, completed, chunk, environment, private)
				assert(executable == "/usr/bin/osascript" and chunk == nil and environment == nil and private == true)
				local task = { args = args, completed = completed, settled = false }
				world.tasks[#world.tasks + 1] = task
				local handle = {
					isSettled = function() return task.settled end,
					onSettled = function(callback) task.observer = callback return true end,
					terminate = function()
						world.cancelled = world.cancelled + 1
						return not options.terminate_refused, "pending"
					end,
					start = function()
						if options.start_refused then task.settled = true return false end
						if options.synchronous then
							task.settled = true
							completed(0, "OK:41:" .. NONCE .. "\n", "")
							if task.observer then task.observer() end
						end
						return true
					end,
				}
				return handle
			end,
		}
		package.loaded[MODULE] = nil
		local probe = require(MODULE)
		function world.start()
			local cancellation
			local operation = probe.body({ timeout_ms = 10000 })
			local actor = operation(function(result) world.replies[#world.replies + 1] = result end,
				function(cancel) cancellation = cancel end, options.origin or 0)
			return actor, cancellation, operation
		end
		function world.complete(code, stdout, stderr)
			local task = assert(world.tasks[1])
			task.settled = true
			task.completed(code, stdout, stderr)
			if task.observer then task.observer() end
		end
		local okay, failure = pcall(body, probe, world)
		hs = saved_hs
		if not okay then error(failure, 0) end
	end)
	package.loaded["adapters.shell_runner"] = saved_shell
	hs = saved_hs
end

helpers.describe("healthcheck: owned normal AppleEvent diagnostic", function()
	helpers.it("acknowledges the exact PID/nonce only after native closure", function()
		with_probe({}, function(probe, world)
			local actor = world.start()
			helpers.assert_eq(#world.replies, 0)
			helpers.assert_eq(world.tasks[1].args[2]:find('tell application "/owned/Example.app"', 1, true) ~= nil, true)
			helpers.assert_eq(world.tasks[1].args[3], "return tostring(hs.processInfo.processID) .. ':" .. NONCE .. "'")
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(world.replies[1].state, "ok")
			helpers.assert_eq(world.replies[1].cleanup, "settled")
			helpers.assert_eq(actor.snapshot().native_status, 0)
			helpers.assert_eq(world.replies[1].native_status, 0)
			helpers.assert_eq(world.replies[1].runtime_pid, 41)
			helpers.assert_eq(actor.snapshot().runtime_pid, 41)
			helpers.assert_eq(world.replies[1].sender_context, "driver_spawned_osascript")
			helpers.assert_eq(actor.snapshot().sender_context, "driver_spawned_osascript")
			helpers.assert_eq(world.replies[1].qualification_scope, "local_runtime_nonce")
			helpers.assert_eq(actor.snapshot().qualification_scope, "local_runtime_nonce")
			helpers.assert_eq(probe.active_count(), 0)
		end)
	end)
	helpers.it("retains synchronous completion until the actual start return", function()
		with_probe({ synchronous = true }, function(probe, world)
			world.start()
			helpers.assert_eq(#world.replies, 1)
			helpers.assert_eq(world.replies[1].state, "ok")
			helpers.assert_eq(probe.active_count(), 0)
		end)
	end)
	helpers.it("distinguishes typed missing consent, native timeout and malformed output", function()
		for _, row in ipairs({
			{ "ERR:-1743\n", "error", "permission_refused", -1743 },
			{ "ERR:-1744\n", "error", "consent_required", -1744 },
			{ "ERR:-1712\n", "timeout", "native_timeout", -1712 },
			{ "ERR:-50\n", "error", "native_refused", -50 },
			{ "ERR:-1743junk\n", "error", "native_output_refused" },
			{ "ERR:-01743\n", "error", "native_output_refused" },
			{ "ERR:-2147483649\n", "error", "native_output_refused" },
			{ "OK:42:" .. NONCE .. "\n", "error", "native_output_refused" },
			{ "OK:41:foreign\n", "error", "native_output_refused" },
			{ "OK:41:" .. NONCE .. "\nEXTRA\n", "error", "native_output_refused" },
		}) do
			with_probe({}, function(_, world)
				local actor = world.start()
				world.complete(0, row[1], "")
				helpers.assert_eq(world.replies[1].state, row[2])
				helpers.assert_eq(world.replies[1].detail, row[3])
				helpers.assert_eq(actor.snapshot().native_status, row[4])
				helpers.assert_eq(world.replies[1].native_status, row[4])
			end)
		end
	end)
	helpers.it("never infers permission from a native exit or private stderr", function()
		with_probe({}, function(_, world)
			local actor = world.start()
			world.complete(1, "", "PRIVATE -1743")
			helpers.assert_eq(world.replies[1].detail, "native_exit")
			helpers.assert_eq(actor.snapshot().native_status, nil)
			helpers.assert_eq(#world.log, 0)
		end)
	end)
	helpers.it("rejects expired success under the same original deadline", function()
		with_probe({}, function(_, world)
			world.start()
			world.now = 10000
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(world.replies[1].state, "timeout")
		end)
	end)
	helpers.it("does not restart the caller's original clock during setup", function()
		with_probe({}, function(_, world)
			world.now = 6000
			world.start()
			helpers.assert_eq(world.timers[1].delay, 4)
			world.now = 10000
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(world.replies[1].state, "timeout")
		end)
	end)
	helpers.it("retains refused process termination and rejects its late success", function()
		with_probe({ terminate_refused = true }, function(probe, world)
			local actor, cancel = world.start()
			cancel()
			helpers.assert_eq(world.replies[1].state, "cancelled")
			helpers.assert_eq(actor.snapshot().cleanup, "pending")
			helpers.assert_eq(probe.active_count(), 1)
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(#world.replies, 1)
			helpers.assert_eq(world.replies[1].state, "cancelled")
			helpers.assert_eq(actor.snapshot().cleanup, "settled")
			helpers.assert_eq(probe.active_count(), 0)
		end)
	end)
	helpers.it("keeps timer close debt and never restores success on a late ACK", function()
		local options = { stop_refused = true }
		with_probe(options, function(probe, world)
			local actor, cancel = world.start()
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(world.replies[1].state, "error")
			helpers.assert_eq(world.replies[1].detail, "cleanup_debt")
			helpers.assert_eq(actor.snapshot().cleanup, "pending")
			helpers.assert_eq(probe.active_count(), 1)
			options.stop_refused = false
			cancel()
			helpers.assert_eq(actor.snapshot().cleanup, "settled")
			helpers.assert_eq(world.replies[1].state, "error")
			helpers.assert_eq(probe.active_count(), 0)
		end)
	end)
	helpers.it("does not start native work when scripting is disabled", function()
		with_probe({ allowed = false }, function(probe, world)
			world.start()
			helpers.assert_eq(world.replies[1].state, "not_run")
			helpers.assert_eq(world.replies[1].detail, "scripting_disabled")
			helpers.assert_eq(#world.tasks, 0)
			helpers.assert_eq(probe.active_count(), 0)
		end)
	end)
	helpers.it("does not invent a PID when native identity is invalid", function()
		for _, invalid in ipairs({ 0, -1, 41.5, "41" }) do
			with_probe({}, function(probe, world)
				hs.processInfo.processID = invalid
				local actor = world.start()
				helpers.assert_eq(world.replies[1].state, "not_run")
				helpers.assert_eq(world.replies[1].detail, "runtime_identity_unavailable")
				helpers.assert_eq(world.replies[1].runtime_pid, nil)
				helpers.assert_eq(actor.snapshot().runtime_pid, nil)
				helpers.assert_eq(#world.tasks, 0)
				helpers.assert_eq(probe.active_count(), 0)
			end)
		end
	end)
	helpers.it("refuses a failed timer or native start without losing an owner", function()
		for _, options in ipairs({ { timer_refused = true }, { start_refused = true } }) do
			with_probe(options, function(probe, world)
				world.start()
				helpers.assert_eq(world.replies[1].state, "error")
				helpers.assert_eq(world.replies[1].cleanup, "settled")
				helpers.assert_eq(probe.active_count(), 0)
			end)
		end
	end)
	helpers.it("rejects changed runtime identity, duplicate claim and invalid timing", function()
		with_probe({}, function(probe, world)
			local _, cancel, operation = world.start()
			local retained_task, retained_timer = world.tasks[1], world.timers[1]
			local function assert_unchanged_owner()
				helpers.assert_eq(#world.tasks, 1)
				helpers.assert_eq(#world.timers, 1)
				helpers.assert_eq(world.tasks[1], retained_task)
				helpers.assert_eq(world.timers[1], retained_timer)
				helpers.assert_eq(retained_task.settled, false)
				helpers.assert_eq(retained_timer.stopped, nil)
				helpers.assert_eq(#world.replies, 0)
				helpers.assert_eq(world.cancelled, 0)
				helpers.assert_eq(probe.active_count(), 1)
			end
			local duplicate_ok, duplicate_error = pcall(operation, function() end, function() end, 0)
			helpers.assert_eq(duplicate_ok, false)
			helpers.assert_eq(type(duplicate_error), "string")
			helpers.assert_eq(duplicate_error:match("Diagnostic body already claimed$"), "Diagnostic body already claimed")
			assert_unchanged_owner()
			local timing_ok, timing_error = pcall(probe.body, { timeout_ms = 0 })
			helpers.assert_eq(timing_ok, false)
			helpers.assert_eq(type(timing_error), "string")
			helpers.assert_eq(timing_error:match("Invalid diagnostic timing$"), "Invalid diagnostic timing")
			assert_unchanged_owner()
			hs.processInfo.processID = 42
			world.complete(0, "OK:41:" .. NONCE .. "\n", "")
			helpers.assert_eq(world.replies[1].detail, "runtime_identity_changed")
			helpers.assert_eq(world.replies[1].runtime_pid, 41)
			cancel()
		end)
	end)
end)

--- tests/unit/platform/remap/test_lease_heartbeat_constructor_owner.lua

--- ==============================================================================
--- MODULE: Lease Heartbeat Constructor Ownership
--- DESCRIPTION:
--- Uses the actual controller and retained task/timer fixture at the READY boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.lease_controller_fixture")

local function recurring(ctx, live_only)
	local result = {}
	for _, timer in ipairs(ctx.timers) do
		if timer.repeating and (not live_only or not timer.cancelled) then result[#result + 1] = timer end
	end
	return result
end

helpers.describe("lease heartbeat constructor ownership", function()
	helpers.it("rolls back a timer whose constructor reentrantly stops its owning generation", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			local calls = 0
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				calls = calls + 1
				assert(controller.stop("constructor-stop"))
				return timer, committed
			end
			controller.start_paused()
			if calls == 0 then ctx.chunk(1, "READY\n") end
			assert(calls == 1 and #recurring(ctx, false) == 1)
			assert(#recurring(ctx, true) == 0, "Constructor return cannot publish a stopped generation timer")
			local count = #ctx.spawns[1].inputs
			recurring(ctx, false)[1].fn()
			assert(#ctx.spawns[1].inputs == count)
		end)
	end)

	helpers.it("rolls back a timer whose constructor replaces the current generation", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			local first = true
			local original
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				if first then
					first = false
					original = controller.token()
					assert(controller.stop("constructor-replace"))
					assert(controller.start_paused())
				end
				return timer, committed
			end
			controller.start_paused()
			if first then ctx.chunk(1, "READY\n") end
			assert(controller.token() ~= original and #ctx.spawns >= 2)
			ctx.chunk(2, "READY\n")
			assert(controller.status() == "paused" and #recurring(ctx, true) == 1,
				"Only the exact successor may retain its cadence")
			local all = recurring(ctx, false)
			assert(#all == 2)
			local old_count, new_count = #ctx.spawns[1].inputs, #ctx.spawns[2].inputs
			all[1].fn()
			assert(#ctx.spawns[1].inputs == old_count and #ctx.spawns[2].inputs == new_count)
		end)
	end)


	helpers.it("does not publish successful readiness after its constructor stops", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			local results, phases = {}, {}
			controller.init(function(phase) phases[#phases + 1] = phase end)
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				assert(controller.stop("constructor-stop"))
				return timer, committed
			end
			assert(controller.start_paused(function(ok) results[#results + 1] = ok end))
			ctx.chunk(1, "READY\n")
			assert(#results == 1 and results[1] == false)
			assert(controller.status() == "stopping")
			for _, phase in ipairs(phases) do assert(phase ~= "active" and phase ~= "paused") end
			assert(#recurring(ctx, true) == 0)
			assert(#ctx.spawns == 1 and ctx.spawns[1].inputs[1] == "STOP\n")
		end)
	end)

	helpers.it("rolls back after its constructor reports genuine worker completion failure", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local results = {}
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				ctx.complete(1, 73)
				return timer, committed
			end
			assert(controller.start_paused(function(ok) results[#results + 1] = ok end))
			ctx.chunk(1, "READY\n")
			assert(#results == 0, "Actual failure callbacks stay pending until the original fallback fence")
			assert(controller.status() == "fencing")
			assert(#recurring(ctx, false) == 1 and #recurring(ctx, true) == 0)
			local old, fallback = #ctx.spawns[1].inputs, #ctx.spawns[2].inputs
			recurring(ctx, false)[1].fn()
			assert(#ctx.spawns[1].inputs == old and #ctx.spawns[2].inputs == fallback)
			ctx.complete(2, 0)
			assert(#results == 1 and results[1] == false)
		end)
	end)

	helpers.it("retains exact failed rollback debt outside the stopped generation timer slot", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			local retained
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				assert(controller.stop("constructor-debt"))
				ctx.cancel_target, ctx.cancel_failures, retained = timer, 1, timer
				return timer, committed
			end
			assert(controller.start_paused())
			ctx.chunk(1, "READY\n")
			assert(retained.cancel_attempts == 1 and not retained.cancelled)
			local count = #ctx.spawns[1].inputs
			retained.fn()
			assert(#ctx.spawns[1].inputs == count)
			assert(controller.status() == "stopping")
			assert(retained.cancel_attempts == 2 and retained.cancelled)
		end)
	end)

	helpers.it("does not fail a superseded stopped owner when constructor commit was refused", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			scheduler.every = function(delay, fn)
				local timer = every(delay, fn)
				assert(controller.stop("constructor-refused"))
				return timer, false
			end
			assert(controller.start_paused())
			ctx.chunk(1, "READY\n")
			assert(controller.status() == "stopping")
			assert(#ctx.spawns == 1, "Stale constructor refusal cannot create a second failure fence")
			assert(#recurring(ctx, false) == 1 and #recurring(ctx, true) == 0)
		end)
	end)

	helpers.it("keeps STOP and guardian retirement behind the original fence while exact rollback debt settles", function()
		support.with_fixture(function(load)
			local controller, ctx = load()
			controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local every = scheduler.every
			local retained, stopped, stop_reason
			scheduler.every = function(delay, fn)
				local timer, committed = every(delay, fn)
				assert(controller.stop("constructor-fence", function(ok, reason)
					stopped, stop_reason = ok, reason
				end))
				ctx.cancel_target, ctx.cancel_failures, retained = timer, 1, timer
				return timer, committed
			end
			assert(controller.start_paused())
			ctx.chunk(1, "READY\n")
			assert(retained.cancel_attempts == 1 and stopped == nil)
			local removed, removal_reason
			assert(controller.unregister_guardian(function(ok, reason)
				removed, removal_reason = ok, reason
			end) == false)
			assert(removed == false and removal_reason == "guardian-owner-busy")
			assert(#ctx.spawns == 1 and stopped == nil)
			retained.fn()
			assert(#ctx.spawns[1].inputs == 1 and stopped == nil)
			assert(controller.status() == "stopping" and retained.cancelled)
			assert(stopped == nil, "Exact timer cleanup is not native STOPPED authority")
			ctx.chunk(1, "STOPPED\n")
			assert(stopped == true and stop_reason == "stopped")
			assert(controller.unregister_guardian(function(ok) removed = ok end))
			assert(#ctx.spawns == 2 and ctx.spawns[2].args[1] == "--unregister-remap-guardian")
			ctx.complete(2, 0, "unregistered\n")
			assert(removed == true)
		end)
	end)
	helpers.it("ACK constructor cannot overwrite its reentrant STOP watchdog", function()
		support.with_fixture(function(load)
			local controller, ctx = load(); controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, first, stop_timer = scheduler.after, true, nil
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 4 and first then first = false; assert(controller.stop("ack-constructor")) end
				if delay == 7 then stop_timer = timer end
				return timer, committed
			end
			assert(controller.start_paused())
			assert(controller.status() == "stopping" and stop_timer)
			stop_timer.fired = true; stop_timer.fn()
			assert(#ctx.spawns == 2, "The actual retained STOP deadline must start its existing fallback fence")
		end)
	end)
	helpers.it("heartbeat retry constructor must retire a handle after reentrant STOP", function()
		support.with_fixture(function(load)
			local controller, ctx = load(); controller.init(); assert(controller.start_paused());ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, retry = scheduler.after, nil
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 1 then retry = timer;assert(controller.stop("retry-constructor")) end
				return timer, committed
			end
			ctx.chunk(1, "PING_FAILED 1\n")
			assert(controller.status() == "stopping" and retry)
			assert(retry.cancelled, "Stopped owner cannot retain a heartbeat retry candidate")
		end)
	end)

	helpers.it("rolls back the original READY deadline after authentic reentrant READY", function()
		support.with_fixture(function(load)
			local controller, ctx = load(); controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, ready_timer = scheduler.after, nil
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 4 then ready_timer = timer;ctx.chunk(1, "READY\n") end
				return timer, committed
			end
			local started = 0
			assert(controller.start_paused(function(ok) assert(ok);started = started + 1 end))
			assert(started == 1 and controller.status() == "paused")
			assert(ready_timer.cancelled, "Acknowledged READY cannot retain its returned stale deadline")
			ready_timer.fn()
			assert(controller.status() == "paused")
			ctx.fire_heartbeat_timer();assert(ctx.spawns[1].inputs[1] == "PING 1\n")
		end)
	end)

	helpers.it("preserves the retiring STOP watchdog while an ACK constructor installs a live successor", function()
		support.with_fixture(function(load)
			local controller, ctx = load(); controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, first, stale, stop_timer = scheduler.after, true, nil, nil
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 7 then stop_timer = timer end
				if delay == 4 and first then
					first, stale = false, timer
					assert(controller.stop("ack-replace"));assert(controller.start_paused());ctx.chunk(2, "READY\n")
				end
				return timer, committed
			end
			assert(controller.start_paused())
			assert(controller.status() == "paused" and stale.cancelled and stop_timer)
			stop_timer.fired = true;stop_timer.fn()
			assert(#ctx.spawns == 3 and ctx.spawns[3].args[1] == "--karabiner-lease-revoke")
			assert(controller.status() == "paused")
			ctx.fire_heartbeat_timer();assert(ctx.spawns[2].inputs[1] == "PING 1\n")
		end)
	end)

	helpers.it("does not retain a negative-heartbeat retry after genuine reentrant RESUMED recovery", function()
		support.with_fixture(function(load)
			local controller, ctx = load();controller.init();assert(controller.start_paused());ctx.chunk(1, "READY\n")
			ctx.fire_heartbeat_timer()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, retry, resumed = scheduler.after, nil, 0
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 1 then
					retry = timer;assert(controller.resume(function(ok) assert(ok);resumed = resumed + 1 end));ctx.chunk(1, "RESUMED\n")
				end
				return timer, committed
			end
			ctx.chunk(1, "PING_FAILED 1\n")
			assert(controller.status() == "active" and resumed == 1 and retry)
			assert(retry.cancelled, "Clean mode recovery retires the returned negative-heartbeat retry")
			local count = #ctx.spawns[1].inputs;retry.fn();assert(#ctx.spawns[1].inputs == count)
		end)
	end)

	helpers.it("does not turn a superseded uncommitted ACK candidate into a new failure fence", function()
		support.with_fixture(function(load)
			local controller, ctx = load();controller.init()
			local scheduler = package.loaded["adapters.timer_scheduler"]
			local after, first, stale, stop_timer = scheduler.after, true, nil, nil
			scheduler.after = function(delay, fn)
				local timer, committed = after(delay, fn)
				if delay == 7 then stop_timer = timer end
				if delay == 4 and first then
					first, stale = false, timer;assert(controller.stop("uncommitted-ack"));return timer, false
				end
				return timer, committed
			end
			assert(controller.start_paused())
			assert(controller.status() == "stopping" and #ctx.spawns == 1 and stale.cancelled)
			stop_timer.fired = true;stop_timer.fn();assert(#ctx.spawns == 2)
		end)
	end)
end)

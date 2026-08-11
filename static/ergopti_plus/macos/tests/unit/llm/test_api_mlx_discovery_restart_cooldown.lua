--- tests/unit/llm/test_api_mlx_discovery_restart_cooldown.lua

--- ==============================================================================
--- MODULE: MLX Discovery — Inter-Cycle Cooldown
--- DESCRIPTION:
--- A failed discovery cycle used to restart itself on the very next run-loop
--- tick. finish_discovery(false) clears the in-flight mutex and then fires every
--- queued callback synchronously; each one is a warmup that re-tests
--- is_discovered() — still false on the failure path — and calls discover()
--- again inline. The new cycle then re-initialises BOTH pacing variables, so the
--- exponential backoff was reset before it ever applied and the retry landed
--- immediately: a curl + HTTP storm on the main thread, happening precisely when
--- the server is not answering.
---
--- The backoff that already existed paces probes WITHIN a cycle. Nothing paced
--- the cycles themselves, and a cycle is what the failure path restarts.
---
--- WHAT IS PINNED:
---   1. A second discover() inside the cooldown window arms no new probe.
---   2. It is DEFERRED, not dropped — the caller's on_done still runs. Refusing
---      outright would strand every warmup queued behind it, which is the bug
---      the callback queue exists to prevent.
---   3. reset() clears the cooldown. reset() means the server changed — a
---      relaunch, a model switch — so the next probe concerns a DIFFERENT server
---      and must not wait out a delay earned by the previous one.
---
--- The clock and the scheduler are controlled, not real: a test that waits for
--- a cooldown is a slow test that passes for the wrong reason on a loaded CI box.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ Controlled environment ========
-- ==========================================
-- ==========================================

--- Installs a scheduler whose clock the test drives and whose timers never fire
--- on their own, plus the network stubs discovery needs to fail cleanly.
--- @return table env { now, advance, timers, probes, discovery }
local function make_env()
	local env = { now = 1000, timers = {}, probes = 0, next_timer_id = 0 }

	package.loaded["adapters.timer_scheduler"] = {
		now = function() return env.now end,
		after = function(delay, fn)
			env.next_timer_id = env.next_timer_id + 1
			local handle = { id = env.next_timer_id }
			env.timers[#env.timers + 1] = { delay = delay, fn = fn, handle = handle }
			return handle, true
		end,
		cancel = function(handle)
			for i, timer in ipairs(env.timers) do
				if timer.handle == handle then
					table.remove(env.timers, i)
					break
				end
			end
			return nil
		end,
		activeCount = function() return #env.timers end,
	}

	-- Every probe fails, which is the path that retries.
	package.loaded["adapters.http_client"] = {
		new = function()
			return {
				post = function(_, _, _, _, cb)
					env.probes = env.probes + 1
					if cb then cb({ status = 404, body = "" }) end
				end,
				get = function(_, _, _, cb)
					env.probes = env.probes + 1
					if cb then cb({ status = 404, body = "" }) end
				end,
			}
		end,
	}

	--- Drives the current cycle to its FAILED end.
	---
	--- do_poll gives up once `now - started_at >= DISCOVERY_MAX_WAIT_SEC` and calls
	--- finish_discovery(false) — the path that used to restart immediately. Taking
	--- that branch needs no shell stub at all, which is why the clock is jumped
	--- rather than the curl chain simulated.
	function env.finish_cycle()
		env.now = env.now + 200      -- past the 180 s discovery_max_wait
		for i, t in ipairs(env.timers) do
			table.remove(env.timers, i)
			t.fn()
			return true
		end
		return false
	end

	--- Runs the timer whose recorded delay is `delay`, advancing the clock by it.
	--- @param delay number|nil When nil, runs the first pending timer.
	function env.fire(delay)
		for i, t in ipairs(env.timers) do
			if delay == nil or math.abs(t.delay - delay) < 0.001 then
				table.remove(env.timers, i)
				env.now = env.now + t.delay
				t.fn()
				return true
			end
		end
		return false
	end

	-- Loaded by a plain require AFTER the stubs are installed, not through
	-- load_with_stubs: the module captures its HTTP client at require time
	-- (`local _probe_client = require("adapters.http_client").new()`), and
	-- load_with_stubs resets the stub table it would have to capture.
	package.loaded["modules.llm.api_mlx_discovery"] = nil
	env.discovery = require("modules.llm.api_mlx_discovery")
	return env
end




-- ==========================================
-- ==========================================
-- ======= 2/ The cooldown ==================
-- ==========================================
-- ==========================================

helpers.describe("MLX discovery: a failed cycle does not restart on the next tick", function()

	helpers.it("a re-entry inside the window arms no new probe", function()
		local env = make_env()
		env.discovery.reset()

		local original_callbacks = 0
		local retry_callbacks = 0
		env.discovery.discover(function()
			original_callbacks = original_callbacks + 1
			-- This is the production shape: api_mlx.warmup() is the completion
			-- callback and re-enters discovery while fan-out is still draining.
			env.discovery.discover(function() retry_callbacks = retry_callbacks + 1 end)
		end)
		-- Let the cycle FAIL. Without this the second discover() would be refused by
		-- the pre-existing in-flight mutex and the test would pass without the
		-- cooldown existing at all.
		env.finish_cycle()
		helpers.assert_eq(original_callbacks, 1, "the failed cycle must answer its waiter")
		helpers.assert_eq(retry_callbacks, 0,
			"the re-entrant waiter belongs to the deferred cycle, not the failed one")
		helpers.assert_eq(#env.timers, 1,
			"the callback's re-entry must arm exactly one deferred timer after fan-out")

		-- The DELAY is what distinguishes the two outcomes, not the count. Without a
		-- cooldown discover() arms its poll with TimerScheduler.after(0, do_poll) —
		-- the next run-loop tick, which IS the storm. With one it arms the deferred
		-- retry seconds out. Counting timers passes either way, which is how the
		-- first version of this test passed with the cooldown removed.
		local armed = env.timers[#env.timers]
		helpers.assert_true(armed.delay > 1, string.format(
			"the retry after a failed cycle was armed at %.3fs. A delay of 0 means the "
				.. "cycle restarts on the very next run-loop tick with the backoff reset — "
				.. "a curl + HTTP storm on the main thread, happening exactly when the "
				.. "server is not answering.", armed.delay))
	end)

	helpers.it("the deferred cycle is scheduled, not dropped", function()
		local env = make_env()
		env.discovery.reset()
		env.discovery.discover(function() end)
		env.finish_cycle()

		local before = #env.timers
		env.discovery.discover(function() end)
		helpers.assert_true(#env.timers > before,
			"the refused cycle must be re-armed through the scheduler — dropping it strands "
				.. "every warmup queued behind it, which is what the callback queue exists "
				.. "to prevent")

		-- And firing it must actually start the probe chain, so the deferral is a
		-- delay and not a quiet drop with a timer to show for it.
		local deferred = env.timers[#env.timers]
		env.now = env.now + deferred.delay
		table.remove(env.timers)
		deferred.fn()
		helpers.assert_true(#env.timers > 0,
			"firing the deferred retry must arm the poll — otherwise the cycle was dropped "
				.. "after all and every queued warmup is stranded")
	end)

	helpers.it("reset() clears the cooldown so a new server is not made to wait", function()
		local env = make_env()
		env.discovery.reset()
		env.discovery.discover(function() end)
		env.finish_cycle()

		-- A model switch or a server relaunch. The next probe is about a different
		-- server and must not wait out a delay the previous one earned.
		env.discovery.reset()
		local before = #env.timers
		env.discovery.discover(function() end)
		helpers.assert_true(#env.timers > before, "reset() then discover() must arm something")
		local armed = env.timers[#env.timers]
		helpers.assert_true(armed.delay < 1, string.format(
			"after reset() the poll was armed at %.3fs — it must be immediate. reset() means "
				.. "a different server, so waiting out a cooldown earned by the previous one "
				.. "delays the model the user just switched TO.", armed.delay))
	end)

end)





-- ==========================================
-- ==========================================
-- ======= 3/ The constant is shared ========
-- ==========================================
-- ==========================================

helpers.describe("MLX discovery: the cooldown is a registry value", function()

	helpers.it("reads discovery_retry_cooldown_ms from the shared timings registry", function()
		-- A literal here would be a fourth pacing number in a file that already has
		-- three, and the only one not visible to the cross-driver timings gate.
		-- Selected by a declaration unique to modules/llm/api_mlx_discovery.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function read_active_model_arg")
		helpers.assert_true(src ~= nil, "modules/llm/api_mlx_discovery.lua source must be locatable")
		helpers.assert_true(src:find('Timings%.sec%("llm", "discovery_retry_cooldown_ms"%)') ~= nil,
			"the cooldown must come from the shared timings registry, not a literal")
	end)

end)

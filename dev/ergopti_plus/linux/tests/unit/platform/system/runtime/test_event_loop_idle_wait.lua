--- tests/unit/platform/system/runtime/test_event_loop_idle_wait.lua

--- ==============================================================================
--- MODULE: Event Loop Idle Wait Tests
--- DESCRIPTION:
--- libuv polls with a zero timeout while an idle handle is active, so the luv
--- loop used to spin a whole core (measured 99.997 % of one core, 180 000 idle
--- ticks per second, with nothing to do). The tick now yields: it sleeps on the
--- input descriptors when the daemon supplies a wait, and a fixed millisecond
--- otherwise. The ceilings below count idle ticks over a real libuv run, which
--- are two orders of magnitude apart, so they hold on a loaded machine.
---
--- The tick sleeps before libuv polls, so an event libuv watches used to wait
--- the wait out first: an owned archive download, one 64 KiB chunk per file
--- write acknowledgement, ran at 3 MB/s (two 8 ms waits per chunk). The wait
--- now polls the loop's backend descriptor too, and a callback that restarts a
--- reader skips the next wait (wake()). The last block counts the waits that
--- timed out over real chains of those events.
--- ==============================================================================

local helpers = require("tests.helpers")
local ok_luv, luv = pcall(require, "luv")

--- Runs the real loop for `window_ms` and counts its idle ticks.
--- @param options table Extra run options (idleWait).
--- @param window_ms number Run length.
--- @return number ticks, table loop
local function count_ticks(options, window_ms)
	local loop = helpers.load_module("core.events.loop")
	local ticks, started = 0, luv.hrtime()
	local run_options = { onIdle = function()
		ticks = ticks + 1
		if (luv.hrtime() - started) / 1e6 >= window_ms then loop.stop() end
	end }
	for key, value in pairs(options or {}) do run_options[key] = value end
	loop.run(run_options)
	return ticks, loop
end

if not ok_luv then
	helpers.describe("event loop idle wait", function()
		helpers.it("needs the real luv backend", function()
			helpers.assert_true(false, "the unit lane installs luv; this module measures its real loop")
		end)
	end)
	return
end

helpers.describe("event loop idle wait: the luv idle tick yields", function()
	helpers.it("does not spin without an input wait (about a millisecond per tick)", function()
		local ticks = count_ticks(nil, 300)
		helpers.assert_true(ticks > 0)
		-- A spinning loop ran tens of thousands of ticks in this window.
		helpers.assert_true(ticks < 5000, "idle loop spun: " .. ticks .. " ticks in 300 ms")
	end)

	helpers.it("sleeps in the supplied wait and passes it the cadence bound", function()
		local sleep = require("core.timing.engine.native_sleep").bind(require("ffi"))
		local requested = {}
		local ticks = count_ticks({ idleWait = function(timeout_ms)
			requested[#requested + 1] = timeout_ms
			sleep(timeout_ms / 1000)
			return false
		end }, 300)
		helpers.assert_true(#requested > 0, "the wait was never consulted")
		helpers.assert_eq(requested[1], 8, "bounded by the loop's cadence")
		helpers.assert_true(ticks < 500, "wait did not slow the tick: " .. ticks .. " ticks")
	end)

	helpers.it("counts input wakes and quiet waits", function()
		local loop = helpers.load_module("core.events.loop")
		local perf = require("core.logger.engine.perf_counters")
		perf._reset_for_test()
		local answers, calls = { true, false, true }, 0
		loop.run({
			onIdle = function() if calls >= #answers then loop.stop() end end,
			idleWait = function() calls = calls + 1; return answers[calls] end,
		})
		local counts = perf.snapshot().counts
		helpers.assert_eq(counts["loop.idle_wakes_input"], 2)
		helpers.assert_eq(counts["loop.idle_timeouts"], 1)
	end)

	helpers.it("falls back to the fixed yield when the wait declines", function()
		local declined = 0
		local ticks = count_ticks({ idleWait = function() declined = declined + 1; return nil end }, 300)
		helpers.assert_true(declined > 0)
		helpers.assert_true(ticks < 5000, "declined wait spun the loop: " .. ticks .. " ticks")
	end)

	helpers.it("drops a raising wait after one report and keeps running", function()
		local raised = 0
		local ticks = count_ticks({ idleWait = function() raised = raised + 1; error("wait refused") end }, 200)
		helpers.assert_eq(raised, 1, "a raising wait must be dropped, not retried on every tick")
		helpers.assert_true(ticks > 1 and ticks < 5000)
	end)

	helpers.it("returns at once when a callback stops the loop", function()
		local loop = helpers.load_module("core.events.loop")
		local waited = 0
		loop.run({ onIdle = function() loop.stop() end, idleWait = function() waited = waited + 1; return false end })
		helpers.assert_eq(waited, 0, "stop() must not be followed by a wait")
	end)

	helpers.it("refuses a wait that is not a function", function()
		local loop = helpers.load_module("core.events.loop")
		helpers.assert_throws(function() loop.run({ onIdle = function() end, idleWait = 8 }) end)
		helpers.assert_true(not loop.isRunning())
	end)
end)

-- A real libuv chain under the daemon's own wait: a quiet FIFO stands in for the
-- keyboard, as in test_evdev_reader_wait_any, and the loop's companion joins it.
if package.config:sub(1, 1) == "/" and pcall(require, "ffi") then
	--- Runs `step` as a chain of `cycles` libuv events under the real wait and
	--- counts the waits that timed out instead of ending on the event.
	--- @param setup function(loop, finish) Starts the chain; calls finish() at its end.
	--- @return integer timeouts, integer wakes
	local function count_timeouts(setup)
		local reader = helpers.load_module("platform.input.evdev_reader")
		local loop = helpers.load_module("core.events.loop")
		local perf = require("core.logger.engine.perf_counters")
		local keyboard = os.tmpname()
		os.remove(keyboard)
		local made = os.execute("mkfifo '" .. keyboard .. "'")
		helpers.assert_true(made == true or made == 0, "mkfifo failed")
		helpers.assert_true(reader.use_ffi_backend())
		helpers.assert_true(reader.open(keyboard, reader.KEYBOARD))
		local quiet_writer = luv.fs_open(keyboard, "w", 438)
		perf._reset_for_test()
		local done = false
		setup(loop, function() done = true end)
		local started = luv.hrtime()
		loop.run({
			onIdle = function()
				-- A ceiling, not a timing assertion: a broken chain cannot hang the suite.
				if done or (luv.hrtime() - started) / 1e6 > 10000 then loop.stop() end
			end,
			idleWait = function(timeout_ms, companion)
				return reader.wait_any_readable(timeout_ms, companion and { companion } or nil)
			end,
		})
		local counts = perf.snapshot().counts
		luv.fs_close(quiet_writer)
		reader.close(reader.KEYBOARD)
		reader._reset_backend()
		os.remove(keyboard)
		helpers.assert_true(done, "the chain did not finish")
		return counts["loop.idle_timeouts"] or 0, counts["loop.idle_wakes_requested"] or 0
	end

	helpers.describe("event loop idle wait: libuv events end the wait", function()
		helpers.it("hands the wait a companion on the loop's backend descriptor", function()
			local loop = helpers.load_module("core.events.loop")
			local seen, ticks = nil, 0
			loop.run({
				onIdle = function()
					ticks = ticks + 1
					if seen or ticks > 20 then loop.stop() end
				end,
				idleWait = function(_, companion) seen = companion; return false end,
			})
			helpers.assert_type(seen, "table")
			local records, count = seen.begin()
			helpers.assert_eq(count, 1)
			helpers.assert_eq(records[0].fd, luv.backend_fd(), "the loop's own epoll descriptor")
			helpers.assert_eq(records[0].events, 1, "polled for POLLIN")
			seen.finish()
		end)

		helpers.it("ends the wait on a thread-pool completion instead of timing it out", function()
			local cycles = 40
			local timeouts = count_timeouts(function(_, finish)
				local left = cycles
				local function next_stat()
					left = left - 1
					if left < 0 then finish(); return end
					luv.fs_stat("/", next_stat)
				end
				next_stat()
			end)
			-- Before the companion every completion waited out the 8 ms wait: one
			-- timeout per cycle. A few may still come from scheduling noise.
			helpers.assert_true(timeouts < cycles / 4, timeouts .. " of " .. cycles .. " completions timed the wait out")
		end)

		--- The download's own pattern: a reader paused while its chunk is written,
		--- data arriving meanwhile (libuv then drops the stopped descriptor from
		--- epoll), and the reader restarted one poll later by the acknowledgement.
		--- @param wake boolean Whether the restart calls loop.wake().
		--- @return integer timeouts, integer wakes
		local function paused_reader(wake)
			-- Refused up front: a raise inside the libuv check callback below
			-- would not reach the runner.
			helpers.assert_type(helpers.load_module("core.events.loop").wake, "function")
			local cycles = 30
			-- A FIFO opened read-write never blocks, whatever the luv version.
			local path = os.tmpname()
			os.remove(path)
			local made = os.execute("mkfifo '" .. path .. "'")
			helpers.assert_true(made == true or made == 0, "mkfifo failed")
			local read_fd = luv.fs_open(path, "r+", 438)
			local write_fd = luv.fs_open(path, "w", 438)
			local pipe = luv.new_pipe(false)
			helpers.assert_true(pipe:open(read_fd) ~= nil)
			local check = luv.new_check()
			local timeouts, wakes = count_timeouts(function(loop, finish)
				local left, polls = cycles, nil
				local function on_read(err, data)
					helpers.assert_nil(err)
					if not data then return end
					pipe:read_stop()
					left = left - 1
					if left <= 0 then finish(); return end
					luv.fs_write(write_fd, "x") -- The next chunk lands while paused.
					polls = 2 -- This poll's check, then the one after libuv drops the descriptor.
				end
				check:start(function()
					if not polls then return end
					polls = polls - 1
					if polls > 0 then return end
					polls = nil
					pipe:read_start(on_read)
					if wake then loop.wake() end
				end)
				luv.fs_write(write_fd, "x")
				pipe:read_start(on_read)
			end)
			check:stop()
			check:close()
			pipe:close()
			luv.fs_close(write_fd)
			while luv.loop_alive() do luv.run("once") end
			os.remove(path)
			return timeouts, wakes, cycles
		end

		helpers.it("lets a reader restarted with wake() read on the next poll", function()
			local timeouts, wakes, cycles = paused_reader(true)
			helpers.assert_true(wakes >= cycles - 1, "the restarts asked for " .. wakes .. " wakes")
			helpers.assert_true(timeouts < cycles / 4, timeouts .. " of " .. cycles .. " restarts timed the wait out")
		end)

		helpers.it("times the wait out for that restart without wake() (control)", function()
			-- What the download did before: libuv registers the restarted reader
			-- only on its next poll, which no descriptor announces.
			local timeouts, wakes, cycles = paused_reader(false)
			helpers.assert_eq(wakes, 0)
			helpers.assert_true(timeouts >= cycles / 2, "only " .. timeouts .. " of " .. cycles .. " restarts timed out")
		end)

		helpers.it("skips one wait per wake() and none once stopped", function()
			local loop = helpers.load_module("core.events.loop")
			local ticks, waits = 0, 0
			loop.run({
				onIdle = function()
					ticks = ticks + 1
					if ticks == 1 then loop.wake() elseif ticks == 3 then loop.stop() end
				end,
				idleWait = function() waits = waits + 1; return false end,
			})
			helpers.assert_eq(waits, 1, "the woken tick skipped its wait, the next one waited")
			loop.wake()
			local later = 0
			loop.run({
				onIdle = function() later = later + 1; if later == 2 then loop.stop() end end,
				idleWait = function() waits = waits + 1; return false end,
			})
			helpers.assert_eq(waits, 2, "a wake() outside a run is not carried into the next one")
		end)
	end)
end

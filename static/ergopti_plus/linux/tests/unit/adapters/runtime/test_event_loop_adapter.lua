--- tests/unit/adapters/runtime/test_event_loop_adapter.lua
---
--- Unit tests for the event_loop adapter (luv/pump dual-path).
--- Tests the full API surface (run/stop/isRunning/HAS_LUV) with mock callbacks
--- so the adapter can be verified without luv or a real daemon.
---
--- Strategy:
--- 1. Structural: verify module shape (exports, HAS_LUV boolean).
--- 2. Pump fallback: run() with mock onIdle + onPeriodic, call stop() from
---    inside onIdle on the N-th iteration, assert callback counts.
--- 3. Edge cases: double-run is no-op, stop-when-not-running is safe,
---    callback exceptions don't crash the loop.

local helpers = require("tests.helpers")
local native_ok, native_luv = pcall(require, "luv")
local function load_pump_loop()
  return helpers.load_module_with_dependency("adapters.event_loop", "luv", false)
end
local el = load_pump_loop()

--- Models actual idle readiness and timer deadlines with an independent clock.
--- @param refusal table|nil Optional role/kind of one refused native admission.
--- @return table loop, table state, table backend
local function bounded_native_fixture(refusal)
	local state = { handles = {}, starts = {}, clock = 0, stops = 0, idle_starts = 0, updates = 0, phase = "outside" }
	local backend = {}
	local function refused(role, kind)
		if not refusal or refusal.role ~= role or refusal.kind ~= kind then return false end
		if refusal.receipt == "throw" then error("controlled " .. role .. " " .. kind .. " refusal") end
		return true
	end
	local function create(kind)
		local role = kind == "prepare" and "prepare" or "pump"
		if kind == "timer" then
			for _, handle in ipairs(state.handles) do
				if not handle.closed and handle.role == "pump" then role = "periodic" end
			end
		end
		if refused(role, "allocation") then
			if refusal.receipt == "false" then return false end
			return nil
		end
		local handle = { kind = kind, role = role }
		state.handles[#state.handles + 1] = handle
		return handle
	end
	function backend.new_idle() return create("idle") end
	function backend.new_timer() return create("timer") end
	function backend.new_prepare() return create("prepare") end
	function backend.update_time() state.updates = state.updates + 1 end
	local function start(handle, callback)
		if refused(handle.role, "start") then
			if refusal.receipt == "false" then return false, "controlled start refusal" end
			return nil, "controlled start refusal"
		end
		handle.active, handle.callback = true, callback
		return 0
	end
	function backend.idle_start(handle, callback)
		state.idle_starts = state.idle_starts + 1
		return start(handle, callback)
	end
	function backend.prepare_start(handle, callback) return start(handle, callback) end
	function backend.timer_start(handle, delay, interval, callback)
		handle.role = delay == 0 and interval == 1 and "pump" or "periodic"
		state.starts[#state.starts + 1] = { role = handle.role, delay = delay, interval = interval, updates = state.updates }
		handle.due, handle.interval = state.clock + delay, interval
		return start(handle, callback)
	end
	function backend.idle_stop(handle) assert(handle.kind == "idle"); handle.active = false; handle.stopped_by = "idle"; return 0 end
	function backend.timer_stop(handle) assert(handle.kind == "timer"); handle.active = false; handle.stopped_by = "timer"; return 0 end
	function backend.prepare_stop(handle) assert(handle.kind == "prepare"); handle.active = false; handle.stopped_by = "prepare"; return 0 end
	function backend.close(handle, callback) handle.closed, handle.active, handle.close_callback = true, false, callback end
	function backend.stop() state.stops = state.stops + 1 end
	local function timers()
		local ready = {}
		for _, handle in ipairs(state.handles) do
			if handle.active and not handle.closed and handle.kind == "timer" and handle.due <= state.clock then ready[#ready + 1] = handle end
		end
		for _, handle in ipairs(ready) do
			if handle.active then
				if handle.interval > 0 then handle.due = state.clock + handle.interval else handle.active = false end
				handle.callback()
			end
		end
	end
	function backend.run()
		local previous = state.stops
		state.phase = "preamble"
		timers()
		if previous ~= state.stops then return end
		for _ = 1, 50 do
			local spinning, next_due = false, nil
			state.phase = "idle"
			for _, handle in ipairs(state.handles) do
				if handle.active and handle.kind == "idle" then spinning = true; handle.callback() end
			end
			state.phase = "prepare"
			if state.before_prepare then state.before_prepare() end
			for _, handle in ipairs(state.handles) do
				if handle.active and handle.kind == "prepare" then handle.callback() end
			end
			state.phase = "poll"
			if previous == state.stops and not spinning then
				for _, handle in ipairs(state.handles) do
					if handle.active and handle.kind == "timer" and (not next_due or handle.due < next_due) then next_due = handle.due end
				end
				if next_due then state.clock = next_due end
			end
			state.phase = "closing"
			for _, handle in ipairs(state.handles) do
				if handle.close_callback then local callback = handle.close_callback; handle.close_callback = nil; callback() end
			end
			if previous ~= state.stops then return end
			state.phase = "timers"
			timers()
		end
		error("the controlled native loop must reach its own stop", 0)
	end
	local loop = helpers.load_module_with_dependency("adapters.event_loop", "luv", backend)
	return loop, state, backend
end

helpers.describe("native event-loop bounded pumping", function()
	helpers.it("native-pump-owner uses an acknowledged immediate one-millisecond timer", function()
		local loop, state = bounded_native_fixture()
		local calls = 0
		loop.run({ onIdle = function() calls = calls + 1; if calls == 3 then loop.stop() end end })
		helpers.assert_eq(calls, 3)
		helpers.assert_eq(state.idle_starts, 0, "a native idle source makes every poll immediately runnable")
		helpers.assert_eq(#state.starts, 1)
		helpers.assert_eq({ state.starts[1].role, state.starts[1].delay, state.starts[1].interval }, { "pump", 0, 1 })
		helpers.assert_true(state.starts[1].updates > 0, "arming must refresh native time")
		helpers.assert_eq(state.handles[1].stopped_by, "timer")
		helpers.assert_true(state.handles[1].closed)
	end)

	helpers.it("native-pump-owner lets poll advance between quiet callbacks", function()
		local loop, state = bounded_native_fixture()
		local times = {}
		loop.run({ onIdle = function() times[#times + 1] = state.clock; if #times == 3 then loop.stop() end end })
		helpers.assert_eq(times, { 0, 1, 2 }, "the next quiet pump must wait for the next independent timer deadline")
	end)

	helpers.it("native-pump-owner separates periodic work when the primary callback is absent", function()
		local loop, state = bounded_native_fixture()
		local handlers, periodic = 0, 0
		loop.add_idle_handler(function() handlers = handlers + 1; if handlers == 5 then loop.stop() end end)
		loop.run({ periodSec = .001, onPeriodic = function() periodic = periodic + 1; loop.stop() end })
		helpers.assert_eq(periodic, 1, "quiet pumping must not keep native time from reaching periodic work")
		helpers.assert_true(handlers > 0)
		helpers.assert_eq({ state.starts[1].delay, state.starts[2].delay }, { 0, 1 })
		helpers.assert_eq({ state.starts[1].role, state.starts[2].role }, { "pump", "periodic" })
	end)

	helpers.it("native-pump-owner preserves handler and recursive-deferred ordering", function()
		local loop = bounded_native_fixture()
		local seen, ticks = {}, 0
		loop.add_idle_handler(function() seen[#seen + 1] = "handler" end)
		loop.defer(function()
			seen[#seen + 1] = "deferred1"
			loop.defer(function() seen[#seen + 1] = "deferred2"; loop.stop() end)
		end)
		loop.run({ onIdle = function() ticks = ticks + 1; seen[#seen + 1] = "primary" .. ticks end })
		helpers.assert_eq(seen, { "primary1", "handler", "deferred1", "primary2", "handler", "deferred2" })
	end)

	helpers.it("native-pump-owner stops secondary handlers and deferred work after a stop", function()
		local loop = bounded_native_fixture()
		local seen = {}
		loop.add_idle_handler(function() seen[#seen + 1] = "first"; loop.stop() end)
		loop.add_idle_handler(function() seen[#seen + 1] = "late" end)
		loop.defer(function() seen[#seen + 1] = "deferred" end)
		loop.run({ onIdle = function() seen[#seen + 1] = "primary" end })
		helpers.assert_eq(seen, { "primary", "first" })
	end)

	helpers.it("native-pump-owner stops inside an iteration and acknowledges its queued close", function()
		local loop, state, backend = bounded_native_fixture()
		local closed, calls = false, 0
		loop.run({ onIdle = function()
			calls = calls + 1
			-- The fixture owns this synthetic closing handle, independently of the adapter.
			state.handles[#state.handles + 1] = { close_callback = function() closed = true end }
			loop.stop()
		end })
		helpers.assert_eq(calls, 1)
		helpers.assert_true(closed, "stop from a preamble timer skips the closing phase")
	end)

	helpers.it("native-pump-owner dispatches due work only from prepare and coalesces repeated marks", function()
		local loop, state = bounded_native_fixture()
		local calls, phases = 0, {}
		state.before_prepare = function()
			for _, handle in ipairs(state.handles) do
				if handle.active and handle.role == "pump" and handle.kind == "timer" then handle.callback(); handle.callback() end
			end
		end
		loop.run({ onIdle = function()
			calls = calls + 1; phases[#phases + 1] = state.phase
			if calls == 2 then loop.stop() end
		end })
		helpers.assert_eq(phases, { "prepare", "prepare" })
		helpers.assert_eq(state.clock, 1, "repeated due marks must coalesce until the next iteration")
	end)

	helpers.it("native-pump-owner keeps periodic work in the iteration after pump handlers", function()
		local loop, state = bounded_native_fixture()
		local seen, ticks = {}, 0
		loop.add_idle_handler(function() if state.clock == 1 then seen[#seen + 1] = "handler" end end)
		loop.run({ onIdle = function()
			ticks = ticks + 1; if ticks == 5 then loop.stop() end
			if state.clock == 1 then seen[#seen + 1] = "pump" end
		end,
			periodSec = .001, onPeriodic = function() seen[#seen + 1] = state.phase; loop.stop() end })
		helpers.assert_eq(seen, { "pump", "handler", "prepare" })
	end)

	helpers.it("native-pump-owner suppresses due periodic work after a pump stop without dispatching future foreign work", function()
		local loop, state, backend = bounded_native_fixture()
		local periodic, foreign, ticks = 0, 0, 0
		local handle = { kind = "timer", role = "foreign", active = true, due = 10, interval = 10,
			callback = function() foreign = foreign + 1 end }
		state.handles[#state.handles + 1] = handle
		loop.run({ onIdle = function() ticks = ticks + 1; if state.clock == 1 or ticks == 5 then loop.stop() end end,
			periodSec = .001, onPeriodic = function() periodic = periodic + 1 end })
		helpers.assert_eq({ periodic, foreign }, { 0, 0 })
		helpers.assert_true(handle.active and not handle.closed, "foreign ownership must remain untouched")
		backend.close(handle)
	end)

	for _, kind in ipairs({ "allocation", "start" }) do
		for _, receipt in ipairs({ "nil", "false", "throw" }) do
			helpers.it("native-pump-owner unwinds prepare " .. kind .. " " .. receipt .. " and retries", function()
				local refusal = { role = "prepare", kind = kind, receipt = receipt }
				local loop, state = bounded_native_fixture(refusal)
				local ran = pcall(loop.run, { onIdle = function() loop.stop() end, onPeriodic = function() end })
				helpers.assert_eq(ran, false)
				helpers.assert_eq(loop.isRunning(), false)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
				refusal.role = nil
				local calls = 0
				loop.run({ onIdle = function() calls = calls + 1; loop.stop() end })
				helpers.assert_eq(calls, 1)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
			end)
		end
	end

	for _, role in ipairs({ "pump", "periodic" }) do
		for _, kind in ipairs({ "allocation", "start" }) do
			helpers.it("native-pump-owner unwinds " .. role .. " " .. kind .. " refusal and retries", function()
				local refusal = { role = role, kind = kind }
				local loop, state = bounded_native_fixture(refusal)
				local ran = pcall(loop.run, { onIdle = function() loop.stop() end, onPeriodic = function() end })
				helpers.assert_eq(ran, false); helpers.assert_eq(loop.isRunning(), false)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
				refusal.role = nil
				local calls = 0
				loop.run({ onIdle = function() calls = calls + 1; loop.stop() end })
				helpers.assert_eq(calls, 1)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
			end)
		end
	end
end)

--- Models libuv stop admission while an independently owned handle stays live.
local function stop_fixture(source)
	local state = { handles = {}, stops = 0, waited = false }
	local backend = {}
	local function new_handle(kind)
		local handle = { kind = kind, active = false }
		state.handles[#state.handles + 1] = handle
		return handle
	end
	function backend.new_idle() local handle = new_handle("idle"); handle.role = "pump"; return handle end
	function backend.update_time() end -- native void-style clock refresh
	function backend.new_timer() return new_handle("timer") end
	function backend.new_prepare() state.prepare_allocations = (state.prepare_allocations or 0) + 1; return new_handle("prepare") end
	function backend.prepare_start(handle, callback) handle.active, handle.callback = true, callback; return 0 end
	function backend.prepare_stop(handle) handle.active = false; return 0 end
	function backend.idle_start(handle, callback) handle.active, handle.callback = true, callback; return 0 end
	function backend.timer_start(handle, delay, interval, callback)
		handle.role = delay == 0 and interval == 1 and "pump" or "periodic"
		handle.active, handle.callback = true, callback; return 0
	end
	function backend.idle_stop(handle) handle.active = false; return 0 end
	function backend.timer_stop(handle) handle.active = false; return 0 end
	function backend.close(handle) handle.closed = true end
	function backend.stop() state.stops = state.stops + 1 end
	function backend.run()
		local stops_before = state.stops
		for _, handle in ipairs(state.handles) do
			if not handle.closed and handle.role == (source == "periodic" and "periodic" or "pump") then
				handle.callback()
				break
			end
		end
		for _, handle in ipairs(state.handles) do
			if handle.kind == "prepare" and handle.active then handle.callback() end
		end
		-- Stopping the adapter's own idle/timer cannot retire a foreign owner.
		state.waited = state.stops == stops_before
	end
	local previous_backend, previous_loop = package.loaded.luv, package.loaded["adapters.event_loop"]
	package.loaded.luv, package.loaded["adapters.event_loop"] = backend, nil
	local ok, loop = pcall(require, "adapters.event_loop")
	package.loaded.luv, package.loaded["adapters.event_loop"] = previous_backend, previous_loop
	if not ok then error(loop, 0) end
	return loop, state, backend
end

helpers.describe("linux-event-stop-receipts", function()
	for _, source in ipairs({ "idle", "periodic", "deferred" }) do
		helpers.it("linux-event-stop-receipts: " .. source .. " signals native stop without stealing handles", function()
			local loop, state = stop_fixture(source)
			local calls = 0
			local function stop() calls = calls + 1; loop.stop(); loop.stop() end
			local options = {}
			if source == "idle" then options.onIdle = stop
			elseif source == "periodic" then options.onPeriodic = stop
			else
				helpers.assert_true(loop.defer(stop))
				options.onIdle = function() end
			end
			loop.run(options)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(state.stops, 1, "native run needs explicit stop while foreign owners remain")
			helpers.assert_true(not state.waited)
			helpers.assert_true(not loop.isRunning())
			for _, handle in ipairs(state.handles) do
				helpers.assert_true(handle.closed and not handle.active, "adapter releases its own handles")
			end
		end)
	end
	helpers.it("linux-event-stop-receipts: repeated runs acquire independent stop ownership", function()
		local loop, state = stop_fixture("idle")
		for _ = 1, 2 do
			loop.run({ onIdle = function() loop.stop() end })
			helpers.assert_true(not state.waited)
		end
		helpers.assert_eq(state.stops, 2)
		helpers.assert_true(not loop.isRunning())
		for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
	end)
	helpers.it("linux-event-stop-receipts: inactive stop cannot interrupt the native owner", function()
		local loop, state = stop_fixture("idle")
		loop.stop()
		loop.stop()
		helpers.assert_eq(state.stops, 0)
		helpers.assert_eq(#state.handles, 0)
	end)
end)

helpers.describe("event_loop adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports run, stop, isRunning, HAS_LUV", function()
      helpers.assert_true(type(el.run)       == "function", "run is a function")
      helpers.assert_true(type(el.stop)      == "function", "stop is a function")
      helpers.assert_true(type(el.isRunning) == "function", "isRunning is a function")
      helpers.assert_true(type(el.HAS_LUV)   == "boolean",  "HAS_LUV is a boolean")
    end)

    helpers.it("exports a checked millisecond wait", function()
      helpers.assert_true(type(el.sleep_ms) == "function", "sleep_ms is a function")
      helpers.assert_true(not el.sleep_ms(-1), "negative waits must be rejected")
      helpers.assert_true(not el.sleep_ms("1"), "non-numeric waits must be rejected")
    end)

    helpers.it("HAS_LUV is false when the dependency is explicitly unavailable", function()
      helpers.assert_true(el.HAS_LUV == false, "HAS_LUV is false (luv absent)")
    end)
  end)

  -- ==========================================================================
  -- 2. Pump fallback — run() with mock callbacks
  -- ==========================================================================

  helpers.describe("pump fallback (luv absent)", function()

    helpers.it("calls onIdle repeatedly until stop() is called from inside onIdle", function()
      local idle_count = 0
      local max_idle   = 5

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= max_idle then
            el.stop()
          end
        end,
      })

      helpers.assert_true(idle_count >= max_idle,
        string.format("onIdle called at least %d times (got %d)", max_idle, idle_count))
      helpers.assert_true(el.isRunning() == false, "isRunning is false after loop exits")
    end)

    helpers.it("calls onPeriodic at least once when periodSec is very small", function()
      local periodic_count = 0

      -- Use a tiny period so onPeriodic fires within the first few idle ticks.
      el.run({
        onIdle = function()
          -- Stop after enough ticks for one periodic fire.
          if periodic_count >= 1 then
            el.stop()
          end
        end,
        onPeriodic = function()
          periodic_count = periodic_count + 1
        end,
        periodSec = 0.001,  -- fire almost immediately
      })

      helpers.assert_true(periodic_count >= 1,
        string.format("onPeriodic called at least once (got %d)", periodic_count))
    end)

    helpers.it("onPeriodic is NOT called when omitted from opts", function()
      local idle_count   = 0
      local periodic_ran = false

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= 10 then el.stop() end
        end,
        -- onPeriodic intentionally omitted
      })

      -- The loop ran; since we never set periodic_ran, it must still be false.
      helpers.assert_true(periodic_ran == false, "onPeriodic was never invoked (nil callback)")
    end)
  end)

  -- ==========================================================================
  -- 3. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()

    helpers.it("run() with empty opts returns immediately (guard against infinite loop)", function()
      local start = os.clock()
      el.run({})
      local elapsed = os.clock() - start
      helpers.assert_true(elapsed < 0.1,
        string.format("run({}) returned in < 100 ms (got %.3f s)", elapsed))
      helpers.assert_true(el.isRunning() == false, "isRunning is false after empty-run return")
    end)

    helpers.it("run() with nil opts returns immediately", function()
      local start = os.clock()
      el.run(nil)
      local elapsed = os.clock() - start
      helpers.assert_true(elapsed < 0.1,
        string.format("run(nil) returned in < 100 ms (got %.3f s)", elapsed))
    end)

    helpers.it("stop() when not running is safe (idempotent)", function()
      -- Ensure any previous test's loop is done.
      -- Called directly. A stop that never started must leave the loop runnable:
      -- the shutdown path stops defensively, and a wedged loop takes the daemon
      -- with it on the next start.
      el.stop()
      helpers.assert_eq(el.isRunning(), false, "and must report itself stopped")

      -- Double stop is also safe.
      ok = pcall(function() el.stop() end)
      helpers.assert_true(ok, "double stop() does not crash")
    end)

    helpers.it("callback exceptions are caught and do not crash the loop", function()
      local idle_count = 0

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count == 1 then
            error("BANG — this must not crash the loop")
          end
          if idle_count >= 5 then
            el.stop()
          end
        end,
      })

      helpers.assert_true(idle_count >= 5,
        string.format("loop survived exception and ran %d idle iterations", idle_count))
    end)

    helpers.it("onPeriodic exception is caught and does not crash the loop", function()
      local idle_count     = 0
      local periodic_count = 0

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= 10 then el.stop() end
        end,
        onPeriodic = function()
          periodic_count = periodic_count + 1
          error("PERIODIC BANG — must not crash the loop")
        end,
        periodSec = 0.001,
      })

      helpers.assert_true(periodic_count >= 1,
        string.format("onPeriodic was called %d times despite exceptions", periodic_count))
      helpers.assert_true(idle_count >= 10,
        "onIdle continued to fire after periodic exceptions")
    end)
  end)

  -- ==========================================================================
  -- 4. Integration contract — daemon-level callbacks
  -- ==========================================================================

  helpers.describe("daemon integration contract", function()

    helpers.it("supports the canonical {onIdle, onPeriodic, periodSec} shape", function()
      local idle_ran     = false
      local periodic_ran = false

      el.run({
        onIdle = function()
          idle_ran = true
          el.stop()
        end,
        onPeriodic = function()
          periodic_ran = true
        end,
        periodSec = 0.001,
      })

      helpers.assert_true(idle_ran,     "onIdle was invoked")
      -- onPeriodic may or may not fire before stop() in one idle tick;
      -- we only assert it doesn't crash.
    end)
  end)

  -- ==========================================================================
  -- 5. Idle handler registration — GTK/WebKit2GTK context pump
  -- ==========================================================================

  helpers.describe("idle handler registration (webview pump)", function()

    helpers.it("exposes add_idle_handler so webview_manager can pump the GTK context", function()
      helpers.assert_true(type(el.add_idle_handler) == "function",
        "add_idle_handler is a function")
    end)

    helpers.it("pumps registered idle handlers every tick even under clock starvation", function()
      -- Fresh module instance so no handler leaks in from or out to other tests.
      local elx = load_pump_loop()

      -- Register the GTK-context pump BEFORE touching the clock: if the API is
      -- missing (the pre-fix regression) this line raises and the frozen clock
      -- below is never installed, so no state leaks into later tests.
      local pumps = 0
      elx.add_idle_handler(function() pumps = pumps + 1 end)

      -- Freeze the wall clock so the periodSec gate can never advance. The ONLY
      -- thing that can still drive the GTK context is the per-iteration idle
      -- pump — this reproduces the CPU-time clock stall that would otherwise
      -- freeze WebKit2GTK webviews; the handler must fire on every tick anyway.
      local real_clock = os.clock
      os.clock = function() return 42 end

      local ticks = 0
      local ok, err = pcall(function()
        elx.run({
          onIdle = function()
            ticks = ticks + 1
            if ticks >= 5 then elx.stop() end
          end,
          onPeriodic = function() end,   -- present but must stay starved
          periodSec  = 1000,
        })
      end)

      os.clock = real_clock  -- always restore, even if run() raised

      helpers.assert_true(ok, "loop ran to completion without raising: " .. tostring(err))
      helpers.assert_eq(pumps, 4,
        "the handler runs on each live tick; the fifth primary callback stops before secondary dispatch")
    end)

    helpers.it("rejects a non-function handler (fail-fast) without crashing", function()
      local elx = load_pump_loop()
      -- A no-op means the handler is not REGISTERED. One that stored 42 and called
      -- it on the next tick would crash the loop a frame later, far from here.
      elx.add_idle_handler(42)
      helpers.assert_eq(elx.isRunning(), false,
        "a refused handler must not have started anything")
    end)
  end)

end)

helpers.describe("linux-periodic-finite-admission", function()
	for _, case in ipairs({ { name = "NaN", value = 0 / 0 },
		{ name = "positive infinity", value = math.huge },
		{ name = "negative infinity", value = -math.huge },
		{ name = "positive converted overflow", value = 1e308 },
		{ name = "negative converted overflow", value = -1e308 } }) do
		helpers.it("linux-periodic-finite-admission: refuses " .. case.name .. " before allocation", function()
			-- This explicit backend seam counts admission; the separate native
			-- fixture proves actual libuv callbacks and foreign handle ownership.
			local loop, state = stop_fixture("periodic")
			local refused_calls, healthy_calls = 0, 0
			local ok = pcall(loop.run, { periodSec = case.value,
				onPeriodic = function() refused_calls = refused_calls + 1; loop.stop() end })
			local allocated = #state.handles
			helpers.assert_true(not loop.isRunning())
			loop.run({ periodSec = 0.001,
				onPeriodic = function() healthy_calls = healthy_calls + 1; loop.stop() end })
			helpers.assert_eq(healthy_calls, 1, "duration refusal must release run ownership for retry")
			helpers.assert_true(not ok)
			helpers.assert_eq(refused_calls, 0)
			helpers.assert_eq(allocated, 0, "invalid duration must not acquire idle or timer resources")
		end)
	end
	for _, case in ipairs({ { name = "zero", value = 0, milliseconds = 1 },
		{ name = "finite negative", value = -0.005, milliseconds = 1 },
		{ name = "submillisecond fraction", value = 0.0005, milliseconds = 1 },
		{ name = "fraction", value = 0.0055, milliseconds = 5 },
		{ name = "numeric string", value = "0.002", milliseconds = 2 },
		{ name = "default", milliseconds = 250 },
		{ name = "nonnumeric default", value = "not a number", milliseconds = 250 },
		{ name = "large finite", value = 1e12, milliseconds = 1e15 } }) do
		helpers.it("linux-periodic-finite-admission: preserves " .. case.name .. " native conversion", function()
			local loop, state, backend = stop_fixture("periodic")
			local native_start, first, repeat_ms = backend.timer_start
			backend.timer_start = function(handle, delay, interval, callback)
				first, repeat_ms = delay, interval
				return native_start(handle, delay, interval, callback)
			end
			local calls = 0
			loop.run({ periodSec = case.value, onPeriodic = function() calls = calls + 1; loop.stop() end })
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(first, case.milliseconds)
			helpers.assert_eq(repeat_ms, case.milliseconds)
			helpers.assert_eq(#state.handles, 2 + (state.prepare_allocations or 0))
			for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
		end)
	end
	for _, value in ipairs({ 0 / 0, math.huge, 1e308 }) do
		helpers.it("linux-periodic-finite-admission: idle-only ignores unused duration " .. tostring(value), function()
			local loop, state = stop_fixture("idle")
			loop.run({ periodSec = value, onIdle = function() loop.stop() end })
			helpers.assert_eq(#state.handles, 1 + (state.prepare_allocations or 0))
			helpers.assert_true(state.handles[1].closed)
		end)
	end
	if native_ok and package.config:sub(1, 1) == "/" then
		helpers.it("linux-periodic-finite-admission: real libuv owns refusal and retry resources", function()
			local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop_periodic_admission.lua"
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local result = os.execute(quote(executable) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native periodic admission fixture must succeed")
		end)
	end
end)


helpers.describe("linux-sleep-completion-receipts", function()
	local receipts = {
		{ name = "boolean native success", result = true, expected = true },
		{ name = "numeric native success", result = 0, expected = true },
		{ name = "nil native failure", result = nil, expected = false },
		{ name = "numeric native failure", result = 1792, expected = false },
		{ name = "false native failure", result = false, expected = false },
		{ name = "raised command failure", raises = true, expected = false },
	}
	for _, branch in ipairs({ "explicit FFI absence", "explicit cdef refusal" }) do
		for _, case in ipairs(receipts) do
			helpers.it("linux-sleep-completion-receipts: " .. branch .. " honors " .. case.name, function()
				local dependency = false
				if branch == "explicit cdef refusal" then
					dependency = { cdef = function() error("controlled cdef refusal") end }
				end
				local loop = helpers.load_module_with_dependency("adapters.event_loop", "ffi", dependency)
				local execute = os.execute
				local commands = {}
				os.execute = function(command)
					commands[#commands + 1] = command
					if #commands > 1 then return true, "exit", 0 end
					if case.raises then error("controlled command exception") end
					return case.result, "exit", case.expected and 0 or 7
				end
				local ok, err = xpcall(function()
					helpers.assert_eq(loop.sleep_ms(20), case.expected)
					helpers.assert_eq(commands[1], "sleep 0.020", "native command argument must remain unchanged")
					helpers.assert_eq(loop.sleep_ms(25), true, "following native success must remain usable")
					helpers.assert_eq(commands[2], "sleep 0.025")
					helpers.assert_eq(loop.sleep_ms(-1), false)
					helpers.assert_eq(loop.sleep_ms("25"), false)
					helpers.assert_eq(#commands, 2, "invalid typed/negative waits must not execute a command")
				end, debug.traceback)
				os.execute = execute
				if not ok then error(err, 0) end
			end)
		end
	end
end)

if native_ok and package.config:sub(1, 1) == "/" then
	helpers.it("linux-sleep-completion-receipts: native command wait and refusal receipts are truthful", function()
		local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
		local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop_sleep_receipts.lua"
		local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
		local result = os.execute(quote(executable) .. " " .. quote(fixture))
		helpers.assert_true(result == true or result == 0, "native wait completion fixture must succeed")
	end)
end

helpers.describe("event loop backend isolation", function()
  helpers.it("dependency fixtures restore cached and preload values after success", function()
    local loaded, preload = package.loaded.luv, package.preload.luv
    local native = helpers.load_module_with_dependency("adapters.event_loop", "luv", {})
    helpers.assert_true(native.HAS_LUV, "present dependency selects the native backend")
    helpers.assert_true(package.loaded.luv == loaded, "restore the exact original cache")
    helpers.assert_true(package.preload.luv == preload, "restore the exact original loader")
    helpers.assert_true(not load_pump_loop().HAS_LUV, "absent dependency selects polling independently")
    helpers.assert_true(package.loaded.luv == loaded, "polling must not conceal installed luv")
  end)

  helpers.it("dependency fixtures restore values and preserve a throwing module error", function()
    local name = "tests.fixture_backend_load_failure"
    local old_loaded, old_preload = package.loaded[name], package.preload[name]
    local loaded, preload = package.loaded.luv, package.preload.luv
    package.preload[name] = function()
      require("luv")
      error("backend fixture load failure")
    end
    local ok, err = pcall(helpers.load_module_with_dependency, name, "luv", {})
    package.loaded[name], package.preload[name] = old_loaded, old_preload
    helpers.assert_true(not ok, "module failure must propagate")
    helpers.assert_contains(tostring(err), "backend fixture load failure")
    helpers.assert_true(package.loaded.luv == loaded, "restore cache after a failed require")
    helpers.assert_true(package.preload.luv == preload, "restore loader after a failed require")
  end)

  -- The isolated child uses the POSIX transport of this Linux driver.
  if native_ok and package.config:sub(1, 1) == "/" then
    helpers.it("installed luv dispatches callbacks, closes its handles and waits through child exits", function()
      -- libuv's default loop is process-wide: other tests may own active handles.
      local executable = assert(arg and arg[-1], "the running Lua interpreter must be identifiable")
      local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop.lua"
      local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
      local result = os.execute(quote(executable) .. " " .. quote(fixture))
      helpers.assert_true(result == true or result == 0, "isolated native loop fixture must succeed")
    end)
    helpers.it("installed luv unwinds failed loop startup and permits the next run", function()
      local executable = assert(arg and arg[-1], "the running Lua interpreter must be identifiable")
      local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop_startup.lua"
      local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
      local result = os.execute(quote(executable) .. " " .. quote(fixture))
      helpers.assert_true(result == true or result == 0, "isolated native startup ownership must succeed")
    end)
  else
    print("  [native luv POSIX integration unavailable; explicit backend fixtures still run]")
  end
end)

helpers.describe("linux-event-reentry", function()
	for _, source in ipairs({ "idle", "periodic", "deferred" }) do
		for _, stopping in ipairs({ false, true }) do
			helpers.it("linux-event-reentry: " .. source .. " guards " .. (stopping and "stopping" or "running") .. " ownership", function()
				local loop, state = stop_fixture(source)
				local outer, nested = 0, 0
				local function callback()
					outer = outer + 1
					if stopping then loop.stop() end
					loop.run({ onIdle = function() nested = nested + 1; loop.stop() end })
					loop.stop()
				end
				local options = {}
				if source == "idle" then options.onIdle = callback
				elseif source == "periodic" then options.onPeriodic = callback
				else loop.defer(callback); options.onIdle = function() end end
				loop.run(options)
				helpers.assert_eq(outer, 1)
				helpers.assert_eq(nested, 0, "an unreturned run still owns its native handles")
				helpers.assert_eq(#state.handles, (source == "periodic" and 2 or 1) + (state.prepare_allocations or 0),
					"callback reentry must not acquire another native loop")
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
				helpers.assert_true(not loop.isRunning())
			end)
		end
	end

	helpers.it("linux-event-reentry: raised native run releases the admission guard for retry", function()
		local loop, state, backend = stop_fixture("idle")
		-- The retained backend is private to this fixture, so native refusal is
		-- explicit rather than a claim that libuv itself threw spontaneously.
		local run = backend.run
		backend.run = function() error("simulated native run refusal") end
		local ok, err = pcall(loop.run, { onIdle = function() loop.stop() end })
		helpers.assert_true(not ok)
		helpers.assert_contains(tostring(err), "simulated native run refusal")
		helpers.assert_true(not loop.isRunning())
		for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
		backend.run = run
		local calls = 0
		loop.run({ onIdle = function() calls = calls + 1; loop.stop() end })
		helpers.assert_eq(calls, 1, "completed error cleanup must permit a later run")
		for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
	end)

	if native_ok and package.config:sub(1, 1) == "/" then
		helpers.it("linux-event-reentry: installed libuv retains exact run ownership through stop", function()
			local executable = assert(arg and arg[-1], "running Lua interpreter must be identifiable")
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop_reentry.lua"
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local result = os.execute(quote(executable) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native reentry ownership fixture must succeed")
		end)
	end
end)

helpers.describe("linux-defer-finite-admission", function()
	for _, case in ipairs({ { name = "NaN", value = 0 / 0 },
		{ name = "positive infinity", value = math.huge },
		{ name = "negative infinity", value = -math.huge } }) do
		helpers.it("linux-defer-finite-admission: rejects " .. case.name .. " without queue ownership", function()
			local loop = load_pump_loop()
			local weak = setmetatable({}, { __mode = "v" })
			local calls = 0
			local function owned_callback()
				local marker = {}
				weak[1] = marker
				return function() calls = calls + 1; return marker end
			end
			local callback = owned_callback()
			helpers.assert_eq(loop.defer(callback, case.value), false)
			callback = nil
			collectgarbage("collect")
			collectgarbage("collect")
			helpers.assert_eq(weak[1], nil, "refused work must not remain owned by the deferred queue")
			loop._run_idle_tick()
			helpers.assert_eq(calls, 0)
			loop.defer(function() calls = calls + 1 end)
			loop._run_idle_tick()
			helpers.assert_eq(calls, 1, "an invalid delay must not starve following healthy work")
		end)
	end
end)

helpers.describe("event loop: stop cancels queued dispatch", function()
	for _, branch in ipairs({ "pump", "native" }) do
		local function fresh_loop(source)
			if branch == "pump" then return load_pump_loop() end
			return stop_fixture(source or "idle")
		end

		helpers.it(branch .. " stop inside a deferred callback cancels the remaining batch and waiting work", function()
			local loop = fresh_loop()
			local calls, weak = {}, setmetatable({}, { __mode = "v" })
			local function waiting_callback()
				local marker = {}; weak[1] = marker
				return function() calls[#calls + 1] = "waiting"; return marker end
			end
			helpers.assert_true(loop.defer(waiting_callback(), 1000))
			helpers.assert_true(loop.defer(function() calls[#calls + 1] = "quit"; loop.stop() end))
			helpers.assert_true(loop.defer(function() calls[#calls + 1] = "old action" end))
			loop.run({ onIdle = function() end })
			helpers.assert_eq(calls, { "quit" }, "a successful stop withdraws the rest of the detached batch")
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_eq(weak[1], nil, "stopped waiting work must release its retained owner")
			loop._run_idle_tick()
			loop.run({ onIdle = function()
				loop.defer(function() calls[#calls + 1] = "new action"; loop.stop() end)
			end })
			helpers.assert_eq(calls, { "quit", "new action" }, "a later run cannot replay stopped work")
		end)

		helpers.it(branch .. " stop in the primary idle callback prevents secondary and periodic dispatch", function()
			local loop = fresh_loop()
			local calls = {}
			loop.add_idle_handler(function() calls[#calls + 1] = "secondary" end)
			loop.defer(function() calls[#calls + 1] = "deferred" end)
			loop.run({ periodSec = 0.001,
				onIdle = function() calls[#calls + 1] = "quit"; loop.stop() end,
				onPeriodic = function() calls[#calls + 1] = "periodic" end,
			})
			helpers.assert_eq(calls, { "quit" })
		end)


		helpers.it(branch .. " periodic stop releases pending work and prevents reentrant stopped pumping", function()
			local loop = fresh_loop("periodic")
			local after_stop, weak = 0, setmetatable({}, { __mode = "v" })
			local function waiting_callback()
				local marker = {}; weak[1] = marker
				return function() return marker end
			end
			loop.add_idle_handler(function() if not loop.isRunning() then after_stop = after_stop + 1 end end)
			loop.defer(waiting_callback(), 1000)
			loop.run({ periodSec = 0.001, onIdle = function() end, onPeriodic = function()
				loop.stop()
				loop._run_idle_tick()
			end })
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_eq(after_stop, 0, "a stopped callback cannot reenter manual dispatch before cleanup returns")
			helpers.assert_eq(weak[1], nil, "periodic stop cancels waiting callbacks without awaiting their deadline")
		end)

		helpers.it(branch .. " stop in a secondary handler cancels subsequent handlers and deferred actions", function()
			local loop = fresh_loop()
			local calls = {}
			loop.add_idle_handler(function() calls[#calls + 1] = "quit"; loop.stop() end)
			loop.add_idle_handler(function() calls[#calls + 1] = "later handler" end)
			loop.defer(function() calls[#calls + 1] = "deferred" end)
			loop.run({ periodSec = 0.001, onIdle = function() end,
				onPeriodic = function() calls[#calls + 1] = "periodic" end })
			helpers.assert_eq(calls, { "quit" })
		end)
	end

	helpers.it("inactive stop preserves explicit pre-start pumping and new work after a completed run", function()
		local loop = load_pump_loop()
		local calls = 0
		loop.defer(function() calls = calls + 1 end)
		loop.stop()
		loop._run_idle_tick()
		helpers.assert_eq(calls, 1, "a defensive inactive stop must not cancel pre-start work")
		loop.run({ onIdle = function() loop.stop() end })
		loop.defer(function() calls = calls + 1 end)
		loop._run_idle_tick()
		helpers.assert_eq(calls, 2, "manual pumping remains an explicit supported owner after run returns")
	end)
end)

--- Loads the polling loop over a controlled wall clock.
--- @param resolution number Milliseconds the clock can overstate a gap by.
--- @return table loop, table clock { now }
local function pump_on_clock(resolution)
	local clock = { now = 0 }
	local previous = package.loaded["infra.monotonic"]
	package.loaded["infra.monotonic"] = {
		now_ms = function() return clock.now end,
		resolution_ms = function() return resolution end,
	}
	local ok, loop = pcall(load_pump_loop)
	package.loaded["infra.monotonic"] = previous
	if not ok then error(loop, 0) end
	return loop, clock
end

helpers.describe("linux-pump-periodic-wall-clock", function()
	helpers.it("linux-pump-periodic-wall-clock: callbacks that wait without CPU keep the periodic cadence", function()
		local loop, clock = pump_on_clock(0)
		local iterations, ticks = 0, {}
		loop.run({ periodSec = 0.25,
			onIdle = function()
				iterations = iterations + 1
				clock.now = clock.now + 400 -- Blocked on I/O: wall time passes, CPU time does not.
				if iterations >= 6 then loop.stop() end
			end,
			onPeriodic = function() ticks[#ticks + 1] = clock.now end })
		helpers.assert_eq(ticks, { 400, 800, 1200, 1600, 2000 },
			"every 400 ms iteration exceeds the 250 ms period, whatever the CPU clock says")
	end)

	helpers.it("linux-pump-periodic-wall-clock: a coarse second boundary cannot fire the tick early", function()
		local loop, clock = pump_on_clock(1000)
		local iterations, ticks = 0, 0
		loop.run({ periodSec = 0.25,
			onIdle = function()
				iterations = iterations + 1
				if iterations == 1 then clock.now = 1000 end -- A boundary crossed after about 1 ms.
				if iterations >= 3 then loop.stop() end
			end,
			onPeriodic = function() ticks = ticks + 1 end })
		helpers.assert_eq(ticks, 0)
	end)
end)

helpers.describe("linux-pump-periodic-finite-admission", function()
	for _, value in ipairs({ 0 / 0, math.huge, -math.huge, 1e308 }) do
		helpers.it("linux-pump-periodic-finite-admission: refuses " .. tostring(value) .. " before pumping", function()
			local loop = load_pump_loop()
			local idles, ticks = 0, 0
			local ok, err = pcall(loop.run, { periodSec = value,
				onIdle = function() idles = idles + 1; if idles > 3 then loop.stop() end end,
				onPeriodic = function() ticks = ticks + 1 end })
			helpers.assert_eq(ok, false, "a nonfinite period must not tick every iteration or never")
			helpers.assert_contains(tostring(err), "must be finite")
			helpers.assert_eq(idles, 0)
			helpers.assert_eq(ticks, 0)
			helpers.assert_eq(loop.isRunning(), false)
			local healthy = 0
			loop.run({ periodSec = 0.001, onPeriodic = function() healthy = healthy + 1; loop.stop() end })
			helpers.assert_eq(healthy, 1, "a refused period leaves the loop reusable")
		end)
	end
	helpers.it("linux-pump-periodic-finite-admission: an idle-only loop ignores an unused period", function()
		local loop = load_pump_loop()
		local idles = 0
		loop.run({ periodSec = 0 / 0, onIdle = function() idles = idles + 1; loop.stop() end })
		helpers.assert_eq(idles, 1)
	end)
end)

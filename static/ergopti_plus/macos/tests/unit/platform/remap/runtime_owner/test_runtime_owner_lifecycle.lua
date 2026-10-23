--- tests/unit/platform/remap/runtime_owner/test_runtime_owner_lifecycle.lua

--- ==============================================================================
--- MODULE: Owned Runtime Lifecycle
--- DESCRIPTION:
--- Proves how platform/remap/runtime_owner.lua requests the physical capture
--- after admission, becomes ready only when the capture admits its first stream,
--- reports a lost or slow capture once, restarts only on request, and stops with
--- exact settlement.
---
--- ROOT CAUSES ENCODED: (a) the user-side Console is owned by the launcher's
--- installed-source role, so the Lua owner spawns no process and a second
--- Console can never start next to it; (b) READY means the capture admitted a
--- stream, not that a request was accepted, or the lease would start against a
--- Console that is not there yet; (c) a stop that returned before the capture
--- was observed settled would let a late credit or a second runtime overlap;
--- (d) a lost or slow capture must be reported once and never restarted in a
--- loop.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.platform.remap.runtime_owner_fixture")

--- Builds an admitted owner.
--- @param tweak function|nil Receives the world before the owner starts.
--- @return table owner
--- @return table world
local function admitted(tweak)
	local owner, world = Fixture.load_owner(), Fixture.new_world()
	if tweak then tweak(world) end
	owner.init(world.ports)
	owner.start({ close_other_instances = true })
	helpers.assert_eq(owner.status().state, "admitted")
	return owner, world
end

--- Requests the capture and returns the callback record.
--- @param owner table Owner.
--- @return table record { accepted, calls }
local function start_peers(owner)
	local record = { calls = {} }
	record.accepted = owner.ensure_peers(function(ok, why) record.calls[#record.calls + 1] = { ok, why } end)
	return record
end

--- Makes the capture admit its first stream and lets the owner look.
--- @param world table World.
local function admit_stream(world)
	world.capture_state = "admitted"
	world.tick()
end

--- Counts how many times the owner reported one state.
--- @param world table World.
--- @param name string State name.
--- @return integer count
local function visits(world, name)
	local total = 0
	for _, state in ipairs(world.calls.states) do
		if state == name then total = total + 1 end
	end
	return total
end





-- =====================================
-- =====================================
-- ======= 1/ Requesting Capture =======
-- =====================================
-- =====================================

helpers.describe("owned runtime owner: the capture request", function()
	helpers.it("refuses a request before admission and starts nothing", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		owner.init(world.ports)
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, false)
		helpers.assert_eq(#record.calls, 0)
		helpers.assert_eq(#world.calls.capture_start, 0)
	end)

	helpers.it("refuses a request after an unavailable admission", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = Fixture.listing("6.0.0", "activated enabled")
		owner.init(world.ports)
		owner.start({ close_other_instances = true })
		helpers.assert_eq(start_peers(owner).accepted, false)
		helpers.assert_eq(#world.calls.capture_start, 0)
	end)

	helpers.it("does not start the capture while the owned configuration is missing", function()
		local owner, world = admitted(function(w)
			w.files["/home/user/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json"] = nil
		end)
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, true)
		helpers.assert_eq(record.calls[1], { false, "owned_configuration_missing" })
		helpers.assert_eq(#world.calls.capture_start, 0)
		helpers.assert_eq(owner.status().state, "admitted")
	end)

	helpers.it("requests the pinned capture once and spawns no process of its own", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, true)
		helpers.assert_eq(#record.calls, 0, "accepting the request is not readiness")
		helpers.assert_eq(world.calls.capture_start, { world.pinned.capture })
		helpers.assert_eq(owner.status().state, "peers_starting")
		helpers.assert_eq(world.calls.timers, { 0.25 })
		helpers.assert_nil(world.ports.process, "the Console belongs to the launcher's installed-source role")
	end)

	helpers.it("is ready only once the capture admits its first stream", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		world.tick()
		world.tick()
		helpers.assert_eq(#record.calls, 0)
		helpers.assert_eq(owner.status().state, "peers_starting")
		admit_stream(world)
		helpers.assert_eq(record.calls, { { true, "ready" } })
		helpers.assert_eq(owner.status().state, "ready")
		helpers.assert_eq(world.tick(), 0, "a ready owner leaves no poll armed")
		helpers.assert_eq(owner.status().capture, { state = "admitted" })
	end)

	helpers.it("is idempotent once ready and shares one start between callers", function()
		local owner, world = admitted()
		local first = start_peers(owner)
		local second = start_peers(owner)
		helpers.assert_eq(second.accepted, true)
		helpers.assert_eq(#world.calls.capture_start, 1)
		admit_stream(world)
		helpers.assert_eq(first.calls, { { true, "ready" } })
		helpers.assert_eq(second.calls, { { true, "ready" } })
		local again = start_peers(owner)
		helpers.assert_eq(again.calls[1], { true, "already-ready" })
		helpers.assert_eq(#world.calls.capture_start, 1)
	end)

	helpers.it("fails without a retry when the capture refuses to start", function()
		local owner, world = admitted(function(w) w.capture_accepts = false end)
		local record = start_peers(owner)
		helpers.assert_eq(record.calls[1], { false, "capture_start_refused" })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(#world.calls.capture_start, 1)
		helpers.assert_eq(#world.calls.timers, 0)
		helpers.assert_eq(owner.stop(), true)
		helpers.assert_eq(world.calls.capture_stop, 0, "a capture that never started is not stopped")
	end)

	helpers.it("fails once, and revokes the capture, when no stream is admitted in time", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		local polls = math.ceil(owner.READY_TIMEOUT_SEC / owner.READY_POLL_INTERVAL_SEC)
		for _ = 1, polls do world.tick() end
		helpers.assert_eq(record.calls, { { false, "capture_start_timeout" } })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_contains(owner.status().explanation, "30")
		helpers.assert_eq(world.calls.capture_stop, 1)
		helpers.assert_eq(world.tick(), 0)
		helpers.assert_eq(#world.calls.capture_start, 1)
	end)

	helpers.it("fails when the capture ends before it admitted a stream", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		world.capture_state = "stopped"
		world.tick()
		helpers.assert_eq(record.calls, { { false, "capture_lost" } })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(world.calls.capture_stop, 1)
	end)

	helpers.it("treats an unreadable capture status as a lost capture, never as progress", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		world.ports.capture.status = function() error("status broke") end
		world.tick()
		helpers.assert_eq(record.calls, { { false, "capture_lost" } })
	end)

	helpers.it("fails and revokes the capture when the readiness check cannot be scheduled", function()
		local owner, world = admitted()
		world.timer_commits = false
		local record = start_peers(owner)
		helpers.assert_eq(record.calls, { { false, "readiness_timer_refused" } })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(world.calls.capture_stop, 1)
	end)
end)





-- =====================================
-- =====================================
-- ======= 2/ Losing The Capture =======
-- =====================================
-- =====================================

helpers.describe("owned runtime owner: a lost capture", function()
	helpers.it("reports the loss once, revokes the capture and never restarts by itself", function()
		local owner, world = admitted()
		start_peers(owner)
		admit_stream(world)
		world.lost_callback("stream ended")
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(owner.status().reason, "capture_lost")
		helpers.assert_contains(owner.status().explanation, "stream ended")
		helpers.assert_eq(world.calls.capture_stop, 1)
		helpers.assert_eq(#world.calls.capture_start, 1)
		world.lost_callback("again")
		helpers.assert_eq(visits(world, "failed"), 1)
		helpers.assert_eq(world.calls.capture_stop, 1)
	end)

	helpers.it("answers the waiting callers with the loss when it happens before readiness", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		world.lost_callback("bridge exited")
		helpers.assert_eq(record.calls, { { false, "capture_lost" } })
		helpers.assert_eq(world.tick(), 0, "the readiness poll is cancelled with the loss")
	end)

	helpers.it("ignores a loss report while nothing was started, after a stop and after a release", function()
		local owner, world = admitted()
		world.lost_callback("early")
		helpers.assert_eq(owner.status().state, "admitted")
		start_peers(owner)
		owner.stop()
		world.lost_callback("late")
		helpers.assert_eq(owner.status().state, "stopped")
		helpers.assert_eq(owner.release(), true)
		world.lost_callback("stale")
		helpers.assert_eq(owner.status().state, "uninitialized")
	end)

	helpers.it("refuses a new admission while the lost capture is retained", function()
		local owner, world = admitted(function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		admit_stream(world)
		world.lost_callback("gone")
		helpers.assert_eq(owner.start({ close_other_instances = true }), false)
		world.capture_stop_callback()
		helpers.assert_eq(owner.start({ close_other_instances = true }), true)
	end)
end)





-- ===================================
-- ===================================
-- ======= 3/ Stop And Restart =======
-- ===================================
-- ===================================

helpers.describe("owned runtime owner: stop", function()
	helpers.it("stops the capture and settles only when it is observed settled", function()
		local owner, world = admitted(function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		admit_stream(world)
		local stopped = 0
		local settled, pending = owner.stop(function() stopped = stopped + 1 end)
		helpers.assert_eq(settled, false)
		helpers.assert_eq(pending, "capture_pending")
		helpers.assert_eq(owner.status().state, "stopping")
		world.capture_stop_callback()
		helpers.assert_eq(owner.status().state, "stopped")
		helpers.assert_eq(stopped, 1)
	end)

	helpers.it("retries the same capture while its stop is pending and never starts another", function()
		local owner, world = admitted(function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		admit_stream(world)
		owner.stop()
		owner.stop()
		helpers.assert_eq(world.calls.capture_stop, 2)
		helpers.assert_eq(#world.calls.capture_start, 1)
		helpers.assert_eq(owner.status().state, "stopping")
	end)

	helpers.it("cancels the readiness poll and answers the waiting callers", function()
		local owner, world = admitted()
		local record = start_peers(owner)
		owner.stop()
		helpers.assert_eq(record.calls, { { false, "stopped" } })
		helpers.assert_eq(world.calls.cancelled, 1)
		helpers.assert_eq(world.tick(), 0)
		helpers.assert_eq(owner.status().state, "stopped")
	end)

	helpers.it("settles at once when nothing was started", function()
		local owner = Fixture.load_owner()
		local world = Fixture.new_world()
		owner.init(world.ports)
		helpers.assert_eq(owner.stop(), true)
		helpers.assert_eq(owner.status().state, "stopped")
		helpers.assert_eq(world.calls.capture_stop, 0)
	end)

	helpers.it("is idempotent once stopped and never calls the observer twice", function()
		local owner, world = admitted()
		start_peers(owner)
		admit_stream(world)
		local calls = 0
		owner.stop(function() calls = calls + 1 end)
		owner.stop(function() calls = calls + 1 end)
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(world.calls.capture_stop, 1)
	end)

	helpers.it("refuses a second, different stop observer while one is pending", function()
		local owner, world = admitted(function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		admit_stream(world)
		owner.stop(function() end)
		local settled, pending = owner.stop(function() end)
		helpers.assert_eq(settled, false)
		helpers.assert_eq(pending, "observer_conflict")
	end)

	helpers.it("restarts only on request, through a settled stop, and asks the capture port again", function()
		local owner, world = admitted()
		start_peers(owner)
		admit_stream(world)
		local settled
		helpers.assert_eq(owner.restart({ close_other_instances = true }, function(ok) settled = ok end), true)
		helpers.assert_eq(settled, true)
		helpers.assert_eq(world.calls.capture_stop, 1)
		helpers.assert_eq(owner.status().state, "admitted")
		world.capture_state = "starting"
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, true)
		helpers.assert_eq(#world.calls.capture_start, 2)
	end)

	helpers.it("names the capture port's refusal of a second capture in one Lua VM instead of hiding it", function()
		local owner, world = admitted()
		start_peers(owner)
		admit_stream(world)
		owner.restart({ close_other_instances = true })
		world.capture_accepts = false
		local record = start_peers(owner)
		helpers.assert_eq(record.calls[1], { false, "capture_start_refused" })
		helpers.assert_eq(owner.status().state, "failed")
	end)

	helpers.it("refuses a restart while the previous stop is pending", function()
		local owner, world = admitted(function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		admit_stream(world)
		helpers.assert_eq(owner.restart({ close_other_instances = true }), false)
		helpers.assert_eq(#world.calls.capture_start, 1)
	end)
end)





-- ==========================
-- ==========================
-- ======= 4/ Release =======
-- ==========================
-- ==========================

helpers.describe("owned runtime owner: release", function()
	helpers.it("refuses while a capture is retained and allows a new binding after the stop", function()
		local owner, world = admitted()
		start_peers(owner)
		admit_stream(world)
		helpers.assert_eq(owner.release(), false)
		helpers.assert_eq(owner.init(Fixture.new_world().ports), false)
		owner.stop()
		helpers.assert_eq(owner.release(), true)
		helpers.assert_eq(owner.status().state, "uninitialized")
		helpers.assert_eq(owner.init(world.ports), true)
	end)
end)

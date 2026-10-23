--- tests/unit/platform/remap/runtime_owner/test_runtime_owner_lifecycle.lua

--- ==============================================================================
--- MODULE: Owned Runtime Lifecycle
--- DESCRIPTION:
--- Proves how platform/remap/runtime_owner.lua starts the user-side process and
--- the physical capture after admission, restarts only on request, and stops
--- both with exact settlement.
---
--- ROOT CAUSES ENCODED: (a) the Console must read Ergopti's own configuration
--- (XDG_CONFIG_HOME) and exit with Hammerspoon (owner PID), or it would keep
--- grabbing the keyboards after a crash; (b) a stop that returned before the
--- process was observed gone would let a late credit or a second runtime
--- overlap; (c) a lost runtime must be reported once and never restarted in a
--- loop.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.platform.remap.runtime_owner_fixture")

--- Builds an admitted owner.
--- @param capture boolean Whether the capture was requested.
--- @param tweak function|nil Receives the world before the owner starts.
--- @return table owner
--- @return table world
local function admitted(capture, tweak)
	local owner, world = Fixture.load_owner(), Fixture.new_world()
	if tweak then tweak(world) end
	owner.init(world.ports)
	owner.start({ close_other_instances = true, capture = capture })
	helpers.assert_eq(owner.status().state, "admitted")
	return owner, world
end

--- Starts the peers and returns the callback record.
--- @param owner table Owner.
--- @return table record { accepted, calls }
local function start_peers(owner)
	local record = { calls = {} }
	record.accepted = owner.ensure_peers(function(ok, why) record.calls[#record.calls + 1] = { ok, why } end)
	return record
end





-- =================================
-- =================================
-- ======= 1/ Starting Peers =======
-- =================================
-- =================================

helpers.describe("owned runtime owner: user-side process", function()
	helpers.it("refuses peers before admission and spawns nothing", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		owner.init(world.ports)
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, false)
		helpers.assert_eq(#record.calls, 0)
		helpers.assert_eq(#world.calls.spawn, 0)
	end)

	helpers.it("refuses peers after an unavailable admission", function()
		local owner, world = Fixture.load_owner(), Fixture.new_world()
		world.listing_text = Fixture.listing("6.0.0", "activated enabled")
		owner.init(world.ports)
		owner.start({ close_other_instances = true, capture = false })
		helpers.assert_eq(start_peers(owner).accepted, false)
		helpers.assert_eq(#world.calls.spawn, 0)
	end)

	helpers.it("does not start the process while the owned configuration is missing", function()
		local owner, world = admitted(false, function(w)
			w.files["/home/user/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json"] = nil
		end)
		local record = start_peers(owner)
		helpers.assert_eq(record.accepted, true)
		helpers.assert_eq(record.calls[1], { false, "owned_configuration_missing" })
		helpers.assert_eq(#world.calls.spawn, 0)
		helpers.assert_eq(owner.status().state, "admitted")
	end)

	helpers.it("starts the owned Console with Ergopti's configuration home and the owner PID", function()
		local owner, world = admitted(false)
		local record = start_peers(owner)
		helpers.assert_eq(record.calls[1], { true, "ready" })
		helpers.assert_eq(#world.calls.spawn, 1)
		local spawn = world.calls.spawn[1]
		helpers.assert_eq(spawn.executable, require("platform.remap.ke_paths").OWNED.CONSOLE)
		helpers.assert_eq(spawn.arguments, { "--owner-pid", "4242" })
		helpers.assert_eq(spawn.environment, { XDG_CONFIG_HOME = "/home/user/Library/Application Support/ErgoptiPlus" })
		helpers.assert_eq(owner.status().state, "ready")
		helpers.assert_eq(owner.status().peer, "running")
		helpers.assert_eq(#world.calls.capture_start, 0)
	end)

	helpers.it("is idempotent once ready", function()
		local owner, world = admitted(false)
		start_peers(owner)
		local again = start_peers(owner)
		helpers.assert_eq(again.calls[1], { true, "already-ready" })
		helpers.assert_eq(#world.calls.spawn, 1)
	end)

	helpers.it("fails, without a retry, when the process cannot start", function()
		local owner, world = admitted(false, function(w) w.peer_starts = false end)
		local record = start_peers(owner)
		helpers.assert_eq(record.calls[1], { false, "peer_spawn_failed" })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(owner.status().peer, "none")
		helpers.assert_eq(#world.calls.spawn, 1)
	end)

	helpers.it("starts the pinned capture only after the process, and only when requested", function()
		local owner, world = admitted(true)
		start_peers(owner)
		helpers.assert_eq(world.calls.capture_start, { { executable = "/owned/cli" } })
		helpers.assert_eq(owner.status().capture.state, "capturing")
	end)

	helpers.it("fails when the capture refuses and still stops the retained process", function()
		local owner, world = admitted(true, function(w) w.capture_accepts = false end)
		local record = start_peers(owner)
		helpers.assert_eq(record.calls[1], { false, "capture_start_refused" })
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(owner.status().peer, "running")
		helpers.assert_eq(owner.stop(), true)
		helpers.assert_eq(world.calls.terminate, 1)
		helpers.assert_eq(owner.status().peer, "none")
	end)
end)





-- =====================================
-- =====================================
-- ======= 2/ Losing The Process =======
-- =====================================
-- =====================================

helpers.describe("owned runtime owner: a lost process", function()
	helpers.it("reports the loss once, revokes the capture and never restarts by itself", function()
		local owner, world = admitted(true)
		start_peers(owner)
		world.exit_peer(9)
		helpers.assert_eq(owner.status().state, "failed")
		helpers.assert_eq(owner.status().reason, "peer_exited")
		helpers.assert_contains(owner.status().explanation, "9")
		helpers.assert_eq(world.calls.capture_stop, 1)
		helpers.assert_eq(#world.calls.spawn, 1)
		local failed = 0
		for _, state in ipairs(world.calls.states) do
			if state == "failed" then failed = failed + 1 end
		end
		helpers.assert_eq(failed, 1)
	end)

	helpers.it("refuses a new admission while the lost process or capture is retained", function()
		local owner, world = admitted(true, function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		world.exit_peer(1)
		helpers.assert_eq(owner.start({ close_other_instances = true, capture = true }), false)
		world.capture_stop_callback()
		helpers.assert_eq(owner.start({ close_other_instances = true, capture = true }), false)
	end)
end)





-- ===================================
-- ===================================
-- ======= 3/ Stop And Restart =======
-- ===================================
-- ===================================

helpers.describe("owned runtime owner: stop", function()
	helpers.it("revokes the capture before it terminates the process", function()
		local owner, world = admitted(true, function(w) w.capture_settles_sync = false end)
		start_peers(owner)
		local stopped = 0
		local settled, pending = owner.stop(function() stopped = stopped + 1 end)
		helpers.assert_eq(settled, false)
		helpers.assert_eq(pending, "capture_pending")
		helpers.assert_eq(world.calls.terminate, 0)
		world.capture_stop_callback()
		helpers.assert_eq(world.calls.terminate, 1)
		helpers.assert_eq(owner.status().state, "stopped")
		helpers.assert_eq(stopped, 1)
	end)

	helpers.it("does not settle until the process is observed gone, and retries the same handle", function()
		local owner, world = admitted(false, function(w) w.peer_settles_on_terminate = false end)
		start_peers(owner)
		local settled, pending = owner.stop()
		helpers.assert_eq(settled, false)
		helpers.assert_eq(pending, "peer_pending")
		owner.stop()
		helpers.assert_eq(world.calls.terminate, 2)
		helpers.assert_eq(#world.calls.spawn, 1)
		helpers.assert_eq(owner.status().state, "stopping")
		world.exit_peer(0)
		helpers.assert_eq(owner.status().state, "stopped")
	end)

	helpers.it("settles at once when nothing was started", function()
		local owner = Fixture.load_owner()
		local world = Fixture.new_world()
		owner.init(world.ports)
		helpers.assert_eq(owner.stop(), true)
		helpers.assert_eq(owner.status().state, "stopped")
	end)

	helpers.it("is idempotent once stopped and never calls the observer twice", function()
		local owner = admitted(false)
		start_peers(owner)
		local calls = 0
		owner.stop(function() calls = calls + 1 end)
		owner.stop(function() calls = calls + 1 end)
		helpers.assert_eq(calls, 1)
	end)

	helpers.it("restarts only on request, through a settled stop", function()
		local owner, world = admitted(false)
		start_peers(owner)
		local settled
		helpers.assert_eq(owner.restart({ close_other_instances = true, capture = false },
			function(ok) settled = ok end), true)
		helpers.assert_eq(settled, true)
		helpers.assert_eq(world.calls.terminate, 1)
		helpers.assert_eq(owner.status().state, "admitted")
		helpers.assert_eq(start_peers(owner).calls[1], { true, "ready" })
		helpers.assert_eq(#world.calls.spawn, 2)
	end)

	helpers.it("refuses a restart while the previous stop is pending", function()
		local owner, world = admitted(false, function(w) w.peer_settles_on_terminate = false end)
		start_peers(owner)
		helpers.assert_eq(owner.restart({ close_other_instances = true, capture = false }), false)
		helpers.assert_eq(#world.calls.spawn, 1)
	end)
end)





-- ==========================
-- ==========================
-- ======= 4/ Release =======
-- ==========================
-- ==========================

helpers.describe("owned runtime owner: release", function()
	helpers.it("refuses while a process is retained and allows a new binding after the stop", function()
		local owner, world = admitted(false)
		start_peers(owner)
		helpers.assert_eq(owner.release(), false)
		helpers.assert_eq(owner.init(Fixture.new_world().ports), false)
		owner.stop()
		helpers.assert_eq(owner.release(), true)
		helpers.assert_eq(owner.status().state, "uninitialized")
		helpers.assert_eq(owner.init(world.ports), true)
	end)
end)

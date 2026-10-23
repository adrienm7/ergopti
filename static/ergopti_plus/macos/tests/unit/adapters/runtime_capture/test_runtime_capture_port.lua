--- tests/unit/adapters/runtime_capture/test_runtime_capture_port.lua

--- ==============================================================================
--- MODULE: Owned Runtime Capture Port
--- DESCRIPTION:
--- Pins how adapters/runtime_capture_port.lua drives the managed physical
--- history session for the owned runtime: only the pinned declaration and the
--- bundle-bound launcher reach the session, a managed session is single-use, its
--- status is normalized to what the runtime owner understands, a refusal after
--- the start is pushed once, and a stop keeps one observer identity however many
--- times the owner retries it.
---
--- ROOT CAUSES ENCODED: (a) the runtime owner retries a pending stop with a new
--- closure each time, but the session accepts one observer identity, so a naive
--- pass-through would silently drop the settlement; (b) the history policy has
--- many internal states and the owner must not learn them; (c) a caller-chosen
--- executable or role would let anything run as the capture.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAUNCHER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

local PIN = { requirement = "identifier \"com.ergoptiplus.app\"", batch_limit = 64, frame_limit = 65536,
	history_capacity = 4096 }

--- Copies the pin with overrides.
--- @param overrides table|nil Replacement fields; false removes one.
--- @return table pin
local function pin_with(overrides)
	local pin = {}
	for key, value in pairs(PIN) do pin[key] = value end
	for key, value in pairs(overrides or {}) do
		if value == false then pin[key] = nil else pin[key] = value end
	end
	return pin
end

--- Builds the port over a modelled session and installed source.
--- @param tweak function|nil Receives the world before the port is built.
--- @return table port
--- @return table world
local function load_port(tweak)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.runtime_capture_port"] = nil
	package.loaded["adapters.installed_physical_source"] = nil
	local world = { prepared = {}, started = {}, stops = {}, shutdowns = 0, state = "prepared", retired = false,
		available = true, start_result = true, prepare_refused = false, closed_value = true }
	if tweak then tweak(world) end
	local manager = {}
	function manager.start(options)
		world.started[#world.started + 1] = options
		return world.start_result, world.start_failure
	end
	function manager.stop(observer)
		world.stops[#world.stops + 1] = observer
		return true
	end
	function manager.retired() return world.retired end
	function manager.status() return { state = world.state } end
	world.manager = manager
	local source = {
		available = function() return world.available, world.available_reason end,
		launcher = function() return LAUNCHER end,
		spawn = function() error("only the session spawns through this port") end,
		shutdown = function() world.shutdowns = world.shutdowns + 1 end,
		closed = function() return world.closed_value end,
	}
	local history = { prepare_managed_metrics = function(capacity, on_refused, spawn)
		world.prepared[#world.prepared + 1] = { capacity = capacity, on_refused = on_refused, spawn = spawn }
		if world.prepare_refused then return nil, "physical_history_media_preparation_failed" end
		return manager
	end }
	world.source = source
	local port = require("adapters.runtime_capture_port").new({ source = source, history = history })
	return port, world
end





-- ============================
-- ============================
-- ======= 1/ Starting  =======
-- ============================
-- ============================

helpers.describe("runtime capture port: start", function()
	helpers.it("starts the managed session from the pinned declaration and the bundle-bound launcher only", function()
		local port, world = load_port()
		helpers.assert_eq(port.start(PIN), true)
		helpers.assert_eq(world.prepared[1].capacity, 4096)
		helpers.assert_true(rawequal(world.prepared[1].spawn, world.source.spawn))
		helpers.assert_eq(world.started, { {
			executable = LAUNCHER,
			arguments = { "--installed-physical-source" },
			requirement = PIN.requirement,
			batch_limit = 64,
			frame_limit = 65536,
		} })
	end)

	helpers.it("refuses an incomplete or malformed declaration before preparing anything", function()
		for _, overrides in ipairs({
			{ requirement = false }, { requirement = "" }, { requirement = "a\nb" }, { requirement = 5 },
			{ batch_limit = false }, { batch_limit = 0 }, { batch_limit = 1.5 }, { batch_limit = "64" },
			{ frame_limit = false }, { frame_limit = -1 },
			{ history_capacity = false }, { history_capacity = 0 },
		}) do
			local port, world = load_port()
			helpers.assert_eq(port.start(pin_with(overrides)), false)
			helpers.assert_eq(#world.prepared, 0)
		end
		local port, world = load_port()
		helpers.assert_eq(port.start(nil), false)
		helpers.assert_eq(port.start("capture"), false)
		helpers.assert_eq(#world.prepared, 0)
	end)

	helpers.it("takes no executable or arguments from the declaration", function()
		local port, world = load_port()
		port.start(pin_with({ executable = "/bin/sh", arguments = { "-c", "true" } }))
		helpers.assert_eq(world.started[1].executable, LAUNCHER)
		helpers.assert_eq(world.started[1].arguments, { "--installed-physical-source" })
	end)

	helpers.it("is single-use: a second start is refused and prepares nothing", function()
		local port, world = load_port()
		helpers.assert_eq(port.start(PIN), true)
		helpers.assert_eq(port.start(PIN), false)
		helpers.assert_eq(#world.prepared, 1)
		helpers.assert_eq(#world.started, 1)
	end)

	helpers.it("names an unavailable installed source and prepares nothing", function()
		local port, world = load_port(function(w) w.available = false; w.available_reason = "no bundle" end)
		helpers.assert_eq(port.start(PIN), false)
		helpers.assert_eq(#world.prepared, 0)
	end)

	helpers.it("fails when the managed session is refused or refuses to start", function()
		local refused, refused_world = load_port(function(w) w.prepare_refused = true end)
		helpers.assert_eq(refused.start(PIN), false)
		helpers.assert_eq(#refused_world.started, 0)
		local declined, declined_world = load_port(function(w) w.start_result = false; w.start_failure = "busy" end)
		helpers.assert_eq(declined.start(PIN), false)
		helpers.assert_eq(#declined_world.started, 1)
	end)
end)





-- =============================
-- =============================
-- ======= 2/ Observing  =======
-- =============================
-- =============================

helpers.describe("runtime capture port: status and loss", function()
	helpers.it("reports stopped before any session exists", function()
		local port = load_port()
		helpers.assert_eq(port.status(), { state = "stopped" })
	end)

	helpers.it("normalizes the policy's states to starting, admitted and stopped", function()
		local port, world = load_port()
		port.start(PIN)
		for state, expected in pairs({
			prepared = "starting", starting = "starting", waiting = "starting", suspended = "starting",
			suspending = "starting", admitted = "admitted", retiring = "stopped", terminal = "stopped",
			stopped = "stopped", retired = "stopped", unheard_of = "stopped",
		}) do
			world.state = state
			helpers.assert_eq(port.status(), { state = expected }, state)
		end
	end)

	helpers.it("pushes a refusal of the session once, with its reason", function()
		local port, world = load_port()
		local seen = {}
		port.on_lost(function(reason) seen[#seen + 1] = reason end)
		port.start(PIN)
		world.prepared[1].on_refused("physical_history_policy_refused")
		world.prepared[1].on_refused("again")
		helpers.assert_eq(seen, { "physical_history_policy_refused" })
	end)

	helpers.it("contains a failing loss observer", function()
		local port, world = load_port()
		port.on_lost(function() error("observer broke") end)
		port.start(PIN)
		world.prepared[1].on_refused("gone")
		helpers.assert_eq(port.status(), { state = "starting" })
	end)

	helpers.it("rejects a loss observer that is not a function", function()
		local port = load_port()
		helpers.assert_throws(function() port.on_lost("observer") end)
	end)
end)





-- ===========================
-- ===========================
-- ======= 3/ Stopping =======
-- ===========================
-- ===========================

helpers.describe("runtime capture port: stop", function()
	helpers.it("is settled at once when no session exists", function()
		local port, world = load_port()
		helpers.assert_eq(port.stop(function() end), true)
		helpers.assert_eq(world.shutdowns, 0)
	end)

	helpers.it("reports pending until the session is retired, then releases the native owner once", function()
		local port, world = load_port()
		port.start(PIN)
		helpers.assert_eq(port.stop(function() end), false)
		helpers.assert_eq(world.shutdowns, 0)
		world.retired = true
		helpers.assert_eq(port.stop(function() end), true)
		helpers.assert_eq(port.stop(function() end), true)
		helpers.assert_eq(world.shutdowns, 1)
	end)

	helpers.it("hands the session one observer identity however often the owner retries", function()
		local port, world = load_port()
		port.start(PIN)
		local first_calls, second_calls = 0, 0
		port.stop(function() first_calls = first_calls + 1 end)
		port.stop(function() second_calls = second_calls + 1 end)
		helpers.assert_eq(#world.stops, 2)
		helpers.assert_true(rawequal(world.stops[1], world.stops[2]))
		world.stops[1](true)
		helpers.assert_eq(first_calls, 0, "the latest owner closure is the one notified")
		helpers.assert_eq(second_calls, 1)
		helpers.assert_eq(world.shutdowns, 1)
	end)

	helpers.it("ignores a notification that is not the literal true", function()
		local port, world = load_port()
		port.start(PIN)
		local calls = 0
		port.stop(function() calls = calls + 1 end)
		world.stops[1](false)
		world.stops[1](nil)
		helpers.assert_eq(calls, 0)
		helpers.assert_eq(world.shutdowns, 0)
	end)

	helpers.it("passes no observer to the session when the owner passes none", function()
		local port, world = load_port()
		port.start(PIN)
		port.stop()
		helpers.assert_nil(world.stops[1])
	end)

	helpers.it("rejects an observer that is not a function and delegates closed to the source", function()
		local port, world = load_port()
		helpers.assert_throws(function() port.stop("observer") end)
		helpers.assert_eq(port.closed(), true)
		world.closed_value = false
		helpers.assert_eq(port.closed(), false)
	end)
end)

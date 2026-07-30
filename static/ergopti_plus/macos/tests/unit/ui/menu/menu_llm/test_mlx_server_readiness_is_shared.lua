--- tests/unit/ui/menu/menu_llm/test_mlx_server_readiness_is_shared.lua

--- ==============================================================================
--- MODULE: Regression — a duplicate start_server must join, not resolve early
--- DESCRIPTION:
--- The boot sequence dispatches an MLX requirements check twice: a primary chain
--- and a 3 s "backup". The guard between them compares a generation counter that is
--- bumped only at TERMINAL outcomes, so it asks "has the other chain FINISHED?"
--- when the question it must answer is "has the other chain STARTED?". On the MLX
--- path a terminal outcome is 60-90 s away, so at t=3 s the counter always still
--- matches and the backup always dispatches a second, concurrent check.
---
--- ROOT CAUSE ENCODED, and deliberately not at the dispatcher. The second dispatch
--- lands on start_server's reuse short-circuit, which resolved on
--- `existing:isRunning()`. That says the PROCESS is alive — not that the model is
--- loaded — so the duplicate caller's on_success fired while the first caller's
--- readiness probe was still running: sixty to ninety seconds early, with the
--- prediction path told the model was ready before its weights were resident.
---
--- The dispatcher is left alone on purpose.
--- tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua asserts
--- `#captured_checks == 2` in three places, under this exact setup; gating the
--- backup would turn all three red and its own test would be their negation. Fixing
--- the SINK is below the seam that test stubs, so a duplicate dispatch becomes
--- harmless instead of forbidden.
---
--- PROVENANCE: source invariant. start_server spawns a detached Python server and
--- drives a 120-retry readiness probe; the branch under test is chosen from live
--- hs.task state, so driving it end to end would mean simulating the whole server
--- lifecycle.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the readiness marker, which is the function this fix moves state into.
local ANCHOR = "mark_server_ready"




-- ==================================================================
-- ==================================================================
-- ======= 1/ Readiness is shared, not per-invocation ===============
-- ==================================================================
-- ==================================================================

--- @return string Comment-stripped source of the MLX server mixin.
local function server_code()
	local src = helpers.read_driver_source(ANCHOR)
	helpers.assert_true(src ~= nil and src ~= "",
		"the MLX server mixin must be locatable by '" .. ANCHOR .. "'; an empty corpus "
		.. "would make every assertion below vacuous")
	return (src:gsub("%-%-[^\n]*", ""))
end


helpers.describe("MLX server: a duplicate start joins the startup in flight", function()

	helpers.it("does not resolve the reuse path on isRunning alone", function()
		local code = server_code()

		local at = code:find("obj._server_target == target_model", 1, true)
		helpers.assert_true(at ~= nil, "the reuse short-circuit must still exist")
		local branch = code:sub(at, at + 900)

		helpers.assert_true(branch:find("obj._server_ready", 1, true) ~= nil,
			"isRunning() means the PROCESS is alive, not that the model is loaded. "
			.. "Resolving on it told a duplicate caller the server was ready 60-90 s "
			.. "before its weights were resident, so readiness has to be its own state")
	end)

	helpers.it("queues a caller that arrives during startup", function()
		local code = server_code()
		local at = code:find("obj._server_target == target_model", 1, true)
		local branch = code:sub(at, at + 900)

		helpers.assert_true(branch:find("_server_waiters", 1, true) ~= nil,
			"a caller arriving before readiness must be able to wait. Dropping its "
			.. "callback instead would recreate the never-released prediction lock that "
			.. "several guards in this file exist to prevent")
	end)

	helpers.it("drains every waiter exactly once when the server becomes ready", function()
		local code = server_code()
		local at = code:find("local function " .. ANCHOR, 1, true)
		helpers.assert_true(at ~= nil, "mark_server_ready must exist")
		local body = code:sub(at, at + 700)

		helpers.assert_true(body:find("obj._server_ready = true", 1, true) ~= nil,
			"readiness must be published where a LATER call can see it")
		helpers.assert_true(body:find("obj._server_waiters = {}", 1, true) ~= nil,
			"and the queue must be cleared before the callbacks run, or a waiter added "
			.. "from inside one of them would be invoked twice")
	end)

	helpers.it("a fresh launch clears the previous readiness", function()
		local code = server_code()

		-- Without this the state would be sticky: a server terminated for a model
		-- switch would leave _server_ready = true, and the next duplicate request
		-- would resolve against a process that no longer exists.
		local at = code:find("local startup_confirmed = false", 1, true)
		helpers.assert_true(at ~= nil, "the launch path must still be findable")
		local body = code:sub(at, at + 400)
		helpers.assert_true(body:find("obj._server_ready = false", 1, true) ~= nil,
			"a fresh launch must reset readiness, or a stale true resolves a duplicate "
			.. "request against a terminated process")
	end)

	helpers.it("an adopted server counts as ready", function()
		local code = server_code()

		-- The cross-session adoption path skips the launch entirely: the weights are
		-- already resident. A duplicate request must resolve there rather than queue
		-- behind a startup that will never run.
		local at = code:find("Adopting MLX server from a previous session", 1, true)
		helpers.assert_true(at ~= nil, "the adoption path must still be findable")
		local body = code:sub(at, at + 700)
		helpers.assert_true(body:find("obj._server_ready = true", 1, true) ~= nil,
			"an adopted server is ready; queueing against it would hang every later "
			.. "caller forever, since no probe is running to drain the queue")
	end)

end)

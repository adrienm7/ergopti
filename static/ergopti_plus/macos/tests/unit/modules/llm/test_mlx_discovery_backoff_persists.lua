--- tests/unit/modules/llm/test_mlx_discovery_backoff_persists.lua

--- ==============================================================================
--- MODULE: Regression — the discovery backoff must survive a failed cycle
--- DESCRIPTION:
--- The inter-probe delay doubles on each miss, capped, which is the whole point
--- of a backoff. But it was a LOCAL of discover(), initialised to the initial
--- delay on entry — so a cycle that gave up and a caller that retried on the next
--- run-loop tick started again from the shortest interval. Against a server that
--- is down, that is a curl spawn and an HTTP POST per tick, indefinitely, with
--- the backoff resetting every time it was supposed to grow.
---
--- ROOT CAUSE ENCODED:
--- State that must outlive a call, scoped inside it. The reset belongs on the
--- SUCCESS path, where "the server answered" is the fact that justifies probing
--- eagerly again.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("api_mlx_discovery: the backoff is not reset by a new cycle", function()

	helpers.it("keeps the poll delay at module scope, not inside discover()", function()
		local src = helpers.read_driver_source("DISCOVERY_POLL_INITIAL_SEC")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the discovery source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")

		helpers.assert_true(code:find("local poll_delay_sec%s*=%s*DISCOVERY_POLL_INITIAL_SEC") == nil,
			"a delay re-initialised on entry to discover() means a failed cycle followed by a "
			.. "retry on the next tick probes at the shortest interval again, forever")
		helpers.assert_true(code:find("_poll_delay_sec", 1, true) ~= nil,
			"the backoff has to outlive the call whose failures grew it")
	end)

	helpers.it("resets the backoff only when discovery succeeds", function()
		local src = helpers.read_driver_source("_poll_delay_sec")
		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("_endpoints_discovered = true", 1, true)
		helpers.assert_not_nil(at, "the success path must exist")
		local body = code:sub(at, at + 400)
		helpers.assert_true(body:find("_poll_delay_sec", 1, true) ~= nil,
			"'the server answered' is the fact that justifies probing eagerly again; nothing "
			.. "else should shorten the interval")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= The ollama serve wrapper is reaped on quit ===============
-- ==================================================================
-- ==================================================================

--- stop_mlx_server only terminates the in-process wrapper; the same is true of
--- the `ollama serve` pipeline this driver launches through /bin/sh. It was not
--- on the helper-teardown list at all, so it survived every quit path and kept
--- appending to the Ergopti log after Hammerspoon was gone.
helpers.describe("quit: the ollama serve wrapper is terminated with the other helpers", function()

	helpers.it("terminate_helper_processes reaps it", function()
		local src = helpers.read_driver_source("terminate_helper_processes")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the menu_llm source must be readable or this asserts nothing")
		local at = src:find("function M.terminate_helper_processes", 1, true)
		helpers.assert_not_nil(at, "the teardown must exist")
		local body = src:sub(at, at + 900)
		helpers.assert_true(body:find("ollama serve", 1, true) ~= nil,
			"the wrapper is a /bin/sh pipeline, so terminating the hs.task reaps only the "
			.. "shell; without an explicit kill the server outlives every quit path")
	end)

end)

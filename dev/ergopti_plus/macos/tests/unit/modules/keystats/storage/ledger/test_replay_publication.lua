--- tests/unit/modules/keystats/storage/ledger/test_replay_publication.lua

--- ==============================================================================
--- MODULE: Local Replay Publication and Cleanup
--- DESCRIPTION:
--- Exercises actual manager initialization, ingestion and stop against physical
--- ledgers and the existing real-SQLite process bridge. Refused reads, SQL,
--- scheduling and durability restoration cannot admit a partial cache. This is
--- portable API qualification, not a claim about a physical macOS run loop.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote
local script = helpers.driver_root() .. "../../../tools/diagnostics/keystats_startup_replay_test.py"

local scenarios = {
	{ "cold cache yields before replay completes", "test_cold_cache_yields_before_replay_finishes" },
	{ "cancelled partial cache resumes after restart", "test_cancelled_partial_cache_replays_on_restart" },
	{ "warm outbox retains its newer cursor", "test_warm_outbox_cursor_never_rewinds_to_older_ledger" },
	{ "failed replay blocks live and final ingest", "test_replay_failures_block_both_ingest_paths_until_restart" },
	{ "metadata refusal retains the pending replay", "test_metadata_refusals_never_clear_the_pending_replay" },
	{ "durability refusal retains its cleanup owner", "test_durable_mode_refusal_retains_cleanup_and_blocks_publication" },
	{ "timer refusal retains the database", "test_timer_cancel_refusal_retains_the_database_until_exact_cleanup" },
}

helpers.describe("local ledger replay safety", function()
	for _, scenario in ipairs(scenarios) do
		helpers.it("local-ledger-replay-safety: " .. scenario[1], function()
			local command = "python3 " .. quote(script) .. " " .. quote("StartupReplayTests." .. scenario[2]) .. " 2>&1"
			local process = assert(io.popen(command, "r"))
			local output = assert(process:read("*a"))
			local accepted, kind, status = process:close()
			helpers.assert_eq(accepted, true, output)
			helpers.assert_eq(kind, "exit", output)
			helpers.assert_eq(status, 0, output)
			helpers.assert_contains(output, "Ran 1 test", output)
			helpers.assert_contains(output, "\nOK\n", output)
		end)
	end
end)

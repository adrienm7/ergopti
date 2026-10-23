--- tests/unit/modules/keystats/storage/test_cold_rollover_context.lua

--- ==============================================================================
--- MODULE: Cold Cache Rollover Context Regression
--- DESCRIPTION:
--- A final durable rollover retires typing continuity even when its disposable
--- SQLite cache disappears before the next queued typing entry is ingested.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.keystats.ledger_append_fixture")
local batch = "-- === ingest batch 2026-10-20 23:59:59.900 (offset 0 -> 99, 1 entry(ies)) ===\n"
	.. "BEGIN TRANSACTION;\nINSERT INTO example VALUES ('x');\nCOMMIT;\n"
local marker = "-- === day rollover 2026-10-20 -> 2026-10-21 ===\n"

local function cursor(ledger, scenario)
	fixture.with_manager(function(manager)
		local complete = require("modules.keystats.export")._last_complete_batch_offset(ledger)
		scenario(manager._local_ledger_replay_cursor(ledger, complete))
	end)
end

helpers.describe("cold cache rollover context", function()
	helpers.it("recognizes a final canonical marker (cold-rollover-context)", function()
		cursor(batch .. "\n" .. marker, function(value)
			helpers.assert_eq(value.trailing_rollover, true)
			helpers.assert_eq(value.offset, 0)
			helpers.assert_eq(value.date, "2026-10-21")
		end)
	end)

	helpers.it("recognizes repeated markers and the producer empty old date (cold-rollover-context)", function()
		cursor(batch .. "\n-- === day rollover  -> 2026-10-20 ===\n\n" .. marker, function(value)
			helpers.assert_eq(value.trailing_rollover, true)
			helpers.assert_eq(value.offset, 0)
			helpers.assert_eq(value.date, "2026-10-21")
		end)
	end)

	helpers.it("rejects marker text inside committed multiline SQL literals (cold-rollover-context)", function()
		local ledger = "BEGIN TRANSACTION;\nINSERT INTO example VALUES ('x\n" .. marker
			.. "quoted '' apostrophe\nCOMMIT;\nstill quoted');\nCOMMIT;\n"
		cursor(ledger, function(value)
			helpers.assert_eq(value.trailing_rollover, false,
				"committed user text cannot authorize a context reset")
		end)
	end)

	helpers.it("rejects malformed markers ordinary comments and torn SQL (cold-rollover-context)", function()
		for _, suffix in ipairs({
			"-- ordinary comment\n",
			"-- === day rollover unknown -> 2026-10-21 ===\n",
			"-- === day rollover 2026-10-20 -> 2026-1-21 ===\n",
			"-- === day rollover 2026-10-20 -> 2026-10-21 ==\n",
			marker .. "BEGIN TRANSACTION;\n",
			"BEGIN TRANSACTION;\n" .. marker,
			"-- === day rollover 2026-10-20\nBEGIN TRANSACTION;\n -> 2026-10-21 ===\n",
			marker .. "-- ordinary comment\n",
		}) do
			cursor(batch .. suffix, function(value)
				helpers.assert_eq(value.trailing_rollover, false, suffix)
			end)
		end
	end)

	helpers.it("preserves normal cursor continuity without a final marker (cold-rollover-context)", function()
		for _, ledger in ipairs({batch, batch:gsub("2026%-10%-20", "2026-10-21"),
			batch .. marker .. batch:gsub("2026%-10%-20", "2026-10-21")}) do
			cursor(ledger, function(value)
				helpers.assert_eq(value.trailing_rollover, false)
				helpers.assert_eq(value.offset, 99)
			end)
		end
		cursor("", function(value)
			helpers.assert_eq(value.trailing_rollover, false)
			helpers.assert_eq(value.date, nil)
		end)
	end)
end)

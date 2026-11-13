--- tests/unit/metrics/engine/storage/test_data_sql_outbox_fixture_scope.lua

--- ==============================================================================
--- MODULE: Data SQL Outbox Fixture Isolation Tests
--- DESCRIPTION:
--- Verifies exact module and native restoration after real ingest attempts or
--- an exception following construction of the real log manager.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.data_sql_outbox_fixture")

local OWNERS = {
	"core.fs.adapters.file_system", "core.timing.engine.timings", "metrics.engine.metrics",
	"metrics.engine.aggregator.aggregator", "metrics.engine.reader.export",
	"core.fs.adapters.ledger_append", "metrics.engine.journal.log_manager", "metrics.engine.journal.rotation",
	"metrics.engine.journal.sqlite_writer", "core.logger.engine.logger",
	"core.events.timer_scheduler", "metrics.engine.journal.timestamp",
}

helpers.describe("Data SQL outbox fixture isolation", function()
	for _, fail_construction in ipairs({ false, true }) do
		local label = fail_construction and "construction failure" or "successful observation"
		helpers.it("(outbox-fixture-scope) restores exact owners after " .. label, function()
			helpers.with_stub_scope(OWNERS, function()
				helpers.load_with_stubs("hs")
				local prior_hs = _G.hs
				local prior_export = {}
				package.loaded["metrics.engine.aggregator.aggregator"] = false
				package.loaded["metrics.engine.journal.rotation"] = nil
				package.loaded["metrics.engine.reader.export"] = prior_export
				local original_loader = helpers.load_with_stubs
				if fail_construction then
					helpers.load_with_stubs = function(name, ...)
						local result = original_loader(name, ...)
						if name == "metrics.engine.journal.log_manager" then error("outbox construction marker") end
						return result
					end
				end
				local ok, observed = pcall(Fixture.run_refused_transaction, "commit")
				helpers.load_with_stubs = original_loader
				if fail_construction then
					helpers.assert_eq(ok, false)
					helpers.assert_contains(tostring(observed), "outbox construction marker")
				else
					helpers.assert_eq(ok, true, tostring(observed))
					helpers.assert_eq(observed.reads, 2)
					helpers.assert_eq(observed.rollbacks, 4)
				end
				helpers.assert_nil(package.loaded["metrics.engine.journal.rotation"], "absent modules must not become sentinels")
				helpers.assert_eq(package.loaded["metrics.engine.aggregator.aggregator"], false)
				helpers.assert_true(package.loaded["metrics.engine.reader.export"] == prior_export)
				helpers.assert_true(_G.hs == prior_hs, "the fixture must restore the exact native host")
			end)
		end)
	end
end)

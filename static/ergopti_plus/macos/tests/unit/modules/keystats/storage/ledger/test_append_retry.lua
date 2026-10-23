--- tests/unit/modules/keystats/storage/ledger/test_append_retry.lua

--- ==============================================================================
--- MODULE: Canonical SQL Append Retry Regression
--- DESCRIPTION:
--- Real native files preserve the committed prefix across partial append receipts,
--- cache-independent retries, uncertain clears and foreign path/tail replacement.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keystats.ledger_append_fixture")

helpers.describe("local SQL append retry", function()
	helpers.it("publishes one healthy canonical batch", function()
		Fixture.with_manager(function(manager, state)
			manager.ingest_once()
			assert(state.outbox == "" and state.reads == 1)
			assert(state.bytes() == state.prefix .. state.batch)
		end)
	end)
	for _, fault in ipairs({ "write nil", "write throw", "write foreign", "close nil", "close throw", "close foreign" }) do
		helpers.it("resumes the exact batch after " .. fault, function()
			Fixture.with_manager(function(manager, state)
				state.fault = fault
				manager.ingest_once()
				assert(state.outbox == state.batch and state.reads == 0, "a refused receipt cannot clear the outbox")
				assert(state.close_count == 1, "every consumed stream must be closed exactly once")
				assert(state.bytes():sub(1, #state.prefix) == state.prefix)
				state.fault = nil
				state.restart().ingest_once()
				assert(state.outbox == "" and state.reads == 1)
				assert(state.bytes() == state.prefix .. state.batch, "retry must not append a second BEGIN or duplicate batch")
			end)
		end)
	end
	helpers.it("does not append again when the SQLite clear refused", function()
		Fixture.with_manager(function(manager, state)
			state.clear_refused = true; manager.ingest_once()
			assert(state.outbox == state.batch and state.reads == 0)
			assert(state.bytes() == state.prefix .. state.batch)
			state.clear_refused = false; state.restart().ingest_once()
			assert(state.outbox == "" and state.bytes() == state.prefix .. state.batch)
		end)
	end)
	for _, foreign in ipairs({ "tail", "inode", "batch" }) do
		helpers.it("refuses a foreign " .. foreign .. " instead of repairing it", function()
			Fixture.with_manager(function(manager, state)
				state.fault = "write nil"; manager.ingest_once(); state.fault = nil
				if foreign == "tail" then state.write(state.bytes() .. "FOREIGN") end
				if foreign == "inode" then
					state.write(state.bytes(), state.path .. ".replacement")
					assert(os.rename(state.path .. ".replacement", state.path))
				end
				if foreign == "batch" then state.outbox = state.batch .. "-- foreign outbox\n" end
				local before, outbox = state.bytes(), state.outbox
				state.restart().ingest_once()
				assert(state.bytes() == before and state.outbox == outbox and state.reads == 0)
			end)
		end)
	end
	helpers.it("refuses an unowned legacy torn tail before creating an intent", function()
		Fixture.with_manager(function(manager, state)
			state.write(state.prefix .. "BEGIN TRANSACTION;\nINSERT INTO")
			local before = state.bytes(); manager.ingest_once()
			assert(state.bytes() == before and state.outbox == state.batch and state.reads == 0)
		end)
	end)
end)

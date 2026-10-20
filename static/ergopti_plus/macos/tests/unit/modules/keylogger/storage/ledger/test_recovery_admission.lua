--- tests/unit/modules/keylogger/storage/ledger/test_recovery_admission.lua

--- ==============================================================================
--- MODULE: Durable Ledger Journal Admission
--- DESCRIPTION:
--- The durable pending batch remains authoritative across cache loss, ambiguous
--- SQLite clears, native read refusals and later legitimate rollover comments.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keylogger.ledger_append_fixture")

helpers.describe("durable ledger journal admission", function()
	helpers.it("repairs the pending tail before fresh-cache replay", function()
		Fixture.with_manager(function(manager, state)
			state.fault = "write nil"; manager.ingest_once(); state.fault = nil
			state.outbox = ""
			state.restart()
			local ledger = require("adapters.ledger_append")
			assert(ledger.recover(state.path, ""))
			assert(state.bytes() == state.prefix .. state.batch, "replay must see a complete canonical batch")
			assert(state.journal().phase == "pending", "recovery cannot claim SQLite replay or clear")
			state.restart().ingest_once()
			assert(state.journal().phase == "settled" and state.bytes() == state.prefix .. state.batch)
		end)
	end)
	helpers.it("settles an uncertain SQLite clear without replaying canonical SQL", function()
		Fixture.with_manager(function(manager, state)
			state.clear_uncertain = true; manager.ingest_once()
			assert(state.outbox == "" and state.reads == 0 and state.journal().phase == "pending")
			state.clear_uncertain = false; state.restart().ingest_once()
			assert(state.reads == 1 and state.journal().phase == "settled")
			assert(state.bytes() == state.prefix .. state.batch)
		end)
	end)
	helpers.it("retains pending publication when the terminal journal write refuses", function()
		Fixture.with_manager(function(manager, state)
			local write = state.files.write_if_unchanged
			state.files.write_if_unchanged = function(path, content, ...)
				if content:find('"settled"', 1, true) then return false end
				return write(path, content, ...)
			end
			manager.ingest_once()
			assert(state.outbox == "" and state.reads == 0 and state.journal().phase == "pending")
			state.files.write_if_unchanged = write
			state.restart().ingest_once()
			assert(state.journal().phase == "settled" and state.reads == 1)
			assert(state.bytes() == state.prefix .. state.batch)
		end)
	end)
	for _, fault in ipairs({ "read nil", "read throw", "close false" }) do
		helpers.it("requires the exact read and close receipts after " .. fault, function()
			Fixture.with_manager(function(manager, state)
				state.read_fault = fault; manager.ingest_once()
				assert(state.bytes() == state.prefix and state.outbox == state.batch and state.reads == 0)
				assert(state.close_count == 1 and state.journal().phase == "pending")
				state.read_fault = nil; state.restart().ingest_once()
				assert(state.bytes() == state.prefix .. state.batch and state.outbox == "")
			end)
		end)
	end
	helpers.it("permits a later rollover and a different batch after settlement", function()
		Fixture.with_manager(function(manager, state)
			manager.ingest_once()
			local previous = state.bytes() .. "-- legitimate rollover\n"
			state.write(previous)
			state.outbox = state.batch:gsub("'new'", "'next'")
			local next_batch = state.outbox
			state.restart().ingest_once()
			assert(state.bytes() == previous .. next_batch and state.outbox == "")
		end)
	end)
	for _, complete in ipairs({ true, false }) do
		helpers.it("validates a replaced settled origin, complete=" .. tostring(complete), function()
			Fixture.with_manager(function(manager, state)
				manager.ingest_once()
				local replacement = state.prefix .. (complete and "" or "BEGIN TRANSACTION;\nINSERT INTO")
				state.write(replacement, state.path .. ".compact")
				assert(os.rename(state.path .. ".compact", state.path))
				state.outbox = state.batch
				state.restart().ingest_once()
				if complete then assert(state.bytes() == replacement .. state.batch and state.outbox == "")
				else assert(state.bytes() == replacement and state.outbox == state.batch) end
			end)
		end)
	end
	helpers.it("blocks rollover before any canonical marker while a tail is refused", function()
		Fixture.with_manager(function(manager, state)
			state.activate()
			state.fault = "write nil"; manager.ingest_once()
			local before = state.bytes()
			-- A refused clear keeps the same pending append owner through rollover.
			state.fault = nil; state.clear_refused = true
			assert(manager.day_rollover() == false)
			assert(state.rotations == nil and state.outbox == state.batch)
			assert(state.bytes():sub(1, #before) == before)
		end)
	end)
	helpers.it("retains refused native cleanup in the manager teardown after SQLite closes", function()
		Fixture.with_manager(function(manager, state)
			local release, refused, retained = state.files.release_write_locks, true, nil
			state.files.release_write_locks = function(group)
				if refused then
					if retained then assert(retained == group, "cleanup must retain its exact capability") end
					retained = group; return false, "public filesystem release refused"
				end
				return release(group)
			end
			manager.ingest_once()
			assert(state.outbox == "" and state.bytes() == state.prefix .. state.batch and state.reads == 0)
			local stopped = manager.stop({ process_exit = true })
			assert(stopped == false and state.closed, "native cleanup debt must retain the lifecycle retry")
			refused = false
			assert(manager.stop({ process_exit = true }) == true, "cleanup must retry even after the DB closes")
			assert(state.bytes() == state.prefix .. state.batch and state.outbox == "",
				"teardown cleanup cannot append or replay SQL")
			state.restart().ingest_once()
			assert(state.outbox == "" and state.bytes() == state.prefix .. state.batch)
		end)
	end)
	helpers.it("does not need to reread the historical prefix for a later batch", function()
		Fixture.with_manager(function(manager, state)
			manager.ingest_once()
			state.outbox = state.batch:gsub("'new'", "'next'")
			local read = state.files.read_with_status
			state.files.read_with_status = function(path, ...)
				assert(path ~= state.path, "normal journaled batches must remain O(batch)")
				return read(path, ...)
			end
			state.restart().ingest_once()
			assert(state.outbox == "" and state.reads == 2)
		end)
	end)
end)

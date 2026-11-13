--- tests/unit/metrics/engine/storage/test_ledger_replay_chunk_boundaries.lua

--- Exercises SQL and cursor evidence across native read boundaries.
local helpers = require("tests.helpers")
local Replay = require("metrics.engine.reader.ledger_replay")

local first = "-- === ingest batch 2026-10-20 12:00:00.000 (offset 0 -> 5, 1 entry(ies)) ===\n"
	.. "BEGIN TRANSACTION;\nINSERT INTO t VALUES('one');\nCOMMIT;\n"
local marker = "-- === day rollover 2026-10-20 -> 2026-10-21 ===\n"
local second = "-- === ingest batch 2026-10-21 12:00:00.000 (offset 0 -> 9, 1 entry(ies)) ===\n"
	.. "BEGIN TRANSACTION;\nINSERT INTO t VALUES('it''s -- literal\nCOMMIT;\ninside');\nCOMMIT;\n"
local cases = {
	{ name = "escaped quote and false commit", complete = first .. second, tail = "" },
	{ name = "rollover then transaction", complete = first .. marker .. second, tail = "" },
	{ name = "committed marker and torn literal", complete = first .. marker .. second,
		tail = "BEGIN TRANSACTION;\nINSERT INTO t VALUES('unfinished\nCOMMIT;\n" },
	{ name = "rollover-only tail", complete = first, tail = marker },
	{ name = "comment with false boundary", complete = first .. "-- COMMIT; is a comment\n" .. second, tail = "" },
}

--- Replays one real file, deliberately yielding at every applied block.
local function replay(path, size, block_size)
	Replay.READ_BYTES = block_size
	local state, applied = Replay.new_state(), {}
	local status, cursor
	repeat
		status, cursor = Replay.step({
			path = path, size = size, state = state,
			exec = function(sql) applied[#applied + 1] = sql; return true end,
			clock = function() return 1 end, deadline = 0,
			cursor = function(bytes, complete) return { bytes = bytes, complete = complete } end,
		})
	until status ~= "more"
	return status, table.concat(applied), cursor, state.offset
end

helpers.describe("ledger replay is independent of native read boundaries", function()
	for _, case in ipairs(cases) do
		helpers.it(case.name, function()
			local bytes = case.complete .. case.tail
			local path = os.tmpname()
			local stream = assert(io.open(path, "wb"))
			assert(stream:write(bytes)); assert(stream:close())
			local old_size = Replay.READ_BYTES
			local ok, err = xpcall(function()
				local status, sql, cursor, offset = replay(path, #bytes, #bytes + 1)
				helpers.assert_eq(status, "done")
				helpers.assert_eq(sql, case.complete)
				helpers.assert_eq(offset, #case.complete)
				if case.name == "rollover-only tail" then
					helpers.assert_true(cursor.bytes:find(marker, 1, true) ~= nil)
				end
				for _, block in ipairs({ 1, 2, 3, 7, 8, 9, 15, 31 }) do
					local got_status, got_sql, got_cursor, got_offset = replay(path, #bytes, block)
					helpers.assert_eq(got_status, status)
					helpers.assert_eq(got_sql, sql)
					helpers.assert_eq(got_offset, offset)
					helpers.assert_eq(got_cursor, cursor)
				end
			end, debug.traceback)
			Replay.READ_BYTES = old_size
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end
end)

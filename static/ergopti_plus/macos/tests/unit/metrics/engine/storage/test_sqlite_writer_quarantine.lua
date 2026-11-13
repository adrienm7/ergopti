--- tests/unit/metrics/engine/storage/test_sqlite_writer_quarantine.lua

--- An unproved rollback must not leave the writer usable by another owner.
local helpers = require("tests.helpers")

helpers.describe("SQLite writer quarantine", function()
	for _, failure in ipairs({ false, true }) do
		helpers.it("unpublishes the exact poisoned handle before close, refusal=" .. tostring(failure), function()
			local writer = helpers.load_with_stubs("metrics.engine.journal.sqlite_writer")
			local writes = 0
			local db = {
				close = function()
					helpers.assert_eq(writer.get_db(), nil, "handle must be unpublished before native close")
					return failure and 5 or 0
				end,
				isopen = function() return false end,
				exec = function() writes = writes + 1; return 0 end,
			}
			local index
			for i = 1, math.huge do
				local name = debug.getupvalue(writer.get_db, i)
				assert(name, "writer handle upvalue missing")
				if name == "_db" then index = i; break end
			end
			debug.setupvalue(writer.get_db, index, db)
			helpers.assert_eq(writer.quarantine_db({}), false, "a different owner must not be retired")
			helpers.assert_eq(writer.get_db(), db)
			helpers.assert_eq(writer.quarantine_db(db), not failure)
			helpers.assert_eq(writer.get_db(), nil)
			helpers.assert_eq(writer.apply_typing_updates("device", {}), false)
			helpers.assert_eq(writer.set_meta("cursor", "1"), false)
			helpers.assert_eq(writes, 0, "another owner cannot acknowledge a write on the poisoned handle")
		end)
	end
	helpers.it("unpublishes during a source lease and closes only after release", function()
		local writer = helpers.load_with_stubs("metrics.engine.journal.sqlite_writer")
		local closes = 0
		local db = { close = function() closes = closes + 1; return 0 end }
		for i = 1, math.huge do
			local name = debug.getupvalue(writer.get_db, i)
			assert(name, "writer handle upvalue missing")
			if name == "_db" then debug.setupvalue(writer.get_db, i, db); break end
		end
		helpers.assert_eq(writer.acquire_backup_source(db), true)
		helpers.assert_eq(writer.close_db(), false)
		helpers.assert_eq(closes, 0)
		helpers.assert_eq(writer.quarantine_db(db), false)
		helpers.assert_eq(writer.get_db(), nil)
		helpers.assert_eq(writer.apply_typing_updates("device", {}), false)
		helpers.assert_eq(closes, 0, "backup must release the source before native close")
		helpers.assert_eq(writer.release_backup_source(db), true)
		helpers.assert_eq(closes, 1)
	end)
end)

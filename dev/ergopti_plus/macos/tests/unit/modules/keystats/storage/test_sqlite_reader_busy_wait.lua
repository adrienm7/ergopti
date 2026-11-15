--- tests/unit/modules/keystats/storage/test_sqlite_reader_busy_wait.lua

--- ==============================================================================
--- MODULE: sqlite_reader waits for the writer's lock (metrics dashboard)
--- DESCRIPTION:
--- db.sqlite uses a rollback journal (docs/memory/maintainer-decisions.md,
--- « Metrics dashboard »), so the writer's COMMIT locks readers out for a few
--- milliseconds. The reader opened with no busy wait: that read failed at once
--- with SQLITE_BUSY and the dashboard projected nothing, or part of the store.
--- It now waits for the registry's `sqlite_read_busy_timeout_ms` before it
--- refuses. A hot journal is not waited for: it stays the writer's to recover.
--- ==============================================================================

local helpers = require("tests.helpers")

local OPEN_READONLY = 0x1

--- Loads the reader over a recording sqlite3 double.
--- @return table reader, table execs Statements run on every handle, in order.
local function load_reader()
	local execs = {}
	local sqlite3 = { OK = 0, OPEN_READONLY = OPEN_READONLY }
	function sqlite3.open(_, flags)
		assert(flags == OPEN_READONLY, "the dashboard opens read-only")
		return {
			exec = function(_, sql) execs[#execs + 1] = sql; return 0 end,
			close = function() return 0 end,
			nrows = function() return function() return nil end end,
		}
	end
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	helpers.provide_timings()
	return helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite3 }), execs
end

helpers.describe("sqlite_reader busy wait (rollback-journal store)", function()
	for _, call in ipairs({
		{ "read_manifest", function(reader) return reader.read_manifest("/db.sqlite") end },
		{ "read_ngrams", function(reader) return reader.read_ngrams("/db.sqlite", "2026-10-01", "2026-10-21") end },
		{ "fingerprint", function(reader) return reader.fingerprint("/db.sqlite", "2026-10-21") end },
	}) do
		helpers.it(call[1] .. " waits for the writer's COMMIT lock before refusing", function()
			local reader, execs = load_reader()
			pcall(call[2], reader)
			local wait = require("core.timing.engine.timings").ms("keystats", "sqlite_read_busy_timeout_ms")
			helpers.assert_true(wait > 0, "the registry owns a positive wait")
			local found = false
			for _, sql in ipairs(execs) do
				if sql == string.format("PRAGMA busy_timeout = %d;", wait) then found = true end
			end
			helpers.assert_true(found, "the read connection must set the registry's busy wait")
		end)
	end
end)

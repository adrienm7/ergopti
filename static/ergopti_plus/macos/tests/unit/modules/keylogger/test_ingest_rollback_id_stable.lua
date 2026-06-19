--- tests/unit/modules/keylogger/test_ingest_rollback_id_stable.lua

--- ==============================================================================
--- MODULE: Regression — ingest rollback restores the event-id counter (KL-1)
--- DESCRIPTION:
--- build_inserts() allocates event ids via _alloc_event_id() BEFORE the ingest
--- transaction opens, advancing the module-level _next_event_id. On a rolled-back
--- batch the persisted meta value is undone but the in-memory counter stayed
--- advanced AND the file offset was not advanced, so the retried (identical) batch
--- re-keyed the same entries with NEW ids — bypassing the (device_id, id)
--- INSERT OR IGNORE idempotency and leaving a permanent id gap that desyncs a peer
--- replaying data.sql.
---
--- Fix: snapshot _next_event_id before build_inserts and restore it on rollback
--- (SqliteWriter.get_next_event_id / set_next_event_id), so the retry reuses the
--- same ids. The DB-bound ingest_once is integration-tested; here the accessor
--- round-trip is behavioral and the rollback wiring is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger: event-id counter is restorable + restored on rollback (KL-1)", function()
	helpers.it("SqliteWriter exposes a get/set round-trip for the event-id counter", function()
		local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")
		helpers.assert_true(type(SW.get_next_event_id) == "function", "get_next_event_id must exist")
		helpers.assert_true(type(SW.set_next_event_id) == "function", "set_next_event_id must exist")

		local snap = SW.get_next_event_id()
		SW.set_next_event_id(snap + 5)
		helpers.assert_eq(SW.get_next_event_id(), snap + 5, "set must advance the counter")
		SW.set_next_event_id(snap)
		helpers.assert_eq(SW.get_next_event_id(), snap, "set must restore the counter to the snapshot")
	end)

	helpers.it("ingest snapshots the counter before build_inserts and restores it on rollback", function()
		local path = helpers.driver_root() .. "modules/keylogger/log_manager.lua"
		local fh = io.open(path, "r"); helpers.assert_true(fh ~= nil, "cannot open log_manager.lua")
		local src = fh:read("*a"); fh:close()

		local snap_pos    = src:find("local saved_event_id = SqliteWriter.get_next_event_id()", 1, true)
		local build_pos   = src:find("SqliteWriter.build_inserts", 1, true)
		local restore_pos = src:find("SqliteWriter.set_next_event_id(saved_event_id)", 1, true)
		local rollback_pos = src:find('db:exec("ROLLBACK;")', 1, true)

		helpers.assert_true(snap_pos ~= nil, "ingest must snapshot the counter (saved_event_id)")
		helpers.assert_true(build_pos ~= nil and snap_pos < build_pos, "the snapshot must precede build_inserts")
		helpers.assert_true(restore_pos ~= nil, "the rollback path must restore the counter")
		helpers.assert_true(rollback_pos ~= nil and restore_pos > rollback_pos,
			"the counter restore must happen on the rollback path (after ROLLBACK)")
	end)
end)

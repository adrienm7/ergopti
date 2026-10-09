--- tests/unit/modules/keylogger/test_data_sql_ordering.lua

--- ==============================================================================
--- MODULE: Regression — data.sql INSERT ordering invariant (C4)
--- DESCRIPTION:
--- build_inserts() allocates a per-device sequential `id` via _alloc_event_id().
--- The data.sql file is an append-only replay ledger; a peer that replays it
--- expects events in ascending (device_id, id) order so it can join tables and
--- detect gaps. Two invariants must hold:
---
--- INVARIANT 1 — MONOTONE: successive calls to build_inserts() allocate strictly
--- increasing IDs. If this regresses (e.g., two callers share _next_event_id in an
--- unguarded way) replayed events appear out of order or are silently dropped by
--- `INSERT OR IGNORE` because a lower-id row already exists.
---
--- INVARIANT 2 — EMBEDDED: the allocated id appears correctly in the generated
--- INSERT string. If _alloc_event_id() is called but its return value is not
--- threaded to the builder, the INSERT would carry a wrong (stale or 0) id,
--- corrupting the replay order.
---
--- These are behavioral tests that load the real sqlite_writer module via the
--- unit-test stubs to call build_inserts() directly.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger/sqlite_writer: data.sql INSERT ordering (C4)", function()

	local function make_entry(type_name, ts)
		ts = ts or "2026-06-20T12:00:00.000Z"
		local e = { type = type_name, timestamp = ts }
		if type_name == "typing" then
			e.text = "hello"; e.wpm = 80
		elseif type_name == "app_switch" then
			e.prev_app = "A"; e.next_app = "B"; e.duration_ms = 100
		elseif type_name == "system_event" then
			e.action = "sleep"
		end
		return e
	end


	-- ===== Invariant 1: monotone IDs across successive build_inserts calls =====

	helpers.it("successive build_inserts calls allocate strictly increasing IDs", function()
		local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")

		local id_start = SW.get_next_event_id()
		local stmts1 = SW.build_inserts(make_entry("app_switch"))
		local id_after1 = SW.get_next_event_id()

		local stmts2 = SW.build_inserts(make_entry("app_switch"))
		local id_after2 = SW.get_next_event_id()

		helpers.assert_true(#stmts1 > 0, "build_inserts must return at least one statement")
		helpers.assert_true(#stmts2 > 0, "second build_inserts must return at least one statement")

		-- Each call must advance the counter by exactly 1 (one event = one id)
		helpers.assert_eq(id_after1, id_start + 1,
			"first build_inserts must advance _next_event_id by 1")
		helpers.assert_eq(id_after2, id_start + 2,
			"second build_inserts must advance _next_event_id by 2 total")
	end)


	-- ===== Invariant 2: the allocated id is embedded in the INSERT string =====

	helpers.it("the allocated id appears as an integer literal in the INSERT statement", function()
		local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")

		local id_before = SW.get_next_event_id()
		local stmts = SW.build_inserts(make_entry("app_switch"))
		helpers.assert_true(#stmts > 0, "build_inserts must return at least one statement")

		local sql = stmts[1]
		-- The id must appear as an integer column in the INSERT VALUES list.
		-- Pattern: VALUES (<device_id>, <id>, ...) — the id is the second column.
		-- We search for ", <id>, " or "(<device_str>, <id>, " to confirm embedding.
		local id_str = tostring(id_before)
		helpers.assert_true(
			sql:find(", " .. id_str .. ", ", 1, true) ~= nil
			or sql:find("(" .. id_str .. ",", 1, true) ~= nil
			or sql:find(", " .. id_str .. ")", 1, true) ~= nil,
			"allocated id " .. id_str .. " must be embedded in the INSERT statement; "
			.. "got: " .. sql:sub(1, 120))
	end)


	-- ===== Invariant 3: snapshot + restore gives the next batch the same IDs =====

	helpers.it("set_next_event_id restores the counter so a retried batch gets identical IDs", function()
		local SW = helpers.load_with_stubs("modules.keylogger.sqlite_writer")

		local snap = SW.get_next_event_id()

		-- First attempt: allocate two ids
		SW.build_inserts(make_entry("app_switch"))
		SW.build_inserts(make_entry("system_event"))
		helpers.assert_eq(SW.get_next_event_id(), snap + 2, "two build_inserts must advance counter by 2")

		-- Simulate rollback: restore snapshot
		SW.set_next_event_id(snap)
		helpers.assert_eq(SW.get_next_event_id(), snap, "set_next_event_id must restore counter to snapshot")

		-- Retry: must produce the same first id
		local id_retry = SW.get_next_event_id()
		helpers.assert_eq(id_retry, snap,
			"retried batch must start at the same id as the original attempt (idempotent replay)")
	end)
end)

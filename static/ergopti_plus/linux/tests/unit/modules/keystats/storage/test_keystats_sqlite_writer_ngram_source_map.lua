--- tests/unit/modules/keystats/storage/test_keystats_sqlite_writer_ngram_source_map.lua

---
--- Compliance tests for the Linux SQLite writer module.
--- Verifies the module API surface, graceful degradation when sqlite3 is absent,
--- and the public methods do not crash.  Since sqlite3 CLI is not guaranteed
--- on the maintainer's Windows machine (nor on CI), the database-path methods
--- are tested with the expectation that is_available() returns false.

package.loaded["tests.support.modules.keystats.storage.keystats_sqlite_writer_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.storage.keystats_sqlite_writer_fixture")
local helpers, it, with_writer_read_receipts, with_ngram_sql =
	Fixture.helpers, Fixture.it, Fixture.with_writer_read_receipts, Fixture.with_ngram_sql




helpers.describe("linux-sqlite-ngram-source-map", function()
	it("linux-sqlite-ngram-source-map: each admitted source is merged as a literal key", function()
		with_ngram_sql(function(writer, statements)
			helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
				x = { c = 4, td = 7, cd = 2, e = 1, sources = { extension = 2, hotstring = 1, llm = 1, other = 1 } },
			}))
			helpers.assert_eq(#statements, 1)
			local sql = statements[1]
			helpers.assert_contains(sql, "json_each(esrc_json)")
			helpers.assert_contains(sql, "json_each(excluded.esrc_json)")
			helpers.assert_contains(sql, "SUM(value)")
			helpers.assert_contains(sql, "GROUP BY key")
			for _, key in ipairs({ "extension", "hotstring", "llm", "other" }) do
				helpers.assert_contains(sql, '"' .. key .. '":')
			end
			for _, scalar in ipairs({ "c", "td", "cd", "e" }) do
				helpers.assert_contains(sql, scalar .. " = " .. scalar .. " + excluded." .. scalar .. ", ")
			end
		end)
	end)

	it("linux-sqlite-ngram-source-map: all nine native table families share literal-key merging", function()
		with_ngram_sql(function(writer, statements)
			local families = 0
			for target in pairs(writer.NGRAM_TABLES) do
				families = families + 1
				helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
					x = { c = 1, sources = { ["extension.v2"] = 1 } },
				}, target))
				local sql = statements[families]
				helpers.assert_contains(sql, "INSERT INTO " .. target .. " ")
				helpers.assert_contains(sql, "json_each(esrc_json)")
				helpers.assert_contains(sql, "json_each(excluded.esrc_json)")
			end
			helpers.assert_eq(families, 9)
			helpers.assert_eq(#statements, 9)
		end)
	end)

	it("linux-sqlite-ngram-source-map: original numeric admission and floors retain every string label", function()
		with_ngram_sql(function(writer, statements)
			helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
				x = { c = 1, sources = { extension = 2.9, [""] = 1.9, string_count = "3", zero = 0, negative = -1 } },
			}))
			local sql = statements[1]
			helpers.assert_contains(sql, '"extension":2')
			helpers.assert_contains(sql, '"":1')
			helpers.assert_true(not sql:find("string_count", 1, true))
			helpers.assert_true(not sql:find('"zero"', 1, true))
			helpers.assert_true(not sql:find('"negative"', 1, true))
		end)
	end)

	it("linux-sqlite-ngram-source-map: refused native receipt never acknowledges a source delta", function()
		for _, status in ipairs({ 7, 127, "missing" }) do
			with_writer_read_receipts("", status, function(writer)
				helpers.assert_eq(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
					x = { c = 1, sources = { extension = 1 } },
				}), false)
			end)
		end
	end)
end)




helpers.describe("linux-sqlite-ngram-source-encoding", function()
	local cases = {
		{ "ordinary", "addon" },
		{ "quoted UTF-8", "addon.é'\"" },
		{ "literal backslash escape", "addon\\t" },
		{ "unknown backslash escape", "addon\\q" },
		{ "newline", "addon\nline" },
		{ "tab", "addon\tfield" },
		{ "carriage return", "addon\rfield" },
	}
	for _, case in ipairs(cases) do
		it("linux-sqlite-ngram-source-encoding: " .. case[1] .. " remains one exact JSON key", function()
			with_ngram_sql(function(writer, statements)
				helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
					x = { c = 2, td = 7, cd = 2, e = 1, sources = { [case[2]] = 2 } },
				}))
				helpers.assert_eq(#statements, 1)
				local source_json = statements[1]:match(",2,7,2,1,'(.-)'%)")
				helpers.assert_type(source_json, "string", "actual admitted SQL must carry the source map")
				-- SQL quotes are doubled after JSON encoding; restore only that outer layer.
				source_json = source_json:gsub("''", "'")
				local expected = { [case[2]] = 2 }
				helpers.assert_eq(require("json").decode(source_json), expected)
				helpers.assert_eq(source_json, require("json").encode(expected))
			end)
		end)
	end
	it("linux-sqlite-ngram-source-encoding: original numeric admission and floors are unchanged", function()
		with_ngram_sql(function(writer, statements)
			helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
				x = { c = 2, sources = { ["addon\n"] = 2.9, [""] = 0.5,
					string_count = "3", zero = 0, negative = -1, [1] = 4 } },
			}))
			local source_json = statements[1]:match(",2,0,0,0,'(.-)'%)")
			helpers.assert_type(source_json, "string")
			helpers.assert_eq(require("json").decode(source_json), { ["addon\n"] = 2, [""] = 0 })
		end)
	end)
end)




helpers.describe("linux-system-day-owned-read", function()
	local complete = '{"date":"2026-10-05","wifi_changes":4,"space_switches":0,"battery_sum":150,"battery_count":2,"battery_min":70,"battery_max":80,"audio_muted_ms":1000,"locked_ms":2000,"sleep_ms":3000,"awake_ms":4000,"passive_count":0,"night_wake_count":0}'

	it("linux-system-day-owned-read: accepts the complete typed native row", function()
		with_writer_read_receipts(complete, 0, function(writer)
			local row, accepted = writer.read_system_day("owned", "2026-10-05")
			helpers.assert_true(accepted)
			helpers.assert_eq(row.awake_ms, 4000)
			helpers.assert_eq(row.wifi_changes, 4)
			helpers.assert_eq(row.battery_min, 70)
		end)
	end)

	it("linux-system-day-owned-read: distinguishes accepted absence", function()
		with_writer_read_receipts("", 0, function(writer)
			local row, accepted = writer.read_system_day("owned", "2026-10-05")
			helpers.assert_true(accepted)
			helpers.assert_nil(row)
		end)
	end)

	it("linux-system-day-owned-read: preserves absent battery bounds", function()
		local body = complete:gsub('"battery_min":70', '"battery_min":null')
			:gsub('"battery_max":80', '"battery_max":null')
			:gsub('"battery_sum":150', '"battery_sum":null')
			:gsub('"battery_count":2', '"battery_count":null')
		with_writer_read_receipts(body, 0, function(writer)
			local row, accepted = writer.read_system_day("owned", "2026-10-05")
			helpers.assert_true(accepted)
			helpers.assert_nil(row.battery_min)
			helpers.assert_nil(row.battery_max)
			helpers.assert_eq(row.battery_sum, 0)
			helpers.assert_eq(row.battery_count, 0)
		end)
	end)

	for _, status in ipairs({ 1, "missing" }) do
		it("linux-system-day-owned-read: refuses unacknowledged native row " .. status, function()
			with_writer_read_receipts(complete, status, function(writer)
				local row, accepted = writer.read_system_day("owned", "2026-10-05")
				helpers.assert_eq(accepted, false)
				helpers.assert_nil(row)
			end)
		end)
	end

	for _, body in ipairs({ "not-json", "[" .. complete .. "]" }) do
		it("linux-system-day-owned-read: refuses malformed or array-shaped row " .. body, function()
			with_writer_read_receipts(body, 0, function(writer)
				local row, accepted = writer.read_system_day("owned", "2026-10-05")
				helpers.assert_eq(accepted, false)
				helpers.assert_nil(row)
			end)
		end)
	end

	it("linux-system-day-owned-read: refuses another day in the returned row", function()
		with_writer_read_receipts(complete, 0, function(writer)
			local row, accepted = writer.read_system_day("owned", "2026-10-06")
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(row)
		end)
	end)

	it("linux-system-day-owned-read: refuses a typed string counter", function()
		with_writer_read_receipts(complete:gsub('"awake_ms":4000', '"awake_ms":"4000"'), 0, function(writer)
			local row, accepted = writer.read_system_day("owned", "2026-10-05")
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(row)
		end)
	end)

	it("linux-system-day-owned-read: query names only the exact escaped device and date", function()
		local captured
		with_writer_read_receipts(function(command)
			if command:find("FROM agg_system_day", 1, true) then captured = command end
			return complete
		end, 0, function(writer)
			local row, accepted = writer.read_system_day("owned' a", "2026-10-05")
			helpers.assert_true(accepted)
			helpers.assert_eq(row.awake_ms, 4000)
			helpers.assert_contains(captured, "WHERE device_id='owned'' a' AND date='2026-10-05'")
		end)
	end)
end)




helpers.describe("linux-sqlite-ngram-group-transaction", function()
	helpers.it("linux-sqlite-typing-derived-transaction: raw source and derivatives share one receipt", function()
		local writes = {}
		with_writer_read_receipts(function(command)
			if command:find("SELECT CAST(value AS INTEGER)", 1, true) then return "1\n" end
			if command:find("INSERT OR IGNORE INTO events_typing", 1, true) then writes[#writes + 1] = command end
			return ""
		end, 0, function(writer)
			helpers.assert_true(writer.insert_typing_events("owned", {
				{ app = "owned", text = "a", events_json = '[["a",0]]' },
			}, {
				ngrams = { { table_name = "ngram_chars", date = "2000-01-01", app = "owned", ngrams = { a = 1 } } },
				daily = { chars_class = { { date = "2000-01-01", app = "owned", letter = 1 } } },
			}))
		end)
		helpers.assert_eq(#writes, 1)
		local command = writes[1]
		helpers.assert_contains(command, "INSERT INTO ngram_chars")
		helpers.assert_contains(command, "INSERT INTO agg_app_day_chars_class")
		local _, starts = command:gsub("BEGIN IMMEDIATE;", "")
		local _, commits = command:gsub("COMMIT;", "")
		helpers.assert_eq(starts, 1, "nested or separate connections cannot own an atomic typing batch")
		helpers.assert_eq(commits, 1)
	end)

	helpers.it("linux-sqlite-ngram-group-transaction: one checked transaction owns admitted tokens", function()
		with_ngram_sql(function(writer, statements)
			helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
				alpha = { c = 3, td = 20, cd = 2, e = 1, sources = { hotstring = 1, addon = 2 } },
				beta = { c = 5, td = 40, cd = 3, e = 2, sources = { llm = 2, addon = 3 } },
				rejected = 0,
			}))
			helpers.assert_eq(#statements, 1)
			helpers.assert_contains(statements[1], "BEGIN IMMEDIATE;\nINSERT INTO ngram_chars")
			helpers.assert_contains(statements[1], ";\nCOMMIT;")
			helpers.assert_contains(statements[1], "'alpha',3,20,2,1,")
			helpers.assert_contains(statements[1], "'beta',5,40,3,2,")
			helpers.assert_true(not statements[1]:find("'rejected'", 1, true))
		end)
	end)

	helpers.it("linux-sqlite-ngram-group-transaction: native refusal remains false", function()
		with_writer_read_receipts("", 7, function(writer)
			helpers.assert_eq(writer.upsert_ngrams("owned", "2000-01-01", "owned", { alpha = 3, beta = 5 }), false)
		end)
	end)
end)




helpers.describe("keystats-device-log-privacy", function()
	helpers.it("keystats-device-log-privacy: native registration receipt keeps identity only in SQL", function()
		local previous_logger, previous_writer = package.loaded["logger.shim"], package.loaded["modules.keystats.sqlite_writer"]
		local messages, registration_requests = {}, 0
		local logger = {}
		for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
			logger[level] = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
		end
		package.loaded["logger.shim"] = logger
		local ok, err = xpcall(function()
			with_writer_read_receipts(function(command)
				if command:find("INSERT INTO devices", 1, true) then
					registration_requests = registration_requests + 1
					helpers.assert_contains(command, "private-host-identity")
					helpers.assert_contains(command, "Private Test Host")
				end
				return ""
			end, 0, function(writer)
				messages = {}
				helpers.assert_eq(writer.register_device("private-host-identity", "Private Test Host", "linux", "test-kernel", "test-signature"), true)
				helpers.assert_eq(registration_requests, 1)
				helpers.assert_eq(#messages, 1)
				helpers.assert_eq(messages[1], "Device registered.")
				helpers.assert_nil(messages[1]:find("private-host-identity", 1, true))
			end)
		end, debug.traceback)
		package.loaded["logger.shim"], package.loaded["modules.keystats.sqlite_writer"] = previous_logger, previous_writer
		if not ok then error(err, 0) end
	end)
end)




helpers.describe("linux-sqlite-media-startup-boundary", function()
	it("linux-sqlite-media-startup-boundary: startup refusal cannot reach the target body", function()
		local called = false
		local ok, failure = pcall(with_writer_read_receipts, "", 0, function() called = true end, 7)
		helpers.assert_eq(ok, false, "a refused mandatory media schema must fail initialization")
		helpers.assert_type(failure, "string")
		helpers.assert_eq(called, false, "no operation may run after startup refusal")
	end)

	it("linux-sqlite-media-startup-boundary: configured receipt belongs only to the target query", function()
		local calls = 0
		with_writer_read_receipts(function(command)
			calls = calls + 1
			helpers.assert_contains(command, "SELECT value FROM receipt;", "startup must not consume target output")
			return "untrusted row"
		end, 7, function(writer)
			helpers.assert_nil(writer.query_rows("SELECT value FROM receipt;"))
		end)
		helpers.assert_eq(calls, 1, "only the original target query consumes its configured fault")
	end)

	it("linux-sqlite-media-startup-boundary: actual first open commits both additive native tables", function()
		local writer = helpers.load_module("modules.keystats.sqlite_writer")
		local path = os.tmpname()
		local available = os.execute("command -v sqlite3 >/dev/null 2>&1")
		local ok, reason = xpcall(function()
			if available ~= true and available ~= 0 then
				helpers.assert_eq(writer.open_db(path), false, "missing SQLite is an explicit prerequisite refusal")
				return
			end
			helpers.assert_true(writer.open_db(path), "the original native startup must finish before a query")
			local rows = writer.query_rows("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('ngram_media_keys','agg_app_day_media_hold');")
			helpers.assert_eq(rows, { "2" }, "schema startup must really commit both shared tables without fixture provisioning")
		end, debug.traceback)
		writer.close_db()
		os.remove(path)
		if not ok then error(reason, 0) end
	end)
end)




helpers.describe("SQLite scancode no-op receipts", function()
	for _, values in ipairs({ {}, { [30] = 0 }, { [30] = -1 }, { ["invalid"] = 1 } }) do
		it("preserves the acknowledged no-op without submitting a non-SQL boolean", function()
			with_writer_read_receipts("", 0, function(writer)
				helpers.assert_true(writer.upsert_scancodes("owned", "2000-01-01", "app", values))
			end)
		end)
	end
end)




helpers.describe("SQLite flush native capability", function()
	it("refuses absent luv before any reservation or native ownership", function()
		local name = "infra.sqlite_batch_process"
		local previous = package.loaded[name]
		package.loaded[name] = { is_available = function() return false end,
			start = function() error("unavailable transport dispatched") end }
		local ok, err = pcall(function()
			with_writer_read_receipts("", 0, function(writer)
				helpers.assert_eq(writer.flush_transport_available(), false)
				local operation = writer.start_flush("owned", { raw = { typing = {}, hotstrings = {}, shortcuts = {}, switches = {} }, upserts = {} })
				helpers.assert_eq(operation, nil)
			end)
		end)
		package.loaded[name] = previous
		if not ok then error(err, 0) end
	end)
end)




helpers.describe("SQLite terminal flush retry fence", function()
	it("cannot acquire another child after committed cleanup dispatch is refused", function()
		local name, calls = "infra.sqlite_batch_process", 0
		local previous = package.loaded[name]
		package.loaded[name] = { is_available = function() return true end,
			start = function()
				calls = calls + 1
				if calls == 3 then return nil end -- No marker-GC child acquired.
				return { poll = function() return { ok = true, output = "1\n" } end,
					is_settled = function() return true end, cancel = function() return true end }
			end }
		local ok, err = pcall(function()
			with_writer_read_receipts("", 0, function(writer)
				local operation = assert(writer.start_flush("owned", {
					raw = { typing = {}, hotstrings = {}, shortcuts = {}, switches = {} }, upserts = {},
				}))
				operation:pump(); operation:pump()
				helpers.assert_true(operation:is_settled())
				helpers.assert_true(operation.result.committed)
				helpers.assert_eq(operation:is_retryable(), false)
				helpers.assert_eq(operation:retry(), false)
				helpers.assert_eq(calls, 3, "a retired operation cannot own a new unobserved native child")
			end)
		end)
		package.loaded[name] = previous
		if not ok then error(err, 0) end
	end)
end)





-- SQLite's json_group_object cuts an object key at an embedded NUL, so a merged
-- map turned "a\u0000b" into a second "a" key. Every numeric map the writer
-- merges (n-gram sources, error buckets, burst lengths) shares one expression.
helpers.describe("linux-sqlite-nul-map-keys", function()
	it("linux-sqlite-nul-map-keys: every merged numeric map spells its keys through json_quote", function()
		local command = require("modules.keystats.sqlite_command")
		local previous_build, merges = command.build, {}
		command.build = function(path, sql, options)
			if sql:find("json_each(excluded.", 1, true) then merges[#merges + 1] = sql end
			return previous_build(path, sql, options)
		end
		local ok, reason = xpcall(function()
			Fixture.with_category_commands(nil, function(writer)
				local nul = "a\0b"
				helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned",
					{ x = { c = 1, sources = { [nul] = 1 } } }))
				helpers.assert_true(writer.upsert_hourly("owned",
					{ date = "2000-01-01", app = "owned", hour = "10", c = 1, e = 1, e_buckets = { [nul] = 1 } }))
				helpers.assert_true(writer.upsert_hourly_min5("owned",
					{ date = "2000-01-01", app = "owned", slot = "10:00", c = 1, e = 1, e_buckets = { [nul] = 1 } }))
				helpers.assert_true(writer.upsert_burst("owned",
					{ date = "2000-01-01", app = "owned", count_total = 1, length_buckets = { [nul] = 1 } }))
			end)
		end, debug.traceback)
		command.build = previous_build
		if not ok then error(reason, 0) end
		helpers.assert_eq(#merges, 4, "the source, hourly, five-minute and burst merges are all observed")
		for _, sql in ipairs(merges) do
			helpers.assert_true(sql:find("json_group_object", 1, true) == nil,
				"json_group_object truncates a key at NUL and must not rebuild a merged map")
			helpers.assert_contains(sql, "json_quote(k)")
			helpers.assert_contains(sql, "'{}')")
		end
	end)
end)

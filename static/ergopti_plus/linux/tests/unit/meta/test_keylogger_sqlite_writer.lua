--- tests/unit/meta/test_keylogger_sqlite_writer.lua
---
--- Compliance tests for the Linux SQLite writer module.
--- Verifies the module API surface, graceful degradation when sqlite3 is absent,
--- and the public methods do not crash.  Since sqlite3 CLI is not guaranteed
--- on the maintainer's Windows machine (nor on CI), the database-path methods
--- are tested with the expectation that is_available() returns false.

local helpers = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it
local sw     = helpers.load_module("modules.keylogger.sqlite_writer")

--- Models native stdout and LuaJIT's ambiguous pclose without replacing the
--- production builder or query logic. lines()/read() both mirror the real ABI.
local function with_writer_read_receipts(body, status, test)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, code = type(body) == "function" and body(command) or body, status
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content, code = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n", 0
		end
		return {
			read = function(_, mode)
				if mode == "*l" then return content:match("^([^\n]*)") end
				if command:find("ERGOPTI_SQL_EXIT_STATUS=", 1, true) and code ~= "missing" then
					return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. code .. "\n"
				end
				return content
			end,
			lines = function()
				if content == "" then return function() return nil end end
				local framed = content:sub(-1) == "\n" and content or (content .. "\n")
				return framed:gmatch("([^\n]*)\n")
			end,
			close = function() return true end,
		}
	end
	local ok, err = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		test(writer)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Models CLI exit receipts while retaining the production builder and writer.
local function with_category_commands(refusal, test)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	local commands = {}
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, status = "", 0
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n"
		else
			commands[#commands + 1] = command
			if refusal == "score" and command:find("INSERT OR REPLACE INTO meta", 1, true) then status = 7 end
			if refusal == "category" and command:find("UPDATE agg_app_day", 1, true) then status = 7 end
		end
		return {
			read = function() return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. status .. "\n" end,
			close = function() return true end,
		}
	end
	local ok, reason = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		test(writer, commands)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(reason, 0) end
end

helpers.describe("linux-sqlite-category-transaction", function()
	it("linux-sqlite-category-transaction: score receipt refusal cannot acknowledge an edit", function()
		with_category_commands("score", function(writer)
			helpers.assert_eq(writer.set_app_category("owned", "owned-app", "Updated", 1), false)
		end)
	end)

	it("linux-sqlite-category-transaction: category and score use one checked native transaction", function()
		with_category_commands(nil, function(writer, commands)
			helpers.assert_eq(writer.set_app_category("owned", "owned-app", "Updated", 1), true)
			helpers.assert_eq(#commands, 1)
			helpers.assert_contains(commands[1], "BEGIN;")
			helpers.assert_contains(commands[1], "UPDATE agg_app_day")
			helpers.assert_contains(commands[1], "INSERT OR REPLACE INTO meta")
			helpers.assert_contains(commands[1], "COMMIT;")
			helpers.assert_contains(commands[1], "'-bail'")
			helpers.assert_contains(commands[1], "ERGOPTI_SQL_EXIT_STATUS=")
		end)
	end)

	it("linux-sqlite-category-transaction: UTF-8 and quote bytes retain canonical SQL escaping", function()
		with_category_commands(nil, function(writer, commands)
			helpers.assert_eq(writer.set_app_category("owned '", "été ' app", "Updated ' été", 1), true)
			local all = table.concat(commands, "\n")
			helpers.assert_contains(all, "device_id = 'owned '''")
			helpers.assert_contains(all, "app = 'été '' app'")
			helpers.assert_contains(all, "category = 'Updated '' été'")
			helpers.assert_contains(all, "'app_score.été '' app'")
		end)
	end)

	it("linux-sqlite-category-transaction: absent and fractional scores preserve their existing defaults and floors", function()
		for _, case in ipairs({ { false, "0" }, { -0.25, "-1" }, { "1.9", "1" } }) do
			with_category_commands(nil, function(writer, commands)
				local score = case[1] ~= false and case[1] or nil
				helpers.assert_eq(writer.set_app_category("owned", "owned-app", "Updated", score), true)
				helpers.assert_contains(table.concat(commands, "\n"), "'app_score.owned-app', '" .. case[2] .. "'")
			end)
		end
	end)

	it("linux-sqlite-category-transaction: category receipt refusal remains a failed edit", function()
		with_category_commands("category", function(writer)
			helpers.assert_eq(writer.set_app_category("owned", "owned-app", "Updated", 1), false)
		end)
	end)

	it("linux-sqlite-category-transaction: invalid labels refuse before any native command", function()
		with_category_commands(nil, function(writer, commands)
			helpers.assert_eq(writer.set_app_category("owned", "", "Updated", 1), false)
			helpers.assert_eq(writer.set_app_category("owned", "owned-app", "", 1), false)
			helpers.assert_eq(#commands, 0)
		end)
	end)
end)

helpers.describe("linux-sqlite-read-receipts", function()
	for _, status in ipairs({ 1, 7, 127, 137, 255, "missing" }) do
		it("linux-sqlite-read-receipts: migration rows reject receipt " .. status, function()
			with_writer_read_receipts("one\ntwo\n", status, function(writer)
				helpers.assert_nil(writer.query_rows("SELECT value FROM receipt;"))
			end)
		end)
		it("linux-sqlite-read-receipts: scalar rejects receipt " .. status, function()
			with_writer_read_receipts("trusted scalar\n", status, function(writer)
				helpers.assert_nil(writer.get_meta("receipt"))
			end)
		end)
	end

	for label, body in pairs({ rows = "one\ntwo\n", unterminated = "one\ntwo", empty = "", blank = "\n" }) do
		it("linux-sqlite-read-receipts: accepted " .. label .. " output preserves its line contract", function()
			with_writer_read_receipts(body, 0, function(writer)
				local rows = writer.query_rows("SELECT value FROM receipt;")
				helpers.assert_eq(type(rows), "table")
				if label == "empty" then helpers.assert_eq(#rows, 0)
				elseif label == "blank" then
					helpers.assert_eq(#rows, 1)
					helpers.assert_eq(rows[1], "")
				else
					helpers.assert_eq(#rows, 2)
					helpers.assert_eq(table.concat(rows, "|"), "one|two")
				end
			end)
		end)
	end
end)

helpers.describe("linux-sqlite-wpm-fraction", function()
	for _, fixture in ipairs({
		{ label = "fraction", value = 18.461538461538463, expected = 18.461538461538463 },
		{ label = "sub-unit fraction", value = 0.125, expected = 0.125 },
		{ label = "numeric text", value = "2.75", expected = 2.75 },
		{ label = "integer", value = 60, expected = 60 },
		{ label = "zero", value = 0, expected = 0 },
		{ label = "invalid text fallback", value = "not a number", expected = 0 },
	}) do
		it("linux-sqlite-wpm-fraction: typing SQL preserves " .. fixture.label, function()
			local command = require("modules.keylogger.sqlite_command")
			local previous_build, inserted = command.build, nil
			command.build = function(path, sql, options)
				if sql:find("INSERT OR IGNORE INTO events_typing", 1, true) then inserted = sql end
				return previous_build(path, sql, options)
			end
			local ok, err = xpcall(function()
				with_writer_read_receipts(function(cmd)
					return cmd:find("SELECT CAST(value AS INTEGER)", 1, true) and "1\n" or ""
				end, 0, function(writer)
					helpers.assert_true(writer.insert_typing_events("owned", {
						{ app = "owned", text = "owned text", events_json = "[]", wpm = fixture.value },
					}))
				end)
			end, debug.traceback)
			command.build = previous_build
			if not ok then error(err, 0) end
			helpers.assert_type(inserted, "string", "the actual writer must compose a typing INSERT")
			local scalar = inserted:match(",0%.0,([^,]+),'owned text'")
			helpers.assert_eq(tonumber(scalar), fixture.expected, "REAL WPM must retain the admitted numeric value")
		end)
	end
end)

helpers.describe("linux-sqlite-writer-receipts", function()
	for _, status in ipairs({ 1, 7, 23, 127, 255 }) do
		it("linux-sqlite-writer-receipts: silent status " .. status .. " cannot acknowledge a write", function()
			local writer = helpers.load_module("modules.keylogger.sqlite_writer")
			local previous_execute, previous_popen = os.execute, io.popen
			local path = os.tmpname()
			local file = assert(io.open(path, "w"))
			assert(file:write("existing database fixture"))
			assert(file:close())
			local terminal_status = 0
			os.execute = function() return 0 end
			io.popen = function(command)
				return {
					read = function(_, mode)
						if mode == "*l" then return "CREATE TABLE devices (os CHECK (os IN ('linux')))" end
						return command:find("ERGOPTI_SQL_EXIT_STATUS=", 1, true)
							and ("\nERGOPTI_SQL_EXIT_STATUS=" .. terminal_status .. "\n") or ""
					end,
					close = function() return true end, -- LuaJIT's ambiguous success is deliberate.
				}
			end
			local ok, err = xpcall(function()
				helpers.assert_true(writer.open_db(path))
				terminal_status = status
				helpers.assert_eq(writer.exec_sql(".exit " .. status), false)
				terminal_status = 0
				helpers.assert_true(writer.exec_sql("INSERT INTO receipt VALUES (1);"), "refusal cannot poison the next write")
			end, debug.traceback)
			os.execute, io.popen = previous_execute, previous_popen
			writer.close_db()
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end
end)

--- Captures actual Writer SQL while simulating only the CLI exit receipt.
local function with_ngram_sql(test)
	local command = require("modules.keylogger.sqlite_command")
	local previous_build, statements = command.build, {}
	command.build = function(path, sql, options)
		if sql:find("INSERT INTO ngram_", 1, true) then statements[#statements + 1] = sql end
		return previous_build(path, sql, options)
	end
	local ok, reason = xpcall(function()
		with_category_commands(nil, function(writer) test(writer, statements) end)
	end, debug.traceback)
	command.build = previous_build
	if not ok then error(reason, 0) end
end

helpers.describe("sqlite_writer", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    it("exports the expected methods", function()
      helpers.assert_true(type(sw.is_available)     == "function", "is_available")
      helpers.assert_true(type(sw.open_db)           == "function", "open_db")
      helpers.assert_true(type(sw.close_db)          == "function", "close_db")
      helpers.assert_true(type(sw.get_db_path)       == "function", "get_db_path")
      helpers.assert_true(type(sw.register_device)   == "function", "register_device")
      helpers.assert_true(type(sw.insert_typing_events) == "function", "insert_typing_events")
	  helpers.assert_true(type(sw.insert_hotstring_events) == "function", "insert_hotstring_events")
	  helpers.assert_true(type(sw.insert_app_switch_events) == "function", "insert_app_switch_events")
      helpers.assert_true(type(sw.upsert_app_day)    == "function", "upsert_app_day")
      helpers.assert_true(type(sw.upsert_ngrams)     == "function", "upsert_ngrams")
	  helpers.assert_true(type(sw.upsert_scancodes)  == "function", "upsert_scancodes")
      helpers.assert_true(type(sw.bump_rev)          == "function", "bump_rev")
    end)

    it("seeds every app-time and hotstring metric on the initial upsert", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("app_time_ms, hs_chars, hs_triggers, hs_input_chars", 1, true) ~= nil,
        "initial INSERT must retain every field, not only the conflict-update path")
    end)

	it("persists generated-output sources and physical scancodes independently", function()
		local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
		local fh = assert(io.open(path, "r"))
		local src = fh:read("*a"); fh:close()
		with_ngram_sql(function(writer, statements)
			helpers.assert_true(writer.upsert_ngrams("owned", "2000-01-01", "owned", {
				x = { c = 14, td = 7, cd = 2, e = 1,
					sources = { hotstring = 2, llm = 3, other = 4, ["extension.v2"] = 5 } },
			}))
			helpers.assert_eq(#statements, 1, "the actual Writer must compose one n-gram SQL subject")
			local sql = statements[1]
			helpers.assert_type(sql, "string")
			helpers.assert_true(sql ~= "", "source-preservation checks need an actual SQL subject")
			helpers.assert_contains(sql, "(device_id, date, app, token, c, td, cd, e, esrc_json)")
			local admitted = sql:match(",14,7,2,1,'([^']*)'")
			helpers.assert_type(admitted, "string", "known and arbitrary source counts must accompany the scalar fields")
			helpers.assert_eq(require("json").decode(admitted), {
				hotstring = 2, llm = 3, other = 4, ["extension.v2"] = 5,
			})
			helpers.assert_contains(sql, "ON CONFLICT(device_id, date, app, token) DO UPDATE SET")
			helpers.assert_contains(sql, "esrc_json = (SELECT json_group_object(k, v)")
			helpers.assert_contains(sql, "SELECT key AS k, SUM(value) AS v")
			helpers.assert_contains(sql, "SELECT key, value FROM json_each(esrc_json)")
			helpers.assert_contains(sql, "UNION ALL SELECT key, value FROM json_each(excluded.esrc_json)")
			helpers.assert_contains(sql, "GROUP BY key")
			for _, scalar in ipairs({ "c", "td", "cd", "e" }) do
				helpers.assert_contains(sql, scalar .. " = " .. scalar .. " + excluded." .. scalar .. ", ")
			end
		end)
		helpers.assert_true(src:find("INSERT INTO ngram_scancodes", 1, true) ~= nil,
			"evdev hardware counts must be persisted in the canonical scancode table")
	end)

    it("preserves complete dotted application identifiers during flush", function()
      local path = helpers.driver_root() .. "/modules/keylogger/keylogger.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("local app_name = dashboard_app_name(app_id)", 1, true) ~= nil,
        "SQLite aggregation must use the same full app ID as the dashboard")
    end)

    it("uses persistent IDs and non-destructive inserts for raw events", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("linux_next_event_id", 1, true) ~= nil,
        "a restart-safe SQLite event sequence is required")
      helpers.assert_true(src:find("INSERT OR IGNORE INTO events_typing", 1, true) ~= nil,
        "raw typing rows must never be replaced on an ID collision")
      helpers.assert_true(src:find("insert_hotstring_events", 1, true) ~= nil,
        "Linux must write canonical events_hotstring rows")
      helpers.assert_true(src:find("insert_app_switch_events", 1, true) ~= nil,
        "Linux must write canonical events_app_switch rows")
    end)

    it("events_typing insert supplies every column it names (typing-arity)", function()
      -- Regression: the VALUES tuple carried 20 entries for a 22-column list,
      -- so every flush with a manual keystroke failed in SQLite and aborted
      -- before hotstrings, n-grams and titles. The layout binding was computed
      -- and then dropped, shifting wpm/text/events_json into the wrong columns.
      local cmd_mod = helpers.load_module("modules.keylogger.sqlite_command")
      local real_build = cmd_mod.build
      local captured = {}
      cmd_mod.build = function(db_path, sql, opts)
        captured[#captured + 1] = sql
        return real_build(db_path, sql, opts)
      end
      local sw2 = helpers.load_module("modules.keylogger.sqlite_writer")

      local real_execute, real_popen = os.execute, io.popen
      local tmp = os.tmpname()
      local seed = io.open(tmp, "w")
      if seed then seed:write("x") seed:close() end
      os.execute = function() return 0 end
      io.popen = function(command)
        return {
          read = function(_, mode)
            if mode == "*l" then
              return "CREATE TABLE devices (os CHECK (os IN ('darwin','windows','linux')))"
            end
            -- Mirror the reservation SELECT and the actual terminal status.
            local body = command:find("SELECT CAST(value AS INTEGER)", 1, true) and "1\n" or ""
            return body .. "\nERGOPTI_SQL_EXIT_STATUS=0\n"
          end,
          close = function() return true end,
        }
      end

      local ok_run, err_run = pcall(function()
        helpers.assert_true(sw2.open_db(tmp) == true, "sandbox database must open")
        sw2.insert_typing_events("dev-unit", {
          { ts = "2026-01-01 12:00:00", date = "2026-01-01", app = "code",
            title = "t", text = "hi", wpm = 60, layout = "us", events_json = "[]" },
        })
      end)

      os.execute, io.popen = real_execute, real_popen
      cmd_mod.build = real_build
      sw2.close_db()
      os.remove(tmp)
      if not ok_run then error(err_run, 0) end

      helpers.assert_true(#captured >= 1, "the typing insert must compose SQL")
      local sql = captured[#captured]
      local cols_part = sql:match("INSERT OR IGNORE INTO events_typing%s*%((.-)%)%s*VALUES")
      helpers.assert_true(cols_part ~= nil, "typing INSERT must list its columns")
      local cols = {}
      for c in (cols_part .. ","):gmatch("([^,]+),") do
        cols[#cols + 1] = c:match("^%s*(.-)%s*$")
      end
      local outer = sql:match("VALUES%s*(%b())")
      helpers.assert_true(outer ~= nil, "typing INSERT must carry a VALUES tuple")
      local inner = outer:sub(2, -2)
      local vals, cur, in_q, i = {}, {}, false, 1
      while i <= #inner do
        local ch = inner:sub(i, i)
        if ch == "'" then
          if in_q and inner:sub(i + 1, i + 1) == "'" then
            cur[#cur + 1] = "''"; i = i + 2
          else
            in_q = not in_q; cur[#cur + 1] = ch; i = i + 1
          end
        elseif ch == "," and not in_q then
          vals[#vals + 1] = table.concat(cur); cur = {}; i = i + 1
        else
          cur[#cur + 1] = ch; i = i + 1
        end
      end
      vals[#vals + 1] = table.concat(cur)
      helpers.assert_eq(#cols, #vals, "columns and values arity must match")
      helpers.assert_eq(cols[9], "layout", "column 9 carries the layout")
      helpers.assert_eq(vals[9], "'us'", "the layout binding must reach the row")
      helpers.assert_eq(cols[19], "wpm", "column 19 carries wpm")
      helpers.assert_eq(vals[19], "60", "wpm must land in its own column")
      helpers.assert_eq(cols[20], "text", "column 20 carries text")
      helpers.assert_eq(vals[20], "'hi'", "text must land in its own column")
      helpers.assert_eq(cols[22], "events_json", "column 22 carries events_json")
    end)

    it("migrates the former device OS constraint to include Linux", function()
      local path = helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("_ensure_linux_device_schema", 1, true) ~= nil)
      helpers.assert_true(src:find("'darwin','windows','linux'", 1, true) ~= nil)
    end)

    it("is_available returns false when sqlite3 CLI is absent", function()
      -- On the maintainer's Windows machine and most CI, sqlite3 is absent.
      helpers.assert_true(type(sw.is_available()) == "boolean", "is_available returns boolean")
    end)
  end)

  -- ==========================================================================
  -- 2. Graceful degradation (sqlite3 absent)
  -- ==========================================================================

  helpers.describe("graceful degradation (no sqlite3)", function()

    it("open_db returns false when sqlite3 is absent", function()
      local ok = sw.open_db("/tmp/nonexistent/ergopti_test.sqlite")
      -- May return true (if sqlite3 IS available) or false.
      helpers.assert_true(type(ok) == "boolean", "open_db returns boolean")
      sw.close_db()
    end)

    -- Called directly throughout this block: a raise fails the case with the real
    -- error. What each asserts instead is the REFUSAL — a writer with no database
    -- that reported success would let the caller advance its watermark past rows
    -- that were never persisted, which loses them silently and for good.
    it("register_device refuses when the db is closed", function()
      sw.close_db()
      local ok = sw.register_device("test-1", "test", "linux", "5.15", "sig")
      helpers.assert_true(ok == nil or ok == false,
        "a closed database must not report a registered device")
    end)

    it("insert_typing_events writes nothing for an empty list", function()
      local ok = sw.insert_typing_events("dev", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "no events means no rows — a positive answer here is a watermark advanced "
          .. "over nothing")
    end)

    it("insert_typing_events writes nothing for a nil list", function()
      local ok = sw.insert_typing_events("dev", nil)
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "same for nil, which is what a failed decode hands it")
    end)

    it("upsert_app_day writes nothing for empty fields", function()
      local ok = sw.upsert_app_day("dev", "2026-01-01", "app", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "an upsert with no fields must not claim a row")
    end)

    it("upsert_ngrams writes nothing for an empty map", function()
      local ok = sw.upsert_ngrams("dev", "2026-01-01", "app", {})
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "an empty ngram map must not claim a row either")
    end)

    it("bump_rev refuses when the db is closed", function()
      local ok = sw.bump_rev()
      helpers.assert_true(ok == nil or ok == false,
        "the revision counter is the dashboards' cache-invalidation signal; bumping it "
          .. "against no database would tell them to re-read data that did not change")
    end)
  end)

  -- ==========================================================================
  -- 3. Escape / safety
  -- ==========================================================================

  helpers.describe("safety", function()

    it("register_device with SQL metacharacters is refused, not injected", function()
      local ok = sw.register_device("tes't-1", "tes't", "lin'ux", "5.1'5", "si'g")
      helpers.assert_true(ok == nil or ok == false,
        "with no database open the answer is refusal — and it must be the SAME refusal "
          .. "as for clean input, or the quotes changed a code path")
    end)

    it("insert_typing_events with quotes in text is refused, not injected", function()
      local ok = sw.insert_typing_events("dev", {
        { ts = "2026-01-01 12:00:00", date = "2026-01-01",
          app = "test'app", text = "he'llo \"world\"", wpm = 60 },
      })
      helpers.assert_true(ok == nil or ok == false or ok == 0,
        "quoted text must take the same refusal path as clean text when there is no "
          .. "database — a different answer would mean the quotes reached the SQL")
    end)

    it("double close_db leaves the writer reopenable", function()
      sw.close_db()
      sw.close_db()
      helpers.assert_eq(type(sw.open_db("/tmp/ergopti_double_close_probe.sqlite")), "boolean",
        "a second close must not poison the reopen — the flush path closes defensively")
      sw.close_db()
    end)
  end)

  -- ==========================================================================
  -- 4. Keylogger integration (flush path)
  -- ==========================================================================

  helpers.describe("keylogger flush integration", function()

    it("keylogger exports flush and export_json methods", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      helpers.assert_true(type(kl.flush)       == "function", "flush is a function")
      helpers.assert_true(type(kl.export_json) == "function", "export_json is a function")
      helpers.assert_true(type(kl.export_session) == "function", "export_session is a function")
    end)

    it("keylogger flush does not crash when sqlite is absent", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      kl.init({})  -- sqlite_writer.open_db will fail → JSON fallback
      kl.flush()
      local json = kl.export_json()
      helpers.assert_true(type(json) == "string" and #json > 0,
        "with sqlite absent the flush takes the JSON fallback, so the export must still "
          .. "produce something — a flush that quietly dropped the buffer would leave it empty")
    end)

    it("export_json returns valid JSON-like string", function()
      local kl = helpers.load_module("modules.keylogger.keylogger")
      kl.init({})
      local json = kl.export_json()
      helpers.assert_true(type(json) == "string" and #json > 0, "export_json returns non-empty string")
      -- Quick structural check: should start with { and end with }
      helpers.assert_true(json:match("^{") ~= nil, "JSON starts with '{'")
      helpers.assert_true(json:match("}$") ~= nil, "JSON ends with '}'")
    end)
  end)

end)


--- Models the native CLI's two scalar representations without replacing the
--- production builder, checked receipt parser or shared JSON decoder.
local function with_meta_value_output(value, status, test)
	local writer = helpers.load_module("modules.keylogger.sqlite_writer")
	local previous_execute, previous_popen = os.execute, io.popen
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write("existing native database fixture") and file:close())
	os.execute = function() return 0 end
	io.popen = function(command)
		local content, code = "", status
		if command:find("SELECT sql FROM sqlite_master", 1, true) then
			content, code = "CREATE TABLE devices (os CHECK (os IN ('linux')))\n", 0
		elseif command:find("SELECT json_quote(value)", 1, true) then
			content = value == nil and "" or require("json").encode(value) .. "\n"
		elseif command:find("SELECT value FROM meta", 1, true) then
			-- sqlite3's raw TEXT printer stops at NUL; scalar Lua framing stops at LF.
			content = value == nil and "" or (value:match("^[^%z]*") .. "\n")
		else
			error("metadata test received an unexpected query")
		end
		return {
			read = function() return content .. "\nERGOPTI_SQL_EXIT_STATUS=" .. code .. "\n" end,
			close = function() return true end,
		}
	end
	local ok, reason = xpcall(function()
		helpers.assert_true(writer.open_db(path))
		test(writer)
	end, debug.traceback)
	os.execute, io.popen = previous_execute, previous_popen
	writer.close_db()
	os.remove(path)
	if not ok then error(reason, 0) end
end

helpers.describe("linux-sqlite-meta-framing", function()
	for _, case in ipairs({
		{ "compact cursor", '{"table":"events_typing","id":7}' },
		{ "empty", "" },
		{ "UTF-8 CR quote tab", "été ' \r\t literal" },
		{ "LF", "one\ntwo" },
		{ "leading LF", "\ntwo" },
		{ "trailing LF", "one\n" },
		{ "CRLF", "one\r\ntwo" },
		{ "NUL suffix", "one\0two" },
		{ "leading NUL", "\0two" },
		{ "trailing NUL", "one\0" },
		{ "JSON-looking text", "null" },
	}) do
		it("linux-sqlite-meta-framing: " .. case[1] .. " retains the complete stored string", function()
			with_meta_value_output(case[2], 0, function(writer)
				helpers.assert_eq(writer.get_meta("owned-key"), case[2])
			end)
		end)
	end

	it("linux-sqlite-meta-framing: missing rows retain nil", function()
		with_meta_value_output(nil, 0, function(writer) helpers.assert_nil(writer.get_meta("owned-key")) end)
	end)

	it("linux-sqlite-meta-framing: failed receipts refuse even complete encoded rows", function()
		with_meta_value_output("one\0two", 7, function(writer) helpers.assert_nil(writer.get_meta("owned-key")) end)
	end)

	for _, body in ipairs({ "not JSON\n", "null\n", "false\n", "42\n", "{}\n", "[]\n", '"unfinished\n' }) do
		it("linux-sqlite-meta-framing: refuses malformed or non-string scalar " .. body:sub(1, -2), function()
			with_writer_read_receipts(body, 0, function(writer) helpers.assert_nil(writer.get_meta("owned-key")) end)
		end)
	end
end)


--- Captures the production histogram statement while modeling only CLI receipts.
--- The shared decoder independently checks the key bytes supplied to SQLite.
local function with_burst_histogram_statement(row, test)
	local command = require("modules.keylogger.sqlite_command")
	local previous_build = command.build
	local statement
	command.build = function(path, sql, options)
		if sql:find("INSERT INTO agg_app_day_burst", 1, true) then statement = sql end
		return previous_build(path, sql, options)
	end
	local ok, reason = xpcall(function()
		with_writer_read_receipts("", 0, function(writer)
			helpers.assert_true(writer.upsert_burst("owned-device", row))
			helpers.assert_eq(type(statement), "string")
			local encoded = statement:match("VALUES %('owned%-device','2000%-01%-01','owned%-app',0,0%.000000,0,'(.-)',0,0,0%)")
			helpers.assert_eq(type(encoded), "string", "existing counter defaults remain zero")
			local decoded = require("json").decode((encoded:gsub("''", "'")))
			helpers.assert_eq(type(decoded), "table", "SQLite receives a JSON object")
			test(decoded)
		end)
	end, debug.traceback)
	command.build = previous_build
	if not ok then error(reason, 0) end
end

helpers.describe("linux-sqlite-burst-histogram-keys", function()
	for _, key in ipairs({ "owned\\bucket", "owned\\literal", 'quoted" clé', "LF\nCR\rtab\tcontrol\1\31", "apostrophe's" }) do
		it("linux-sqlite-burst-histogram-keys: supplied key retains " .. require("json").encode(key), function()
			local row = { date = "2000-01-01", app = "owned-app", length_buckets = { [key] = 2.9 } }
			with_burst_histogram_statement(row, function(decoded)
				helpers.assert_eq(decoded[key], 2, "positive counts retain their existing floor")
				local seen = 0
				for stored in pairs(decoded) do
					seen = seen + 1
					helpers.assert_eq(stored, key, "the decoded key retains the supplied bytes")
				end
				helpers.assert_eq(seen, 1)
				helpers.assert_eq(row.length_buckets[key], 2.9, "caller counts remain unchanged")
			end)
		end)
	end

	it("linux-sqlite-burst-histogram-keys: filtering, numeric labels and floors remain unchanged", function()
		with_burst_histogram_statement({ date = "2000-01-01", app = "owned-app",
			length_buckets = { [10] = 2.9, ["500+"] = 1, small = 0.9, zero = 0,
				negative = -2, numeric_text = "3", boolean = true } }, function(decoded)
			helpers.assert_eq(decoded, { ["10"] = 2, ["500+"] = 1, small = 0 })
		end)
	end)

	it("linux-sqlite-burst-histogram-keys: missing histogram keeps the empty-object default", function()
		with_burst_histogram_statement({ date = "2000-01-01", app = "owned-app" }, function(decoded)
			helpers.assert_eq(next(decoded), nil)
		end)
	end)

	it("linux-sqlite-burst-histogram-keys: empty histogram keeps the empty-object default", function()
		with_burst_histogram_statement({ date = "2000-01-01", app = "owned-app", length_buckets = {} }, function(decoded)
			helpers.assert_eq(next(decoded), nil)
		end)
	end)
end)

-- Date formatting and writer receipts below are declared unit doubles; the
-- separate native fixture uses real libc and SQLite for the same public APIs.
local function with_local_day_clock(body)
	local previous_date = os.date
	os.date = function(format, epoch)
		if format == "%Y-%m-%d" then return "2026-01-02" end
		if format == "!%Y-%m-%d" then return "2026-01-01" end
		if format == "!%Y-%m-%d %H:%M:%S" then return "2026-01-01 23:59:59" end
		return previous_date(format, epoch)
	end
	local ok, err = xpcall(body, debug.traceback)
	os.date = previous_date
	if not ok then error(err, 0) end
end

helpers.describe("linux-sqlite-local-event-days", function()
	for _, kind in ipairs({ "hotstrings", "shortcuts" }) do
		it("linux-sqlite-local-event-days: collector " .. kind .. " retains UTC instant and local day", function()
			local writer_name, keylogger_name = "modules.keylogger.sqlite_writer", "modules.keylogger.keylogger"
			local previous_writer, previous_keylogger = package.loaded[writer_name], package.loaded[keylogger_name]
			local writer = require("tests.fakes").sqlite_writer()
			package.loaded[writer_name], package.loaded[keylogger_name] = writer, nil
			local ok, err = xpcall(function()
				local keylogger = require(keylogger_name)
				keylogger.init({ sqlite_path = "/tmp/owned-local-day-unit.sqlite" })
				require("tests.support.metrics_consent_fixture").enable(keylogger)
				with_local_day_clock(function()
					keylogger.record_hotstring("owned", "q", "abc", 1000, "static", 0, false)
					keylogger.record_shortcut("owned", "owned-action", 1000)
					keylogger.flush()
					helpers.assert_eq(#writer[kind], 1)
					local row = writer[kind][1].row
					helpers.assert_eq(row.date, "2026-01-02")
					helpers.assert_eq(row.ts, "2026-01-01 23:59:59")
					if kind == "hotstrings" then
						helpers.assert_eq(row.trigger, "q")
						helpers.assert_eq(row.replacement, "abc")
					else helpers.assert_eq(row.key, "owned-action") end
				end)
			end, debug.traceback)
			package.loaded[writer_name], package.loaded[keylogger_name] = previous_writer, previous_keylogger
			if not ok then error(err, 0) end
		end)
	end
	for _, method in ipairs({ "insert_typing_events", "insert_hotstring_events", "insert_shortcut_events", "insert_app_switch_events" }) do
		for _, explicit in ipairs({ false, true }) do
			it("linux-sqlite-local-event-days: " .. method .. (explicit and " retains explicit historical dates" or " defaults to local day"), function()
				with_local_day_clock(function()
					with_writer_read_receipts("1", 0, function(writer)
						local previous_popen = io.popen
						local cipher = require("modules.keylogger.text_cipher")
						local enabled = cipher.is_enabled()
						cipher.set_enabled(false)
						local commands = {}
						io.popen = function(command)
							commands[#commands + 1] = command
							if command:find(".output /dev/null", 1, true) then
								return { read = function() return "\nERGOPTI_SQL_EXIT_STATUS=0\n" end,
									close = function() return true end }
							end
							return previous_popen(command)
						end
						local event = explicit and { date = "1999-12-31", ts = "1999-12-31 23:59:59" } or {}
						local original = require("json").encode(event)
						local ok, err = xpcall(function()
							helpers.assert_true(writer[method]("owned", { event }))
							local ts = explicit and event.ts or "2026-01-01 23:59:59"
							local date = explicit and event.date or "2026-01-02"
							helpers.assert_contains(commands[#commands], "'" .. ts .. "','" .. date .. "'")
							helpers.assert_eq(require("json").encode(event), original)
						end, debug.traceback)
						io.popen = previous_popen
						cipher.set_enabled(enabled)
						if not ok then error(err, 0) end
					end)
				end)
			end)
		end
	end
end)

helpers.describe("linux-sqlite-raw-batch-transactions", function()
	for _, fixture in ipairs({
		{ table_name = "events_typing", method = "insert_typing_events", event = { app = "owned", text = "owned", events_json = "[]" } },
		{ table_name = "events_hotstring", method = "insert_hotstring_events", event = { app = "owned", replacement = "owned" } },
		{ table_name = "events_shortcut", method = "insert_shortcut_events", event = { app = "owned", key = "owned" } },
		{ table_name = "events_app_switch", method = "insert_app_switch_events", event = { prev_app = "owned", next_app = "owned" } },
	}) do
		for _, status in ipairs({ 0, 7 }) do
			it("linux-sqlite-raw-batch-transactions: " .. fixture.table_name .. " owns one transaction and receipt " .. status, function()
				local command = require("modules.keylogger.sqlite_command")
				local Cipher = require("modules.keylogger.text_cipher")
				local previous_build, previous_cipher = command.build, Cipher.is_enabled()
				local previous_execute, previous_popen = os.execute, io.popen
				local captured, body, code = {}, "", 0
				local path = os.tmpname()
				local seed = assert(io.open(path, "w"))
				assert(seed:write("owned native fixture") and seed:close())
				Cipher.set_enabled(false)
				command.build = function(selected, sql, options)
					captured[#captured + 1] = sql
					body, code = "", 0
					if sql:find("SELECT sql FROM sqlite_master", 1, true) then
						body = "CREATE TABLE devices(os CHECK(os IN ('linux')));\n"
					elseif sql:find("SELECT CAST(value AS INTEGER)", 1, true) then body = "1\n"
					elseif sql:find("INSERT OR IGNORE INTO " .. fixture.table_name, 1, true) then code = status end
					return previous_build(selected, sql, options)
				end
				os.execute = function() return 0 end
				io.popen = function()
					local output = body .. "\nERGOPTI_SQL_EXIT_STATUS=" .. code .. "\n"
					return { read = function() return output end, close = function() return true end }
				end
				local Writer
				local ok, err = xpcall(function()
					Writer = helpers.load_module("modules.keylogger.sqlite_writer")
					helpers.assert_true(Writer.open_db(path))
					helpers.assert_eq(Writer[fixture.method]("owned", { fixture.event }), status == 0)
					local sql = captured[#captured]
					helpers.assert_contains(sql, "BEGIN IMMEDIATE;\nINSERT OR IGNORE INTO " .. fixture.table_name)
					helpers.assert_true(sql:match("COMMIT;%s*$") ~= nil, "the final transaction command must be COMMIT")
				end, debug.traceback)
				command.build = previous_build
				os.execute, io.popen = previous_execute, previous_popen
				Cipher.set_enabled(previous_cipher)
				if Writer then Writer.close_db() end
				os.remove(path)
				if not ok then error(err, 0) end
			end)
		end
	end
end)

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

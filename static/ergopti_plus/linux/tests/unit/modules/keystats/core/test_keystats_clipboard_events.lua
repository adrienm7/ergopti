--- tests/unit/modules/keystats/core/test_keystats_clipboard_events.lua

--- ==============================================================================
--- MODULE: Clipboard Copy/Paste Bursts In The Linux Metrics Database
--- DESCRIPTION:
--- Windows writes events_clipboard (clipboard_copy, clipboard_paste,
--- paste_burst) and Linux wrote none. These tests replay the shared contract,
--- prove the recorder buffers the rows and flushes them once, that a pause or
--- an excluded context records nothing and clears the copy provenance, and
--- that the writer's SQL lands in the real schema through the sqlite3 CLI.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")
local quote = require("text_utils").shell_quote

require("test.clipboard_events_contract").register(helpers)

local HAS_SQLITE = (function()
	local status = os.execute("command -v sqlite3 >/dev/null 2>&1")
	return status == true or status == 0
end)()

--- Runs a keystats instance over the flush double and hands it to the body.
--- @param body fun(keystats, fake_writer)
local function with_keystats(body)
	local fake_writer = setmetatable({
		open_db = function() return true end,
		ensure_token_encoding = function() return true end,
		ensure_awake_definition = function() return true end,
		register_device = function() return true end,
		read_open_walk = function() return nil, true end,
		upsert_open_walk = function() return true end,
		is_available = function() return true end,
		bump_rev = function() return true end,
	}, { __index = Fakes.sqlite_writer() })
	require("tests.support.sqlite_flush_fake").attach(fake_writer)
	local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
	local previous_writer, previous_keystats = package.loaded[writer_name], package.loaded[keystats_name]
	package.loaded[writer_name], package.loaded[keystats_name] = fake_writer, nil
	local ok, err = pcall(function()
		local keystats = require(keystats_name)
		keystats.init({ sqlite_path = "/tmp/ergopti_keystats_clipboard_mock.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		body(keystats, fake_writer)
	end)
	package.loaded[writer_name], package.loaded[keystats_name] = previous_writer, previous_keystats
	if not ok then error(err, 0) end
end

local function rows_of(fake_writer)
	local out = {}
	for _, entry in ipairs(fake_writer.clipboard_events) do
		out[#out + 1] = { kind = entry.row.kind, app = entry.row.app, meta = entry.row.meta }
	end
	return out
end

helpers.describe("Linux clipboard copy/paste bursts", function()
	helpers.it("linux-clipboard-flush: copies, pastes and their burst reach the writer once", function()
		with_keystats(function(keystats, fake_writer)
			keystats.record_clipboard_chord("org.kde.kate", "copy", 1000)
			for at = 2000, 6000, 1000 do keystats.record_clipboard_chord("org.kde.kate", "paste", at) end
			keystats.flush()
			local rows = rows_of(fake_writer)
			helpers.assert_eq(#rows, 7, "one copy, five pastes, one burst")
			helpers.assert_eq(rows[1].kind, "clipboard_copy")
			helpers.assert_eq(rows[1].meta, { content_type = "unknown" })
			helpers.assert_eq(rows[2].kind, "clipboard_paste")
			helpers.assert_eq(rows[2].meta.copy_lag_ms, 1000)
			helpers.assert_eq(rows[2].meta.source_app, rows[1].app)
			helpers.assert_eq(rows[7], { kind = "paste_burst", app = rows[1].app,
				meta = { count = 5, window_ms = require("infra.timings").ms("keystats", "paste_burst_window_ms") } })
			keystats.flush()
			helpers.assert_eq(#fake_writer.clipboard_events, 7, "a second flush must not replay the rows")
		end)
	end)

	helpers.it("linux-clipboard-pause: a paused or excluded chord records nothing and drops the copy's provenance", function()
		with_keystats(function(keystats, fake_writer)
			keystats.record_clipboard_chord("org.kde.kate", "copy", 1000)
			keystats.suspend_collection()
			keystats.record_clipboard_chord("org.kde.kate", "copy", 2000)
			keystats.record_clipboard_chord("org.kde.kate", "paste", 2500)
			keystats.resume_collection()
			keystats.record_clipboard_chord("org.kde.kate", "paste", 3000)
			keystats.record_clipboard_chord("org.kde.kate", "copy", 4000)
			keystats.record_clipboard_chord("org.kde.kate", "copy", 5000, true)
			keystats.record_clipboard_chord("org.kde.kate", "paste", 6000)
			keystats.flush()
			local rows = rows_of(fake_writer)
			helpers.assert_eq(#rows, 4, "the paused copy and paste and the excluded copy are not rows")
			helpers.assert_eq(rows[2].meta, { copy_lag_ms = -1, source_app = "" },
				"the paused copy cleared the provenance of the first one")
			helpers.assert_eq(rows[4].meta, { copy_lag_ms = -1, source_app = "" },
				"the excluded copy cleared the provenance of the recorded one")
		end)
	end)

	helpers.it("linux-clipboard-unrecorded-app: an application left out of the metrics has no clipboard rows", function()
		with_keystats(function(keystats, fake_writer)
			keystats.set_disabled_apps({ "org.kde.kate" })
			keystats.record_clipboard_chord("org.kde.kate", "copy", 1000)
			keystats.record_clipboard_chord("org.mozilla.firefox", "paste", 2000)
			keystats.flush()
			local rows = rows_of(fake_writer)
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1].meta, { copy_lag_ms = -1, source_app = "" })
		end)
	end)

	helpers.it("linux-clipboard-writer: the writer's statements land in the shared schema", function()
		if not HAS_SQLITE then return end
		local command = require("modules.keystats.sqlite_command")
		local Cipher = require("modules.keystats.text_cipher")
		local previous_build, previous_cipher = command.build, Cipher.is_enabled()
		local previous_execute, previous_popen = os.execute, io.popen
		local statement, body = nil, ""
		local path = os.tmpname()
		local seed = assert(io.open(path, "w"))
		assert(seed:write("owned native fixture") and seed:close())
		Cipher.set_enabled(false)
		command.build = function(selected, sql, options)
			if sql:find("INSERT OR IGNORE INTO events_clipboard", 1, true) then statement = sql end
			body = ""
			if sql:find("SELECT sql FROM sqlite_master", 1, true) then
				body = "CREATE TABLE devices(os CHECK(os IN ('linux')));\n"
			elseif sql:find("SELECT CAST(value AS INTEGER)", 1, true) then body = "1\n" end
			return previous_build(selected, sql, options)
		end
		os.execute = function() return 0 end
		io.popen = function()
			local output = body .. "\nERGOPTI_SQL_EXIT_STATUS=0\n"
			return { read = function() return output end, close = function() return true end }
		end
		local writer
		local ok, reason = xpcall(function()
			writer = helpers.load_module("modules.keystats.sqlite_writer")
			helpers.assert_true(writer.open_db(path))
			writer.insert_clipboard_events("owned", {
				{ ts = "2026-11-10 10:00:00.000", date = "2026-11-10", kind = "clipboard_paste", app = "l'app",
					meta = { copy_lag_ms = 12, source_app = "kate" } },
				{ ts = "2026-11-10 10:00:01.000", date = "2026-11-10", kind = "paste_burst", app = "kate",
					meta = { count = 5, window_ms = 10000 } },
			})
		end, debug.traceback)
		command.build = previous_build
		os.execute, io.popen = previous_execute, previous_popen
		Cipher.set_enabled(previous_cipher)
		if writer then writer.close_db() end
		os.remove(path)
		if not ok then error(reason, 0) end
		helpers.assert_true(statement ~= nil, "the writer issued no events_clipboard INSERT")
		local inserts = {}
		for line in statement:gmatch("[^\n]+") do
			if line:find("^INSERT OR IGNORE INTO events_clipboard") then inserts[#inserts + 1] = line end
		end
		helpers.assert_eq(#inserts, 2)
		local db = os.tmpname()
		local script = os.tmpname()
		local handle = assert(io.open(script, "wb"))
		local schema = assert(io.open(require("infra.paths").shared("data/db/schema.sql"), "rb"))
		handle:write(".output /dev/null\n", schema:read("*a"), "\n.output stdout\n", table.concat(inserts, "\n"),
			"\nSELECT kind || '|' || app || '|' || meta_json FROM events_clipboard ORDER BY id;\n")
		schema:close()
		handle:close()
		local pipe = assert(io.popen("sqlite3 -bail -noheader " .. quote(db) .. " < " .. quote(script) .. " 2>&1"))
		local output = pipe:read("*a")
		pipe:close()
		os.remove(script)
		os.remove(db)
		helpers.assert_eq(output, "clipboard_paste|l'app|{\"copy_lag_ms\":12,\"source_app\":\"kate\"}\n"
			.. "paste_burst|kate|{\"count\":5,\"window_ms\":10000}\n")
	end)
end)

--- tests/support/keystats/rollover_marker_process.lua

--- ==============================================================================
--- MODULE: Rollover Marker Native Process
--- DESCRIPTION:
--- Actual storage modules and private native streams with the existing Python
--- SQLite bridge. Metadata/lock ports remain portable controls, not Cocoa proof.
--- ==============================================================================

return function()
	-- Prepared fix regression proposal only. Do not execute before Root ACK and source binding.
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver = root .. "/static/ergopti_plus/macos"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	local Json = require("json")
	local Helpers = require("tests.helpers")
	local Lfs = require("lfs")
	local case = assert(os.getenv("ERGOPTI_ROLLOVER_CASE"))
	local phase = assert(os.getenv("ERGOPTI_ROLLOVER_PHASE"))
	assert(case ~= "", "explicit case required")
	local strategy = assert(os.getenv("ERGOPTI_ROLLOVER_STRATEGY"))
	local fault_ports
	assert(phase == "prepare" or phase == "cold_boot" or phase == "warm_boot" or phase == "reject_boot")
	local OLD, NEW = "2026-10-20", "2026-10-21"
	local active_day = phase == "prepare" and OLD or NEW
	local real_date, real_open = os.date, io.open
	local ledger = temporary .. "/metrics/by_device/device/data.sql"
	local journal = temporary .. "/metrics/by_device/device/today.log"
	local cache = temporary .. "/ergopti_metrics/device/db.sqlite"
	local operations, timers, native_streams = {}, {}, {}
	local errors, warnings, sqlite_live, fault_armed = {}, {}, false, false
	local marker_opens, marker_refusals = 0, 0
	local result, manager, writer, rotation, scheduler = nil, nil, nil, nil, nil
	local reset_updates = 0

	local function read_file(path)
		local stream = assert(real_open(path, "rb"))
		local bytes = assert(stream:read("*a"))
		assert(stream:close())
		return bytes
	end

	local function rpc(message)
		message.kind = "request"
		assert(io.stdout:write(Json.encode(message) .. "\n"))
		assert(io.stdout:flush())
		return assert(Json.decode_lossless(assert(io.stdin:read("*l"))))
	end

	local function request(message)
		local response = rpc(message)
		assert(response.ok, response.error)
		return response.value
	end

	local function open_database(path)
		assert(path == cache, "SQLite escaped the owned disposable cache")
		local identity = request({ op = "open", path = path })
		sqlite_live = true
		local database = { last_error = "" }
		function database:exec(sql)
			if sql == "UPDATE meta SET value='0' WHERE key='today_log_offset';" then reset_updates = reset_updates + 1 end
			local response = rpc({ op = "exec", connection = identity, sql = sql })
			self.last_error = response.error or ""
			if fault_ports and fault_ports.armed and case == "reset_commit_refused"
				and sql == "COMMIT;" and response.ok == false then
				assert(self.last_error:find("locked", 1, true), self.last_error)
				fault_ports.faults = fault_ports.faults + 1
			end
			return response.ok and response.value or 1
		end
		function database:nrows(sql)
			local rows = request({ op = "rows", connection = identity, sql = sql })
			for _, row in ipairs(rows) do
				for key, value in pairs(row) do if Json.is_null(value) then row[key] = nil end end
			end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		function database:prepare(sql)
			local statement = { values = nil, finalized = false }
			function statement:bind_values(...)
				assert(not self.finalized)
				self.values = { ... }
				return 0
			end
			function statement:step()
				assert(not self.finalized and self.values)
				local response = rpc({ op = "bound", connection = identity, sql = sql, values = self.values })
				database.last_error = response.error or ""
				return response.ok and 101 or 1
			end
			function statement:finalize()
				assert(not self.finalized); self.finalized = true
				return 0
			end
			return statement
		end
		function database:errmsg() return self.last_error end
		function database:isopen() return sqlite_live end
		function database:close()
			local status = request({ op = "close", connection = identity })
			sqlite_live = false
			return status
		end
		return database
	end

	local function new_timer(seconds, callback)
		local timer = { active = false, seconds = seconds, callback = callback, starts = 0, stops = 0 }
		function timer:start() self.active = true; self.starts = self.starts + 1; return self end
		function timer:stop() self.active = false; self.stops = self.stops + 1; return self end
		function timer:running() return self.active end
		timers[#timers + 1] = timer
		return timer
	end

	local function counts()
		local database = assert(writer.get_db(), "actual writer must own its SQLite handle")
		local values = {}
		for _, item in ipairs({ { "old", OLD }, { "new", NEW } }) do
			for row in database:nrows("SELECT COUNT(*) AS count, COALESCE(SUM(duration_ms),0) AS duration"
				.. " FROM events_app_switch WHERE date='" .. item[2] .. "'") do
				values[item[1] .. "_events"] = row.count
				values[item[1] .. "_duration"] = row.duration
			end
			for row in database:nrows("SELECT COALESCE(SUM(app_time_ms),0) AS duration"
				.. " FROM agg_app_day WHERE date='" .. item[2] .. "' AND app='Editor'") do
				values[item[1] .. "_aggregate"] = row.duration
			end
		end
		return values
	end

	local function retire()
		local outcomes = {}
		if manager then
			local ok, stopped = pcall(manager.stop, { process_exit = true })
			outcomes.manager_stop_call_ok, outcomes.manager_stop = ok, stopped == true
		end
		if scheduler then
			local ok, stopped = pcall(scheduler.cancelAll)
			outcomes.scheduler_cancel_call_ok, outcomes.scheduler_cancel = ok, stopped ~= false
		end
		outcomes.streams_closed = 0
		-- Rotation currently exposes no public close method. These are the exact
		-- native append capabilities this private fixture acquired, never a path
		-- reopened for cleanup. The process exit remains a separate waited boundary.
		for _, stream in ipairs(native_streams) do
			if io.type(stream) == "file" then
				local ok, closed = pcall(stream.close, stream)
				assert(ok and closed == true, "owned rotation stream cleanup refused")
				outcomes.streams_closed = outcomes.streams_closed + 1
			end
		end
		outcomes.timers_retired = true
		for _, timer in ipairs(timers) do
			if timer:running() then outcomes.timers_retired = false end
		end
		outcomes.sqlite_retired = not sqlite_live
		assert(outcomes.manager_stop_call_ok and outcomes.manager_stop)
		assert(outcomes.scheduler_cancel_call_ok and outcomes.scheduler_cancel)
		assert(outcomes.timers_retired and outcomes.sqlite_retired)
		return outcomes
	end

	local Fixture = require("tests.support.file_system_transaction_fixture")
	Fixture.with_fixture(function(native)
		local outcome = table.pack(xpcall(function()
			local adapter = native.make_adapter()
			Helpers.load_with_stubs("hs", {
				fs = { attributes = Lfs.attributes, dir = Lfs.dir, mkdir = Lfs.mkdir,
					rmdir = Lfs.rmdir, symlinkAttributes = Lfs.symlinkattributes },
				json = { encode = Json.encode, decode = Json.decode_lossless },
				sqlite3 = { OK = 0, ERROR = 1, DONE = 101, ROW = 100, open = open_database },
				execute = function(command)
					assert(command:find("IOPlatformUUID", 1, true), "unexpected shell command in private probe")
					return "fixture-host-identity", true, "exit", 0
				end,
				timer = { new = new_timer, absoluteTime = function() return 1000000000 end,
					secondsSinceEpoch = function() return 1792497600 end },
			})
			package.loaded["adapters.file_system"] = adapter
			local logger = Helpers.make_logger_stub()
			logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
			logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			-- The actual modules and their normal shared data remain loaded. No
			-- Rotation, writer, aggregator, export, or manager implementation is faked.
			os.date = function(format, epoch)
				if format == "%Y-%m-%d" and epoch == nil then return active_day end
				return real_date(format, epoch)
			end
			fault_ports = require("tests.support.keystats.rollover_marker_fault_ports").install({
				case = case, phase = phase, ledger = ledger, journal = journal,
				adapter = adapter, json = Json, fs = Lfs, streams = native_streams })
			manager = require("modules.keystats.log_manager")
			writer = require("modules.keystats.sqlite_writer")
			rotation = require("modules.keystats.rotation")
			scheduler = require("adapters.timer_scheduler")
			local initialized = manager.init({ LOG_DIR = temporary .. "/metrics" })
			if phase == "reject_boot" then
				assert(initialized == false, "unowned identity/nonprefix suffix must reject public initialization")
				assert(writer.get_db() == nil, "failed init must close its actual SQLite connection")
				assert(rotation.is_initialized() == false, "failed recovery must not admit the journal writer")
				result = { kind = "done", phase = phase, case = case, init_rejected = true }
				return
			end
			assert(initialized, table.concat(errors, " | "))
			assert(writer.get_db() ~= nil, "public bootstrap must open actual SQLite")
			local function enqueue_new()
				assert(manager.append_log({ type = "app_switch", timestamp = NEW .. " 00:00:01.000",
					prev_app = "Editor", next_app = "Other", duration_ms = 11 }))
				for _, timer in ipairs(timers) do
					if timer:running() and timer.seconds == 0 then timer.callback() end
				end
			end
			local function assert_complete()
				local value = counts()
				assert(value.old_events == 1 and value.old_duration == 37 and value.old_aggregate == 37)
				assert(value.new_events == 1 and value.new_duration == 11 and value.new_aggregate == 11)
				manager.ingest_once()
				local after = counts()
				assert(after.old_events == 1 and after.new_events == 1 and after.new_aggregate == 11)
				local entries, offset, status = rotation.read_new_entries()
				assert(#entries == 0 and status == rotation.READ_STATUS_EOF)
				return after, offset
			end
			if phase == "prepare" then
				assert(manager.append_log({ type = "app_switch", timestamp = OLD .. " 23:59:59.000",
					prev_app = "Editor", next_app = "Other", duration_ms = 37, padding = string.rep("x", 8192) }))
				if case == "ordinary_pending_append" then fault_ports.armed = true end
				manager.ingest_once()
				fault_ports.armed = false
				local old_offset = rotation.get_offset()
				assert(old_offset == #read_file(journal) and old_offset > 8192)
				local old_counts = counts()
				assert(old_counts.old_events == 1 and old_counts.old_aggregate == 37)
				local rolled = nil
				if case ~= "ordinary_pending_append" then
					active_day = NEW
					fault_ports.armed = true
					rolled = manager.day_rollover()
					fault_ports.armed = false
					assert(rolled == (case == "healthy" or case == "old_stream_close_error_after_close"), "refused rollover must not report success")
				end
				assert(fault_ports.faults == (case == "healthy" and 0 or 1), "exactly one configured fault")
				if strategy == "runtime" or strategy == "authority_absent" or strategy == "authority_unrelated" then
					if rolled ~= true then
						local before = Lfs.symlinkattributes(journal) and read_file(journal) or nil
						enqueue_new()
						assert(counts().new_events == 0)
						local after = Lfs.symlinkattributes(journal) and read_file(journal) or nil
						assert(after == before, "fenced producer must retain the FIFO head without new source writes")
					else enqueue_new() end
					if strategy == "authority_absent" or strategy == "authority_unrelated" then
						assert(case == "release_refused_after_terminal")
						local sidecar = ledger .. ".append-journal.json"
						local original = read_file(sidecar)
						local before_ledger, before_updates, before_streams = read_file(ledger), reset_updates, #native_streams
						if strategy == "authority_absent" then assert(os.remove(sidecar))
						else
							local changed = assert(Json.decode_lossless(original))
							assert(changed.version == 1 and changed.phase == "settled")
							changed.batch = "\n-- unrelated settled append\n"
							local file = assert(real_open(sidecar, "wb"))
							assert(file:write(Json.encode(changed))); assert(file:close())
						end
						assert(manager.ingest_once() == false, "uncorrelated completion must remain fenced")
						assert(read_file(ledger) == before_ledger and reset_updates == before_updates)
						assert(#native_streams == before_streams and Lfs.symlinkattributes(journal) == nil)
						assert(counts().new_events == 0)
						local file = assert(real_open(sidecar, "wb")); assert(file:write(original)); assert(file:close())
					end
					manager.ingest_once()
					local after, offset = assert_complete()
					local content = read_file(ledger)
					local _, marker_count = content:gsub("%-%- === day rollover", "")
					assert(marker_count == 1 and fault_ports.journal_removals == 1)
					result = { kind = "done", phase = phase, case = case, strategy = strategy,
						rollover_result = rolled, old_offset = old_offset, counts = after, offset = offset }
				else
					assert(strategy == "restart" or strategy == "sqlite_open_refusal", "explicit restart strategy required")
					result = { kind = "done", phase = phase, case = case, strategy = strategy,
						rollover_result = rolled, old_offset = old_offset, counts = counts(),
						journal_present = Lfs.symlinkattributes(journal) ~= nil }
				end
			else
				local before = counts()
				assert(before.old_events == 1 and before.old_duration == 37 and before.old_aggregate == 37)
				if before.new_events == 0 then enqueue_new(); manager.ingest_once() end
				local after, offset = assert_complete()
				result = { kind = "done", phase = phase, case = case, strategy = strategy,
					before = before, after = after, offset = offset }
			end
			result.faults = fault_ports.faults
			result.operations = { journal_removals = fault_ports.journal_removals,
				marker_opens = fault_ports.marker_opens, marker_writes = fault_ports.marker_writes,
				pending_publications = fault_ports.pending_publications,
				terminal_publications = fault_ports.terminal_publications }

		end, debug.traceback))
		-- Always restore the IO fault and local clock before mandatory retirement.
		fault_armed = false
		if fault_ports then fault_ports.restore() end
		io.open, os.date = real_open, real_date
		local cleanup_ok, cleanup = pcall(retire)
		if not outcome[1] then error(outcome[2], 0) end
		assert(cleanup_ok, cleanup)
		result.cleanup, result.errors, result.warnings = cleanup, errors, warnings
		assert(io.stdout:write(Json.encode(result) .. "\n")); assert(io.stdout:flush())
	end)

end

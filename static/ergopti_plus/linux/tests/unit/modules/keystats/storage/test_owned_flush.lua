--- tests/unit/modules/keystats/storage/test_owned_flush.lua

--- Logical ownership regressions. Native SQLite/pipe/process receipts are covered
--- by run_sqlite_owned_flush_receipts.lua; these ports deliberately stage ACKs.
local helpers = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it
local Fakes = require("tests.fakes")
local function assert_false(value) helpers.assert_eq(value, false) end
require("infra.monotonic") -- Load the genuine clock before temporary native ports.

local function with_collector(body, launch)
	local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
	local old_writer, old_keystats = package.loaded[writer_name], package.loaded[keystats_name]
	local metrics_name = "modules.keystats.metrics_collector"
	local old_metrics = package.loaded[metrics_name]
	local writer, operations, collector = Fakes.sqlite_writer(), {}, nil
	writer.start_flush = function(device, payload)
		if launch then return launch(collector, device, payload) end
		local op = { payload = payload, current_phase = "commit", physical = false }
		function op:pump()
			if self.physical and self.outcome == "commit" then
				self.done, self.safe, self.result = true, true, { committed = true }
			elseif self.physical and self.outcome == "abort" then
				self.safe, self.current_phase = true, "commit_retry"
				if self.stopped then self.done, self.result = true, { committed = false, error = "controlled rollback" } end
			end
			return self.done == true
		end
		function op:is_settled() return self.done == true end
		function op:is_read_safe() return self.safe == true end
		function op:is_retryable() return self.current_phase == "commit_retry" and not self.done end
		function op:phase() return self.current_phase end
		function op:retry()
			self.retries = (self.retries or 0) + 1
			self.physical, self.safe, self.outcome, self.current_phase = false, false, nil, "commit"
			return true
		end
		function op:cancel() self.stopped = true; return self:is_settled() end
		operations[#operations + 1] = op
		return op
	end
	package.loaded[writer_name], package.loaded[keystats_name], package.loaded[metrics_name] = writer, nil, nil
	local ok, err = xpcall(function()
		collector = require(keystats_name)
		collector.init({ sqlite_path = "/tmp/owned-flush-logical.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(collector)
		body(collector, operations, writer)
	end, debug.traceback)
	package.loaded[writer_name], package.loaded[keystats_name], package.loaded[metrics_name] = old_writer, old_keystats, old_metrics
	if not ok then error(err, 0) end
end

helpers.describe("owned SQLite collector flush", function()
	for _, phase in ipairs({ "pending", "rollback", "stopping", "healthy" }) do
		it("rendered session reset preserves its real " .. phase .. " acknowledgement", function()
			with_collector(function(k, ops)
				local Logger, I18n = require("logger.shim"), require("infra.i18n")
				local startup, menu_name = "ui.menu.start_at_login", "ui.menu.menu_builder"
				local old_startup, old_menu = package.loaded[startup], package.loaded[menu_name]
				package.loaded[startup] = { command_available = function() return false end,
					enabled = function() return false end }
				local info, failure = Logger.info, Logger.error
				local successes, refusals = 0, 0
				Logger.info = function(tag, message, ...)
					if message == "Metrics session reset." then successes = successes + 1 end
					return info(tag, message, ...)
				end
				Logger.error = function(tag, message, ...)
					if message == "Metrics session reset was refused; the session is unchanged." then refusals = refusals + 1 end
					return failure(tag, message, ...)
				end
				local ok, err = xpcall(function()
					k.on_keydown("a", 1000, "owned")
					if phase ~= "healthy" then
						assert_false(k.flush())
						if phase == "rollback" then
							ops[1].outcome, ops[1].physical = "abort", true
							assert_false(k.pump_flush())
						elseif phase == "stopping" then assert_false(k.stop()) end
						helpers.assert_true(k.has_flush_debt())
					end
					local menu = helpers.load_module("ui.menu.menu_builder").build({ keystats = k })
					local reset
					for _, parent in ipairs(menu) do
						if parent.title == I18n.get("menu.metrics.title") then
							for _, row in ipairs(parent.menu or {}) do
								if row.title == I18n.get("menu.metrics.reset_session") then reset = row end
							end
						end
					end
					helpers.assert_true(type(reset) == "table" and type(reset.fn) == "function")
					helpers.assert_eq(reset.disabled == true, false)
					local generation = k.get_flush_status().generation
					local result = reset.fn()
					helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
					helpers.assert_true(k.has_flush_debt())
					helpers.assert_eq(successes, 0, "An unacknowledged reset must not announce success")
					if phase == "healthy" then
						helpers.assert_true(result, "one healthy click owns its asynchronous completion")
						helpers.assert_eq(refusals, 0, "accepted native work is not a refusal")
						helpers.assert_true(k.get_flush_status().generation > generation)
						ops[1].outcome, ops[1].physical = "commit", true
						helpers.assert_true(k.pump_flush())
						helpers.assert_eq(k.get_session_stats().keystrokes, 0)
						helpers.assert_eq(successes, 1)
						helpers.assert_eq(refusals, 0)
					else
						assert_false(result)
						helpers.assert_eq(refusals, 1)
						helpers.assert_eq(k.get_flush_status().generation, generation)
						if phase ~= "stopping" then
							ops[1].outcome, ops[1].physical = "commit", true
							helpers.assert_true(k.pump_flush())
							k.on_keydown("b", 1100, "owned")
							helpers.assert_true(reset.fn(), "a fresh user request owns new input after the old write settles")
							helpers.assert_eq(ops[2].payload.raw.typing[1].text, "b")
							ops[2].outcome, ops[2].physical = "commit", true
							helpers.assert_true(k.pump_flush())
							helpers.assert_eq(k._pending_buffer_count_for_test(), 0)
							helpers.assert_eq(successes, 1)
							helpers.assert_eq(refusals, 1)
						end
					end
				end, debug.traceback)
				Logger.info, Logger.error = info, failure
				package.loaded[startup], package.loaded[menu_name] = old_startup, old_menu
				if not ok then error(err, 0) end
			end)
		end)
	end

	it("never publishes staged COMMIT before exact physical ACK", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.flush())
			local calls = 0
			k.when_flush_settled(function() calls = calls + 1 end)
			ops[1].outcome = "commit"
			assert_false(k.pump_flush())
			helpers.assert_eq(calls, 0)
			helpers.assert_true(k.is_flush_pending())
			helpers.assert_eq(k.get_dashboard_payload(), nil)
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
			ops[1].physical = true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(calls, 1)
			assert_false(k.has_flush_debt())
		end)
	end)

	it("known rollback exposes all old+new RAM while retry keeps the original snapshot", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "owned"); k.flush()
			k.on_keydown("b", 1100, "owned")
			local generation = k.get_flush_status().generation
			ops[1].outcome, ops[1].physical = "abort", true
			k.pump_flush()
			helpers.assert_true(k.get_flush_status().read_safe)
			helpers.assert_true(k.has_flush_debt())
			assert_false(k.reset_session())
			local range = assert(k.get_range_payload())
			helpers.assert_eq(range.today.owned.c.a.c, 1)
			helpers.assert_eq(range.today.owned.c.b.c, 1)
			k.flush()
			helpers.assert_true(k.get_flush_status().generation > generation)
			helpers.assert_eq(#ops, 1)
			helpers.assert_eq(ops[1].payload.raw.typing[1].text, "a")
			helpers.assert_eq(ops[1].retries, 1)
			ops[1].outcome, ops[1].physical = "commit", true
			k.pump_flush(); k.flush()
			helpers.assert_eq(#ops, 2)
			helpers.assert_eq(ops[2].payload.raw.typing[1].text, "b")
		end)
	end)

	it("blocks reset, migration, re-init and category edits through retained debt", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "owned"); k.flush()
			assert_false(k.init({ sqlite_path = "/tmp/other.sqlite" }))
			helpers.assert_eq(k.configuration_snapshot(), nil, "scope preparation must refuse before acquiring runtime rollback")
			assert_false(k.clear_cache())
			assert_false(k.set_app_category("owned", "productive", 1))
			assert_false(k.set_encrypt_enabled(true))
			assert_false(k.migrate_stored_text())
			ops[1].outcome, ops[1].physical = "abort", true
			k.pump_flush()
			assert_false(k.clear_cache())
			assert_false(k.reset_session())
		end)
	end)

	it("stop closes producers and waits old plus exactly one final snapshot", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "owned"); k.flush()
			k.on_keydown("b", 1100, "owned")
			local callbacks = 0; k.when_flush_settled(function() callbacks = callbacks + 1 end)
			assert_false(k.stop())
			k.on_keydown("c", 1200, "owned")
			helpers.assert_eq(k._pending_buffer_count_for_test(), 2)
			ops[1].outcome, ops[1].physical = "commit", true
			assert_false(k.stop())
			helpers.assert_eq(#ops, 2)
			helpers.assert_eq(ops[2].payload.raw.typing[1].text, "b")
			ops[2].outcome, ops[2].physical = "commit", true
			helpers.assert_true(k.stop())
			helpers.assert_true(k.stop())
			helpers.assert_eq(#ops, 2)
			helpers.assert_eq(callbacks, 0)
			assert_false(k.flush())
			assert_false(k.when_flush_settled(function() error("stopped observer ran") end))
		end)
	end)

	it("failed business persistence acknowledges only physical retirement and retains source", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "owned"); k.flush()
			assert_false(k.stop())
			ops[1].outcome = "abort"
			assert_false(k.stop())
			ops[1].physical = true
			helpers.assert_true(k.stop())
			helpers.assert_true(k.has_flush_debt())
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
			assert_false(k.get_flush_status().committed)
		end)
	end)

	it("nil dispatch restores old prefix plus synchronously admitted new input", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.flush())
			assert_false(k.has_flush_debt())
			helpers.assert_eq(k._pending_buffer_count_for_test(), 2)
			local row = assert(k.get_range_payload()).today.owned.c
			helpers.assert_eq(row.a.c, 1); helpers.assert_eq(row.b.c, 1)
		end, function(k) k.on_keydown("b", 1100, "owned"); return nil end)
	end)

	it("a throwing dispatch retains uncertain ownership instead of inventing ACK", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.flush())
			helpers.assert_true(k.has_flush_debt())
			assert_false(k.get_flush_status().read_safe)
			assert_false(k.stop())
		end, function() error("controlled uncertain acquisition") end)
	end)


	it("(live-range-app-filter) RAM characters, sources and physical keys honor selected apps", function()
		with_collector(function(k)
			for _, app in ipairs({ "org.example.selected", "org.example.excluded" }) do
				k.on_keydown("a", 1000, app)
				k.record_physical_key(app, 30, 1000)
				k.record_synthetic_output(app, "s", "hotstring", 1100)
			end
			for _, apps in ipairs({ { "org.example.selected" }, { false, "", "org.example.selected" } }) do
				local today = assert(k.get_range_payload(nil, nil, apps)).today
				helpers.assert_nil(today["org.example.excluded"], "An excluded app must not be reintroduced from RAM")
				helpers.assert_eq(today["org.example.selected"].c.a.c, 1)
				helpers.assert_eq(today["org.example.selected"].c.s.hs, 1)
				helpers.assert_eq(today["org.example.selected"].sc_kb["30"].c, 1)
			end
			helpers.assert_eq(next(assert(k.get_range_payload(nil, nil, { "other" })).today), nil)
		end)
	end)

	it("(live-range-app-filter) absent or wholly invalid selection keeps the SQL all-apps contract", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "org.example.selected")
			k.on_keydown("b", 1100, "org.example.excluded")
			for _, apps in ipairs({ false, {}, { false, "" } }) do
				local today = assert(k.get_range_payload(nil, nil, apps)).today
				helpers.assert_eq(today["org.example.selected"].c.a.c, 1)
				helpers.assert_eq(today["org.example.excluded"].c.b.c, 1)
			end
		end)
	end)

	it("(live-range-app-filter) rollback retains complete RAM while selection survives the COMMIT watermark", function()
		with_collector(function(k, ops)
			k.on_keydown("a", 1000, "selected")
			k.on_keydown("x", 1100, "excluded")
			k.flush()
			k.on_keydown("b", 1200, "selected")
			k.on_keydown("y", 1300, "excluded")
			helpers.assert_nil(k.get_range_payload(nil, nil, { "selected" }))
			ops[1].outcome, ops[1].physical = "abort", true
			k.pump_flush()
			local today = assert(k.get_range_payload(nil, nil, { "selected" })).today
			helpers.assert_nil(today.excluded)
			helpers.assert_eq(today.selected.c.a.c, 1)
			helpers.assert_eq(today.selected.c.b.c, 1)
			k.flush()
			ops[1].outcome, ops[1].physical = "commit", true
			k.pump_flush()
			today = assert(k.get_range_payload(nil, nil, { "selected" })).today
			helpers.assert_nil(today.excluded)
			helpers.assert_nil(today.selected.c.a, "Committed characters leave the live delta")
			helpers.assert_eq(today.selected.c.b.c, 1)
			local all = assert(k.get_range_payload()).today
			helpers.assert_eq(all.excluded.c.y.c, 1, "Selection cannot discard retained input")
		end)
	end)


	it("(sqlite-range-date-boundary) excluded days never regain live characters or physical keys", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "selected")
			k.record_physical_key("selected", 30, 1000)
			for _, bounds in ipairs({ { "2020-01-01", "2020-01-01" }, { "2100-01-01", "2100-01-01" } }) do
				local payload = assert(k.get_range_payload(bounds[1], bounds[2], { "selected" }))
				helpers.assert_nil(next(payload.today), "Excluded live input must stay outside the requested dates")
			end
			local today = os.date("%Y-%m-%d")
			local payload = assert(k.get_range_payload(today, today, { "selected" }))
			helpers.assert_eq(payload.today.selected.c.a.c, 1)
			helpers.assert_eq(payload.today.selected.sc_kb["30"].c, 1)
		end)
	end)


	it("(sqlite-range-date-boundary) a missing projection owner refuses instead of merging unrestricted RAM", function()
		local name = "modules.keystats.sqlite_reader"
		local previous, preload = package.loaded[name], package.preload[name]
		package.loaded[name] = nil
		package.preload[name] = function() error("deliberately absent projection owner") end
		local ok, err = xpcall(function()
			with_collector(function(k)
				k.on_keydown("a", 1000, "selected")
				local payload, reason = k.get_range_payload("2020-01-01", "2020-01-01")
				helpers.assert_nil(payload)
				helpers.assert_eq(reason, "SQLite projection unavailable")
				helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
			end)
		end, debug.traceback)
		package.loaded[name], package.preload[name] = previous, preload
		if not ok then error(err, 0) end
	end)


	it("(sqlite-range-date-boundary) one captured day owns both SQL and RAM across midnight", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "selected")
			local native_date, captures = os.date, 0
			os.date = function(format, timestamp)
				if format == "%Y-%m-%d" and timestamp == nil then
					captures = captures + 1
					return captures == 1 and "2026-10-18" or "2026-10-19"
				end
				return native_date(format, timestamp)
			end
			local ok, err = xpcall(function()
				local payload = assert(k.get_range_payload("2026-10-18", "2026-10-18", { "selected" }))
				helpers.assert_eq(payload.today.selected.c.a.c, 1)
				helpers.assert_eq(captures, 1, "SQL and RAM must share the original local date")
			end, debug.traceback)
			os.date = native_date
			if not ok then error(err, 0) end
		end)
	end)

	it("healthy reset returns a real ACK and retires its UI generation", function()
		with_collector(function(k, operations)
			local generation = k.get_flush_status().generation
			k.on_keydown("a", 1000, "owned")
			assert_false(k.reset_session())
			helpers.assert_eq(operations[1].payload.raw.typing[1].text, "a")
			helpers.assert_eq(k.get_session_stats().keystrokes, 1)
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_true(k.reset_session())
			helpers.assert_true(k.get_flush_status().generation > generation)
			helpers.assert_eq(k._pending_buffer_count_for_test(), 0)
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
		end)
	end)
end)

helpers.describe("linux-open-session-crash-recovery", function()
	--- A keystroke stamp just before now on the monotonic clock the flush settles
	--- with. A fixed small stamp read as typed long ago once the host had been up
	--- longer than the session gap, so the session closed at the first flush.
	local function recent_stamp(index)
		return math.floor(require("infra.monotonic").now_ms()) - 1000 + 100 * index
	end
	--- Starts one collector process against a shared logical database.
	local function process(writer, body)
		local writer_name, keystats_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
		local old_writer, old_keystats = package.loaded[writer_name], package.loaded[keystats_name]
		package.loaded[writer_name], package.loaded[keystats_name] = writer, nil
		local ok, err = xpcall(function()
			local collector = require(keystats_name)
			collector.init({ sqlite_path = "/tmp/open-walk-logical.sqlite" })
			require("tests.support.metrics_consent_fixture").enable(collector)
			body(collector)
		end, debug.traceback)
		package.loaded[writer_name], package.loaded[keystats_name] = old_writer, old_keystats
		if not ok then error(err, 0) end
	end
	local function record(writer)
		for key, value in pairs(writer.meta) do
			if key:find("^open_walk:") then return value end
		end
	end
	local function sessions_for(writer, app)
		local rows = {}
		for _, entry in ipairs(writer.sessions) do
			if entry.row.app == app then rows[#rows + 1] = entry.row end
		end
		return rows
	end

	it("linux-open-session-crash-recovery: the session still open at a COMMIT is recorded with it", function()
		local writer = Fakes.sqlite_writer()
		process(writer, function(k)
			for index, char in ipairs({ "a", "b", "c" }) do k.on_keydown(char, recent_stamp(index), "owned") end
			helpers.assert_true(k.flush())
		end)
		local text = record(writer)
		helpers.assert_true(type(text) == "string", "an open session must be recorded beside the rows it was cut from")
		helpers.assert_contains(text, '"app":"owned"')
		helpers.assert_eq(#sessions_for(writer, "owned"), 0, "the session is still open, not credited")
	end)

	it("linux-open-session-crash-recovery: a process after a crash credits the open session once", function()
		local writer = Fakes.sqlite_writer()
		process(writer, function(k)
			for index, char in ipairs({ "a", "b", "c" }) do k.on_keydown(char, recent_stamp(index), "owned") end
			helpers.assert_true(k.flush())
			-- No stop(): the process dies here, before its final flush.
		end)
		process(writer, function(k)
			helpers.assert_true(k.flush())
			local credited = sessions_for(writer, "owned")
			helpers.assert_eq(#credited, 1, "the crashed session must be credited by the next process")
			helpers.assert_eq(credited[1].count_total, 1)
			helpers.assert_eq(credited[1].longest_chars, 3)
			helpers.assert_eq(record(writer), "[]", "the credited session leaves the record")
			helpers.assert_true(k.flush())
			helpers.assert_eq(#sessions_for(writer, "owned"), 1, "a recovered session is credited exactly once")
		end)
	end)

	it("linux-open-session-crash-recovery: a clean stop leaves nothing to recover", function()
		local writer = Fakes.sqlite_writer()
		process(writer, function(k)
			for index, char in ipairs({ "a", "b" }) do k.on_keydown(char, recent_stamp(index), "owned") end
			helpers.assert_true(k.flush())
			k.stop()
			helpers.assert_eq(#sessions_for(writer, "owned"), 1)
			helpers.assert_eq(record(writer), "[]")
		end)
		process(writer, function(k)
			k.flush()
			helpers.assert_eq(#sessions_for(writer, "owned"), 1, "a stopped process's session is not credited twice")
		end)
	end)

	it("linux-open-session-crash-recovery: an unchanged open state is not rewritten", function()
		local writer = Fakes.sqlite_writer()
		local writes = 0
		local start = writer.start_flush
		writer.start_flush = function(device, payload)
			for _, entry in ipairs(payload.upserts) do
				if entry.kind == "open_walk" then writes = writes + 1 end
			end
			return start(device, payload)
		end
		process(writer, function(k)
			helpers.assert_true(k.flush())
			helpers.assert_eq(writes, 0, "nothing open and nothing recorded: no write")
			k.on_keydown("a", recent_stamp(1), "owned")
			helpers.assert_true(k.flush())
			helpers.assert_eq(writes, 1)
			helpers.assert_true(k.flush())
			helpers.assert_eq(writes, 1, "an unchanged open session is not written again")
		end)
	end)

	it("linux-open-session-crash-recovery: a malformed record credits nothing and is replaced", function()
		for _, text in ipairs({ "not json", '[{"date":"2026-10-21","app":"owned","session":[1]}]', '{"app":"x"}' }) do
			local writer = Fakes.sqlite_writer()
			-- The driver names its device after the kernel nodename, not the hostname
			-- program, which minimal Arch, Fedora and openSUSE images lack.
			local nodename = assert(io.open("/proc/sys/kernel/hostname", "rb"))
			local host = (nodename:read("*l") or "linux"):gsub("%s+", "")
			nodename:close()
			writer.meta["open_walk:linux-" .. host] = text
			process(writer, function(k)
				for index, char in ipairs({ "a", "b" }) do k.on_keydown(char, recent_stamp(index), "fresh") end
				helpers.assert_true(k.flush())
			end)
			helpers.assert_eq(#writer.sessions, 0, text)
			helpers.assert_contains(record(writer), '"app":"fresh"')
		end
	end)
end)

helpers.describe("session reset preserves committed and pending history", function()
	it("reset-preserves-history: waits for close COMMIT before clearing live counters", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			k.on_keydown("b", 1100, "owned")
			assert_false(k.reset_session())
			helpers.assert_eq(k.get_session_stats().keystrokes, 2, "pending reset cannot clear live counters")
			helpers.assert_eq(operations[1].payload.raw.typing[1].text, "ab")
			helpers.assert_eq(#operations[1].payload.raw.sessions, 2)
			helpers.assert_eq(operations[1].payload.raw.sessions[1].kind, "session_start")
			helpers.assert_eq(operations[1].payload.raw.sessions[2].kind, "session_end")
			helpers.assert_eq(operations[1].payload.raw.sessions[2].duration_ms, 100)
			assert_false(k.reset_session())
			helpers.assert_eq(#operations, 1, "an unacknowledged reset cannot launch another writer")
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_true(k.pump_flush())
			local generation = k.get_flush_status().generation
			helpers.assert_true(k.reset_session())
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
			helpers.assert_eq(k.get_flush_status().generation, generation + 1)
			helpers.assert_eq(#operations, 1, "acknowledged closing history must not be written twice")
			helpers.assert_true(k.flush())
			helpers.assert_eq(#operations, 1, "a later flush cannot replay reset history")
			helpers.assert_eq(k.get_app_stats().owned.keystrokes, 2, "the daily app history is not a live session counter")
		end)
	end)

	it("reset-preserves-history: retains input arriving during an outstanding reset", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.reset_session())
			k.on_keydown("b", 1100, "owned")
			helpers.assert_eq(operations[1].payload.raw.typing[1].text, "a", "the original reset snapshot stays immutable")
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1, "successor input remains independently owned")
			assert_false(k.reset_session())
			helpers.assert_eq(#operations, 2)
			helpers.assert_eq(operations[2].payload.raw.typing[1].text, "b")
			helpers.assert_eq(#operations[2].payload.raw.sessions, 2)
			operations[2].outcome, operations[2].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_true(k.reset_session())
			helpers.assert_eq(k.get_app_stats().owned.keystrokes, 2)
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
			helpers.assert_eq(k._pending_buffer_count_for_test(), 0)
			k.on_keydown("c", 1200, "owned")
			assert_false(k.flush())
			helpers.assert_eq(operations[3].payload.raw.typing[1].text, "c")
			local added_chars = 0
			for _, entry in ipairs(operations[3].payload.upserts) do
				if entry.kind == "app_day" then added_chars = added_chars + entry.args[3].chars end
			end
			helpers.assert_eq(added_chars, 1, "daily COMMIT watermarks prevent recrediting the old session")
		end)
	end)

	it("reset-preserves-history: a refused writer retains the source and live figures", function()
		with_collector(function(k)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.reset_session())
			helpers.assert_eq(k.get_session_stats().keystrokes, 1)
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
			assert_false(k.has_flush_debt(), "refusal acquired no native owner")
			assert_false(k.reset_session())
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1, "retry cannot discard the original input")
		end, function() return nil end)
	end)

	it("reset-preserves-history: closes a paused session without ending its pause", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			k.suspend_collection()
			assert_false(k.reset_session())
			helpers.assert_eq(operations[1].payload.raw.typing[1].text, "a")
			helpers.assert_eq(operations[1].payload.raw.sessions[2].kind, "session_end")
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_true(k.reset_session())
			helpers.assert_true(k.is_collection_suspended())
		end)
	end)
end)

helpers.describe("session reset receipt currency", function()
	it("reset-preserves-history: an ordinary successor flush cannot reuse the old reset receipt", function()
		with_collector(function(k, operations)
			local now = math.floor(require("infra.monotonic").now_ms())
			k.on_keydown("a", now, "owned")
			assert_false(k.reset_session())
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			k.on_keydown("b", now + 100, "owned")
			assert_false(k.flush())
			operations[2].outcome, operations[2].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(k._pending_buffer_count_for_test(), 0, "the ordinary flush has stored the successor text")
			assert_false(k.reset_session())
			helpers.assert_eq(#operations, 3, "the successor's open session needs its own closing transaction")
			helpers.assert_eq(#operations[3].payload.raw.typing, 0)
			helpers.assert_eq(operations[3].payload.raw.sessions[1].kind, "session_end")
			local settled_sessions = 0
			for _, entry in ipairs(operations[3].payload.upserts) do
				if entry.kind == "session" then settled_sessions = settled_sessions + entry.args[1].count_total end
			end
			helpers.assert_eq(settled_sessions, 1, "the old successful reset cannot suppress aggregate settlement")
			operations[3].outcome, operations[3].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_true(k.reset_session())
		end)
	end)
end)

helpers.describe("session reset inline capture", function()
	it("reset-preserves-history: synchronous COMMIT retains input admitted inside dispatch", function()
		local committed_writer, launches = Fakes.sqlite_writer(), 0
		with_collector(function(k)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.reset_session())
			helpers.assert_eq(k.get_session_stats().keystrokes, 2, "inline successor input must keep its live session")
			helpers.assert_eq(k._pending_buffer_count_for_test(), 1)
			helpers.assert_true(k.reset_session())
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
			helpers.assert_eq(k.get_app_stats().owned.keystrokes, 2)
		end, function(k, device, payload)
			launches = launches + 1
			if launches == 1 then k.on_keydown("b", 1100, "owned") end
			return committed_writer.start_flush(device, payload)
		end)
		helpers.assert_eq(#committed_writer.typing, 2)
		helpers.assert_eq(committed_writer.typing[1].row.text, "a")
		helpers.assert_eq(committed_writer.typing[2].row.text, "b")
		helpers.assert_eq(#committed_writer.session_events, 4, "each admitted session retains both lifecycle markers")
	end)
end)

helpers.describe("session reset refusal keeps exact session ownership", function()
	for _, reentrant in ipairs({ false, true }) do
		it("reset-refusal-owner: retains the original session with reentrant=" .. tostring(reentrant), function()
			local writer, admitted, launches = Fakes.sqlite_writer(), false, 0
			local clock = require("infra.monotonic")
			local previous_now, now = clock.now_ms, math.floor(clock.now_ms())
			clock.now_ms = function() return now end
			local ok, err = pcall(function()
				with_collector(function(k)
					k.on_keydown("a", now, "owned")
					assert_false(k.reset_session())
					assert_false(k.has_flush_debt(), "a refused constructor acquired no native owner")
					now = now + 100
					k.on_keydown("c", now, "owned")
					admitted = true
					helpers.assert_true(k.flush())
					local kinds = {}
					for _, event in ipairs(writer.session_events) do kinds[#kinds + 1] = event.row.kind end
					local expected = reentrant and { "session_start", "idle_start", "idle_end" } or { "session_start" }
					helpers.assert_eq(kinds, expected, "the refused reset must publish neither a close nor a successor start")
					helpers.assert_eq(k.get_session_stats().keystrokes, reentrant and 3 or 2)
					helpers.assert_eq(writer.typing[1].row.text, reentrant and "abc" or "ac")
				end, function(k, device, payload)
					launches = launches + 1
					if not admitted then
						if reentrant then
							now = now + 100
							k.on_keydown("b", now, "owned")
							now = now + require("infra.timings").ms("keystats", "micro_idle_timeout_ms") + 1
							assert_false(k.flush())
						end
						assert_false(k.reset_session(), "nested construction cannot replace the original reset owner")
						return nil
					end
					return writer.start_flush(device, payload)
				end)
			end)
			clock.now_ms = previous_now
			if not ok then error(err, 0) end
			helpers.assert_eq(launches, 2, "nested reset cannot acquire another constructor")
		end)
	end
end)

helpers.describe("session reset construction reentry", function()
	it("reset-refusal-owner: nested reset cannot enter before native reservation", function()
		local writer, launches, nested = Fakes.sqlite_writer(), 0, nil
		local previous_date, intercept, collector = os.date, false, nil
		os.date = function(...)
			if intercept then
				intercept = false
				assert_false(collector.has_flush_debt(), "the nested call precedes native reservation")
				nested = collector.reset_session()
			end
			return previous_date(...)
		end
		local ok, err = pcall(function()
			with_collector(function(k)
				collector = k
				k.on_keydown("a", 1000, "owned")
				intercept = true
				helpers.assert_true(k.reset_session())
				assert_false(nested, "the original construction owner must refuse a second reset")
				helpers.assert_eq(k.get_session_stats().keystrokes, 0)
			end, function(_, device, payload)
				launches = launches + 1
				return writer.start_flush(device, payload)
			end)
		end)
		os.date = previous_date
		if not ok then error(err, 0) end
		helpers.assert_eq(launches, 1)
		helpers.assert_eq(#writer.session_events, 2)
		helpers.assert_eq(writer.session_events[1].row.kind, "session_start")
		helpers.assert_eq(writer.session_events[2].row.kind, "session_end")
	end)
end)

helpers.describe("session reset construction frame retirement", function()
	it("reset-frame-throw: a failed timestamp restores the source owner and permits retry", function()
		local writer, intercept = Fakes.sqlite_writer(), false
		local previous_date = os.date
		os.date = function(...)
			if intercept then intercept = false; error("controlled reset timestamp failure") end
			return previous_date(...)
		end
		local ok, err = pcall(function()
			with_collector(function(k)
				local now = math.floor(require("infra.monotonic").now_ms())
				k.on_keydown("a", now, "owned")
				intercept = true
				helpers.assert_eq(pcall(k.reset_session), false)
				assert_false(k.has_flush_debt())
				k.on_keydown("b", now + 100, "owned")
				helpers.assert_true(k.reset_session(), "a failed constructor cannot keep owning the next reset")
			end, function(_, device, payload) return writer.start_flush(device, payload) end)
		end)
		os.date = previous_date
		if not ok then error(err, 0) end
		helpers.assert_eq(writer.typing[1].row.text, "ab")
		helpers.assert_eq(#writer.session_events, 2)
		helpers.assert_eq(writer.session_events[2].row.duration_ms, 100)
	end)

	it("reset-frame-throw: a throwing native observation retires the temporary dual branch", function()
		local module_name = "keystats.session_events"
		local original = require(module_name)
		local tracker_inputs = {}
		local wrapped = {}
		for key, value in pairs(original) do wrapped[key] = value end
		wrapped.new = function(options)
			local tracker = original.new(options)
			local index = #tracker_inputs + 1
			tracker_inputs[index] = 0
			local input = tracker.input
			tracker.input = function(...)
				tracker_inputs[index] = tracker_inputs[index] + 1
				return input(...)
			end
			return tracker
		end
		package.loaded[module_name] = wrapped
		local foreign = setmetatable({}, { __tostring = function() error("must not format a foreign error") end })
		local first, launches, observe = nil, 0, false
		local writer = Fakes.sqlite_writer()
		local ok, err = pcall(function()
			with_collector(function(k)
				local now = math.floor(require("infra.monotonic").now_ms())
				k.on_keydown("a", now, "owned")
				local called, failure = pcall(k.reset_session)
				helpers.assert_eq(called, false)
				helpers.assert_true(failure == foreign, "the original error object must propagate without formatting")
				helpers.assert_true(k.has_flush_debt(), "uncertain native ownership must remain retained")
				k.on_keydown("b", now + 100, "owned")
				helpers.assert_eq(tracker_inputs[1], 1, "the retired rollback branch cannot receive later input")
				helpers.assert_eq(tracker_inputs[2], 1, "the successor remains the sole live capture owner")
				observe, first.result = true, { committed = true }
				helpers.assert_true(k.pump_flush())
				helpers.assert_true(k.reset_session())
			end, function(_, device, payload)
				launches = launches + 1
				if launches > 1 then return writer.start_flush(device, payload) end
				first = { pump = function() return observe end, is_settled = function() return observe end,
					is_retryable = function() return false end, phase = function() return "commit" end,
					cancel = function() return false end,
					is_read_safe = function() if not observe then error(foreign, 0) end; return true end }
				return first
			end)
		end)
		package.loaded[module_name] = original
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("one-click owned metrics session reset", function()
	it("reset-one-click: completes once after its exact native ACK with an opaque receipt", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			local origin, replies, receipt = k.get_flush_status().generation, {}, nil
			helpers.assert_true(k.request_session_reset(function(success, completed)
				replies[#replies + 1], receipt = success, completed
			end))
			helpers.assert_eq(#replies, 0)
			assert_false(k.reset_session(), "a borrowed synchronous reset cannot replace the user request")
			assert_false(k.request_session_reset(function() error("duplicate callback") end))
			operations[1].outcome = "commit"
			assert_false(k.pump_flush())
			helpers.assert_eq(#replies, 0, "SQLite COMMIT without physical cleanup is not completion")
			operations[1].physical = true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(replies, { true })
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
			local generation, success = k.reset_receipt_generation(receipt, origin)
			helpers.assert_eq(generation, k.get_flush_status().generation)
			helpers.assert_eq(success, true)
			receipt.generation = -1
			helpers.assert_eq(k.reset_receipt_generation(receipt, origin), generation, "caller fields carry no authority")
			helpers.assert_nil(k.reset_receipt_generation({}, origin))
			helpers.assert_nil(k.reset_receipt_generation(receipt, origin + 1))
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(#replies, 1)
			helpers.assert_true(k.reset_session())
			helpers.assert_nil(k.reset_receipt_generation(receipt, origin), "a later generation retires the old receipt")
		end)
	end)

	it("reset-one-click: automatically closes fresh input before completing the same request", function()
		with_collector(function(k, operations)
			local replies = {}
			k.on_keydown("a", 1000, "owned")
			helpers.assert_true(k.request_session_reset(function(success) replies[#replies + 1] = success end))
			k.on_keydown("b", 1100, "owned")
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(#operations, 1, "receipt pumping must not acquire fresh successor work")
			for _ = 1, 3 do helpers.assert_true(k.pump_flush()) end
			helpers.assert_eq(#operations, 1, "idle pumping leaves fresh dispatch to the periodic scheduler")
			assert_false(k.flush())
			helpers.assert_eq(#operations, 2, "the periodic dispatcher closes the same request without another click")
			helpers.assert_eq(#replies, 0)
			helpers.assert_eq(operations[2].payload.raw.typing[1].text, "b")
			operations[2].outcome, operations[2].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(replies, { true })
			helpers.assert_eq(k.get_app_stats().owned.keystrokes, 2)
			helpers.assert_eq(k.get_session_stats().keystrokes, 0)
		end)
	end)

	it("reset-one-click: a refused constructor completes false without altering its session", function()
		local admitted, writer = false, Fakes.sqlite_writer()
		with_collector(function(k)
			local now = math.floor(require("infra.monotonic").now_ms())
			k.on_keydown("a", now, "owned")
			local origin, replies, receipt = k.get_flush_status().generation, {}, nil
			helpers.assert_true(k.request_session_reset(function(success, completed)
				replies[#replies + 1], receipt = success, completed
			end))
			helpers.assert_eq(replies, { false })
			local _, success = k.reset_receipt_generation(receipt, origin)
			helpers.assert_eq(success, false)
			k.on_keydown("b", now + 100, "owned")
			admitted = true
			helpers.assert_true(k.flush())
			helpers.assert_eq(#writer.session_events, 1, "a refused request cannot close its original session")
			helpers.assert_eq(writer.typing[1].row.text, "ab")
		end, function(_, device, payload)
			if not admitted then return nil end
			return writer.start_flush(device, payload)
		end)
	end)
end)

helpers.describe("one-click rendered reset with native SQLite", function()
	it("reset-one-click-native: one menu action finishes after COMMIT without a refusal ERROR", function()
		local database = os.tmpname()
		os.remove(database)
		local native = require("tests.support.keystats_native_fixture")
		local logger, i18n = require("logger.shim"), require("infra.i18n")
		local previous_info, previous_error = logger.info, logger.error
		local startup = "ui.menu.start_at_login"
		local previous_startup = package.loaded[startup]
		local successes, refusals = 0, 0
		logger.info = function(tag, message, ...)
			if message == "Metrics session reset." then successes = successes + 1 end
			return previous_info(tag, message, ...)
		end
		logger.error = function(tag, message, ...)
			if message == "Metrics session reset was refused; the session is unchanged." then refusals = refusals + 1 end
			return previous_error(tag, message, ...)
		end
		package.loaded[startup] = { command_available = function() return false end, enabled = function() return false end }
		local ok, err = pcall(function()
			native.with(function(k)
				k.init({ sqlite_path = database })
				require("tests.support.metrics_consent_fixture").enable(k)
				k.on_keydown("a", math.floor(require("infra.monotonic").now_ms()), "owned")
				local menu = helpers.load_module("ui.menu.menu_builder").build({ keystats = k })
				local reset
				for _, parent in ipairs(menu) do
					if parent.title == i18n.get("menu.metrics.title") then
						for _, row in ipairs(parent.menu or {}) do
							if row.title == i18n.get("menu.metrics.reset_session") then reset = row end
						end
					end
				end
				helpers.assert_true(reset ~= nil and type(reset.fn) == "function")
				helpers.assert_true(reset.fn(), "one rendered click accepts its healthy native operation")
				helpers.assert_eq(successes, 0)
				helpers.assert_eq(refusals, 0)
				helpers.assert_eq(k.get_session_stats().keystrokes, 1, "no live reset before its actual COMMIT")
				native.flush(k)
				helpers.assert_eq(k.get_session_stats().keystrokes, 0)
				helpers.assert_eq(successes, 1)
				helpers.assert_eq(refusals, 0)
				helpers.assert_eq(require("modules.keystats.sqlite_writer").query_rows("SELECT COUNT(*) FROM events_typing;"), { "1" })
			end)
		end)
		logger.info, logger.error, package.loaded[startup] = previous_info, previous_error, previous_startup
		os.remove(database)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("owned reset bridge completion", function()
	for _, mode in ipairs({ "current", "closed", "replacement", "forged", "rebound", "duplicate" }) do
		it("reset-owned-page: " .. mode .. " keeps its exact source and document receipt", function()
			with_collector(function(k, operations)
				local bridge = helpers.load_module("ui.metrics_apps.bridge")
				bridge._reset()
				local epoch, reads, pushed = 1, 0, {}
				k.get_dashboard_payload = function()
					reads = reads + 1
					return { metrics_manifest = { witness = 17 }, app_icons = {}, _prefetch_data = {}, driver_meta = { os = "linux" } }
				end
				if mode == "forged" or mode == "duplicate" then
					local start = k.request_session_reset
					k.request_session_reset = function(complete)
						return start(function(success, receipt)
							if mode == "forged" then complete(success, { generation = k.get_flush_status().generation })
							else complete(success, receipt); complete(success, receipt) end
						end)
					end
				end
				local state = { keystats = k, webview_manager = {
					page_current = function(app, owner) return app == "metrics_apps" and owner == epoch end,
				} }
				bridge._push = function(reply) pushed[#pushed + 1] = reply; return true end
				k.on_keydown("a", 1000, "owned")
				local generation = k.get_flush_status().generation
				helpers.assert_nil(bridge.on_message({ action = "reset" }, state, { app_name = "metrics_apps", epoch = 1 }))
				helpers.assert_eq(reads, 0)
				helpers.assert_eq(#pushed, 0)
				if mode == "closed" then bridge.on_window_closed(1); epoch = 2 end
				if mode == "replacement" then state.keystats = {} end
				if mode == "rebound" then k.reset_receipt_generation = function() error("replacement verifier must not run") end end
				operations[1].outcome, operations[1].physical = "commit", true
				helpers.assert_true(k.pump_flush())
				helpers.assert_eq(k.get_session_stats().keystrokes, 0, "the admitted business request finishes independently of page publication")
				helpers.assert_eq(k.get_flush_status().generation, generation + 2)
				local expected = (mode == "current" or mode == "duplicate") and 1 or 0
				helpers.assert_eq(#pushed, expected)
				helpers.assert_eq(reads, expected, "invalid ownership cannot even read a replacement page's payload")
				if expected == 1 then
					helpers.assert_eq(pushed[1].reset, true)
					helpers.assert_eq(pushed[1].metrics_manifest.witness, 17)
				end
				bridge._reset()
			end)
		end)
	end
end)

helpers.describe("owned reset native bridge", function()
	it("reset-one-click-native: the real async writer sends one complete page reply", function()
		local database = os.tmpname()
		os.remove(database)
		local native = require("tests.support.keystats_native_fixture")
		local ok, err = pcall(function()
			native.with(function(k)
				k.init({ sqlite_path = database })
				require("tests.support.metrics_consent_fixture").enable(k)
				k.on_keydown("a", math.floor(require("infra.monotonic").now_ms()), "owned")
				local bridge = helpers.load_module("ui.metrics_apps.bridge")
				bridge._reset()
				local pushed = {}
				bridge._push = function(reply) pushed[#pushed + 1] = reply; return true end
				local state = { keystats = k, webview_manager = { page_current = function(app, epoch)
					return app == "metrics_apps" and epoch == 1
				end } }
				helpers.assert_nil(bridge.on_message({ action = "reset" }, state, { app_name = "metrics_apps", epoch = 1 }))
				helpers.assert_eq(#pushed, 0)
				native.flush(k)
				helpers.assert_eq(#pushed, 1)
				helpers.assert_eq(pushed[1].reset, true)
				helpers.assert_eq(pushed[1].metrics_manifest[os.date("%Y-%m-%d")].owned.chars, 1)
				helpers.assert_eq(k.get_session_stats().keystrokes, 0)
				bridge._reset()
			end)
		end)
		os.remove(database)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("owned reset admission and shutdown", function()
	it("reset-one-click: pre-existing debt refuses without a hidden continuation", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			assert_false(k.flush())
			local callbacks = 0
			assert_false(k.request_session_reset(function() callbacks = callbacks + 1 end))
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.pump_flush())
			helpers.assert_eq(callbacks, 0)
			helpers.assert_eq(k.get_session_stats().keystrokes, 1, "an unrelated COMMIT cannot finish a refused request")
		end)
	end)

	it("reset-one-click: shutdown cancels its callback once without a success receipt", function()
		with_collector(function(k, operations)
			k.on_keydown("a", 1000, "owned")
			local origin, replies, receipt = k.get_flush_status().generation, {}, nil
			helpers.assert_true(k.request_session_reset(function(success, completed)
				replies[#replies + 1], receipt = success, completed
			end))
			assert_false(k.stop())
			helpers.assert_eq(replies, { false })
			helpers.assert_nil(k.reset_receipt_generation(receipt, origin), "a stopping collector cannot authorize a page reply")
			operations[1].outcome, operations[1].physical = "commit", true
			helpers.assert_true(k.stop())
			helpers.assert_eq(replies, { false })
		end)
	end)
end)

helpers.describe("native sampled reset acknowledgement", function()
	it("reset-sampled-native-ack: consumes the exact committed reset source once", function()
		local quote = require("text_utils").shell_quote
		local root = helpers.driver_root()
		local fixture = root .. "/tests/hardware/run_keystats_reset_ack.lua"
		local status = os.execute("env -u LUA_PATH -u LUA_CPATH luajit " .. quote(fixture) .. " " .. quote(root))
		helpers.assert_true(status == true or status == 0, "actual sampled reset must finish once after COMMIT and cleanup")
	end)
end)

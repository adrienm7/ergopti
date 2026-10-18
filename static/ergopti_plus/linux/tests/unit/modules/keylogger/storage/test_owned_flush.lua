--- tests/unit/modules/keylogger/storage/test_owned_flush.lua

--- Logical ownership regressions. Native SQLite/pipe/process receipts are covered
--- by run_sqlite_owned_flush_receipts.lua; these ports deliberately stage ACKs.
local helpers = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it
local Fakes = require("tests.fakes")
local function assert_false(value) helpers.assert_eq(value, false) end
require("infra.monotonic") -- Load the genuine clock before temporary native ports.

local function with_collector(body, launch)
	local writer_name, keylogger_name = "modules.keylogger.sqlite_writer", "modules.keylogger.keylogger"
	local old_writer, old_keylogger = package.loaded[writer_name], package.loaded[keylogger_name]
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
	package.loaded[writer_name], package.loaded[keylogger_name] = writer, nil
	local ok, err = xpcall(function()
		collector = require(keylogger_name)
		collector.init({ sqlite_path = "/tmp/owned-flush-logical.sqlite" })
		require("tests.support.metrics_consent_fixture").enable(collector)
		body(collector, operations, writer)
	end, debug.traceback)
	package.loaded[writer_name], package.loaded[keylogger_name] = old_writer, old_keylogger
	if not ok then error(err, 0) end
end

helpers.describe("owned SQLite collector flush", function()
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
		local name = "modules.keylogger.sqlite_reader"
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
		with_collector(function(k)
			local generation = k.get_flush_status().generation
			k.on_keydown("a", 1000, "owned")
			helpers.assert_true(k.reset_session())
			helpers.assert_true(k.get_flush_status().generation > generation)
			helpers.assert_eq(k._pending_buffer_count_for_test(), 0)
		end)
	end)
end)
